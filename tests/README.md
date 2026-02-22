# RBAC Test Suite

Validates that AWS Lake Formation row-level and column-level security policies
are correctly enforced for all three IAM roles defined in this POC.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| AWS CLI v2  | Must be configured with credentials that can assume all three test roles (`sts:AssumeRole` on account root is already set up by Terraform). |
| `jq`        | Used to parse Athena JSON responses. Install with `brew install jq` or your package manager. |
| `terraform` | Used at script start to read output values. Must be the same version used to apply. |
| Terraform applied | Run `terraform apply` from the project root first. All outputs must be present. |
| Data uploaded | The 60-row `sales_data.csv` (or equivalent Parquet) must be present under `s3://awslake-claude-dev-datalake/sales/`. Run `bash scripts/upload_data.sh` if needed. |

---

## How to Run

From the **project root** (the directory containing `main.tf`):

```bash
bash tests/test_rbac.sh
```

Or from inside the `tests/` directory:

```bash
cd tests && bash test_rbac.sh
```

The script reads all configuration from `terraform output` — no environment
variables need to be set manually.

---

## What Each Test Validates

### analyst-us role

| Test | Query | Assertion | Rationale |
|------|-------|-----------|-----------|
| 1 | `SELECT COUNT(*) WHERE country != 'US'` | count = 0 | Row filter hides all non-US rows |
| 2 | `SELECT COUNT(*)` | count = 22 | Exactly the 22 US rows are visible |
| 3 | `SELECT * LIMIT 1` | `email` column absent | Column mask removes the email field |

### analyst-global role

| Test | Query | Assertion | Rationale |
|------|-------|-----------|-----------|
| 4 | `SELECT COUNT(*)` | count = 60 | No row filter; all rows visible |
| 5 | `SELECT COUNT(DISTINCT country)` | count = 6 | US, UK, DE, FR, CA, AU all visible |
| 6 | `SELECT * LIMIT 1` | `email` column absent | Column mask removes the email field |

### data-steward role

| Test | Query | Assertion | Rationale |
|------|-------|-----------|-----------|
| 7 | `SELECT COUNT(*)` | count = 60 | No row filter; all rows visible |
| 8 | `SELECT * LIMIT 1` | `email` column present | No column mask on this role |
| 9 | `SELECT COUNT(*) WHERE email IS NOT NULL` | count = 60 | Can directly query the email column |

---

## Expected Output (all passing)

```
=== AWS Lake Formation RBAC Test Suite ===

Reading terraform outputs from: /path/to/awslake-claude

  analyst-us ARN    : arn:aws:iam::123456789012:role/awslake-claude-analyst-us
  analyst-global ARN: arn:aws:iam::123456789012:role/awslake-claude-analyst-global
  data-steward ARN  : arn:aws:iam::123456789012:role/awslake-claude-data-steward
  Athena workgroup  : awslake-claude-workgroup
  Glue database     : awslake_catalog
  Glue table        : sales_data
  Results bucket    : awslake-claude-dev-athena-results
  AWS region        : us-west-2

Running 9 tests...

--- Role: analyst-us ---
Test 1: analyst-us sees only US rows
  PASS  Test 1: analyst-us non-US row count = 0 (got 0, expected 0)
Test 2: analyst-us total row count = 22
  PASS  Test 2: analyst-us total row count = 22 (got 22, expected 22)
Test 3: analyst-us email column is hidden
  PASS  Test 3: analyst-us email column absent (column 'email' is correctly hidden)

--- Role: analyst-global ---
Test 4: analyst-global total row count = 60
  PASS  Test 4: analyst-global total row count = 60 (got 60, expected 60)
Test 5: analyst-global distinct country count = 6
  PASS  Test 5: analyst-global distinct country count = 6 (got 6, expected 6)
Test 6: analyst-global email column is hidden
  PASS  Test 6: analyst-global email column absent (column 'email' is correctly hidden)

--- Role: data-steward ---
Test 7: data-steward total row count = 60
  PASS  Test 7: data-steward total row count = 60 (got 60, expected 60)
Test 8: data-steward email column is visible
  PASS  Test 8: data-steward email column present (column 'email' is visible as expected)
Test 9: data-steward direct email query returns 60 non-null rows
  PASS  Test 9: data-steward email IS NOT NULL count = 60 (got 60, expected 60)

=== Test Summary ===

  Total tests : 9
  Passed      : 9
  Failed      : 0

All 9 tests PASSED. Lake Formation RBAC is correctly configured.
```

---

## Troubleshooting

### Tests fail immediately with an Athena error

**Lake Formation permission propagation delay.** Lake Formation can take up to
2 minutes to propagate permission changes after `terraform apply`. Wait 60-120
seconds and run the script again.

```bash
sleep 90 && bash tests/test_rbac.sh
```

### Tests 1-3 fail for analyst-us (wrong row counts)

- Verify the Lake Formation data cells filter `us_no_email` is applied to the
  `analyst-us` role:
  ```bash
  aws lakeformation list-permissions \
    --principal DataLakePrincipalIdentifier=$(terraform output -raw analyst_us_role_arn) \
    --region $(terraform output -raw aws_region)
  ```
- Check that the row filter expression is `country = 'US'` (not `!=`).

### Tests 3, 6 fail for email column still visible for analyst roles

- Confirm the column-level security is configured on the data cells filter
  by inspecting `aws_lakeformation_data_cells_filter` in `lakeformation.tf`.
- Verify the Lake Formation permission references the filter by name.

### Tests 7-9 fail for data-steward

- Confirm the `data-steward` role has a `SELECT` Lake Formation permission on
  the table without any data cells filter attached.

### `aws sts assume-role` is denied

The trust policy on each role allows the account root. Your calling identity
must belong to the same AWS account. Check with:

```bash
aws sts get-caller-identity
```

If your identity is not in the same account, update `data_lake_admins` in
`terraform.tfvars` and re-apply.

### Data not in S3 (counts all return 0 instead of expected values)

Upload the test dataset:

```bash
bash scripts/upload_data.sh
```

Then confirm the file is present:

```bash
aws s3 ls s3://awslake-claude-dev-datalake/sales/
```

---

## Data Distribution Reference

The 60-row test dataset is distributed as follows:

| Country | Row Count |
|---------|-----------|
| US      | 22        |
| UK      | 12        |
| DE      | 10        |
| FR      | 8         |
| CA      | 5         |
| AU      | 3         |
| **Total** | **60**  |

This is why:
- `analyst-us` sees 22 rows (US only).
- `analyst-global` and `data-steward` see 60 rows (all countries).
- 6 distinct countries are visible to unrestricted roles.
