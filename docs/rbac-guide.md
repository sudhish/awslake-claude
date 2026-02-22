# RBAC Testing Guide: AWS Lake Formation POC

This guide walks through verifying that Lake Formation row-level and column-level security is correctly enforced for each of the three IAM roles deployed by this POC.

---

## Prerequisites

### AWS CLI

```bash
aws --version
# Requires: aws-cli/2.x or higher
```

### Terraform

```bash
terraform version
# Requires: >= 1.5.0
```

### AWS Credentials

Your local credentials must belong to an IAM principal that:

1. Has been granted **Lake Formation administrator** privileges (the Terraform `data_lake_admins` variable, or the principal used during `terraform apply` — which is auto-added as LF admin).
2. Has IAM permission to call `sts:AssumeRole` on the three analyst roles deployed by this stack.
3. Has sufficient IAM permissions to deploy the stack (see `docs/deployment-guide.md`).

Confirm your identity:

```bash
aws sts get-caller-identity
```

---

## Deployment Steps

```bash
cd /path/to/awslake-claude

# 1. Initialise Terraform providers and backend
terraform init

# 2. Review the execution plan
terraform plan

# 3. Apply — this creates all AWS resources
terraform apply
```

Terraform will output the resource names and role ARNs needed for testing. Note these values or retrieve them later with:

```bash
terraform output
```

---

## Data Upload

Upload the sample CSV to the S3 data lake bucket so Athena has data to query:

```bash
# Option A: auto-detect bucket from terraform output (run from project root)
bash scripts/upload_data.sh

# Option B: pass the bucket name explicitly
bash scripts/upload_data.sh awslake-claude-dev-datalake
```

The script uploads `data/sample_sales.csv` to `s3://<bucket>/sales/sample_sales.csv`.

Verify the upload:

```bash
BUCKET=$(terraform output -raw data_lake_bucket_name)
aws s3 ls "s3://${BUCKET}/sales/"
```

---

## Testing RBAC with query_as_role.sh

The script `scripts/query_as_role.sh` automates the full RBAC test loop:

1. Calls `aws sts assume-role` with the target role ARN.
2. Exports the temporary credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) into the shell environment.
3. Submits an Athena query using those credentials.
4. Polls until the query completes (up to ~3 minutes, polling every 3 seconds).
5. Prints the result rows to stdout.

### Script Usage

```bash
bash scripts/query_as_role.sh <role_arn> <workgroup> <database> <query>
```

### Retrieve Values from Terraform Output

```bash
ANALYST_US_ARN=$(terraform output -raw analyst_us_role_arn)
ANALYST_GLOBAL_ARN=$(terraform output -raw analyst_global_role_arn)
DATA_STEWARD_ARN=$(terraform output -raw data_steward_role_arn)
WORKGROUP=$(terraform output -raw athena_workgroup_name)
DATABASE=$(terraform output -raw glue_database_name)
```

### Test analyst-us (US rows only, no email column)

```bash
bash scripts/query_as_role.sh \
  "${ANALYST_US_ARN}" \
  "${WORKGROUP}" \
  "${DATABASE}" \
  "SELECT * FROM sales_data LIMIT 20"
```

### Test analyst-global (all rows, no email column)

```bash
bash scripts/query_as_role.sh \
  "${ANALYST_GLOBAL_ARN}" \
  "${WORKGROUP}" \
  "${DATABASE}" \
  "SELECT * FROM sales_data LIMIT 20"
```

### Test data-steward (all rows, all columns including email)

```bash
bash scripts/query_as_role.sh \
  "${DATA_STEWARD_ARN}" \
  "${WORKGROUP}" \
  "${DATABASE}" \
  "SELECT * FROM sales_data LIMIT 20"
```

---

## Expected Results Table

| Role | Countries Visible | `email` Column Visible | Row Count (full table) | Notes |
|---|---|---|---|---|
| `analyst-us` | **US only** | No | ~18 rows (US records in sample) | Row filter: `country = 'US'`; column exclusion via Data Cells Filter |
| `analyst-global` | **All** (US, UK, DE, FR, CA, AU) | No | 60 rows | No row filter; `email` excluded via explicit column list grant |
| `data-steward` | **All** | **Yes** | 60 rows | Full access; column wildcard grant in Lake Formation |

**Important**: If `SELECT *` is used against `analyst-us` or `analyst-global`, the `email` column will be absent from the result set entirely — it will not appear as NULL. Lake Formation removes it from the schema visible to those roles.

---

## Verification Queries

Use these targeted queries to verify each dimension of access control independently.

### 1. Verify Row-Level Filtering (analyst-us)

```sql
-- Run as analyst-us: should return only US rows
SELECT country, COUNT(*) AS row_count
FROM sales_data
GROUP BY country
ORDER BY country;
```

**Expected**: Only one group — `US`.

```sql
-- Run as analyst-global: should return all countries
SELECT country, COUNT(*) AS row_count
FROM sales_data
GROUP BY country
ORDER BY country;
```

