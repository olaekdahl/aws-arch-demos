#!/usr/bin/env bash
# Module 8 Demo 1 — Change set workflow.
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-auto-cfn

echo "== Initial deploy (v1) =="
aws cloudformation deploy --region "$REGION" --stack-name "$STACK" \
  --template-file template-v1.yaml

echo "== Create change set 'upgrade-1' from v2 =="
aws cloudformation create-change-set --region "$REGION" \
  --stack-name "$STACK" --change-set-name upgrade-1 \
  --template-body file://template-v2.yaml
aws cloudformation wait change-set-create-complete --region "$REGION" \
  --stack-name "$STACK" --change-set-name upgrade-1

echo "== Review changes =="
aws cloudformation describe-change-set --region "$REGION" \
  --stack-name "$STACK" --change-set-name upgrade-1 \
  --query 'Changes[*].ResourceChange.{Action:Action,Logical:LogicalResourceId,Replacement:Replacement}' \
  --output table

echo "== Execute =="
aws cloudformation execute-change-set --region "$REGION" \
  --stack-name "$STACK" --change-set-name upgrade-1
aws cloudformation wait stack-update-complete --region "$REGION" --stack-name "$STACK"
echo "Done."
