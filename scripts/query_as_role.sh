#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# query_as_role.sh
# Demonstrates Lake Formation RBAC by assuming an IAM role and running an
# Athena query under that role's permissions.
#
# Usage:
#   ./query_as_role.sh <role_arn> <workgroup> <database> <query>
#
# Example:
#   ./query_as_role.sh \
#     arn:aws:iam::123456789012:role/lf-analyst-role \
#     primary \
#     sales_db \
#     "SELECT id, name, country, revenue FROM sales_data LIMIT 10"
#
# The script will:
#   1. Assume the given IAM role via STS
#   2. Export temporary credentials into the current shell environment
#   3. Submit the Athena query against the specified workgroup/database
#   4. Poll Athena until the query completes or fails
#   5. Print the result rows to stdout
# ---------------------------------------------------------------------------

# ---- argument validation ---------------------------------------------------
if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <role_arn> <workgroup> <database> <query>" >&2
  echo "" >&2
  echo "Example:" >&2
  echo "  $0 arn:aws:iam::123456789012:role/lf-analyst-role primary sales_db \\" >&2
  echo "     \"SELECT id, name, country, revenue FROM sales_data LIMIT 10\"" >&2
  exit 1
fi

ROLE_ARN="$1"
WORKGROUP="$2"
DATABASE="$3"
QUERY="$4"

POLL_INTERVAL=3   # seconds between status checks
MAX_ATTEMPTS=60   # maximum poll iterations (~3 minutes)

# ---- assume the target role ------------------------------------------------
echo "Assuming role: ${ROLE_ARN}"

CREDENTIALS="$(aws sts assume-role \
  --role-arn "${ROLE_ARN}" \
  --role-session-name "lf-rbac-test-$(date +%s)" \
  --query 'Credentials.{AccessKeyId:AccessKeyId,SecretAccessKey:SecretAccessKey,SessionToken:SessionToken}' \
  --output json)"

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_SESSION_TOKEN

AWS_ACCESS_KEY_ID="$(echo "${CREDENTIALS}"    | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKeyId'])")"
AWS_SECRET_ACCESS_KEY="$(echo "${CREDENTIALS}" | python3 -c "import sys,json; print(json.load(sys.stdin)['SecretAccessKey'])")"
AWS_SESSION_TOKEN="$(echo "${CREDENTIALS}"    | python3 -c "import sys,json; print(json.load(sys.stdin)['SessionToken'])")"

echo "Credentials obtained. Running query as assumed role."
echo ""

# ---- submit Athena query ---------------------------------------------------
echo "Database : ${DATABASE}"
echo "Workgroup: ${WORKGROUP}"
echo "Query    : ${QUERY}"
echo ""

EXECUTION_ID="$(aws athena start-query-execution \
  --query-string "${QUERY}" \
  --work-group "${WORKGROUP}" \
  --query-execution-context "Database=${DATABASE}" \
  --query 'QueryExecutionId' \
  --output text)"

echo "Query execution ID: ${EXECUTION_ID}"
echo "Polling for completion ..."

# ---- poll until the query finishes -----------------------------------------
ATTEMPT=0
while true; do
  ATTEMPT=$((ATTEMPT + 1))

  STATUS="$(aws athena get-query-execution \
    --query-execution-id "${EXECUTION_ID}" \
    --query 'QueryExecution.Status.State' \
    --output text)"

  case "${STATUS}" in
    SUCCEEDED)
      echo "Query SUCCEEDED."
      break
      ;;
    FAILED|CANCELLED)
      REASON="$(aws athena get-query-execution \
        --query-execution-id "${EXECUTION_ID}" \
        --query 'QueryExecution.Status.StateChangeReason' \
        --output text 2>/dev/null || echo "unknown")"
      echo "ERROR: Query ${STATUS}. Reason: ${REASON}" >&2
      exit 1
      ;;
    QUEUED|RUNNING)
      if [[ "${ATTEMPT}" -ge "${MAX_ATTEMPTS}" ]]; then
        echo "ERROR: Timed out waiting for query to complete (${MAX_ATTEMPTS} attempts)." >&2
        exit 1
      fi
      echo "  [${ATTEMPT}/${MAX_ATTEMPTS}] Status: ${STATUS} — waiting ${POLL_INTERVAL}s ..."
      sleep "${POLL_INTERVAL}"
      ;;
    *)
      echo "WARNING: Unknown status '${STATUS}', continuing to poll ..." >&2
      sleep "${POLL_INTERVAL}"
      ;;
  esac
done

# ---- retrieve and print results --------------------------------------------
echo ""
echo "Results:"
echo "--------"

aws athena get-query-results \
  --query-execution-id "${EXECUTION_ID}" \
  --query 'ResultSet.Rows[*].Data[*].VarCharValue' \
  --output text | column -t -s $'\t' || \
aws athena get-query-results \
  --query-execution-id "${EXECUTION_ID}" \
  --output text

echo ""
echo "Done. Query execution ID: ${EXECUTION_ID}"
