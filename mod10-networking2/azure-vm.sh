#!/usr/bin/env bash
# Module 10 — Azure Linux VM that auto-registers as an AWS SSM hybrid managed instance.
# Self-contained mod10 copy (parallel to mod03's azure-vm.sh). Uses 'demo-net2-*' names
# so it can run alongside mod03's version without colliding.
#
# Prereqs:
#   - ./hybrid-ssm.sh deploy already run (creates the activation), OR pass ACT_ID/ACT_CODE.
#   - Azure CLI logged in.
#
# Usage:
#   ./azure-vm.sh deploy
#   ./azure-vm.sh status
#   ./azure-vm.sh cleanup
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
AZ_LOCATION="${AZ_LOCATION:-eastus}"
AZ_RG="${AZ_RG:-demo-net2-hybrid-rg}"
AZ_VM="${AZ_VM:-demo-net2-azure-vm}"
AZ_VNET="${AZ_VNET:-demo-net2-hybrid-vnet}"
AZ_SUBNET="${AZ_SUBNET:-default}"
AZ_NSG="${AZ_NSG:-demo-net2-hybrid-nsg}"
AZ_SIZE="${AZ_SIZE:-Standard_B1s}"
AZ_IMAGE="${AZ_IMAGE:-Ubuntu2204}"
AZ_USER="${AZ_USER:-azureuser}"
ACTIVATION_DESC="demo-net2-hybrid-azure"

cmd="${1:-deploy}"

require() { command -v "$1" >/dev/null || { echo "missing dependency: $1" >&2; exit 1; }; }

resolve_activation() {
  if [[ -n "${ACT_ID:-}" && -n "${ACT_CODE:-}" ]]; then
    echo "Using activation from env: $ACT_ID"
    return
  fi
  echo "Looking up most recent activation (Description=$ACTIVATION_DESC)…"
  ACT_JSON=$(aws ssm describe-activations --region "$AWS_REGION" \
    --query "ActivationList[?Description=='$ACTIVATION_DESC' && Expired==\`false\`] | sort_by(@,&CreatedDate) | [-1]" \
    --output json)
  if [[ -z "$ACT_JSON" || "$ACT_JSON" == "null" ]]; then
    cat >&2 <<EOF
No SSM activation found in $AWS_REGION with description '$ACTIVATION_DESC'.
Run ./hybrid-ssm.sh deploy first, or pass ACT_ID and ACT_CODE as env vars:
  ACT_ID=... ACT_CODE=... $0 deploy
EOF
    exit 1
  fi
  ACT_ID=$(echo "$ACT_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['ActivationId'])")
  EXPIRED=$(echo "$ACT_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['Expired'])")
  if [[ "$EXPIRED" == "True" ]]; then
    echo "Activation $ACT_ID is expired. Re-run ./hybrid-ssm.sh deploy." >&2
    exit 1
  fi
  if [[ -z "${ACT_CODE:-}" ]]; then
    cat >&2 <<EOF
Found ActivationId $ACT_ID but ActivationCode is not retrievable after creation.
Pass it explicitly (printed by ./hybrid-ssm.sh deploy):
  ACT_CODE=... $0 deploy
Or recreate:  ./hybrid-ssm.sh cleanup && ./hybrid-ssm.sh deploy
EOF
    exit 1
  fi
}

