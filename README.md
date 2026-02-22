# awslake-claude

AWS Lake Formation RBAC POC — Terraform IaC for testing row-level and column-level access control using Athena, S3, and Glue in `us-west-2`.

## What This POC Demonstrates

- **Row-level security**: `analyst-us` sees only `country = 'US'` rows via a Lake Formation data cells filter
- **Column-level security**: `analyst-us` and `analyst-global` cannot see the `email` column; only `data-steward` has that privilege
- **Three IAM identities** with different access levels tested against the same Athena table

## RBAC Matrix

| Role | Countries Visible | Email Column | Row Count |
|------|-----------------|--------------|-----------|
| `analyst-us` | US only | No | 20 / 60 |
| `analyst-global` | All (US, UK, DE, FR, CA, AU) | No | 60 / 60 |
| `data-steward` | All | **Yes** | 60 / 60 |

## Architecture

```
S3 (data lake)
    └── Glue Catalog (sales_data table)
            └── Lake Formation (data cells filters + permissions)
                    └── Athena (workgroup)
                            ├── analyst-us role    → US rows, no email
                            ├── analyst-global role → all rows, no email
                            └── data-steward role  → all rows + email
```

## Quick Start

> **Prerequisite (console testing)**: If you plan to test via the AWS Console using `lfuser-*` IAM users, create those users in IAM first (they must exist before `terraform apply`, since `test_users.tf` manages their policies but not the users themselves):
> ```bash
> aws iam create-user --user-name lfuser-us-analyst
> aws iam create-user --user-name lfuser-global-analyst
> aws iam create-user --user-name lfuser-data-steward
> ```

```bash
# 1. Configure
cp terraform.tfvars.example terraform.tfvars

# 2. Deploy
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 3. CRITICAL — revoke IAMAllowedPrincipals to enable Lake Formation RBAC
# Without this step, Lake Formation row/column filters are NOT enforced.
DB=awslake_catalog  # or your glue_db_name variable value
aws lakeformation revoke-permissions \
  --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
  --resource "{\"Database\":{\"Name\":\"${DB}\"}}" \
  --permissions ALL --region us-west-2
aws lakeformation revoke-permissions \
  --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
  --resource "{\"Table\":{\"DatabaseName\":\"${DB}\",\"Name\":\"sales_data\"}}" \
  --permissions ALL --region us-west-2

# 4. Load test data (60 rows, 6 countries)
bash scripts/upload_data.sh

# 5. Run RBAC tests
bash tests/test_rbac.sh
```

## Repository Structure

```
awslake-claude/
├── provider.tf             # AWS provider + Terraform version constraints
├── variables.tf            # All input variables
├── s3.tf                   # Data lake + Athena results S3 buckets
├── glue.tf                 # Glue catalog database + sales_data table
├── iam.tf                  # IAM roles (lf-service, analyst-us, analyst-global, data-steward)
├── lakeformation.tf        # LF settings, resource registration, data cells filter, permissions
├── athena.tf               # Athena workgroup
├── outputs.tf              # All resource outputs
├── test_users.tf           # IAM policies + LF permissions for lfuser-* console test users
├── terraform.tfvars.example
├── data/
│   └── sample_sales.csv    # 60-row test dataset (id, name, email, country, revenue, product, sale_date, region)
├── scripts/
│   ├── upload_data.sh      # Upload CSV to S3 data lake
│   └── query_as_role.sh    # Assume a role and run an Athena query
├── tests/
│   ├── test_rbac.sh        # 9 automated RBAC tests
│   └── README.md
└── docs/
    ├── architecture.md     # Full architecture + data flow + RBAC model
    ├── rbac-guide.md       # Hands-on testing guide with expected results
    ├── deployment-guide.md # Step-by-step deploy + teardown + cost notes
    └── security-review.md  # Security findings (18 items) + recommendations
```

## Requirements

- Terraform >= 1.5.0
- AWS provider ~> 5.0
- AWS CLI >= 2.x + `jq`
- AWS credentials with IAM, S3, Glue, Lake Formation, Athena, STS permissions

## Key Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-west-2` | AWS region |
| `environment` | `dev` | Environment tag |
| `project_name` | `awslake-claude` | Resource name prefix |
| `data_lake_admins` | `[]` | Extra IAM ARNs for LF admin |
| `glue_db_name` | `awslake_catalog` | Glue database name |
| `glue_table_name` | `sales_data` | Glue table name |

## Docs

| Document | Description |
|----------|-------------|
| [Architecture](docs/architecture.md) | Component diagram, data flow, RBAC model |
| [RBAC Guide](docs/rbac-guide.md) | How to test each role, expected results, verification queries |
| [Deployment Guide](docs/deployment-guide.md) | Prerequisites, deploy, teardown, cost estimate |
| [Security Review](docs/security-review.md) | 18 findings, POC vs production delta |
