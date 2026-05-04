#!/usr/bin/env bash
# Module 10 — Hybrid SSM jump host for the cross-cloud peering demo.
# Self-contained mod10 copy (parallel to mod03's hybrid-ssm.sh) — uses 'demo-net2-*'
# resource names so it can run alongside mod03's version without colliding.
#
# What this script does:
#   1. Creates an SSM hybrid activation (ActivationId / ActivationCode) used to register
#      the Azure VM as an AWS managed instance (mi-xxxx).
#   2. Launches an EC2 jump host in the demo-net2-vpc private subnet with:
#        - AmazonSSMManagedInstanceCore  (so the laptop can `start-session` to it)
#        - inline policy granting `ssm:StartSession` on managed instances (mi-*)
#        - userdata that installs the session-manager-plugin
#   3. Switches the SSM activation tier to 'advanced' (required for Session Manager
#      to hybrid mi-* instances). cleanup resets it back to 'standard'.
#   4. Prints registration commands for the Azure VM (or just run ./azure-vm.sh deploy).
#
# Prereqs:
#   - peering.sh deploy (or its ensure_vpc) has created stack 'demo-net2-vpc'
#   - On laptop: aws cli + session-manager-plugin
#
# Usage:
#   ./hybrid-ssm.sh deploy
#   ./hybrid-ssm.sh status
#   ./hybrid-ssm.sh cleanup
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-net2-vpc
NAME=demo-net2-hybrid-jump
ROLE_EC2=demo-net2-hybrid-ec2-role
PROFILE_EC2=demo-net2-hybrid-ec2-profile
ROLE_HYBRID=demo-net2-hybrid-activation-role
ACTIVATION_DESC="demo-net2-hybrid-azure"

cmd="${1:-deploy}"

vpc_outputs() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
    --query 'Stacks[0].Outputs' --output json
}

tier_setting_id() {
  local acct
  acct=$(aws sts get-caller-identity --query Account --output text)
  echo "arn:aws:ssm:${REGION}:${acct}:servicesetting/ssm/managed-instance/activation-tier"
}

set_activation_tier() {
  # $1 = standard|advanced
  local sid; sid=$(tier_setting_id)
  local current
  current=$(aws ssm get-service-setting --region "$REGION" --setting-id "$sid" \
              --query 'ServiceSetting.SettingValue' --output text 2>/dev/null || echo standard)
  if [[ "$current" == "$1" ]]; then
    echo "Activation tier already '$1'."
  else
    echo "Switching activation tier: $current -> $1"
    aws ssm update-service-setting --region "$REGION" --setting-id "$sid" --setting-value "$1"
  fi
}

ensure_hybrid_role() {
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
  # Session Manager to hybrid (mi-*) instances requires the advanced-instances tier
  # (~$0.00695/hour per managed instance). Reset in cleanup.
  set_activation_tier advanced
  sleep 8  # IAM propagation

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

  AMI=$(aws ssm get-parameter --region "$REGION" \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query Parameter.Value --output text)

  SG=$(aws ec2 create-security-group --region "$REGION" \
        --group-name "$NAME-sg" --description "hybrid jump host" --vpc-id "$VPC" \
        --query 'GroupId' --output text 2>/dev/null \
        || aws ec2 describe-security-groups --region "$REGION" \
            --filters "Name=group-name,Values=$NAME-sg" "Name=vpc-id,Values=$VPC" \
            --query 'SecurityGroups[0].GroupId' --output text)
  echo "SG:     $SG  (egress-only)"

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
 Hybrid SSM (mod10) ready. Three hops:
============================================================

[ Hop 1 ]  Laptop -> EC2 jump host:
    aws ssm start-session --region $REGION --target $IID

[ Hop 2 ]  Register the Azure VM as a managed instance.
           Easiest:
             ACT_CODE=$ACT_CODE ./azure-vm.sh deploy
           Or manually on any Linux box with outbound 443:
             curl -L https://s3.$REGION.amazonaws.com/amazon-ssm-$REGION/latest/linux_amd64/amazon-ssm-agent.deb -o /tmp/ssm.deb
             sudo dpkg -i /tmp/ssm.deb
             sudo service amazon-ssm-agent stop || true
             sudo amazon-ssm-agent -register -code "$ACT_CODE" -id "$ACT_ID" -region "$REGION"
             sudo service amazon-ssm-agent start

[ Hop 3 ]  From the EC2 jump host:
    MI=\$(aws ssm describe-instance-information --region $REGION \\
            --query 'InstanceInformationList[?starts_with(InstanceId,\`mi-\`)]|[0].InstanceId' --output text)
    aws ssm start-session --region $REGION --target \$MI

When done:  ./hybrid-ssm.sh cleanup
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
    --query "ActivationList[?Description=='$ACTIVATION_DESC'].[ActivationId,RegistrationsCount,ExpirationDate,Expired]" --output table
}

cleanup() {
  echo "== Deregistering hybrid managed instances (mod10 activations only) =="
  ACT_IDS=$(aws ssm describe-activations --region "$REGION" \
              --query "ActivationList[?Description=='$ACTIVATION_DESC'].ActivationId" --output text || true)
  for AID in $ACT_IDS; do
    for MI in $(aws ssm describe-instance-information --region "$REGION" \
                  --filters "Key=ActivationIds,Values=$AID" \
                  --query 'InstanceInformationList[?starts_with(InstanceId,`mi-`)].InstanceId' --output text); do
      echo "  deregister $MI"
      aws ssm deregister-managed-instance --region "$REGION" --instance-id "$MI" || true
    done
  done

  echo "== Deleting activations =="
  for AID in $ACT_IDS; do
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

  echo "== Resetting SSM activation tier to standard =="
  set_activation_tier standard || true
  echo "Done."
}

case "$cmd" in
  deploy)  deploy ;;
  status)  status ;;
  cleanup) cleanup ;;
  *) echo "usage: $0 deploy|status|cleanup" >&2; exit 2 ;;
esac
