#!/usr/bin/env bash
# Module 10 — Tear down Demo 1 (TGW) stack and reset SSM hybrid tier as a safety net.
#
# Note: Demo 2 (peering) has its own teardown — run those first if you used them:
#   ./azure-vm.sh cleanup
#   ./hybrid-ssm.sh cleanup
#   ./peering.sh cleanup
#   aws cloudformation delete-stack --stack-name demo-net2-vpc
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-net2-tgw

# Safety net: reset SSM hybrid activation tier back to 'standard' to avoid lingering
# per-instance hourly charges if hybrid-ssm.sh / peering.sh weren't cleaned up.
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
