#!/usr/bin/env bash
# Module 3 — Hybrid SSM demo: laptop -> SSM -> EC2 (in private subnet) -> SSM -> Azure VM.
#
# What this script does:
#   1. Creates an SSM hybrid activation (ActivationId / ActivationCode) used to register
#      the Azure VM as an AWS managed instance (mi-xxxx).
#   2. Launches an EC2 jump host in the demo-net-vpc private subnet with:
#        - AmazonSSMManagedInstanceCore  (so the laptop can `start-session` to it)
#        - inline policy granting `ssm:StartSession` on managed instances (mi-*)
#        - userdata that installs the AWS CLI v2 + session-manager-plugin
#      so that, once you SSH-via-SSM into it, you can hop to the Azure VM with
#      `aws ssm start-session --target mi-xxxx`.
#   3. Prints the exact registration commands to run on the Azure VM (Linux + Windows).
#
# Prereqs:
#   - demo-net-vpc stack already deployed (./deploy.sh)
#   - On laptop: aws cli + session-manager-plugin (https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
#   - Azure VM with outbound 443 to *.amazonaws.com (no inbound rules required)
#
# Usage:
#   ./hybrid-ssm.sh deploy     # create activation + EC2 jump host, print connect/register cmds
#   ./hybrid-ssm.sh status     # show registered hybrid managed instances + jump host
#   ./hybrid-ssm.sh cleanup    # tear down EC2, role, activation, deregister mi-*
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-net-vpc
NAME=demo-net-hybrid-jump
ROLE_EC2=demo-net-hybrid-ec2-role
PROFILE_EC2=demo-net-hybrid-ec2-profile
ROLE_HYBRID=demo-net-hybrid-activation-role     # role assumed by the on-prem/Azure VM
ACTIVATION_DESC="demo-net-hybrid-azure"

cmd="${1:-deploy}"

vpc_outputs() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
    --query 'Stacks[0].Outputs' --output json
}

ensure_hybrid_role() {
  # Role that the registered Azure VM will assume — gives it the SSM agent permissions.
  aws iam create-role --role-name "$ROLE_HYBRID" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ssm.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    2>/dev/null || true
  aws iam attach-role-policy --role-name "$ROLE_HYBRID" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
}

ensure_ec2_role() {
  aws iam create-role --role-name "$ROLE_EC2" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    2>/dev/null || true
  aws iam attach-role-policy --role-name "$ROLE_EC2" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  # Inline: allow this EC2 to start sessions to hybrid managed instances (mi-*).
  aws iam put-role-policy --role-name "$ROLE_EC2" \
    --policy-name HopToManagedInstances \
    --policy-document '{
      "Version":"2012-10-17",
      "Statement":[
        {"Effect":"Allow","Action":["ssm:DescribeInstanceInformation","ssm:DescribeSessions","ssm:GetConnectionStatus"],"Resource":"*"},
        {"Effect":"Allow","Action":["ssm:StartSession"],"Resource":["arn:aws:ssm:*:*:managed-instance/mi-*","arn:aws:ssm:*:*:document/AWS-StartSSHSession","arn:aws:ssm:*:*:document/SSM-SessionManagerRunShell"]},
        {"Effect":"Allow","Action":["ssm:TerminateSession","ssm:ResumeSession"],"Resource":"arn:aws:ssm:*:*:session/${aws:username}-*"}
      ]}'
  aws iam create-instance-profile --instance-profile-name "$PROFILE_EC2" 2>/dev/null || true
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_EC2" --role-name "$ROLE_EC2" 2>/dev/null || true
}

deploy() {
  OUT=$(vpc_outputs)
  VPC=$(echo "$OUT"    | python3 -c "import sys,json;o=json.load(sys.stdin);print([x['OutputValue'] for x in o if x['OutputKey']=='VpcId'][0])")
  SUBNET=$(echo "$OUT" | python3 -c "import sys,json;o=json.load(sys.stdin);print([x['OutputValue'] for x in o if x['OutputKey']=='PrivateA'][0])")
  echo "VPC:    $VPC"
  echo "Subnet: $SUBNET (private — egress via NAT GW)"

  ensure_hybrid_role
  ensure_ec2_role
  sleep 8  # IAM propagation

  # --- 1. SSM hybrid activation (single-use is fine; allow 5 registrations) ---
  echo
  echo "== Creating SSM hybrid activation =="
  ACT_JSON=$(aws ssm create-activation --region "$REGION" \
    --description "$ACTIVATION_DESC" \
    --iam-role "$ROLE_HYBRID" \
    --registration-limit 5 \
    --default-instance-name azure-vm \
    --output json)
  ACT_ID=$(echo "$ACT_JSON"   | python3 -c "import sys,json;print(json.load(sys.stdin)['ActivationId'])")
  ACT_CODE=$(echo "$ACT_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['ActivationCode'])")
  echo "ActivationId:   $ACT_ID"
  echo "ActivationCode: $ACT_CODE  (treat as a secret; expires in 24h)"

  # --- 2. EC2 jump host in private subnet ---
  AMI=$(aws ssm get-parameter --region "$REGION" \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query Parameter.Value --output text)

  SG=$(aws ec2 create-security-group --region "$REGION" \
        --group-name "$NAME-sg" --description "hybrid jump host" --vpc-id "$VPC" \
        --query 'GroupId' --output text 2>/dev/null \
        || aws ec2 describe-security-groups --region "$REGION" \
            --filters "Name=group-name,Values=$NAME-sg" "Name=vpc-id,Values=$VPC" \
            --query 'SecurityGroups[0].GroupId' --output text)
  echo "SG:     $SG  (egress-only; SSM is a reverse tunnel, no inbound needed)"

  # Userdata installs session-manager-plugin so the EC2 can start sessions outbound.
  USERDATA=$(cat <<'EOF'
#!/bin/bash
set -e
dnf -y install https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm || \
  yum  -y install https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm
EOF
)

  IID=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI" --instance-type t3.micro \
    --iam-instance-profile Name="$PROFILE_EC2" \
    --subnet-id "$SUBNET" --security-group-ids "$SG" \
    --user-data "$USERDATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
    --query 'Instances[0].InstanceId' --output text)
  echo "EC2:    $IID — waiting ~90s for SSM agent registration…"
  sleep 90

  cat <<EOF

