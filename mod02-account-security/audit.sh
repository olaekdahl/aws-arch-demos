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
