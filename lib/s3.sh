# shellcheck shell=bash
# Shared S3 helpers. Source this file; requires aws CLI and jq (both preinstalled in CloudShell).

# empty_bucket BUCKET
# Deletes every object version and delete marker, in batches of up to 1000,
# then confirms the bucket is empty. Safe to call on a bucket that no longer exists.
empty_bucket() {
  local bucket="$1" batch count total=0
  if ! aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    echo "  s3://$bucket not found (already deleted)"
    return 0
  fi
  echo "  emptying s3://$bucket (all object versions and delete markers)"
  while true; do
    batch=$(aws s3api list-object-versions --bucket "$bucket" --max-items 1000 --output json |
      jq -c '{Objects: ([(.Versions // [])[], (.DeleteMarkers // [])[]] | map({Key, VersionId}) | .[:1000]), Quiet: true}')
    count=$(jq '.Objects | length' <<<"$batch")
    if [ "$count" -eq 0 ]; then
      break
    fi
    aws s3api delete-objects --bucket "$bucket" --delete "$batch" >/dev/null
    total=$((total + count))
    echo "  deleted $total versions/markers so far"
  done
  bucket_is_empty "$bucket"
}

# bucket_is_empty BUCKET -> exit 0 if no versions and no delete markers remain
bucket_is_empty() {
  local bucket="$1" left
  left=$(aws s3api list-object-versions --bucket "$bucket" --max-items 1000 --output json |
    jq '[(.Versions // [])[], (.DeleteMarkers // [])[]] | length')
  if [ "$left" -ne 0 ]; then
    echo "  ERROR: s3://$bucket still has $left versions/markers" >&2
    return 1
  fi
  echo "  s3://$bucket is empty"
}

# bucket_gone BUCKET -> exit 0 if the bucket no longer exists
bucket_gone() {
  if aws s3api head-bucket --bucket "$1" >/dev/null 2>&1; then
    echo "  LEFTOVER: bucket $1 still exists" >&2
    return 1
  fi
  echo "  ok: bucket $1 is gone"
}
