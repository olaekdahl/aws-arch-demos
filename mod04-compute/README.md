# Module 4: Compute

**Topic:** EC2 instance types/AMIs/purchasing options, Lambda intro, Auto Scaling foundations.
**Focus:** Hands-on launching EC2 with SSM Session Manager (no SSH), and launching a Lambda — comparing the two compute models.

---

## Demo 1: EC2 Launch with SSM Session Manager (AWS CLI)

### 1. Overview
- **What it shows:** Launch a t3.micro Amazon Linux 2023 instance, attach an SSM-enabled instance profile, connect via Session Manager (no inbound port).
- **Use case:** Modern keyless EC2 access.
- **Services:** EC2, IAM, SSM.

### 2. Architecture
```
[ Your laptop ]
      | (StartSession over HTTPS)
      v
[ SSM Service ] <------- ssmmessages, ec2messages
      |
      v
[ EC2 t3.micro ]  (no SSH, no inbound rules)
   role: demo-compute-ssm-role
```

### 3. Prerequisites
- AWS CLI v2 + Session Manager plugin installed.
- Default VPC present (or set `SUBNET_ID` env var).

### 4–5. Code — `demo.sh` (single file)
```bash
#!/usr/bin/env bash
# Module 4 Demo 1 — EC2 + SSM Session Manager
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
ROLE=demo-compute-ssm-role
PROFILE=demo-compute-ssm-profile
NAME=demo-compute-ec2

cmd=${1:-up}

up() {
  AMI=$(aws ssm get-parameter --region "$REGION" \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query Parameter.Value --output text)

  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    2>/dev/null || true
  aws iam attach-role-policy --role-name "$ROLE" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam create-instance-profile --instance-profile-name "$PROFILE" 2>/dev/null || true
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE" 2>/dev/null || true
  sleep 8  # propagation

  SUBNET="${SUBNET_ID:-$(aws ec2 describe-subnets --region "$REGION" \
    --filters Name=default-for-az,Values=true \
    --query 'Subnets[0].SubnetId' --output text)}"

  IID=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI" --instance-type t3.micro \
    --iam-instance-profile Name="$PROFILE" \
    --subnet-id "$SUBNET" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
    --query 'Instances[0].InstanceId' --output text)
  echo "Launched $IID — wait ~90s for SSM agent registration, then:"
  echo "  aws ssm start-session --region $REGION --target $IID"
}

down() {
  IID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=running,pending,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  [[ -n "$IID" ]] && aws ec2 terminate-instances --region "$REGION" --instance-ids $IID || true
  aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$PROFILE" 2>/dev/null || true
  aws iam detach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
  echo "Cleanup done."
}

case "$cmd" in
  up) up ;;
  down) down ;;
  *) echo "usage: $0 up|down" ;;
esac
```

### 6. Validation
```bash
aws ssm start-session --region us-east-1 --target <iid>
# In the session: cat /etc/os-release ; whoami  -> ssm-user
```

### 7. Cleanup
```bash
./demo.sh down
```

---

## Demo 2: Lambda "Hello Compute" (Python single-file)

### 1. Overview
- **What it shows:** Package + deploy a Lambda function inline using boto3 — illustrates serverless compute vs EC2.
- **Services:** Lambda, IAM.

### 2. Architecture
```
[ deploy.py ] --> [ Lambda: demo-compute-hello ]
                       role: demo-compute-lambda-role (basic exec)
[ deploy.py invoke ] --> handler returns event echo + region
```

### 3. Prerequisites
- Permissions: `iam:*`, `lambda:*`.

### 4–5. Code — `deploy.py`
```python
"""Module 4 Demo 2 — Lambda quickstart.
In production: separate IaC (CFN/Terraform), src/, tests/."""
import sys, json, time, io, zipfile, boto3
from botocore.exceptions import ClientError

REGION = "us-east-1"
FN     = "demo-compute-hello"
ROLE   = "demo-compute-lambda-role"

HANDLER_SRC = '''
import os, json
def handler(event, context):
    return {"region": os.environ.get("AWS_REGION"),
            "echo": event,
            "msg": "Hello from Lambda"}
'''

iam, lam, sts = boto3.client("iam"), boto3.client("lambda", region_name=REGION), boto3.client("sts")

def _zip():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("app.py", HANDLER_SRC)
    return buf.getvalue()

def deploy():
    try:
        r = iam.create_role(RoleName=ROLE, AssumeRolePolicyDocument=json.dumps(
            {"Version":"2012-10-17","Statement":[{"Effect":"Allow",
              "Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}))
        role_arn = r["Role"]["Arn"]
    except ClientError as e:
        if e.response["Error"]["Code"] != "EntityAlreadyExists": raise
        role_arn = f"arn:aws:iam::{sts.get_caller_identity()['Account']}:role/{ROLE}"
    iam.attach_role_policy(RoleName=ROLE,
        PolicyArn="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole")
    time.sleep(10)
    try:
        lam.create_function(FunctionName=FN, Runtime="python3.12", Role=role_arn,
            Handler="app.handler", Code={"ZipFile": _zip()}, Timeout=10)
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceConflictException": raise
        lam.update_function_code(FunctionName=FN, ZipFile=_zip())
    print(f"Deployed {FN}")

def invoke():
    r = lam.invoke(FunctionName=FN, Payload=json.dumps({"hello":"world"}).encode())
    print(r["Payload"].read().decode())

def cleanup():
    try: lam.delete_function(FunctionName=FN)
    except ClientError: pass
    try:
        iam.detach_role_policy(RoleName=ROLE,
          PolicyArn="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole")
        iam.delete_role(RoleName=ROLE)
    except ClientError: pass
    print("Done.")

if __name__ == "__main__":
    {"deploy": deploy, "invoke": invoke, "cleanup": cleanup}[sys.argv[1]]()
```

### 6. Validation
```bash
python3 deploy.py deploy
python3 deploy.py invoke
# Expect: {"region": "us-east-1", "echo": {"hello":"world"}, "msg": "Hello from Lambda"}
```

### 7. Cleanup
```bash
python3 deploy.py cleanup
```
