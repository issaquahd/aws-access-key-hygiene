#!/usr/bin/env bash
# Deploy the hygiene stack, then upload src/hygiene.py as the function code.
# Optional: MAX_KEY_AGE_DAYS, MAX_UNUSED_DAYS (default 90), STACK_NAME (default access-key-hygiene)
set -u
cd "$(dirname "$0")" || exit 1
export AWS_REGION="${AWS_REGION:-us-east-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"
STACK="${STACK_NAME:-access-key-hygiene}"
. lib/cfn.sh

echo "== deploying stack $STACK in $AWS_REGION"
aws cloudformation deploy --stack-name "$STACK" --template-file access-key-hygiene.yaml \
  --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
  --parameter-overrides "MaxKeyAgeDays=${MAX_KEY_AGE_DAYS:-90}" "MaxUnusedDays=${MAX_UNUSED_DAYS:-90}" || exit 1
FN=$(stack_output "$STACK" FunctionName)

echo "== packaging src/hygiene.py -> build/hygiene.zip (as index.py)"
rm -rf build && mkdir -p build && cp src/hygiene.py build/index.py || exit 1
(cd build && python3 -m zipfile -c hygiene.zip index.py) || exit 1

echo "== uploading code to $FN"
aws lambda update-function-code --function-name "$FN" --zip-file fileb://build/hygiene.zip \
  --query 'LastUpdateStatus' --output text || exit 1
aws lambda wait function-updated --function-name "$FN" || exit 1
aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Outputs' --output table
echo "Next: ./run-once.sh"
