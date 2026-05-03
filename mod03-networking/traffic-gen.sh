#!/usr/bin/env bash
# Module 3 — Generate traffic in demo-net-vpc so VPC Flow Logs have records to inspect.
#
# Launches a t3.micro in a private subnet (egress via NAT GW), uses SSM to:
#   1. curl https://example.com a few times   -> outbound 443
#   2. dig aws.amazon.com                     -> DNS
#   3. ping a public DNS (will fail, ICMP rejected) but still logs flow
#
# Cleanup: pass `down` to terminate the instance.
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-net-vpc
NAME=demo-net-traffic-gen
ROLE=demo-net-traffic-gen-role
PROFILE=demo-net-traffic-gen-profile

cmd="${1:-up}"

vpc_outputs() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
    --query 'Stacks[0].Outputs' --output json
}

up() {
  OUT=$(vpc_outputs)
  VPC=$(echo "$OUT" | python3 -c "import sys,json; o=json.load(sys.stdin); print([x['OutputValue'] for x in o if x['OutputKey']=='VpcId'][0])")
  SUBNET=$(echo "$OUT" | python3 -c "import sys,json; o=json.load(sys.stdin); print([x['OutputValue'] for x in o if x['OutputKey']=='PrivateA'][0])")
  echo "VPC:    $VPC"
  echo "Subnet: $SUBNET (private — egress via NAT GW)"

  AMI=$(aws ssm get-parameter --region "$REGION" \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query Parameter.Value --output text)

  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    2>/dev/null || true
  aws iam attach-role-policy --role-name "$ROLE" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam create-instance-profile --instance-profile-name "$PROFILE" 2>/dev/null || true
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE" 2>/dev/null || true
  sleep 8

  SG=$(aws ec2 create-security-group --region "$REGION" \
        --group-name "$NAME-sg" --description "traffic gen" --vpc-id "$VPC" \
        --query 'GroupId' --output text 2>/dev/null \
        || aws ec2 describe-security-groups --region "$REGION" \
            --filters "Name=group-name,Values=$NAME-sg" "Name=vpc-id,Values=$VPC" \
            --query 'SecurityGroups[0].GroupId' --output text)
  echo "SG:     $SG"

  IID=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI" --instance-type t3.micro \
    --iam-instance-profile Name="$PROFILE" \
    --subnet-id "$SUBNET" --security-group-ids "$SG" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
    --query 'Instances[0].InstanceId' --output text)
  echo "EC2:    $IID — waiting ~90s for SSM agent registration…"
  sleep 90

  echo
  echo "== Generating traffic via SSM =="
  CID=$(aws ssm send-command --region "$REGION" --instance-ids "$IID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=[
      "for i in $(seq 1 10); do curl -s -o /dev/null -w \"GET example.com -> %{http_code}\\n\" https://example.com; done",
      "for h in aws.amazon.com www.google.com github.com; do dig +short $h | head -1; done",
      "ping -c 3 -W 2 1.1.1.1 || true"
    ]' --query 'Command.CommandId' --output text)
  echo "Command: $CID  (sleeping 12s)"
  sleep 12
  aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CID" --instance-id "$IID" \
    --query '{Status:Status,Out:StandardOutputContent}' --output text || true

  echo
  echo "Flow log records typically appear within 1–5 minutes."
  echo "Tail with:"
  echo "  aws logs tail /demo/vpc/flowlogs --region $REGION --since 5m --follow"
  echo
  echo "When done, run: $0 down"
}

down() {
  IID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=running,pending,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  if [[ -n "$IID" ]]; then
    aws ec2 terminate-instances --region "$REGION" --instance-ids $IID
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids $IID
  fi
  SG=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=group-name,Values=$NAME-sg" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
  [[ -n "$SG" && "$SG" != "None" ]] && aws ec2 delete-security-group --region "$REGION" --group-id "$SG" || true

  aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$PROFILE" 2>/dev/null || true
  aws iam detach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
  echo "Traffic generator removed."
}

case "$cmd" in
  up)   up ;;
  down) down ;;
  *) echo "usage: $0 up|down" >&2; exit 2 ;;
esac
