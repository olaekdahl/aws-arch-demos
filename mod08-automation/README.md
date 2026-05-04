# Module 8: Automation

**Topic:** Infrastructure-as-code with CloudFormation, Systems Manager automation.
**Focus:** Use a parameterized CloudFormation template with change sets, and an SSM Automation runbook for routine ops.

## Quick commands
```bash
# Demo 1 — CFN change set workflow (v1 -> v2)
bash run.sh
./cleanup.sh

# Demo 2 — SSM Automation runbook
python3 demo.py run
python3 demo.py status
```

---

## Demo 1: CloudFormation Change Sets Workflow (CLI)

### 1. Overview
- **What it shows:** Deploy a small stack (S3 + DynamoDB), then propose a change via change set, review the diff, and execute — the safe production change pattern.
- **Use case:** Reviewable, auditable infra changes.
- **Services:** CloudFormation, S3, DynamoDB.

### 2. Architecture
```
[ template.yaml v1 ]            [ template.yaml v2 ]
   - Bucket                         - Bucket (versioning)
   - DDB Table (PAY_PER_REQUEST)    - DDB Table (PITR ON)
       |                                |
       v                                v
[ stack: demo-auto-cfn ] --change-set-> review --execute--> updated stack
```

### 3. Prerequisites
- Permissions: `cloudformation:*`, `s3:*`, `dynamodb:*`.

### 4–5. Code — `template-v1.yaml` and `template-v2.yaml`

`template-v1.yaml`:
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Resources:
  Bucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub demo-auto-cfn-${AWS::AccountId}
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        IgnorePublicAcls: true
        BlockPublicPolicy: true
        RestrictPublicBuckets: true
  Table:
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: demo-auto-cfn-table
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions: [{AttributeName: id, AttributeType: S}]
      KeySchema: [{AttributeName: id, KeyType: HASH}]
```

`template-v2.yaml` (adds versioning + PITR):
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Resources:
  Bucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub demo-auto-cfn-${AWS::AccountId}
      VersioningConfiguration: { Status: Enabled }
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        IgnorePublicAcls: true
        BlockPublicPolicy: true
        RestrictPublicBuckets: true
  Table:
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: demo-auto-cfn-table
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions: [{AttributeName: id, AttributeType: S}]
      KeySchema: [{AttributeName: id, KeyType: HASH}]
      PointInTimeRecoverySpecification: { PointInTimeRecoveryEnabled: true }
```

Workflow:
```bash
REGION=us-east-1
STACK=demo-auto-cfn

# Initial deploy
aws cloudformation deploy --region $REGION --stack-name $STACK \
  --template-file template-v1.yaml

# Propose v2 as a change set
aws cloudformation create-change-set --region $REGION \
  --stack-name $STACK --change-set-name upgrade-1 \
  --template-body file://template-v2.yaml

aws cloudformation describe-change-set --region $REGION \
  --stack-name $STACK --change-set-name upgrade-1 \
  --query 'Changes[*].ResourceChange.{Action:Action,Logical:LogicalResourceId,Replacement:Replacement}'

# Execute
aws cloudformation execute-change-set --region $REGION \
  --stack-name $STACK --change-set-name upgrade-1
aws cloudformation wait stack-update-complete --region $REGION --stack-name $STACK
```

### 6. Validation
```bash
aws s3api get-bucket-versioning --bucket demo-auto-cfn-$(aws sts get-caller-identity --query Account --output text)
aws dynamodb describe-continuous-backups --region us-east-1 --table-name demo-auto-cfn-table
```

### 7. Cleanup
```bash
aws cloudformation delete-stack --region us-east-1 --stack-name demo-auto-cfn
```

---

## Demo 2: SSM Automation Runbook — Patch Tagged EC2s (Python boto3)

### 1. Overview
- **What it shows:** Use built-in `AWS-RunPatchBaseline` SSM document to patch all EC2 instances tagged `Patch=true` — automation without writing custom orchestration.
- **Services:** Systems Manager.

### 2. Architecture
```
[demo.py] -> SSM:SendCommand(AWS-RunPatchBaseline) -> tagged EC2s
                                                    -> patch + report
[demo.py status] -> SSM:ListCommandInvocations
```

### 3. Prerequisites
- EC2 instances must have `AmazonSSMManagedInstanceCore` role (see Module 4 demo).
- Tag candidate instances with `Patch=true`.

### 4–5. Code — `demo.py`
```python
"""Module 8 Demo 2 — SSM patch automation.
In production: schedule via Maintenance Window."""
import sys, time, boto3

REGION = "us-east-1"
ssm = boto3.client("ssm", region_name=REGION)

def run():
    r = ssm.send_command(
        Targets=[{"Key":"tag:Patch","Values":["true"]}],
        DocumentName="AWS-RunPatchBaseline",
        Parameters={"Operation":["Scan"]},
        Comment="demo-auto-patch-scan")
    cid = r["Command"]["CommandId"]
    print(f"Command: {cid}")
    return cid

def status(cid=None):
    cid = cid or sys.argv[2]
    invs = ssm.list_command_invocations(CommandId=cid, Details=True)["CommandInvocations"]
    if not invs:
        print("No invocations yet — wait for SSM to enumerate targets.")
        return
    for i in invs:
        print(f"  {i['InstanceId']} -> {i['Status']}")

if __name__ == "__main__":
    {"run": run, "status": status}[sys.argv[1]]()
```

### 6. Validation
```bash
python3 demo.py run     # prints CommandId
python3 demo.py status <CommandId>
# Each instance reports Success after a few minutes.
```

### 7. Cleanup
- No persistent resources created.
