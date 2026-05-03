# Module 13: Backup and Recovery

**Topic:** AWS Backup, RPO/RTO, DR strategies (backup/restore, pilot light, warm standby, multi-site).
**Focus:** Use AWS Backup to centralize backups for an EC2 instance + DynamoDB table with a tag-based selection.

---

## Demo 1: AWS Backup Plan with Tag-Based Selection (CloudFormation)

### 1. Overview
- **What it shows:** Create a Backup vault, plan (daily, 7-day retention), and a selection that picks any resource tagged `Backup=daily`. Demonstrates centralized policy-driven backups.
- **Use case:** Regulatory/operational baseline RPO across heterogeneous resources.
- **Services:** AWS Backup, IAM, EC2, DynamoDB.

### 2. Architecture
```
[ Backup Vault: demo-bkp-vault ]
        ^
        |
[ Backup Plan: demo-bkp-plan ]
   - rule: daily 5:00 UTC, retain 7 days
   - selection: tag Backup=daily
        |
        v   (selects)
   [ EC2 demo-bkp-ec2 (tag Backup=daily) ]
   [ DynamoDB demo-bkp-table (tag Backup=daily) ]
```

### 3. Prerequisites
- Permissions: `cloudformation:*`, `backup:*`, `iam:PassRole`, `ec2:*`, `dynamodb:*`.
- AWS Backup must be opted-in for EC2 and DynamoDB resource types in the region (one-time, console).

### 4. Step-by-Step
```bash
aws cloudformation deploy --region us-east-1 \
  --stack-name demo-bkp --template-file template.yaml \
  --capabilities CAPABILITY_IAM

# Trigger an on-demand backup right away (don't wait for the schedule)
PLAN=$(aws cloudformation describe-stacks --region us-east-1 --stack-name demo-bkp \
  --query "Stacks[0].Outputs[?OutputKey=='PlanId'].OutputValue" --output text)
ROLE=$(aws cloudformation describe-stacks --region us-east-1 --stack-name demo-bkp \
  --query "Stacks[0].Outputs[?OutputKey=='RoleArn'].OutputValue" --output text)
TABLE_ARN=$(aws cloudformation describe-stacks --region us-east-1 --stack-name demo-bkp \
  --query "Stacks[0].Outputs[?OutputKey=='TableArn'].OutputValue" --output text)

aws backup start-backup-job --region us-east-1 \
  --backup-vault-name demo-bkp-vault \
  --resource-arn "$TABLE_ARN" \
  --iam-role-arn "$ROLE"

aws backup list-backup-jobs --region us-east-1 \
  --query 'BackupJobs[*].{Resource:ResourceArn,State:State,Pct:PercentDone}'
```

### 5. Code — `template.yaml`
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: Module 13 — AWS Backup plan with tag-based selection

Parameters:
  LatestAmi:
    Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
    Default: /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64

Resources:
  Vault:
    Type: AWS::Backup::BackupVault
    Properties: { BackupVaultName: demo-bkp-vault }

  BackupRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Statement: [{Effect: Allow, Principal: {Service: backup.amazonaws.com}, Action: sts:AssumeRole}]
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup
        - arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores

  Plan:
    Type: AWS::Backup::BackupPlan
    Properties:
      BackupPlan:
        BackupPlanName: demo-bkp-plan
        BackupPlanRule:
          - RuleName: daily
            TargetBackupVault: !Ref Vault
            ScheduleExpression: cron(0 5 * * ? *)
            StartWindowMinutes: 60
            CompletionWindowMinutes: 180
            Lifecycle: { DeleteAfterDays: 7 }

  Selection:
    Type: AWS::Backup::BackupSelection
    Properties:
      BackupPlanId: !Ref Plan
      BackupSelection:
        SelectionName: tag-backup-daily
        IamRoleArn: !GetAtt BackupRole.Arn
        ListOfTags:
          - { ConditionType: STRINGEQUALS, ConditionKey: Backup, ConditionValue: daily }

  # Sample resources tagged for backup
  Table:
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: demo-bkp-table
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions: [{AttributeName: id, AttributeType: S}]
      KeySchema: [{AttributeName: id, KeyType: HASH}]
      Tags: [{ Key: Backup, Value: daily }]

  Ec2:
    Type: AWS::EC2::Instance
    Properties:
      InstanceType: t3.micro
      ImageId: !Ref LatestAmi
      Tags:
        - { Key: Name, Value: demo-bkp-ec2 }
        - { Key: Backup, Value: daily }

Outputs:
  PlanId:    { Value: !Ref Plan }
  RoleArn:   { Value: !GetAtt BackupRole.Arn }
  TableArn:  { Value: !GetAtt Table.Arn }
```

### 6. Validation
```bash
aws backup list-backup-jobs --region us-east-1 \
  --by-backup-vault-name demo-bkp-vault \
  --query 'BackupJobs[*].[ResourceArn,State,PercentDone]' --output table
# After ~5-10 min: State=COMPLETED for the DDB job
aws backup list-recovery-points-by-backup-vault \
  --region us-east-1 --backup-vault-name demo-bkp-vault \
  --query 'RecoveryPoints[*].[ResourceArn,Status]'
```

### 7. Cleanup
```bash
# Delete recovery points first (CFN won't delete non-empty vaults)
for rp in $(aws backup list-recovery-points-by-backup-vault --region us-east-1 \
              --backup-vault-name demo-bkp-vault \
              --query 'RecoveryPoints[*].RecoveryPointArn' --output text); do
  aws backup delete-recovery-point --region us-east-1 \
    --backup-vault-name demo-bkp-vault --recovery-point-arn "$rp"
done
aws cloudformation delete-stack --region us-east-1 --stack-name demo-bkp
```

---

## Demo 2: DR Strategy Decision Helper (CLI/teaching tool)

### 1. Overview
- **What it shows:** Interactive script that maps RPO/RTO answers to one of: Backup & Restore, Pilot Light, Warm Standby, Multi-Site Active/Active. Reinforces the module's DR taxonomy.

### 2–5. Code — `dr.sh`
```bash
#!/usr/bin/env bash
# Module 13 Demo 2 — DR strategy decision helper.
read -rp "Acceptable RPO (data loss): hours/minutes/seconds? " RPO
read -rp "Acceptable RTO (downtime):  hours/minutes/seconds? " RTO

if [[ "$RPO" == "hours" && "$RTO" == "hours" ]]; then
  echo "-> Backup & Restore (cheapest)"
elif [[ "$RPO" == "minutes" && "$RTO" == "hours" ]]; then
  echo "-> Pilot Light"
elif [[ "$RPO" == "minutes" && "$RTO" == "minutes" ]]; then
  echo "-> Warm Standby"
elif [[ "$RPO" == "seconds" && "$RTO" == "seconds" ]]; then
  echo "-> Multi-Site Active/Active"
else
  echo "-> Hybrid: closest match is Warm Standby; revisit cost trade-offs."
fi
```

### 6. Validation
- Match each input pair to the AWS DR strategy diagram covered in the module.

### 7. Cleanup
- None.
