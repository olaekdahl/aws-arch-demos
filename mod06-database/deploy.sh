#!/usr/bin/env bash
# Module 6 Demo 2 — Deploy Aurora Serverless v2 + Data API
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-db-aurora

VPC=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC" \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')

aws cloudformation deploy --region "$REGION" \
  --stack-name "$STACK" \
  --template-file template.yaml \
  --parameter-overrides VpcId="$VPC" SubnetIds="$SUBNETS" \
  --capabilities CAPABILITY_IAM

CLUSTER_ARN=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ClusterArn'].OutputValue" --output text)
SECRET_ARN=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='SecretArn'].OutputValue" --output text)

echo "ClusterArn=$CLUSTER_ARN"
echo "SecretArn=$SECRET_ARN"
echo "Querying via Data API:"
aws rds-data execute-statement --region "$REGION" \
  --resource-arn "$CLUSTER_ARN" --secret-arn "$SECRET_ARN" \
  --database postgres --sql "select version();"