**Expected**: All 6 countries: AU, CA, DE, FR, UK, US.

### 2. Verify Column-Level Filtering (email exclusion)

```sql
-- Run as analyst-us or analyst-global: should succeed without email in output
SELECT id, name, country, revenue FROM sales_data LIMIT 5;
```

**Expected**: 5 rows, no email column.

```sql
-- Run as analyst-us or analyst-global: SHOULD FAIL (email not accessible)
SELECT email FROM sales_data LIMIT 5;
```

**Expected**: Athena error — something similar to:
```
PERMISSION_DENIED: Principal does not have permission to access column 'email'
```

```sql
-- Run as data-steward: should succeed and return email values
SELECT id, name, email, country FROM sales_data LIMIT 5;
```

**Expected**: 5 rows with populated email addresses.

### 3. Verify Aggregation Works Through Lake Formation

```sql
-- Run as analyst-us: aggregate over visible rows only
SELECT product, SUM(revenue) AS total_revenue
FROM sales_data
GROUP BY product
ORDER BY total_revenue DESC;
```

**Expected**: Revenue totals that reflect only US sales records.

```sql
-- Run as data-steward: aggregate over all rows
SELECT product, SUM(revenue) AS total_revenue
FROM sales_data
GROUP BY product
ORDER BY total_revenue DESC;
```

**Expected**: Higher revenue totals (includes all countries).

### 4. Spot-Check a Specific Record

```sql
-- Row 2 (Sarah Mitchell, UK) should be invisible to analyst-us
SELECT * FROM sales_data WHERE id = 2;
```

- As `analyst-us`: returns 0 rows (UK is filtered out).
- As `analyst-global`: returns 1 row, no email column.
- As `data-steward`: returns 1 row including `sarah.mitchell@acme.io`.

---

## Troubleshooting

### Lake Formation permissions not propagated yet

**Symptom**: Query returns `PERMISSION_DENIED` even for a role that should have access, immediately after `terraform apply`.

**Cause**: Lake Formation permission changes can take up to 60 seconds to propagate.

**Fix**: Wait 60 seconds and retry the query.

---

### STS session token expired

**Symptom**: `query_as_role.sh` fails mid-way with `ExpiredTokenException`.

**Cause**: STS tokens issued by `AssumeRole` have a default duration of 1 hour. If the query polling exceeds this (unlikely for short queries) or the token was obtained earlier, it may have expired.

**Fix**: Re-run the script from the beginning — it obtains a fresh token each time.

---

### Cannot assume role (Access Denied on AssumeRole)

**Symptom**: `aws sts assume-role` returns `AccessDenied`.

**Cause**: The trust policy on the analyst IAM roles allows the **account root** (`arn:aws:iam::<account-id>:root`) to assume them, which means any principal in the account can assume them if they have `sts:AssumeRole` permission. If your caller does not have this IAM permission, the assume-role call fails.

**Fix**: Attach an inline or managed policy to your caller identity that includes:
```json
{
  "Effect": "Allow",
  "Action": "sts:AssumeRole",
  "Resource": "arn:aws:iam::<account-id>:role/awslake-claude-*"
}
```

---

### Athena query fails with "Query workgroup is not found"

**Symptom**: `StartQueryExecution` returns an error about the workgroup.

**Cause**: The workgroup ARN passed to the script does not match the deployed workgroup name, or you are querying in a different AWS region than the one used during `terraform apply`.

**Fix**:
```bash
# Confirm the workgroup name and region
terraform output athena_workgroup_name
terraform output aws_region

# Ensure your AWS CLI is targeting the same region
export AWS_DEFAULT_REGION=$(terraform output -raw aws_region)
```

---

### S3 Access Denied when Athena writes results

**Symptom**: Athena query fails with `S3 Exception. Unable to write to bucket`.

**Cause**: The analyst IAM roles are granted `s3:PutObject` only on the Athena results bucket. If the workgroup is configured with `enforce_workgroup_configuration = true` (it is, in this POC), Athena forces results to `s3://<athena-results-bucket>/results/`, which the role does have write access to. If you try to use a different output location, Athena will reject it.

**Fix**: Always use the workgroup name returned by `terraform output athena_workgroup_name`. Do not override the output location per-query.

---

### Data Cells Filter not applied (analyst-us sees all rows)

**Symptom**: Running as `analyst-us` returns rows for countries other than US.

**Cause**: Lake Formation Data Cells Filter permissions may not have been applied if the `depends_on` chain was not respected during a partial apply, or if the LF admin settings were not set before the permissions were created.

**Fix**:
```bash
# Force a re-apply of the Lake Formation resources
terraform apply -target=aws_lakeformation_data_lake_settings.main
terraform apply -target=aws_lakeformation_data_cells_filter.us_no_email
terraform apply -target=aws_lakeformation_permissions.analyst_us_table
```
