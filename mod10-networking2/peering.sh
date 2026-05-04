#!/usr/bin/env bash
# Module 10 — AWS VPC <-> Azure VNet site-to-site IPsec VPN.
#
# Self-contained: this script + the sibling vpc-template.yaml / hybrid-ssm.sh /
# azure-vm.sh in mod10 are everything needed to run the cross-cloud peering demo
# end-to-end. No files outside mod10 are referenced.
#
# There is no native VPC<->VNet peering. The standard hybrid pattern is a
# route-based IPsec tunnel between AWS VPN Gateway and Azure VPN Gateway
# with static routes on both sides.
#
# Topology:
#
#   AWS demo-net2-vpc (10.30.0.0/16)             Azure demo-net2-hybrid-vnet (10.40.0.0/16)
#       Vgw + CGW + VpnConnection      <===IPsec===>      VirtualNetworkGateway + Connection
#       (private RT route 10.40/16  ->Vgw)                (route 10.30/16 propagated by VNG)
#
# What this script does:
#   1. Auto-bootstraps the AWS VPC stack 'demo-net2-vpc' from ./vpc-template.yaml if
#      not already deployed.
#   2. Creates an Azure VPN Gateway (RouteBased, VpnGw1) — ~30-45 min provisioning.
#      Re-uses the RG/VNet from ./azure-vm.sh if present; otherwise creates them.
#   3. Creates AWS VPN Gateway + Customer Gateway + Site-to-Site VPN Connection
#      (static routing, remote=10.40.0.0/16) and wires routes into the private RT.
#   4. Creates Azure Local Network Gateway + Connection using the AWS-generated PSK.
#   5. Switches the SSM hybrid activation tier to 'advanced' so an mi-* (Azure VM)
#      registered via ./hybrid-ssm.sh + ./azure-vm.sh can be reached with Session
#      Manager. cleanup resets it back to 'standard'.
#
# Prereqs:
#   - az + aws logged in.
#   - For the optional `./peering.sh test` ping subcommand, also run
#       ./hybrid-ssm.sh deploy && ACT_CODE=... ./azure-vm.sh deploy
#     (both are sibling scripts in mod10).
#
# Usage:
#   ./peering.sh deploy
#   ./peering.sh status
#   ./peering.sh test       # run ping over the tunnel from the EC2 jump host
#   ./peering.sh cleanup
#
# Cost (per hour, us-east-1 / eastus):
#   Azure VirtualNetworkGateway VpnGw1   ~ $0.19
#   AWS VPN Connection                   ~ $0.05
#   + a few cents of egress for keepalives
# Tear down promptly.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
AZ_LOCATION="${AZ_LOCATION:-eastus}"
STACK=demo-net2-vpc
AZ_RG="${AZ_RG:-demo-net2-hybrid-rg}"
AZ_VNET="${AZ_VNET:-demo-net2-hybrid-vnet}"
AZ_VPN_GW="${AZ_VPN_GW:-demo-net2-azure-vpngw}"
AZ_VPN_PIP="${AZ_VPN_PIP:-demo-net2-azure-vpngw-pip}"
AZ_LNG="${AZ_LNG:-demo-net2-aws-lng}"          # Local Network Gateway = "AWS, as seen from Azure"
AZ_CONN="${AZ_CONN:-demo-net2-azure-to-aws}"
AZ_VM="${AZ_VM:-demo-net2-azure-vm}"
AZ_NSG="${AZ_NSG:-demo-net2-hybrid-nsg}"
AWS_REMOTE_CIDR=10.40.0.0/16                  # Azure VNet
AZ_REMOTE_CIDR=10.30.0.0/16                   # AWS VPC
ACTIVATION_DESC="demo-net2-hybrid-azure"      # used by tier-toggle book-keeping

cmd="${1:-deploy}"
require() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }

# Local VPC template (mod10 self-contained — no cross-module references).
VPC_TEMPLATE="$(cd "$(dirname "$0")" && pwd)/vpc-template.yaml"

tier_setting_id() {
  local acct
  acct=$(aws sts get-caller-identity --query Account --output text)
  echo "arn:aws:ssm:${AWS_REGION}:${acct}:servicesetting/ssm/managed-instance/activation-tier"
}

