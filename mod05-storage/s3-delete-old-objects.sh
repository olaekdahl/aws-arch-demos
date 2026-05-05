#!/usr/bin/env bash
#
# Scan S3 buckets for objects older than N days and delete them.
# Defaults to dry-run; pass --apply to actually delete.
#
# Usage:
#   ./s3-delete-old-objects.sh                          # dry-run, all buckets, 365 days
#   ./s3-delete-old-objects.sh --days 90                # dry-run, all buckets, 90 days
#   ./s3-delete-old-objects.sh --bucket my-bucket       # dry-run, single bucket
#   ./s3-delete-old-objects.sh --profile my-profile     # use a named AWS profile
#   ./s3-delete-old-objects.sh --apply                  # actually delete

set -euo pipefail

DAYS=365
BUCKET=""
APPLY="false"
REGION="${AWS_REGION:-}"
PROFILE="${AWS_PROFILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)    DAYS="$2"; shift 2 ;;
    --bucket)  BUCKET="$2"; shift 2 ;;
    --region)  REGION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --apply)   APPLY="true"; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

AWS_ARGS=()
[[ -n "$PROFILE" ]] && AWS_ARGS+=(--profile "$PROFILE")

command -v aws >/dev/null || { echo "aws CLI not found" >&2; exit 1; }
command -v jq  >/dev/null || { echo "jq not found"      >&2; exit 1; }

# Cutoff in ISO-8601 UTC; S3 LastModified is ISO-8601, so string compare works.
CUTOFF=$(date -u -d "${DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)

if [[ -n "$BUCKET" ]]; then
  BUCKETS=("$BUCKET")
else
  mapfile -t BUCKETS < <(aws "${AWS_ARGS[@]}" s3api list-buckets --query 'Buckets[].Name' --output text | tr '\t' '\n')
fi

echo "Mode:    $([[ "$APPLY" == "true" ]] && echo APPLY || echo DRY-RUN)"
echo "Profile: ${PROFILE:-<default>}"
echo "Cutoff:  objects with LastModified < $CUTOFF (older than ${DAYS} days)"
echo "Buckets: ${#BUCKETS[@]}"
echo

total_found=0
total_deleted=0

for b in "${BUCKETS[@]}"; do
  [[ -z "$b" ]] && continue

  # Resolve bucket region (S3 is global but list-objects-v2 needs the bucket's region).
  bregion=$(aws "${AWS_ARGS[@]}" s3api get-bucket-location --bucket "$b" --query 'LocationConstraint' --output text 2>/dev/null || echo "")
  [[ "$bregion" == "None" || -z "$bregion" ]] && bregion="us-east-1"
  [[ -n "$REGION" ]] && bregion="$REGION"

  echo "== bucket: $b (region: $bregion) =="

  # Stream keys + sizes for objects older than cutoff. Paginates automatically.
  old_objects=$(aws "${AWS_ARGS[@]}" s3api list-objects-v2 \
      --bucket "$b" \
      --region "$bregion" \
      --query "Contents[?LastModified<'${CUTOFF}'].[Key,LastModified,Size]" \
      --output json 2>/dev/null || echo "[]")

  count=$(jq 'length' <<<"$old_objects")
  if [[ "$count" -eq 0 ]]; then
    echo "  (no objects older than cutoff)"
    continue
  fi

  total_found=$((total_found + count))
  echo "  found: $count old object(s)"

  # Show a small sample so a dry-run is informative.
  jq -r '.[0:5][] | "    - \(.[0])  (\(.[1]), \(.[2]) bytes)"' <<<"$old_objects"
  [[ "$count" -gt 5 ]] && echo "    ... and $((count - 5)) more"

  if [[ "$APPLY" != "true" ]]; then
    continue
  fi

  # delete-objects accepts up to 1000 keys per call.
  while read -r batch; do
    [[ -z "$batch" || "$batch" == "null" ]] && continue
    deleted=$(aws "${AWS_ARGS[@]}" s3api delete-objects \
        --bucket "$b" \
        --region "$bregion" \
        --delete "$batch" \
        --query 'length(Deleted)' \
        --output text)
    total_deleted=$((total_deleted + deleted))
    echo "  deleted batch: $deleted"
  done < <(jq -c '
      [.[] | {Key: .[0]}]
      | _nwise(1000)
      | {Objects: ., Quiet: true}
    ' <<<"$old_objects")
done

echo
echo "Summary: found=$total_found deleted=$total_deleted mode=$([[ "$APPLY" == "true" ]] && echo APPLY || echo DRY-RUN)"
