#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AWS Lake Formation RBAC Validation Test Suite
# =============================================================================
# Tests all three IAM roles against Athena to verify that Lake Formation's
# row-level and column-level security policies are correctly enforced.
#
# Usage: bash tests/test_rbac.sh
# Prerequisites: AWS CLI, jq, terraform applied, data uploaded to S3
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# Test counters
# ---------------------------------------------------------------------------
TOTAL_TESTS=9
PASSED=0
FAILED=0

# ---------------------------------------------------------------------------
# Read terraform outputs
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${CYAN}=== AWS Lake Formation RBAC Test Suite ===${RESET}"
echo ""
echo "Reading terraform outputs from: ${TERRAFORM_DIR}"

if ! command -v terraform &>/dev/null; then
  echo -e "${RED}ERROR: terraform not found in PATH${RESET}" >&2
  exit 1
fi

if ! command -v aws &>/dev/null; then
  echo -e "${RED}ERROR: aws CLI not found in PATH${RESET}" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo -e "${RED}ERROR: jq not found in PATH${RESET}" >&2
  exit 1
fi

pushd "${TERRAFORM_DIR}" > /dev/null

ANALYST_US_ROLE_ARN=$(terraform output -raw analyst_us_role_arn)
ANALYST_GLOBAL_ROLE_ARN=$(terraform output -raw analyst_global_role_arn)
DATA_STEWARD_ROLE_ARN=$(terraform output -raw data_steward_role_arn)
WORKGROUP=$(terraform output -raw athena_workgroup_name)
DATABASE=$(terraform output -raw glue_database_name)
TABLE=$(terraform output -raw glue_table_name)
RESULTS_BUCKET=$(terraform output -raw athena_results_bucket)
AWS_REGION=$(terraform output -raw aws_region)

popd > /dev/null

echo ""
echo "  analyst-us ARN    : ${ANALYST_US_ROLE_ARN}"
echo "  analyst-global ARN: ${ANALYST_GLOBAL_ROLE_ARN}"
echo "  data-steward ARN  : ${DATA_STEWARD_ROLE_ARN}"
echo "  Athena workgroup  : ${WORKGROUP}"
echo "  Glue database     : ${DATABASE}"
echo "  Glue table        : ${TABLE}"
echo "  Results bucket    : ${RESULTS_BUCKET}"
echo "  AWS region        : ${AWS_REGION}"
echo ""

# ---------------------------------------------------------------------------
# run_athena_query_as_role()
#
# Assumes the given IAM role, submits an Athena query, polls until it
# finishes (max 60 s), writes results to stdout, then unsets temp creds.
#
# Args:
#   $1  role_arn
#   $2  sql_query
#   $3  workgroup
#   $4  database
#
# Stdout: raw JSON from athena get-query-results
# Returns: 0 on success, 1 on query failure or timeout
# ---------------------------------------------------------------------------
run_athena_query_as_role() {
  local role_arn="$1"
  local query="$2"
  local workgroup="$3"
  local database="$4"

  # -- Assume the target role --------------------------------------------
  local creds
  creds=$(aws sts assume-role \
    --role-arn "${role_arn}" \
    --role-session-name "rbac-test-$$" \
    --duration-seconds 900 \
    --output json \
    --region "${AWS_REGION}")

  local saved_key="${AWS_ACCESS_KEY_ID:-}"
  local saved_secret="${AWS_SECRET_ACCESS_KEY:-}"
  local saved_token="${AWS_SESSION_TOKEN:-}"

  export AWS_ACCESS_KEY_ID=$(echo "${creds}"    | jq -r '.Credentials.AccessKeyId')
  export AWS_SECRET_ACCESS_KEY=$(echo "${creds}" | jq -r '.Credentials.SecretAccessKey')
  export AWS_SESSION_TOKEN=$(echo "${creds}"     | jq -r '.Credentials.SessionToken')

  # -- Submit the query --------------------------------------------------
  local results_prefix="s3://${RESULTS_BUCKET}/test-runs/$$"

  local execution_id
  execution_id=$(aws athena start-query-execution \
    --query-string "${query}" \
    --work-group "${workgroup}" \
    --query-execution-context "Database=${database}" \
    --result-configuration "OutputLocation=${results_prefix}" \
    --region "${AWS_REGION}" \
    --output json | jq -r '.QueryExecutionId')

  # -- Poll for completion (max 60 s) ------------------------------------
  local max_wait=60
  local elapsed=0
  local state=""

  while [[ ${elapsed} -lt ${max_wait} ]]; do
    state=$(aws athena get-query-execution \
      --query-execution-id "${execution_id}" \
      --region "${AWS_REGION}" \
      --output json | jq -r '.QueryExecution.Status.State')

    case "${state}" in
      SUCCEEDED)
        break
        ;;
      FAILED|CANCELLED)
        local reason
        reason=$(aws athena get-query-execution \
          --query-execution-id "${execution_id}" \
          --region "${AWS_REGION}" \
          --output json | jq -r '.QueryExecution.Status.StateChangeReason // "unknown"')
        echo "ATHENA_ERROR: Query ${state}: ${reason}" >&2
        # Restore original credentials before returning
        _restore_credentials "${saved_key}" "${saved_secret}" "${saved_token}"
        return 1
        ;;
      *)
        sleep 3
        elapsed=$((elapsed + 3))
        ;;
    esac
  done

  if [[ "${state}" != "SUCCEEDED" ]]; then
    echo "ATHENA_ERROR: Query timed out after ${max_wait}s (state: ${state})" >&2
    _restore_credentials "${saved_key}" "${saved_secret}" "${saved_token}"
    return 1
  fi

  # -- Fetch results -----------------------------------------------------
  local results
  results=$(aws athena get-query-results \
    --query-execution-id "${execution_id}" \
    --region "${AWS_REGION}" \
    --output json)

  # -- Restore original credentials -------------------------------------
  _restore_credentials "${saved_key}" "${saved_secret}" "${saved_token}"

  echo "${results}"
  return 0
}

