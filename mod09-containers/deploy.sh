#!/usr/bin/env bash
# Module 9 — Build/push image then deploy ECS Fargate stack.
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
ACCT=$(aws sts get-caller-identity --query Account --output text)
REPO=demo-ctr-app
STACK=demo-ctr-fargate

aws ecr describe-repositories --region "$REGION" --repository-names "$REPO" >/dev/null 2>&1 \
  || aws ecr create-repository --region "$REGION" --repository-name "$REPO"

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ACCT.dkr.ecr.$REGION.amazonaws.com"

docker build -t "$REPO" .
docker tag "$REPO:latest" "$ACCT.dkr.ecr.$REGION.amazonaws.com/$REPO:latest"
docker push "$ACCT.dkr.ecr.$REGION.amazonaws.com/$REPO:latest"

VPC=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC" \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')

aws cloudformation deploy --region "$REGION" \
  --stack-name "$STACK" \
  --template-file template.yaml \
  --parameter-overrides VpcId="$VPC" SubnetIds="$SUBNETS" \
    ImageUri="$ACCT.dkr.ecr.$REGION.amazonaws.com/$REPO:latest" \
  --capabilities CAPABILITY_IAM

aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs" --output table
