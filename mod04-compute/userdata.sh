#!/usr/bin/env bash
# Module 4 Demo 2 — EC2 UserData bootstrap
# Launches an Amazon Linux 2023 instance whose UserData installs nginx and
# renders a page that proves the instance bootstrapped itself on first boot
# (no SSH, no manual config, no AMI baking).
#
# Demonstrates:
#   - cloud-init UserData (runs once, as root, on first boot)
#   - IMDSv2 metadata lookup from inside the instance
#   - Public web access via a security group + public subnet
#   - Bootstrap log location: /var/log/cloud-init-output.log
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
NAME=demo-compute-userdata
SG=demo-compute-userdata-sg
cmd=${1:-deploy}

deploy() {
  AMI=$(aws ssm get-parameter --region "$REGION" \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query Parameter.Value --output text)

  VPC=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' --output text)
  SUBNET="${SUBNET_ID:-$(aws ec2 describe-subnets --region "$REGION" \
    --filters Name=vpc-id,Values=$VPC Name=default-for-az,Values=true \
    --query 'Subnets[0].SubnetId' --output text)}"

  SGID=$(aws ec2 create-security-group --region "$REGION" \
    --group-name "$SG" --description "demo userdata web" --vpc-id "$VPC" \
    --query GroupId --output text 2>/dev/null \
    || aws ec2 describe-security-groups --region "$REGION" \
       --filters Name=group-name,Values="$SG" Name=vpc-id,Values=$VPC \
       --query 'SecurityGroups[0].GroupId' --output text)
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SGID" --protocol tcp --port 80 --cidr 0.0.0.0/0 2>/dev/null || true

  cat > /tmp/userdata.sh <<'EOF'
#!/bin/bash
# This script runs on first boot, as root, exactly once.
# Output goes to /var/log/cloud-init-output.log
set -eux
dnf install -y nginx
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
md() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
IID=$(md instance-id)
ITYPE=$(md instance-type)
AZ=$(md placement/availability-zone)
AMI=$(md ami-id)
cat > /usr/share/nginx/html/index.html <<HTML
<!doctype html><meta charset="utf-8"><title>UserData OK</title>
<style>body{font:16px system-ui;max-width:640px;margin:3rem auto;padding:0 1rem}
h1{color:#0a7}table{border-collapse:collapse;width:100%}
td,th{padding:.4rem .8rem;border-bottom:1px solid #ddd;text-align:left}</style>
<h1>UserData bootstrap succeeded</h1>
<p>This page was written by cloud-init on first boot.</p>
<table>
<tr><th>Instance ID</th><td>$IID</td></tr>
<tr><th>Instance type</th><td>$ITYPE</td></tr>
<tr><th>Availability Zone</th><td>$AZ</td></tr>
<tr><th>AMI</th><td>$AMI</td></tr>
<tr><th>Bootstrapped at</th><td>$(date -u)</td></tr>
</table>
HTML
systemctl enable --now nginx
EOF

  IID=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI" --instance-type t3.micro \
    --subnet-id "$SUBNET" --security-group-ids "$SGID" \
    --associate-public-ip-address \
    --user-data file:///tmp/userdata.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
    --query 'Instances[0].InstanceId' --output text)
  echo "Launched $IID. Waiting for public IP + bootstrap (~90s)..."
  aws ec2 wait instance-running --region "$REGION" --instance-ids "$IID"
  IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  echo
  echo "  Public IP : $IP"
  echo "  Browse to : http://$IP/"
  echo "  Bootstrap log (after SSM registers, ~90s):"
  echo "    aws ssm start-session --region $REGION --target $IID"
  echo "    sudo tail -f /var/log/cloud-init-output.log"
}

cleanup() {
  IID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$NAME" \
              "Name=instance-state-name,Values=running,pending,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  [[ -n "$IID" ]] && aws ec2 terminate-instances --region "$REGION" --instance-ids $IID >/dev/null || true
  [[ -n "$IID" ]] && aws ec2 wait instance-terminated --region "$REGION" --instance-ids $IID || true
  SGID=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters Name=group-name,Values="$SG" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
  [[ -n "$SGID" && "$SGID" != "None" ]] && aws ec2 delete-security-group --region "$REGION" --group-id "$SGID" || true
  rm -f /tmp/userdata.sh
  echo "Cleanup done."
}

case "$cmd" in
  deploy)  deploy ;;
  cleanup) cleanup ;;
  *) echo "usage: $0 deploy|cleanup" >&2; exit 2 ;;
esac
