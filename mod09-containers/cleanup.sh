#!/usr/bin/env bash
# Module 9 — Tear down ECS stack + ECR repo
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-ctr-fargate
REPO=demo-ctr-app
aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"
aws ecr delete-repository --region "$REGION" --repository-name "$REPO" --force 2>/dev/null || true
echo "Done."
