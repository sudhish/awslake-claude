#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# upload_data.sh
# Uploads the sample_sales.csv file to the Lake Formation data lake S3 bucket.
#
# Usage:
#   ./upload_data.sh [<bucket-name>]
#
# If no bucket name is supplied as the first argument, the script attempts to
# retrieve it from the Terraform output in the parent directory.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_FILE="${SCRIPT_DIR}/../data/sample_sales.csv"
S3_KEY="sales/sample_sales.csv"

# Resolve bucket: prefer explicit argument, fall back to terraform output
BUCKET="${1:-$(terraform -chdir="${SCRIPT_DIR}/.." output -raw data_lake_bucket_name 2>/dev/null || true)}"

if [[ -z "${BUCKET}" ]]; then
  echo "ERROR: Could not determine S3 bucket name." >&2
  echo "       Either pass it as the first argument or run 'terraform apply' in the project root first." >&2
  exit 1
fi

if [[ ! -f "${DATA_FILE}" ]]; then
  echo "ERROR: Data file not found at ${DATA_FILE}" >&2
  exit 1
fi

S3_URI="s3://${BUCKET}/${S3_KEY}"

echo "Uploading ${DATA_FILE} to ${S3_URI} ..."
aws s3 cp "${DATA_FILE}" "${S3_URI}"

echo ""
echo "Upload complete: ${S3_URI}"
