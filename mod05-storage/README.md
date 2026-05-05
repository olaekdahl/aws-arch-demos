# Module 5: Storage

**Topic:** S3 (classes, lifecycle, versioning), EBS, EFS, FSx — picking the right storage.
**Focus:** Demonstrate S3 versioning + lifecycle tiering — the most common architectural decision.

## Quick commands
```bash
# Demo 1 — S3 versioning + lifecycle
python3 demo.py deploy
python3 demo.py upload
python3 demo.py inspect
python3 demo.py cleanup

# Demo 2 — interactive storage recommender
bash recommend.sh

# Demo 3 — S3 -> Lambda -> DynamoDB ingest pipeline (provisions in us-east-1)
./pipeline-deploy.sh
./pipeline-teardown.sh
```

---

## Demo 1: S3 Versioned Bucket with Lifecycle Tiering (Python boto3)

### 1. Overview
- **What it shows:** Create a versioned S3 bucket with default encryption + Block Public Access, configure a lifecycle policy that transitions objects to `STANDARD_IA` at 30 days and `GLACIER_IR` at 90 days, expires noncurrent versions at 180 days. Upload a file, overwrite it, and inspect versions.
- **Use case:** Cost-optimized object storage for compliance/log archives.
- **Services:** S3.

### 2. Architecture
```
[boto3 client]
   |
   v
[ S3 Bucket: demo-storage-archive-<acct>-<region> ]
   - Versioning: ENABLED
   - SSE: AES256
   - Block Public Access: ALL ON
   - Lifecycle:
       day 30  -> STANDARD_IA
       day 90  -> GLACIER_IR
       day 180 -> noncurrent versions expired
```

### 3. Prerequisites
- Permissions: `s3:*` on demo bucket.
- boto3.

### 4. Step-by-Step
```bash
python3 demo.py deploy
python3 demo.py upload
python3 demo.py inspect
python3 demo.py cleanup
```

### 5. Code — `demo.py`
```python
"""Module 5 Demo — S3 versioning + lifecycle.
In production: split into bucket.py, lifecycle.py, ops.py."""
import sys, json, boto3
from botocore.exceptions import ClientError

REGION = "us-east-1"
s3  = boto3.client("s3", region_name=REGION)
sts = boto3.client("sts")

def _bucket():
    acct = sts.get_caller_identity()["Account"]
    return f"demo-storage-archive-{acct}-{REGION}"

def up():
    b = _bucket()
    try:
        if REGION == "us-east-1":
            s3.create_bucket(Bucket=b)
        else:
            s3.create_bucket(Bucket=b, CreateBucketConfiguration={"LocationConstraint": REGION})
    except ClientError as e:
        if e.response["Error"]["Code"] not in ("BucketAlreadyOwnedByYou","BucketAlreadyExists"): raise
    s3.put_public_access_block(Bucket=b, PublicAccessBlockConfiguration={
        "BlockPublicAcls": True, "IgnorePublicAcls": True,
        "BlockPublicPolicy": True, "RestrictPublicBuckets": True})
    s3.put_bucket_versioning(Bucket=b, VersioningConfiguration={"Status":"Enabled"})
    s3.put_bucket_encryption(Bucket=b, ServerSideEncryptionConfiguration={
        "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]})
    s3.put_bucket_lifecycle_configuration(Bucket=b, LifecycleConfiguration={
        "Rules":[{
            "ID":"tier-and-expire", "Status":"Enabled", "Filter":{"Prefix":""},
            "Transitions":[
                {"Days":30, "StorageClass":"STANDARD_IA"},
                {"Days":90, "StorageClass":"GLACIER_IR"}],
            "NoncurrentVersionExpiration":{"NoncurrentDays":180},
        }]})
    print(f"Bucket ready: {b}")

def upload():
    b = _bucket()
    s3.put_object(Bucket=b, Key="report.txt", Body=b"v1 content")
    s3.put_object(Bucket=b, Key="report.txt", Body=b"v2 content (replaces v1 -> v1 becomes noncurrent)")
    print("Uploaded 2 versions of report.txt")

def inspect():
    b = _bucket()
    print("Versions:")
    for v in s3.list_object_versions(Bucket=b).get("Versions", []):
        print(f"  - {v['Key']} VID={v['VersionId'][:12]} Latest={v['IsLatest']} Size={v['Size']}")
    print("Lifecycle:")
    print(json.dumps(s3.get_bucket_lifecycle_configuration(Bucket=b)["Rules"], indent=2, default=str))

def down():
    b = _bucket()
    paginator = s3.get_paginator("list_object_versions")
    for page in paginator.paginate(Bucket=b):
        objs = [{"Key": o["Key"], "VersionId": o["VersionId"]}
                for o in page.get("Versions", []) + page.get("DeleteMarkers", [])]
        if objs:
            s3.delete_objects(Bucket=b, Delete={"Objects": objs})
    try: s3.delete_bucket(Bucket=b); print(f"Deleted {b}")
    except ClientError as e: print(e)

if __name__ == "__main__":
    {"up": up, "upload": upload, "inspect": inspect, "down": down}[sys.argv[1]]()
```

