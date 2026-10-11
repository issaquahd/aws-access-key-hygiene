# shellcheck shell=bash
# Shared CloudFormation helpers. Source this file.

# stack_output STACK KEY -> prints the output value (empty if missing)
stack_output() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text 2>/dev/null | sed 's/^None$//'
}

# stack_exists STACK -> exit 0 if the stack exists (in any non-deleted state)
stack_exists() {
  aws cloudformation describe-stacks --stack-name "$1" >/dev/null 2>&1
}

# delete_stack_and_wait STACK [TIMEOUT_SECONDS]
# Polls with a progress line every 20 s instead of a silent waiter.
delete_stack_and_wait() {
  local stack="$1" timeout="${2:-2700}" waited=0 status
  if ! stack_exists "$stack"; then
    echo "  stack $stack not found (already deleted)"
    return 0
  fi
  echo "  deleting stack $stack"
  aws cloudformation delete-stack --stack-name "$stack"
  while true; do
    status=$(aws cloudformation describe-stacks --stack-name "$stack" \
      --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo GONE)
    case "$status" in
      GONE|DELETE_COMPLETE)
        echo "  stack $stack deleted after ${waited}s"
        return 0 ;;
      DELETE_FAILED)
        echo "  ERROR: $stack is DELETE_FAILED; see: aws cloudformation describe-stack-events --stack-name $stack" >&2
        return 1 ;;
    esac
    if [ "$waited" -ge "$timeout" ]; then
      echo "  ERROR: timed out after ${waited}s; $stack is $status" >&2
      return 1
    fi
    echo "  ... $stack is $status (${waited}s)"
    sleep 20
    waited=$((waited + 20))
  done
}

# stack_gone STACK -> exit 0 if the stack no longer exists
stack_gone() {
  if stack_exists "$1"; then
    echo "  LEFTOVER: stack $1 still exists" >&2
    return 1
  fi
  echo "  ok: stack $1 is gone"
}

# log_group_gone NAME -> deletes a leftover Lambda log group, then confirms it is gone
log_group_gone() {
  local name="$1" found
  found=$(aws logs describe-log-groups --log-group-name-prefix "$name" \
    --query "logGroups[?logGroupName=='$name'].logGroupName" --output text)
  if [ -n "$found" ] && [ "$found" != "None" ]; then
    echo "  deleting leftover log group $name"
    aws logs delete-log-group --log-group-name "$name"
  fi
  found=$(aws logs describe-log-groups --log-group-name-prefix "$name" \
    --query "logGroups[?logGroupName=='$name'].logGroupName" --output text)
  if [ -n "$found" ] && [ "$found" != "None" ]; then
    echo "  LEFTOVER: log group $name still exists" >&2
    return 1
  fi
  echo "  ok: log group $name is gone"
}
