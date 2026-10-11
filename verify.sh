#!/usr/bin/env bash
# Check the guardrails (private, encrypted bucket; daily schedule) and run the function once.
set -u
cd "$(dirname "$0")" || exit 1
export AWS_REGION="${AWS_REGION:-us-east-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"
STACK="${STACK_NAME:-access-key-hygiene}"
. lib/cfn.sh
rc=0
TAB=$(printf '\t')

BUCKET=$(stack_output "$STACK" BucketName)
RULE=$(stack_output "$STACK" RuleName)
[ -n "$BUCKET" ] || { echo "Stack $STACK not found; run ./deploy.sh" >&2; exit 1; }

bpa=$(aws s3api get-public-access-block --bucket "$BUCKET" \
  --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text)
if [ "$bpa" = "True${TAB}True${TAB}True${TAB}True" ]; then echo "PASS  Block Public Access all on"; else echo "FAIL  BPA: $bpa"; rc=1; fi
sse=$(aws s3api get-bucket-encryption --bucket "$BUCKET" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)
if [ "$sse" = "AES256" ]; then echo "PASS  default encryption SSE-S3"; else echo "FAIL  encryption: $sse"; rc=1; fi
sched=$(aws events describe-rule --name "$RULE" --query '[ScheduleExpression,State]' --output text)
if [ "$sched" = "rate(1 day)${TAB}ENABLED" ]; then echo "PASS  daily rule enabled"; else echo "FAIL  rule: $sched"; rc=1; fi

./run-once.sh >/dev/null || rc=1
if jq -e '.summary.iam_users >= 0' report.json >/dev/null 2>&1; then
  echo "PASS  report written and downloaded ($(jq -r .summary.findings report.json) findings)"
else
  echo "FAIL  no report"; rc=1
fi
if [ "$rc" -eq 0 ]; then echo "VERIFY OK"; else echo "VERIFY FAILED"; fi
exit "$rc"
