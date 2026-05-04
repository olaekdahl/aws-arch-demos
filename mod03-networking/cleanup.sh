#!/usr/bin/env bash
# Module 3 — Tear down VPC stack
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-net-vpc

# Safety net: reset SSM hybrid activation tier back to 'standard' to avoid lingering
# per-instance hourly charges if hybrid-ssm.sh wasn't cleaned up.
ACCT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [[ -n "$ACCT" ]]; then
  SID="arn:aws:ssm:${REGION}:${ACCT}:servicesetting/ssm/managed-instance/activation-tier"
  CUR=$(aws ssm get-service-setting --region "$REGION" --setting-id "$SID" \
          --query 'ServiceSetting.SettingValue' --output text 2>/dev/null || echo standard)
  if [[ "$CUR" == "advanced" ]]; then
    echo "Resetting SSM activation tier: advanced -> standard"
    aws ssm update-service-setting --region "$REGION" --setting-id "$SID" --setting-value standard || true
  fi
fi

aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"
echo "Done."
