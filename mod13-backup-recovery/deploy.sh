#!/usr/bin/env bash
# Module 13 — Deploy AWS Backup plan + tagged resources, kick off on-demand backup
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-bkp

aws cloudformation deploy --region "$REGION" \
  --stack-name "$STACK" \
  --template-file template.yaml \
  --capabilities CAPABILITY_IAM

ROLE=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='RoleArn'].OutputValue" --output text)
TABLE_ARN=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='TableArn'].OutputValue" --output text)

echo "Starting on-demand backup of DynamoDB table…"
aws backup start-backup-job --region "$REGION" \
  --backup-vault-name demo-bkp-vault \
  --resource-arn "$TABLE_ARN" \
  --iam-role-arn "$ROLE"

echo "List backup jobs:"
aws backup list-backup-jobs --region "$REGION" \
  --by-backup-vault-name demo-bkp-vault \
  --query 'BackupJobs[*].[ResourceArn,State,PercentDone]' --output table