### 6. Validation
- `inspect` shows 2 versions of `report.txt` (one `IsLatest=True`, one `False`) and lifecycle rule with two transitions + noncurrent expiration.

### 7. Cleanup
```bash
python3 demo.py cleanup
```

---

## Demo 2: Pick-the-Right-Storage Decision Helper (CLI)

### 1. Overview
- **What it shows:** CLI script that asks for workload characteristics (access pattern, shared, OS, throughput) and recommends EBS / EFS / FSx / S3 — concretely reinforces the storage selection lesson.

### 2–5. Code — `recommend.sh`
```bash
#!/usr/bin/env bash
# Module 5 Demo 2 — Storage recommender (teaching tool).
ask() { read -rp "$1 " R; echo "$R"; }
A1=$(ask "Single instance attached block, or shared? [block/shared/object]:")
case "$A1" in
  block)
    A2=$(ask "Need >16k IOPS or >1 GB/s? [y/n]:")
    [[ "$A2" == "y" ]] && echo "-> EBS io2 Block Express" || echo "-> EBS gp3"
    ;;
  shared)
    A2=$(ask "Linux NFS or Windows SMB? [linux/windows]:")
    [[ "$A2" == "linux" ]] && echo "-> EFS (One Zone for cost / Standard for HA)" \
                           || echo "-> FSx for Windows File Server"
    ;;
  object)
    A2=$(ask "Access pattern: hot, mixed, cold, archive?:")
    case "$A2" in
      hot)     echo "-> S3 Standard" ;;
      mixed)   echo "-> S3 Intelligent-Tiering" ;;
      cold)    echo "-> S3 Standard-IA or Glacier Instant Retrieval" ;;
      archive) echo "-> S3 Glacier Deep Archive" ;;
    esac
    ;;
esac
```

### 6. Validation
- Run interactively; verify recommendations match the module's decision matrix.

### 7. Cleanup
- None (no AWS resources created).

---

## Demo 3: S3 → Lambda → DynamoDB Ingest Pipeline (CloudFormation)

### 1. Overview
- **What it shows:** A complete event-driven ingest pipeline. A file dropped into the `incoming/` prefix of an S3 bucket triggers a Lambda function that parses the file (CSV with header, or JSON array/object) and writes each row as an item to a DynamoDB table.
- **Use case:** The canonical "land file → process → store" pattern for log ingest, batch loads, partner data drops, etc.
- **Services:** S3, Lambda (Python 3.12), DynamoDB (PAY_PER_REQUEST), IAM, CloudFormation.
- **Region:** All resources are provisioned in `us-east-1`.

### 2. Architecture
```
[ aws s3 cp file.csv s3://...incoming/ ]
              |
              v
   [ S3 Bucket: demo-pipeline-uploads-<acct>-us-east-1 ]
        - SSE: AES256, Block Public Access: ALL ON
        - NotificationConfiguration: prefix=incoming/, ObjectCreated -> Lambda
              |
              v
   [ Lambda: demo-pipeline-processor ]
        - Reads object, parses CSV/JSON, batch-writes to DynamoDB
              |
              v
   [ DynamoDB: demo-pipeline-records ]
        - pk = S3 key, sk = "<row-index>-<uuid8>", plus row fields
```

### 3. Files
- `pipeline-template.yaml` — bucket, table, Lambda (inline Python), IAM role, invoke permission.
- `pipeline-deploy.sh` — `cloudformation deploy`, attaches the S3 notification (out-of-band to avoid the well-known CFN circular dep), uploads a sample CSV, polls DynamoDB to confirm.
- `pipeline-teardown.sh` — empties the bucket (objects + versions + delete markers), deletes the stack, removes the Lambda log group.

### 4. Prerequisites
- AWS CLI configured with credentials that can manage S3, Lambda, DynamoDB, IAM, and CloudFormation.
- `python3` (only used locally if you want to lint).

### 5. Step-by-Step
```bash
./pipeline-deploy.sh
```

Upload the bundled `sample.csv` (10 rows: id,name,amount) to trigger the pipeline:
```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="demo-pipeline-uploads-${ACCT}-us-east-1"

aws s3 cp sample.csv s3://$BUCKET/incoming/sample.csv

# tail the Lambda logs while it processes:
aws logs tail /aws/lambda/demo-pipeline-processor --region us-east-1 --follow

# query the items the Lambda wrote (one S3 key = one pk):
aws dynamodb query --region us-east-1 --table-name demo-pipeline-records \
  --key-condition-expression "pk = :k" \
  --expression-attribute-values '{":k":{"S":"incoming/sample.csv"}}' \
  --output table
```

Expected: 10 items, each with `pk=incoming/sample.csv`, a unique `sk`, and the `id`/`name`/`amount` fields from the CSV row. JSON works the same way — drop a `.json` file (object or array of objects) under `incoming/` and each object becomes one item.

### 6. Validation
- `pipeline-deploy.sh` ends by querying DynamoDB for the sample CSV's key and printing the items it wrote — you should see three rows (alice/bob/carol).
- Lambda logs show `Wrote 3 items from s3://...`.

### 7. Cleanup
```bash
./pipeline-teardown.sh
```
