# Module 2: Account Security

**Topic:** IAM identities, policies, roles, federation, account hardening.
**Focus:** Implement least-privilege identity patterns and detect risky configurations.

---

## Demo 1: Least-Privilege Role + Cross-Service AssumeRole (boto3)

### 1. Overview
- **What it shows:** Create a least-privilege IAM role assumable by an EC2 service principal, attach a scoped customer-managed policy, and verify with `simulate-principal-policy`.
- **Use case:** Every workload needs an execution role — this demo is the canonical pattern.
- **Services:** IAM, STS.

### 2. Architecture
```
[boto3 admin] --create--> [Role: demo-iam-app-role]
                              |- Trust: ec2.amazonaws.com
                              `- Policy: demo-iam-app-policy
                                          (s3:GetObject on demo bucket prefix)
[Simulator]   --check--> Allowed/Denied verdicts
```

### 3. Prerequisites
- Permissions: `iam:*`, `sts:*` on demo principals.
- boto3 installed.

### 4. Step-by-Step
```bash
python3 demo.py deploy
python3 demo.py simulate
python3 demo.py cleanup
```

### 5. Code — `demo.py`
```python
"""Module 2 — Least-privilege IAM role + simulator.
Production split: roles.py, policies.py, simulator.py.
"""
import sys, json, boto3
from botocore.exceptions import ClientError

ROLE = "demo-iam-app-role"
POLICY = "demo-iam-app-policy"
BUCKET_PREFIX = "demo-iam-app-data"

TRUST = {
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "ec2.amazonaws.com"},
        "Action": "sts:AssumeRole",
    }],
}

DOC = {
    "Version": "2012-10-17",
    "Statement": [
        {"Effect": "Allow", "Action": ["s3:GetObject"],
         "Resource": [f"arn:aws:s3:::{BUCKET_PREFIX}-*/*"]},
        {"Effect": "Allow", "Action": ["s3:ListBucket"],
         "Resource": [f"arn:aws:s3:::{BUCKET_PREFIX}-*"]},
    ],
}

iam = boto3.client("iam")

def create():
    try:
        role = iam.create_role(RoleName=ROLE, AssumeRolePolicyDocument=json.dumps(TRUST))
        print("Role:", role["Role"]["Arn"])
    except ClientError as e:
        if e.response["Error"]["Code"] != "EntityAlreadyExists": raise
        print("Role exists.")
    try:
        pol = iam.create_policy(PolicyName=POLICY, PolicyDocument=json.dumps(DOC))
        arn = pol["Policy"]["Arn"]
    except ClientError as e:
        if e.response["Error"]["Code"] != "EntityAlreadyExists": raise
        acct = boto3.client("sts").get_caller_identity()["Account"]
        arn = f"arn:aws:iam::{acct}:policy/{POLICY}"
    iam.attach_role_policy(RoleName=ROLE, PolicyArn=arn)
    print("Attached:", arn)

def simulate():
    acct = boto3.client("sts").get_caller_identity()["Account"]
    role_arn = f"arn:aws:iam::{acct}:role/{ROLE}"
    cases = [
        ("s3:GetObject",   f"arn:aws:s3:::{BUCKET_PREFIX}-prod/file.txt", "allowed"),
        ("s3:GetObject",   "arn:aws:s3:::other-bucket/file.txt",          "implicitDeny"),
        ("s3:DeleteObject",f"arn:aws:s3:::{BUCKET_PREFIX}-prod/file.txt", "implicitDeny"),
    ]
    for action, resource, expect in cases:
        r = iam.simulate_principal_policy(
            PolicySourceArn=role_arn, ActionNames=[action], ResourceArns=[resource])
        verdict = r["EvaluationResults"][0]["EvalDecision"]
        ok = "OK" if verdict == expect else "MISMATCH"
        print(f"[{ok}] {action} on {resource} -> {verdict} (expected {expect})")

def cleanup():
    acct = boto3.client("sts").get_caller_identity()["Account"]
    arn = f"arn:aws:iam::{acct}:policy/{POLICY}"
    try: iam.detach_role_policy(RoleName=ROLE, PolicyArn=arn)
    except ClientError: pass
    try: iam.delete_role(RoleName=ROLE)
    except ClientError: pass
    try: iam.delete_policy(PolicyArn=arn)
    except ClientError: pass
    print("Cleanup done.")

if __name__ == "__main__":
    {"create": create, "simulate": simulate, "cleanup": cleanup}[sys.argv[1]]()
```

### 6. Validation
- `simulate` prints `[OK]` for all three cases — confirming the policy is least-privileged (allows only the specific S3 action on the specific bucket prefix).

### 7. Cleanup
```bash
python3 demo.py cleanup
```

---

## Demo 2: Account Hardening Audit (AWS CLI)

### 1. Overview
- **What it shows:** Quick CLI script to audit common account-security findings (root MFA, password policy, access keys age, IAM users w/o MFA).
- **Use case:** Day-1 health check at the start of any engagement.
- **Services:** IAM credential report.

### 2. Architecture
```
[bash + aws cli] -> IAM:GenerateCredentialReport -> CSV -> filtered findings
```

### 3. Prerequisites
- Permissions: `iam:GenerateCredentialReport`, `iam:GetCredentialReport`, `iam:GetAccountSummary`, `iam:GetAccountPasswordPolicy`.

### 4–5. Code — `audit.sh` (single file)
```bash
#!/usr/bin/env bash
# Module 2 Demo 2 — Account hardening audit.
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"

echo "== Account Summary =="
aws iam get-account-summary --query 'SummaryMap.{MFA:AccountMFAEnabled,Users:Users,RootKeys:AccountAccessKeysPresent}'

echo "== Password Policy =="
aws iam get-account-password-policy 2>/dev/null || echo "WARN: No password policy set."

echo "== Generating credential report =="
aws iam generate-credential-report >/dev/null
sleep 3
aws iam get-credential-report --query Content --output text | base64 -d > /tmp/cred.csv

echo "== Users without MFA =="
awk -F',' 'NR>1 && $4=="true" && $8=="false" {print "  -", $1}' /tmp/cred.csv

echo "== Access keys older than 90 days =="
python3 - <<'PY'
import csv, datetime
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=90)
with open("/tmp/cred.csv") as f:
    for r in csv.DictReader(f):
        for k in ("access_key_1_last_rotated", "access_key_2_last_rotated"):
            v = r[k]
            if v and v != "N/A":
                d = datetime.datetime.fromisoformat(v.replace("Z","+00:00"))
                if d < cutoff:
                    print(f"  - {r['user']} {k} rotated {v}")
PY

rm -f /tmp/cred.csv
echo "== Done =="
```

### 6. Validation
- Output flags any user without MFA and stale keys. A clean account prints headers but no findings.

### 7. Cleanup
- Nothing created. The `/tmp/cred.csv` is auto-removed.