# Internal helper: restore caller credentials after role assumption
_restore_credentials() {
  local key="$1" secret="$2" token="$3"

  if [[ -n "${key}" ]]; then
    export AWS_ACCESS_KEY_ID="${key}"
  else
    unset AWS_ACCESS_KEY_ID
  fi

  if [[ -n "${secret}" ]]; then
    export AWS_SECRET_ACCESS_KEY="${secret}"
  else
    unset AWS_SECRET_ACCESS_KEY
  fi

  if [[ -n "${token}" ]]; then
    export AWS_SESSION_TOKEN="${token}"
  else
    unset AWS_SESSION_TOKEN
  fi
}

# ---------------------------------------------------------------------------
# assert_row_count()
#
# Extracts the first numeric data cell from Athena JSON results and
# compares it against the expected value.
#
# Args:
#   $1  results_json   - raw JSON from get-query-results
#   $2  expected_count - integer
#   $3  test_name      - human-readable label (for PASS/FAIL output)
# ---------------------------------------------------------------------------
assert_row_count() {
  local results_json="$1"
  local expected_count="$2"
  local test_name="$3"

  # The first row of ResultSet.Rows is the column header; the second row
  # holds the first data row. We want the VarCharValue of the first column
  # in the first data row (index 1).
  local actual_count
  actual_count=$(echo "${results_json}" \
    | jq -r '.ResultSet.Rows[1].Data[0].VarCharValue // "ERROR"')

  if [[ "${actual_count}" == "${expected_count}" ]]; then
    echo -e "  ${GREEN}PASS${RESET}  ${test_name} (got ${actual_count}, expected ${expected_count})"
    PASSED=$((PASSED + 1))
  else
    echo -e "  ${RED}FAIL${RESET}  ${test_name} (got ${actual_count}, expected ${expected_count})"
    FAILED=$((FAILED + 1))
  fi
}

