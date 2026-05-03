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
