#!/usr/bin/env bash
# Empty the report bucket (all versions), delete the stack, then prove nothing is left.
set -u
cd "$(dirname "$0")" || exit 1
export AWS_REGION="${AWS_REGION:-us-east-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"
STACK="${STACK_NAME:-access-key-hygiene}"
. lib/s3.sh
. lib/cfn.sh
rc=0

BUCKET=$(stack_output "$STACK" BucketName)
FN=$(stack_output "$STACK" FunctionName)
RULE=$(stack_output "$STACK" RuleName)
[ -n "$FN" ] || FN="$STACK-hygiene"
[ -n "$RULE" ] || RULE="$STACK-daily"

if [ -n "$BUCKET" ]; then
  echo "== empty bucket first"
  empty_bucket "$BUCKET" || rc=1
fi

echo "== delete stack"
delete_stack_and_wait "$STACK" 1200 || rc=1

echo "== verify nothing is left"
stack_gone "$STACK" || rc=1
[ -n "$BUCKET" ] && { bucket_gone "$BUCKET" || rc=1; }
log_group_gone "/aws/lambda/$FN" || rc=1
if aws lambda get-function --function-name "$FN" >/dev/null 2>&1; then
  echo "  LEFTOVER: function $FN" >&2; rc=1
else
  echo "  ok: function $FN is gone"
fi
if aws events describe-rule --name "$RULE" >/dev/null 2>&1; then
  echo "  LEFTOVER: rule $RULE" >&2; rc=1
else
  echo "  ok: rule $RULE is gone"
fi
rm -rf build response.json
echo "(report.json, if downloaded, is still on local disk; delete it when done)"
if [ "$rc" -eq 0 ]; then echo "TEARDOWN OK"; else echo "TEARDOWN INCOMPLETE (see LEFTOVER lines)"; fi
exit "$rc"