# ---------------------------------------------------------------------------
# assert_column_absent()
#
# Checks that the given column name does NOT appear in the result header row.
#
# Args:
#   $1  results_json - raw JSON from get-query-results
#   $2  column_name  - column name to search for (case-insensitive)
#   $3  test_name    - human-readable label
# ---------------------------------------------------------------------------
assert_column_absent() {
  local results_json="$1"
  local column_name="$2"
  local test_name="$3"

  # Extract all column names from the header row (index 0)
  local header_cols
  header_cols=$(echo "${results_json}" \
    | jq -r '[.ResultSet.Rows[0].Data[].VarCharValue] | map(ascii_downcase) | join(",")')

  local needle
  needle=$(echo "${column_name}" | tr '[:upper:]' '[:lower:]')

  if echo "${header_cols}" | grep -qw "${needle}"; then
    echo -e "  ${RED}FAIL${RESET}  ${test_name} (column '${column_name}' is present but should be hidden)"
    FAILED=$((FAILED + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}  ${test_name} (column '${column_name}' is correctly hidden)"
    PASSED=$((PASSED + 1))
  fi
}

# ---------------------------------------------------------------------------
# assert_column_present()
#
# Checks that the given column name DOES appear in the result header row.
#
# Args:
#   $1  results_json - raw JSON from get-query-results
#   $2  column_name  - column name to search for (case-insensitive)
#   $3  test_name    - human-readable label
# ---------------------------------------------------------------------------
assert_column_present() {
  local results_json="$1"
  local column_name="$2"
  local test_name="$3"

  local header_cols
  header_cols=$(echo "${results_json}" \
    | jq -r '[.ResultSet.Rows[0].Data[].VarCharValue] | map(ascii_downcase) | join(",")')

  local needle
  needle=$(echo "${column_name}" | tr '[:upper:]' '[:lower:]')

  if echo "${header_cols}" | grep -qw "${needle}"; then
    echo -e "  ${GREEN}PASS${RESET}  ${test_name} (column '${column_name}' is visible as expected)"
    PASSED=$((PASSED + 1))
  else
    echo -e "  ${RED}FAIL${RESET}  ${test_name} (column '${column_name}' is missing but should be visible)"
    FAILED=$((FAILED + 1))
  fi
}

# ---------------------------------------------------------------------------
# run_test()
#
# Wrapper that calls run_athena_query_as_role and handles query-level errors
# so a single failed query does not abort the entire suite.
#
# Args:
#   $1  role_arn
#   $2  query
#   $3  test_name   - used in error output if query itself fails
#
# Stdout: results JSON on success, empty string on failure
# ---------------------------------------------------------------------------
run_test() {
  local role_arn="$1"
  local query="$2"
  local test_name="$3"

  local result
  if result=$(run_athena_query_as_role \
        "${role_arn}" \
        "${query}" \
        "${WORKGROUP}" \
        "${DATABASE}" 2>&1); then
    echo "${result}"
  else
    echo -e "  ${RED}FAIL${RESET}  ${test_name} (Athena query error: ${result})" >&2
    FAILED=$((FAILED + 1))
    echo ""   # empty result so callers can still run without crashing
  fi
}

# =============================================================================
# TEST CASES
# =============================================================================

echo -e "${BOLD}Running ${TOTAL_TESTS} tests...${RESET}"
echo ""

# ---------------------------------------------------------------------------
# analyst-us tests
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Role: analyst-us ---${RESET}"

# Test 1: analyst-us sees ONLY US rows (non-US count must be 0)
echo "Test 1: analyst-us sees only US rows"
T1_RESULT=$(run_test \
  "${ANALYST_US_ROLE_ARN}" \
  "SELECT COUNT(*) AS cnt FROM ${TABLE} WHERE country != 'US'" \
  "Test 1: analyst-us non-US row count = 0")
if [[ -n "${T1_RESULT}" ]]; then
  assert_row_count "${T1_RESULT}" "0" "Test 1: analyst-us non-US row count = 0"
fi

# Test 2: analyst-us total row count equals 22 (US-only rows)
echo "Test 2: analyst-us total row count = 22"
T2_RESULT=$(run_test \
  "${ANALYST_US_ROLE_ARN}" \
  "SELECT COUNT(*) AS cnt FROM ${TABLE}" \
  "Test 2: analyst-us total row count = 22")
if [[ -n "${T2_RESULT}" ]]; then
  assert_row_count "${T2_RESULT}" "22" "Test 2: analyst-us total row count = 22"
fi

# Test 3: analyst-us cannot see the email column
echo "Test 3: analyst-us email column is hidden"
T3_RESULT=$(run_test \
  "${ANALYST_US_ROLE_ARN}" \
  "SELECT * FROM ${TABLE} LIMIT 1" \
  "Test 3: analyst-us email column absent")
if [[ -n "${T3_RESULT}" ]]; then
  assert_column_absent "${T3_RESULT}" "email" "Test 3: analyst-us email column absent"
fi

echo ""

# ---------------------------------------------------------------------------
# analyst-global tests
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Role: analyst-global ---${RESET}"

# Test 4: analyst-global sees all 60 rows
echo "Test 4: analyst-global total row count = 60"
T4_RESULT=$(run_test \
  "${ANALYST_GLOBAL_ROLE_ARN}" \
  "SELECT COUNT(*) AS cnt FROM ${TABLE}" \
  "Test 4: analyst-global total row count = 60")
if [[ -n "${T4_RESULT}" ]]; then
  assert_row_count "${T4_RESULT}" "60" "Test 4: analyst-global total row count = 60"
fi

# Test 5: analyst-global sees all 6 distinct countries
echo "Test 5: analyst-global distinct country count = 6"
T5_RESULT=$(run_test \
  "${ANALYST_GLOBAL_ROLE_ARN}" \
  "SELECT COUNT(DISTINCT country) AS cnt FROM ${TABLE}" \
  "Test 5: analyst-global distinct country count = 6")
if [[ -n "${T5_RESULT}" ]]; then
  assert_row_count "${T5_RESULT}" "6" "Test 5: analyst-global distinct country count = 6"
fi

# Test 6: analyst-global cannot see the email column
echo "Test 6: analyst-global email column is hidden"
T6_RESULT=$(run_test \
  "${ANALYST_GLOBAL_ROLE_ARN}" \
  "SELECT * FROM ${TABLE} LIMIT 1" \
  "Test 6: analyst-global email column absent")
if [[ -n "${T6_RESULT}" ]]; then
  assert_column_absent "${T6_RESULT}" "email" "Test 6: analyst-global email column absent"
fi

echo ""

# ---------------------------------------------------------------------------
# data-steward tests
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Role: data-steward ---${RESET}"

# Test 7: data-steward sees all 60 rows
echo "Test 7: data-steward total row count = 60"
T7_RESULT=$(run_test \
  "${DATA_STEWARD_ROLE_ARN}" \
  "SELECT COUNT(*) AS cnt FROM ${TABLE}" \
  "Test 7: data-steward total row count = 60")
if [[ -n "${T7_RESULT}" ]]; then
  assert_row_count "${T7_RESULT}" "60" "Test 7: data-steward total row count = 60"
fi

# Test 8: data-steward CAN see the email column
echo "Test 8: data-steward email column is visible"
T8_RESULT=$(run_test \
  "${DATA_STEWARD_ROLE_ARN}" \
  "SELECT * FROM ${TABLE} LIMIT 1" \
  "Test 8: data-steward email column present")
if [[ -n "${T8_RESULT}" ]]; then
  assert_column_present "${T8_RESULT}" "email" "Test 8: data-steward email column present"
fi

# Test 9: data-steward can query email column directly
echo "Test 9: data-steward direct email query returns 60 non-null rows"
T9_RESULT=$(run_test \
  "${DATA_STEWARD_ROLE_ARN}" \
  "SELECT COUNT(*) AS cnt FROM ${TABLE} WHERE email IS NOT NULL" \
  "Test 9: data-steward email IS NOT NULL count = 60")
if [[ -n "${T9_RESULT}" ]]; then
  assert_row_count "${T9_RESULT}" "60" "Test 9: data-steward email IS NOT NULL count = 60"
fi

echo ""

# =============================================================================
# SUMMARY
# =============================================================================
echo -e "${BOLD}${CYAN}=== Test Summary ===${RESET}"
echo ""
echo -e "  Total tests : ${TOTAL_TESTS}"
echo -e "  ${GREEN}Passed      : ${PASSED}${RESET}"
if [[ ${FAILED} -gt 0 ]]; then
  echo -e "  ${RED}Failed      : ${FAILED}${RESET}"
else
  echo -e "  Failed      : ${FAILED}"
fi
echo ""

if [[ ${FAILED} -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All ${TOTAL_TESTS} tests PASSED. Lake Formation RBAC is correctly configured.${RESET}"
  exit 0
else
  echo -e "${RED}${BOLD}${FAILED} of ${TOTAL_TESTS} tests FAILED. Review the output above.${RESET}"
  echo ""
  echo "Common causes:"
  echo "  - Lake Formation permission propagation delay (wait 60-120 s and retry)"
  echo "  - Data not yet uploaded to S3 (run: bash scripts/upload_data.sh)"
  echo "  - Role trust policy missing your caller identity"
  echo "  - Data cells filter not attached to the correct IAM roles"
  exit 1
fi
