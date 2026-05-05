#!/usr/bin/env bash
# Module 7 — Force the ASG to add another instance by bumping DesiredCapacity.
# This bypasses the target-tracking policy (which waits for CPU). Useful when
# you want a deterministic scale-out for a demo.
#
# Usage:
#   ./scale-up.sh        # add 1 instance
#   ./scale-up.sh 2      # add 2 instances
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
STACK=demo-monsc-asg
ADD="${1:-1}"

ASG=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='AsgName'].OutputValue" --output text)

read -r CUR MAX < <(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].[DesiredCapacity,MaxSize]' --output text)

NEW=$((CUR + ADD))
if (( NEW > MAX )); then
  echo "Requested desired=$NEW exceeds MaxSize=$MAX; capping at $MAX"
  NEW=$MAX
fi
if (( NEW == CUR )); then
  echo "ASG $ASG already at MaxSize=$MAX; nothing to do."
  exit 0
fi

echo "==> $ASG: DesiredCapacity $CUR -> $NEW (max $MAX)"
aws autoscaling set-desired-capacity --region "$REGION" \
  --auto-scaling-group-name "$ASG" \
  --desired-capacity "$NEW" \
  --honor-cooldown

echo "==> Polling instances (Ctrl-C to stop)…"
for _ in $(seq 1 30); do
  aws autoscaling describe-auto-scaling-groups --region "$REGION" \
    --auto-scaling-group-names "$ASG" \
    --query 'AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState,HealthStatus]' \
    --output table
  IN_SVC=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
    --auto-scaling-group-names "$ASG" \
    --query "length(AutoScalingGroups[0].Instances[?LifecycleState=='InService'])" \
    --output text)
  if (( IN_SVC >= NEW )); then
    echo "==> $IN_SVC instances InService."
    break
  fi
  sleep 10
done