============================================================
 Hybrid SSM demo is ready. Three hops:
============================================================

[ Hop 1 ]  Laptop  ->  EC2 jump host (Session Manager)
    aws ssm start-session --region $REGION --target $IID

[ Hop 2 ]  On the Azure VM, register it as an AWS managed instance.

  -- Linux (amd64) --
    mkdir -p /tmp/ssm && cd /tmp/ssm
    curl -L https://s3.$REGION.amazonaws.com/amazon-ssm-$REGION/latest/linux_amd64/amazon-ssm-agent.deb -o ssm.deb \\
      || curl -L https://s3.$REGION.amazonaws.com/amazon-ssm-$REGION/latest/linux_amd64/amazon-ssm-agent.rpm -o ssm.rpm
    sudo dpkg -i ssm.deb 2>/dev/null || sudo rpm -i ssm.rpm
    sudo service amazon-ssm-agent stop || true
    sudo amazon-ssm-agent -register -code "$ACT_CODE" -id "$ACT_ID" -region "$REGION"
    sudo service amazon-ssm-agent start

  -- Windows (PowerShell, admin) --
    \$code = "$ACT_CODE"; \$id = "$ACT_ID"; \$region = "$REGION"
    \$dir = "\$env:TEMP\\ssm"; mkdir \$dir -Force | Out-Null; cd \$dir
    Invoke-WebRequest "https://amazon-ssm-\$region.s3.\$region.amazonaws.com/latest/windows_amd64/AmazonSSMAgentSetup.exe" -OutFile setup.exe
    Start-Process .\\setup.exe -ArgumentList "/q","/log","install.log","CODE=\$code","ID=\$id","REGION=\$region" -Wait

  Verify from the laptop (it should show a 'mi-...' instance id):
    aws ssm describe-instance-information --region $REGION \\
      --query 'InstanceInformationList[*].[InstanceId,PingStatus,PlatformName,IPAddress]' --output table

[ Hop 3 ]  From inside the EC2 jump host, hop to the Azure VM:
    MI=\$(aws ssm describe-instance-information --region $REGION \\
            --query 'InstanceInformationList[?starts_with(InstanceId,\`mi-\`)]|[0].InstanceId' --output text)
    aws ssm start-session --region $REGION --target \$MI

When you are done:  ./hybrid-ssm.sh cleanup
EOF
}

status() {
  echo "== EC2 jump hosts =="
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].[InstanceId,State.Name,PrivateIpAddress]' --output table
  echo "== SSM managed instances (incl. hybrid mi-*) =="
  aws ssm describe-instance-information --region "$REGION" \
    --query 'InstanceInformationList[*].[InstanceId,PingStatus,PlatformName,IPAddress,ComputerName]' --output table
  echo "== Activations =="
  aws ssm describe-activations --region "$REGION" \
    --filters "FilterKey=Description,FilterValues=$ACTIVATION_DESC" \
    --query 'ActivationList[*].[ActivationId,RegistrationsCount,ExpirationDate,Expired]' --output table
}

cleanup() {
  echo "== Deregistering hybrid managed instances =="
  for MI in $(aws ssm describe-instance-information --region "$REGION" \
                --query 'InstanceInformationList[?starts_with(InstanceId, `mi-`)].InstanceId' --output text); do
    echo "  deregister $MI"
    aws ssm deregister-managed-instance --region "$REGION" --instance-id "$MI" || true
  done

  echo "== Deleting activations =="
  for AID in $(aws ssm describe-activations --region "$REGION" \
                 --filters "FilterKey=Description,FilterValues=$ACTIVATION_DESC" \
                 --query 'ActivationList[*].ActivationId' --output text); do
    aws ssm delete-activation --region "$REGION" --activation-id "$AID" || true
  done

  echo "== Terminating jump host =="
  IID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=running,pending,stopped,stopping" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  if [[ -n "$IID" ]]; then
    aws ec2 terminate-instances --region "$REGION" --instance-ids $IID
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids $IID
  fi

  SG=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=group-name,Values=$NAME-sg" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
  [[ -n "$SG" && "$SG" != "None" ]] && aws ec2 delete-security-group --region "$REGION" --group-id "$SG" || true

  echo "== IAM cleanup =="
  aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE_EC2" --role-name "$ROLE_EC2" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$PROFILE_EC2" 2>/dev/null || true
  aws iam delete-role-policy --role-name "$ROLE_EC2" --policy-name HopToManagedInstances 2>/dev/null || true
  aws iam detach-role-policy --role-name "$ROLE_EC2" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE_EC2" 2>/dev/null || true

  aws iam detach-role-policy --role-name "$ROLE_HYBRID" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE_HYBRID" 2>/dev/null || true
  echo "Done."
}

case "$cmd" in
  deploy)  deploy ;;
  status)  status ;;
  cleanup) cleanup ;;
  *) echo "usage: $0 deploy|status|cleanup" >&2; exit 2 ;;
esac
