# Module 4: Compute

**Topic:** EC2 instance types/AMIs/purchasing options, Lambda intro, Auto Scaling foundations.
**Focus:** Hands-on launching EC2 with SSM Session Manager (no SSH), and launching a Lambda — comparing the two compute models.

## Quick commands
```bash
# Demo 1 — EC2 + SSM Session Manager
./demo.sh deploy
./demo.sh cleanup

# Demo 2 — Lambda function
python3 deploy.py deploy
python3 deploy.py invoke
python3 deploy.py cleanup
```

---

## Demo 1: EC2 Launch with SSM Session Manager (AWS CLI)

### 1. Overview
- **What it shows:** Launch a t3.micro Amazon Linux 2023 instance, attach an SSM-enabled instance profile, connect via Session Manager (no inbound port).
- **Use case:** Modern keyless EC2 access.
- **Services:** EC2, IAM, SSM.

### Concepts (read this first)

**Why SSM Session Manager replaces SSH**

Traditional SSH access to EC2 requires:
- A key pair (`.pem` file) you have to distribute and rotate.
- An inbound rule allowing port 22 from somewhere — bastion, VPN, or worst-case `0.0.0.0/0`.
- A public IP or jump host.

Each of those is a long-running source of operational pain and security incidents
(leaked keys, scanned-open ports, lost bastions). Session Manager removes all of them.

**How Session Manager actually works**

```
[ Your laptop ]                                     [ EC2 instance ]
      |                                                    ^
      | 1. aws ssm start-session                           | 4. ssm-agent runs the
      |    (TLS over 443 to SSM API)                       |    received commands and
      v                                                    |    streams stdout back
[ SSM Service ] <------- 2. agent polls SSM ---------------+
                          (HTTPS outbound only:
                           ssm, ssmmessages, ec2messages)
                          3. session payload pushed
                             through long-poll channel
```

Key points:
- **All traffic is outbound from the instance** to AWS endpoints. No inbound listener.
- **No SSH daemon, no port 22, no keys.** The SSM agent (preinstalled on Amazon Linux,
  Ubuntu 18.04+, etc.) authenticates with its IAM role.
- The "shell" you get is run by the agent as the `ssm-user` user (sudoer by default).
- Sessions are auditable — every command + output can be logged to S3/CloudWatch Logs,
  and `start-session` calls are recorded in CloudTrail with the IAM principal.

**The SSM-enabled instance profile**

For the agent to register with SSM, the instance must assume a role that grants the
permissions in the AWS-managed policy **`AmazonSSMManagedInstanceCore`**. That policy
allows exactly what the agent needs:

| Permission | Purpose |
|---|---|
| `ssm:UpdateInstanceInformation` | Heartbeat / register the instance |
| `ssmmessages:CreateControlChannel`, `OpenControlChannel`, `CreateDataChannel`, `OpenDataChannel` | Long-poll session traffic |
| `ec2messages:*` | Receive `SendCommand` invocations |
| `s3:GetObject` (limited paths) | Pull the latest agent / patch baselines |

An **instance profile** is just a thin wrapper that attaches a role to an EC2 instance
(EC2 cannot directly assume a role — it assumes one through a profile). The script
creates `demo-compute-ssm-role`, attaches `AmazonSSMManagedInstanceCore`, wraps it in
`demo-compute-ssm-profile`, then launches the instance with `--iam-instance-profile`.

**No inbound rules required**

The launched instance has no security group ingress rules — the demo doesn't even create
one explicitly, so the instance gets the VPC default SG (no ingress from anywhere).
Outbound 443 is enough because Session Manager piggybacks on the agent's existing poll.
For instances in fully **private subnets** (no NAT, no IGW), reach SSM via three
**Interface VPC Endpoints**: `ssm`, `ssmmessages`, `ec2messages` (see Module 10).

### 2. Architecture
```
[ Your laptop ]
      | (StartSession over HTTPS — TLS 443)
      v
[ SSM Service ] <------- ssmmessages, ec2messages (outbound 443 from instance)
      |
      v
[ EC2 t3.micro ]  (no SSH key, no port 22, no inbound rules)
   IAM role: demo-compute-ssm-role
   policy:   AmazonSSMManagedInstanceCore
```

### 3. Prerequisites
- AWS CLI v2.
- **Session Manager plugin** for the AWS CLI (one-time install — see below).
- Default VPC present (or set `SUBNET_ID` env var).

#### Install the Session Manager plugin

| OS | Command |
|---|---|
| **Ubuntu / Debian (x86_64)** | `curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/smp.deb && sudo dpkg -i /tmp/smp.deb` |
| **Ubuntu / Debian (arm64)** | `curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb" -o /tmp/smp.deb && sudo dpkg -i /tmp/smp.deb` |
| **Amazon Linux / RHEL (x86_64)** | `sudo dnf install -y https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm` |
| **macOS** | `brew install --cask session-manager-plugin` |
| **Windows** | Download the MSI: <https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe> |

