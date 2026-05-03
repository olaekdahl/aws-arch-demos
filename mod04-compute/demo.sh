#!/usr/bin/env bash
# Module 4 Demo 1 — EC2 + SSM Session Manager
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
ROLE=demo-compute-ssm-role
PROFILE=demo-compute-ssm-profile
NAME=demo-compute-ec2

cmd=${1:-up}

up() {
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
  sleep 8  # propagation

  SUBNET="${SUBNET_ID:-$(aws ec2 describe-subnets --region "$REGION" \
    --filters Name=default-for-az,Values=true \
    --query 'Subnets[0].SubnetId' --output text)}"

  IID=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI" --instance-type t3.micro \
    --iam-instance-profile Name="$PROFILE" \
    --subnet-id "$SUBNET" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
    --query 'Instances[0].InstanceId' --output text)
  echo "Launched $IID — wait ~90s for SSM agent registration, then:"
  echo "  aws ssm start-session --region $REGION --target $IID"
}

down() {
  IID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=running,pending,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  [[ -n "$IID" ]] && aws ec2 terminate-instances --region "$REGION" --instance-ids $IID || true
  aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$PROFILE" 2>/dev/null || true
  aws iam detach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
  echo "Cleanup done."
}

case "$cmd" in
  up) up ;;
  down) down ;;
  *) echo "usage: $0 up|down" ;;
esac
