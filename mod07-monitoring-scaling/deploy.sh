#!/usr/bin/env bash
# Module 7 — Deploy ALB+ASG with target tracking; optionally trigger stress
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-monsc-asg

VPC=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC" \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')

aws cloudformation deploy --region "$REGION" \
  --stack-name "$STACK" \
  --template-file template.yaml \
  --parameter-overrides VpcId="$VPC" SubnetIds="$SUBNETS" \
  --capabilities CAPABILITY_IAM

URL=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='AlbUrl'].OutputValue" --output text)
ASG=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='AsgName'].OutputValue" --output text)
echo "ALB: $URL"
echo "ASG: $ASG"

if [[ "${1:-}" == "stress" ]]; then
  echo "Triggering stress on first ASG instance via SSM…"
  IID=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
    --auto-scaling-group-names "$ASG" \
    --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
  aws ssm send-command --region "$REGION" --instance-ids "$IID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["nohup stress-ng --cpu 2 --timeout 600s >/tmp/stress.log 2>&1 &"]'
  echo "Watch scale-out:"
  echo "  aws autoscaling describe-auto-scaling-groups --region $REGION --auto-scaling-group-names $ASG \\"
  echo "    --query 'AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState]' --output table"
fi