set_activation_tier() {
  # $1 = standard|advanced
  local sid; sid=$(tier_setting_id)
  local current
  current=$(aws ssm get-service-setting --region "$AWS_REGION" --setting-id "$sid" \
              --query 'ServiceSetting.SettingValue' --output text 2>/dev/null || echo standard)
  if [[ "$current" == "$1" ]]; then
    echo "Activation tier already '$1'."
  else
    echo "Switching activation tier: $current -> $1"
    aws ssm update-service-setting --region "$AWS_REGION" --setting-id "$sid" --setting-value "$1"
  fi
}

vpc_id()        { aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK" \
                    --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' --output text 2>/dev/null; }
priv_rt_id() {
  local v; v=$(vpc_id)
  aws ec2 describe-route-tables --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$v" "Name=tag:Name,Values=*" \
    --query 'RouteTables[?Routes[?NatGatewayId!=null]].RouteTableId | [0]' --output text
}

ensure_vpc() {
  if aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK" \
       --query 'Stacks[0].StackStatus' --output text >/dev/null 2>&1; then
    return 0
  fi
  echo "== Bootstrapping VPC stack '$STACK' from $VPC_TEMPLATE =="
  [[ -f "$VPC_TEMPLATE" ]] || { echo "missing template: $VPC_TEMPLATE" >&2; exit 1; }
  aws cloudformation deploy --region "$AWS_REGION" \
    --stack-name "$STACK" --template-file "$VPC_TEMPLATE" \
    --capabilities CAPABILITY_IAM
}

deploy() {
  require aws; require az
  ensure_vpc
  # advanced-instances tier so Session Manager works to mi-* (Azure VM via hybrid-ssm.sh).
  set_activation_tier advanced
  VPC=$(vpc_id); echo "AWS VPC: $VPC"

  # --------- 1. Azure: ensure RG/VNet, add GatewaySubnet, create VPN GW ---------
  if ! az group show -n "$AZ_RG" -o none 2>/dev/null; then
    echo "== Creating Azure RG/VNet =="
    az group create -n "$AZ_RG" -l "$AZ_LOCATION" -o none
    az network vnet create -g "$AZ_RG" -n "$AZ_VNET" \
      --address-prefix 10.40.0.0/16 --subnet-name default --subnet-prefix 10.40.1.0/24 -o none
  fi
  # GatewaySubnet is required, must be exactly named "GatewaySubnet"
  az network vnet subnet show -g "$AZ_RG" --vnet-name "$AZ_VNET" -n GatewaySubnet -o none 2>/dev/null \
    || az network vnet subnet create -g "$AZ_RG" --vnet-name "$AZ_VNET" \
         -n GatewaySubnet --address-prefix 10.40.255.0/27 -o none

  echo "== Creating Azure public IP for VPN GW =="
  az network public-ip show -g "$AZ_RG" -n "$AZ_VPN_PIP" -o none 2>/dev/null \
    || az network public-ip create -g "$AZ_RG" -n "$AZ_VPN_PIP" \
         --allocation-method Static --sku Standard -o none

  echo "== Creating Azure VPN Gateway ($AZ_VPN_GW) — this takes ~30-45 minutes =="
  if ! az network vnet-gateway show -g "$AZ_RG" -n "$AZ_VPN_GW" -o none 2>/dev/null; then
    az network vnet-gateway create -g "$AZ_RG" -n "$AZ_VPN_GW" \
      --vnet "$AZ_VNET" --public-ip-addresses "$AZ_VPN_PIP" \
      --gateway-type Vpn --vpn-type RouteBased --sku VpnGw1 \
      --no-wait
    echo "    (running async — polling)"
  fi
  while true; do
    state=$(az network vnet-gateway show -g "$AZ_RG" -n "$AZ_VPN_GW" --query 'provisioningState' -o tsv 2>/dev/null || echo "Pending")
    [[ "$state" == "Succeeded" ]] && break
    [[ "$state" == "Failed" ]] && { echo "Azure VPN GW provisioning failed"; exit 1; }
    printf "."; sleep 30
  done
  echo
  AZ_VPN_IP=$(az network public-ip show -g "$AZ_RG" -n "$AZ_VPN_PIP" --query ipAddress -o tsv)
  echo "Azure VPN GW public IP: $AZ_VPN_IP"

  # --------- 2. AWS: VGW + CGW + VPN Connection ---------
  echo "== Creating AWS VPN Gateway =="
  VGW=$(aws ec2 describe-vpn-gateways --region "$AWS_REGION" \
          --filters "Name=tag:Name,Values=demo-net2-vgw" "Name=state,Values=available" \
          --query 'VpnGateways[0].VpnGatewayId' --output text)
  if [[ "$VGW" == "None" || -z "$VGW" ]]; then
    VGW=$(aws ec2 create-vpn-gateway --region "$AWS_REGION" --type ipsec.1 \
            --tag-specifications 'ResourceType=vpn-gateway,Tags=[{Key=Name,Value=demo-net2-vgw}]' \
            --query 'VpnGateway.VpnGatewayId' --output text)
  fi
  echo "VGW: $VGW"

  ATTACHED=$(aws ec2 describe-vpn-gateways --region "$AWS_REGION" --vpn-gateway-ids "$VGW" \
              --query "VpnGateways[0].VpcAttachments[?VpcId=='$VPC'].State | [0]" --output text)
  if [[ "$ATTACHED" != "attached" ]]; then
    aws ec2 attach-vpn-gateway --region "$AWS_REGION" --vpc-id "$VPC" --vpn-gateway-id "$VGW" -o /dev/null || true
    aws ec2 wait vpn-gateway-attached --region "$AWS_REGION" --vpn-gateway-ids "$VGW" 2>/dev/null || sleep 15
  fi

  PRIV_RT=$(priv_rt_id); echo "Private RT: $PRIV_RT"
  aws ec2 enable-vgw-route-propagation --region "$AWS_REGION" \
    --route-table-id "$PRIV_RT" --gateway-id "$VGW" 2>/dev/null || true

  echo "== Creating AWS Customer Gateway (Azure VPN IP $AZ_VPN_IP) =="
  CGW=$(aws ec2 describe-customer-gateways --region "$AWS_REGION" \
          --filters "Name=tag:Name,Values=demo-net2-cgw-azure" "Name=state,Values=available" \
          --query 'CustomerGateways[0].CustomerGatewayId' --output text)
  if [[ "$CGW" == "None" || -z "$CGW" ]]; then
    CGW=$(aws ec2 create-customer-gateway --region "$AWS_REGION" \
            --type ipsec.1 --public-ip "$AZ_VPN_IP" --bgp-asn 65000 \
            --tag-specifications 'ResourceType=customer-gateway,Tags=[{Key=Name,Value=demo-net2-cgw-azure}]' \
            --query 'CustomerGateway.CustomerGatewayId' --output text)
  fi
  echo "CGW: $CGW"

  echo "== Creating AWS VPN Connection (static routing, remote $AWS_REMOTE_CIDR) =="
  VPN=$(aws ec2 describe-vpn-connections --region "$AWS_REGION" \
         --filters "Name=tag:Name,Values=demo-net2-vpn-azure" "Name=state,Values=available,pending" \
         --query 'VpnConnections[0].VpnConnectionId' --output text)
  if [[ "$VPN" == "None" || -z "$VPN" ]]; then
    VPN=$(aws ec2 create-vpn-connection --region "$AWS_REGION" \
           --customer-gateway-id "$CGW" --vpn-gateway-id "$VGW" --type ipsec.1 \
           --options 'StaticRoutesOnly=true' \
           --tag-specifications 'ResourceType=vpn-connection,Tags=[{Key=Name,Value=demo-net2-vpn-azure}]' \
           --query 'VpnConnection.VpnConnectionId' --output text)
  fi
  echo "VPN: $VPN — waiting available…"
  aws ec2 wait vpn-connection-available --region "$AWS_REGION" --vpn-connection-ids "$VPN"

  aws ec2 create-vpn-connection-route --region "$AWS_REGION" \
    --vpn-connection-id "$VPN" --destination-cidr-block "$AWS_REMOTE_CIDR" 2>/dev/null || true
  aws ec2 create-route --region "$AWS_REGION" \
    --route-table-id "$PRIV_RT" --destination-cidr-block "$AWS_REMOTE_CIDR" \
    --gateway-id "$VGW" 2>/dev/null || true

  # Extract tunnel-1 outside IP + PSK from the AWS connection
  T1_IP=$(aws ec2 describe-vpn-connections --region "$AWS_REGION" --vpn-connection-ids "$VPN" \
           --query 'VpnConnections[0].Options.TunnelOptions[0].OutsideIpAddress' --output text)
  T1_PSK=$(aws ec2 describe-vpn-connections --region "$AWS_REGION" --vpn-connection-ids "$VPN" \
           --query 'VpnConnections[0].Options.TunnelOptions[0].PreSharedKey' --output text)
  echo "AWS tunnel-1 outside IP: $T1_IP"

  # --------- 3. Azure: Local Network Gateway + Connection ---------
  echo "== Creating Azure Local Network Gateway (points at AWS tunnel) =="
  if ! az network local-gateway show -g "$AZ_RG" -n "$AZ_LNG" -o none 2>/dev/null; then
    az network local-gateway create -g "$AZ_RG" -n "$AZ_LNG" \
      --gateway-ip-address "$T1_IP" \
      --local-address-prefixes "$AZ_REMOTE_CIDR" -o none
  else
    az network local-gateway update -g "$AZ_RG" -n "$AZ_LNG" \
      --set gatewayIpAddress="$T1_IP" -o none
  fi

  echo "== Creating Azure Connection (IPsec, PSK from AWS) =="
  if ! az network vpn-connection show -g "$AZ_RG" -n "$AZ_CONN" -o none 2>/dev/null; then
    az network vpn-connection create -g "$AZ_RG" -n "$AZ_CONN" \
      --vnet-gateway1 "$AZ_VPN_GW" --local-gateway2 "$AZ_LNG" \
      --shared-key "$T1_PSK" -o none
  else
    az network vpn-connection shared-key update -g "$AZ_RG" \
      --connection-name "$AZ_CONN" --value "$T1_PSK" -o none
  fi

  echo
  echo "Waiting for tunnel to come UP (up to 5 min)…"
  for i in $(seq 1 30); do
    state=$(aws ec2 describe-vpn-connections --region "$AWS_REGION" --vpn-connection-ids "$VPN" \
             --query 'VpnConnections[0].VgwTelemetry[0].Status' --output text 2>/dev/null || echo "DOWN")
    [[ "$state" == "UP" ]] && break
    printf "."; sleep 10
  done
  echo
  status
}

status() {
  require aws; require az
  echo "== AWS VPN Connection telemetry =="
  aws ec2 describe-vpn-connections --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=demo-net2-vpn-azure" \
    --query 'VpnConnections[0].VgwTelemetry[*].[OutsideIpAddress,Status,LastStatusChange,StatusMessage]' \
    --output table 2>/dev/null || true
  echo
  echo "== AWS private route table (should have $AWS_REMOTE_CIDR -> vgw) =="
  PRIV_RT=$(priv_rt_id)
  aws ec2 describe-route-tables --region "$AWS_REGION" --route-table-ids "$PRIV_RT" \
    --query 'RouteTables[0].Routes[*].[DestinationCidrBlock,GatewayId,NatGatewayId,State]' --output table
  echo
  echo "== Azure connection status =="
  az network vpn-connection show -g "$AZ_RG" -n "$AZ_CONN" \
    --query '{name:name,status:connectionStatus,bytesIn:ingressBytesTransferred,bytesOut:egressBytesTransferred}' \
    -o table 2>/dev/null || echo "  (not created yet)"
}

test_ping() {
  require aws
  EC2=$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=demo-net2-hybrid-jump" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
  [[ -z "$EC2" || "$EC2" == "None" ]] && { echo "EC2 jump host not found — run ./hybrid-ssm.sh deploy first"; exit 1; }

  AZ_VM_IP=$(az vm show -g "$AZ_RG" -n "$AZ_VM" -d \
              --query privateIps -o tsv 2>/dev/null || true)
  [[ -z "$AZ_VM_IP" ]] && { echo "Azure VM not found — run ./azure-vm.sh deploy first"; exit 1; }
  echo "Azure VM private IP: $AZ_VM_IP"

  echo "== Ping over VPN from EC2 ($EC2) -> Azure VM ($AZ_VM_IP) =="
  CID=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$EC2" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"ping -c 4 -W 2 $AZ_VM_IP || true\",\"traceroute -n -w 1 -m 6 $AZ_VM_IP || true\"]" \
    --query 'Command.CommandId' --output text)
  sleep 10
  aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$CID" --instance-id "$EC2" \
    --query '{Status:Status,Out:StandardOutputContent}' --output text
  echo
  echo "Note: the Azure VM's NSG must allow ICMP in from $AZ_REMOTE_CIDR for ping to succeed."
  echo "      Add rule:  az network nsg rule create -g $AZ_RG --nsg-name $AZ_NSG \\"
  echo "                   -n allow-aws-icmp --priority 200 --source-address-prefixes $AZ_REMOTE_CIDR \\"
  echo "                   --protocol Icmp --access Allow --direction Inbound"
}

