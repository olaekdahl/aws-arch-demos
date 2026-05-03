#!/usr/bin/env bash
# Module 13 — Delete recovery points first, then stack
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-bkp
VAULT=demo-bkp-vault

echo "Deleting recovery points in $VAULT…"
for rp in $(aws backup list-recovery-points-by-backup-vault --region "$REGION" \
              --backup-vault-name "$VAULT" \
              --query 'RecoveryPoints[*].RecoveryPointArn' --output text 2>/dev/null); do
  echo "  $rp"
  aws backup delete-recovery-point --region "$REGION" \
    --backup-vault-name "$VAULT" --recovery-point-arn "$rp" || true
done

aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"
echo "Done."