deploy() {
  require az; require aws; require python3

  resolve_activation
  echo "AWS region:      $AWS_REGION"
  echo "Azure location:  $AZ_LOCATION"
  echo "Activation:      $ACT_ID"

  echo
  echo "== Creating Azure resource group =="
  az group create -n "$AZ_RG" -l "$AZ_LOCATION" -o table

  echo
  echo "== Creating VNet/subnet/NSG (egress-only) =="
  # NOTE: peering.sh expects this same VNet (10.40.0.0/16) and adds a GatewaySubnet
  # to it. Order doesn't matter — whichever runs first creates the VNet.
  az network vnet show -g "$AZ_RG" -n "$AZ_VNET" -o none 2>/dev/null \
    || az network vnet create -g "$AZ_RG" -n "$AZ_VNET" \
         --address-prefix 10.40.0.0/16 \
         --subnet-name "$AZ_SUBNET" --subnet-prefix 10.40.1.0/24 -o none
  az network nsg show -g "$AZ_RG" -n "$AZ_NSG" -o none 2>/dev/null \
    || az network nsg create -g "$AZ_RG" -n "$AZ_NSG" -o none

  echo
  echo "== Rendering cloud-init (installs + registers SSM agent) =="
  CLOUD_INIT=$(mktemp)
  cat > "$CLOUD_INIT" <<EOF
#cloud-config
package_update: true
runcmd:
  - [ bash, -c, "set -e; cd /tmp && curl -fsSL https://s3.${AWS_REGION}.amazonaws.com/amazon-ssm-${AWS_REGION}/latest/debian_amd64/amazon-ssm-agent.deb -o ssm.deb && dpkg -i ssm.deb" ]
  - [ bash, -c, "systemctl stop amazon-ssm-agent || true" ]
  - [ bash, -c, "amazon-ssm-agent -register -code '${ACT_CODE}' -id '${ACT_ID}' -region '${AWS_REGION}' -y" ]
  - [ bash, -c, "systemctl enable --now amazon-ssm-agent" ]
EOF

  echo
  echo "== Creating VM ($AZ_VM, $AZ_SIZE, $AZ_IMAGE) =="
  az vm create \
    -g "$AZ_RG" -n "$AZ_VM" \
    --image "$AZ_IMAGE" \
    --size "$AZ_SIZE" \
    --admin-username "$AZ_USER" \
    --generate-ssh-keys \
    --vnet-name "$AZ_VNET" --subnet "$AZ_SUBNET" \
    --nsg "$AZ_NSG" \
    --public-ip-address "" \
    --custom-data "$CLOUD_INIT" \
    -o table
  rm -f "$CLOUD_INIT"

  echo
  echo "== Waiting for SSM hybrid registration (mi-…) — up to 5 min =="
  for i in $(seq 1 30); do
    MI=$(aws ssm describe-instance-information --region "$AWS_REGION" \
      --filters "Key=ActivationIds,Values=$ACT_ID" \
      --query 'InstanceInformationList[?starts_with(InstanceId,`mi-`)]|[0].InstanceId' \
      --output text 2>/dev/null || true)
    if [[ -n "$MI" && "$MI" != "None" ]]; then
      echo "Registered as: $MI"
      break
    fi
    printf "."; sleep 10
  done
  echo

  if [[ -z "${MI:-}" || "$MI" == "None" ]]; then
    echo "VM did not register within 5 min. Inspect cloud-init on the VM:" >&2
    echo "  az vm run-command invoke -g $AZ_RG -n $AZ_VM --command-id RunShellScript --scripts 'tail -n 100 /var/log/cloud-init-output.log; systemctl status amazon-ssm-agent --no-pager'" >&2
    exit 1
  fi

  cat <<EOF

============================================================
 Azure VM registered as AWS managed instance: $MI
============================================================

Test the chain (laptop -> EC2 -> Azure VM):

  EC2=\$(aws ec2 describe-instances --region $AWS_REGION \\
    --filters "Name=tag:Name,Values=demo-net2-hybrid-jump" "Name=instance-state-name,Values=running" \\
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
  aws ssm start-session --region $AWS_REGION --target \$EC2
  # then inside that shell:
  aws ssm start-session --region $AWS_REGION --target $MI

When done:  ./azure-vm.sh cleanup
EOF
}

status() {
  require az; require aws
  echo "== Azure VM =="
  az vm show -g "$AZ_RG" -n "$AZ_VM" -d \
    --query '{name:name,powerState:powerState,privateIp:privateIps,publicIp:publicIps}' \
    -o table 2>/dev/null || echo "  (not found)"
  echo
  echo "== AWS hybrid registration =="
  aws ssm describe-instance-information --region "$AWS_REGION" \
    --query 'InstanceInformationList[?starts_with(InstanceId,`mi-`)].[InstanceId,PingStatus,PlatformName,IPAddress,ComputerName]' \
    --output table
}

cleanup() {
  require az
  # Just delete the VM (and its NIC/disk/NSG associations) so the RG/VNet survive
  # for peering.sh. peering.sh's cleanup tears down VNet/RG.
  echo "== Deleting Azure VM $AZ_VM (keeps RG/VNet for peering.sh) =="
  az vm delete -g "$AZ_RG" -n "$AZ_VM" --yes 2>/dev/null || true
  # Best-effort NIC/disk cleanup
  for NIC in $(az network nic list -g "$AZ_RG" --query "[?contains(name,'${AZ_VM}')].name" -o tsv 2>/dev/null); do
    az network nic delete -g "$AZ_RG" -n "$NIC" 2>/dev/null || true
  done
  for DISK in $(az disk list -g "$AZ_RG" --query "[?contains(name,'${AZ_VM}')].name" -o tsv 2>/dev/null); do
    az disk delete -g "$AZ_RG" -n "$DISK" --yes 2>/dev/null || true
  done
  echo "Submitted. The hybrid 'mi-…' will go offline; remove it with ./hybrid-ssm.sh cleanup."
}

case "$cmd" in
  deploy)  deploy ;;
  status)  status ;;
  cleanup) cleanup ;;
  *) echo "usage: $0 deploy|status|cleanup" >&2; exit 2 ;;
esac