cleanup() {
  require aws; require az
  echo "== Azure: connection + LNG =="
  az network vpn-connection delete -g "$AZ_RG" -n "$AZ_CONN" 2>/dev/null || true
  az network local-gateway delete  -g "$AZ_RG" -n "$AZ_LNG"  2>/dev/null || true

  echo "== AWS: VPN connection + routes =="
  VPN=$(aws ec2 describe-vpn-connections --region "$AWS_REGION" \
         --filters "Name=tag:Name,Values=demo-net2-vpn-azure" "Name=state,Values=available,pending" \
         --query 'VpnConnections[0].VpnConnectionId' --output text 2>/dev/null || true)
  if [[ -n "$VPN" && "$VPN" != "None" ]]; then
    aws ec2 delete-vpn-connection --region "$AWS_REGION" --vpn-connection-id "$VPN" || true
  fi

  CGW=$(aws ec2 describe-customer-gateways --region "$AWS_REGION" \
         --filters "Name=tag:Name,Values=demo-net2-cgw-azure" "Name=state,Values=available" \
         --query 'CustomerGateways[0].CustomerGatewayId' --output text 2>/dev/null || true)
  [[ -n "$CGW" && "$CGW" != "None" ]] && \
    aws ec2 delete-customer-gateway --region "$AWS_REGION" --customer-gateway-id "$CGW" || true

  VGW=$(aws ec2 describe-vpn-gateways --region "$AWS_REGION" \
         --filters "Name=tag:Name,Values=demo-net2-vgw" "Name=state,Values=available" \
         --query 'VpnGateways[0].VpnGatewayId' --output text 2>/dev/null || true)
  if [[ -n "$VGW" && "$VGW" != "None" ]]; then
    VPC=$(vpc_id 2>/dev/null || true)
    [[ -n "$VPC" && "$VPC" != "None" ]] && aws ec2 detach-vpn-gateway --region "$AWS_REGION" --vpc-id "$VPC" --vpn-gateway-id "$VGW" 2>/dev/null || true
    sleep 5
    aws ec2 delete-vpn-gateway --region "$AWS_REGION" --vpn-gateway-id "$VGW" || true
  fi

  # Remove the static private RT route if it's still pointing at a deleted VGW
  PRIV_RT=$(priv_rt_id 2>/dev/null || true)
  [[ -n "$PRIV_RT" && "$PRIV_RT" != "None" ]] && \
    aws ec2 delete-route --region "$AWS_REGION" --route-table-id "$PRIV_RT" \
      --destination-cidr-block "$AWS_REMOTE_CIDR" 2>/dev/null || true

  echo "== Azure: VPN GW + public IP =="
  az network vnet-gateway delete -g "$AZ_RG" -n "$AZ_VPN_GW" 2>/dev/null || true
  az network public-ip   delete  -g "$AZ_RG" -n "$AZ_VPN_PIP" 2>/dev/null || true

  echo "== Resetting SSM activation tier to standard =="
  set_activation_tier standard || true
  echo "Done. (Azure RG/VNet kept — used by ./azure-vm.sh)"
}

case "$cmd" in
  deploy)  deploy ;;
  status)  status ;;
  test)    test_ping ;;
  cleanup) cleanup ;;
  *) echo "usage: $0 deploy|status|test|cleanup" >&2; exit 2 ;;
esac
