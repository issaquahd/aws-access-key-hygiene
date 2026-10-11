#!/usr/bin/env bash
# Invoke the hygiene function now (instead of waiting for the daily rule) and download the report.
set -u
cd "$(dirname "$0")" || exit 1
export AWS_REGION="${AWS_REGION:-us-east-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"
STACK="${STACK_NAME:-access-key-hygiene}"
. lib/cfn.sh

FN=$(stack_output "$STACK" FunctionName)
BUCKET=$(stack_output "$STACK" BucketName)
[ -n "$FN" ] || { echo "Stack $STACK not found; run ./deploy.sh" >&2; exit 1; }

echo "== invoking $FN (the credential report can take a few seconds to generate)"
fn_error=$(aws lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out \
  --payload '{}' --cli-read-timeout 180 --query FunctionError --output text response.json) || exit 1
if [ -n "$fn_error" ] && [ "$fn_error" != "None" ]; then
  echo "Function error ($fn_error):" >&2
  cat response.json >&2
  exit 1
fi
KEY=$(jq -r .key response.json)
echo "== downloading s3://$BUCKET/$KEY -> report.json"
aws s3 cp "s3://$BUCKET/$KEY" report.json --only-show-errors || exit 1
jq .summary report.json
jq -r '.findings[] | [.type, .user, (.key // "" | tostring), (.age_days // .unused_days // "" | tostring)] | @tsv' report.json |
  column -t -s "$(printf '\t')"
echo "report.json contains IAM user names; it is gitignored."
