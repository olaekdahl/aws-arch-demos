# Architecting on AWS 7.12.0 — Hands-On Demos

A practical demo set aligned to the AWS *Architecting on AWS* (v7.12.0) modules.

## Conventions
- **Region:** `us-east-1` (override via `export AWS_REGION=...`)
- **Naming:** `demo-{service}-{purpose}`
- **Single-file rule:** each demo is intentionally kept in ONE file for follow-along clarity, even when production would split it.
- **Cost:** Everything is free-tier or cents-per-hour. Run cleanup steps when done.

## Prerequisites (global)
```bash
aws --version              # AWS CLI v2
python3 --version          # 3.10+
pip install boto3
aws configure              # access key / region / output
aws sts get-caller-identity
```

## Modules
| # | Module | Demo Files |
|---|--------|-----------|
| 0 | Introduction | `mod00-intro/` |
| 1 | Architecting Fundamentals | `mod01-fundamentals/` |
| 2 | Account Security | `mod02-account-security/` |
| 3 | Networking 1 | `mod03-networking/` |
| 4 | Compute | `mod04-compute/` |
| 5 | Storage | `mod05-storage/` |
| 6 | Database Services | `mod06-database/` |
| 7 | Monitoring and Scaling | `mod07-monitoring-scaling/` |
| 8 | Automation | `mod08-automation/` |
| 9 | Containers | `mod09-containers/` |
| 10 | Networking 2 | `mod10-networking2/` |
| 11 | Serverless | `mod11-serverless/` |
| 12 | Edge Services | `mod12-edge/` |
| 13 | Backup and Recovery | `mod13-backup-recovery/` |
| 14 | Course Summary | `mod14-summary/` |