Verify:
```bash
session-manager-plugin --version
```

### 4–5. Code — `demo.sh` (single file)
```bash
#!/usr/bin/env bash
# Module 4 Demo 1 — EC2 + SSM Session Manager
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
ROLE=demo-compute-ssm-role
PROFILE=demo-compute-ssm-profile
NAME=demo-compute-ec2

cmd=${1:-deploy}

deploy() {
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

cleanup() {
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
  deploy)  deploy ;;
  cleanup) cleanup ;;
  *) echo "usage: $0 deploy|cleanup" >&2; exit 2 ;;
esac
```

### 6. Validation
```bash
aws ssm start-session --region us-east-1 --target <iid>
# In the session: cat /etc/os-release ; whoami  -> ssm-user
```

### 7. Cleanup
```bash
./demo.sh cleanup
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

---

## Demo 3: EC2 UserData bootstrap (`userdata.sh`)

### 1. Overview
- **What it shows:** An EC2 instance that bootstraps itself on first boot via cloud-init UserData — installs nginx, queries IMDSv2, renders a status page. No SSH, no AMI baking, no manual config.
- **Use case:** Reproducible "golden image without a golden image" — codify the bootstrap, throw the AMI away, scale horizontally.
- **Services:** EC2, IMDSv2.

### 2. How UserData runs
- The script in `--user-data` is delivered to the instance as base64 via the metadata service.
- `cloud-init` executes it **once, as root, on the very first boot** (before the login prompt is even available).
- All output is captured in `/var/log/cloud-init-output.log` — the canonical place to debug bootstrap failures.
- A shebang of `#!/bin/bash` runs as a shell script. Other formats (`#cloud-config`, MIME multipart) are also supported.

### 3. Prerequisites
- Default VPC (or set `SUBNET_ID`).
- The script opens **port 80 from `0.0.0.0/0`** for the demo — fine for a throwaway test, never do this in production.

### 4–5. Run
```bash
./userdata.sh deploy     # launches instance, prints public IP + curl command
# wait ~60–90s for cloud-init to finish, then:
curl http://<public-ip>/
```

The page returned is generated *by the instance, on the instance, on first boot* — proving UserData ran and the instance can introspect itself via IMDSv2.

### 6. Validation — peek at the bootstrap log
```bash
aws ssm start-session --region us-east-1 --target <iid>
sudo tail -n 50 /var/log/cloud-init-output.log
sudo cat /var/lib/cloud/instance/user-data.txt   # the script you sent
```

### 7. Cleanup
```bash
./userdata.sh cleanup
```

---

## Reference: Instance type comparison (`instance-types.html`)

A self-contained, offline HTML page that compares ~30 representative EC2 instance types
across families (Burstable, General, Compute, Memory, Storage, Accelerated) with:

- vCPU / RAM / network / local storage
- Architecture (x86_64 vs Graviton arm64)
- On-demand `$/hr` and `$/mo` (us-east-1, Linux)
- Typical workload for each
- Filterable by family, searchable, sortable by any column
- Decision-making notes (family letters, generation, suffixes, burstable caveats, Spot/SP)

Open it locally:

```bash
xdg-open instance-types.html        # Linux
open instance-types.html            # macOS
start instance-types.html           # Windows
```

> Pricing is a **snapshot** for teaching — always confirm in the AWS Pricing Calculator
> before sizing real workloads.

---

## Reference: AMI choice — Amazon Linux 2023

All Module 4 demos launch **Amazon Linux 2023 (AL2023)** by resolving the SSM Public Parameter
`/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` at deploy time. This
guarantees you always get the latest patched build without hard-coding AMI IDs (which are
region-specific and rotate frequently).

### What AL2023 is optimized for
- **Long-term support** — 5-year support window on a Fedora-derived base.
- **Fast boot, minimal package set, SELinux enforcing** — small attack surface vs. full distros.
- **Pre-installed agents** — `amazon-ssm-agent`, `cloud-init`, `awscli-2`, `nvme-cli`.
- **Deterministic kernel** — `kernel-default` channel, vs. AL2's older `kernel-5.10`.
- **Tuned for AWS** — ENA, NVMe, Nitro, IMDSv2 defaults all preconfigured.

### Best use cases
- General Linux workloads on EC2, ECS-on-EC2, EKS worker nodes.
- Containers, web/API tiers, batch jobs, ML inference VMs.
- Anywhere you previously used Amazon Linux 2 and want LTS without re-platforming.
- SSM-managed fleets (agent already running — no SSH key needed).

### When to pick something else
| Choose | Reason |
|---|---|
| **Ubuntu** | Broader package ecosystem, NVIDIA drivers, ML/data tooling |
| **Bottlerocket** | Purpose-built minimal container host with atomic updates |
| **RHEL / SLES** | You need vendor support contracts |
| **Windows Server** | .NET Framework, Active Directory, MSSQL Server |
