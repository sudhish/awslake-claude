# Deployment Guide: AWS Lake Formation RBAC POC

This guide covers everything needed to deploy, test, and tear down the `awslake-claude` POC from scratch.

---

## AWS Prerequisites

### IAM Permissions Required to Deploy

The IAM principal running `terraform apply` must have the following IAM action permissions. The simplest approach for a personal POC account is to use an IAM user or role with `AdministratorAccess`, but the minimum required actions are:

| Service | Required Actions |
|---|---|
| Lake Formation | `lakeformation:*` |
| Glue | `glue:CreateDatabase`, `glue:CreateTable`, `glue:GetDatabase`, `glue:GetTable`, `glue:DeleteDatabase`, `glue:DeleteTable`, `glue:GetDatabases`, `glue:GetTables` |
| S3 | `s3:CreateBucket`, `s3:DeleteBucket`, `s3:PutBucketPolicy`, `s3:PutBucketVersioning`, `s3:PutEncryptionConfiguration`, `s3:PutLifecycleConfiguration`, `s3:PutPublicAccessBlock`, `s3:ListBucket`, `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` |
| IAM | `iam:CreateRole`, `iam:DeleteRole`, `iam:PutRolePolicy`, `iam:DeleteRolePolicy`, `iam:GetRole`, `iam:PassRole`, `iam:ListRolePolicies`, `iam:GetRolePolicy` |
| Athena | `athena:CreateWorkGroup`, `athena:DeleteWorkGroup`, `athena:GetWorkGroup`, `athena:UpdateWorkGroup` |
| STS | `sts:GetCallerIdentity`, `sts:AssumeRole` |

> **Note on Lake Formation admin bootstrap**: The first time Lake Formation is configured in an account or region, the deploying principal must already have `lakeformation:PutDataLakeSettings` permission. If another Lake Formation administrator exists in the account, they may need to grant you admin access first.

---

## Local Prerequisites

### Terraform

```bash
terraform version
# Required: >= 1.5.0
```

Install via [tfenv](https://github.com/tfutils/tfenv) or the [official downloads](https://developer.hashicorp.com/terraform/install):

```bash
# macOS via Homebrew
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
```

### AWS CLI

```bash
aws --version
# Required: aws-cli/2.x or higher
```

Install via [official instructions](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html):

```bash
# macOS via Homebrew
brew install awscli
```

### AWS Credentials

Credentials must be configured and active before running Terraform or the helper scripts. Use any of the standard methods:

```bash
# Option A: Named profile
aws configure --profile my-poc-profile
export AWS_PROFILE=my-poc-profile

# Option B: Environment variables
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-west-2

# Option C: IAM role via EC2/ECS instance profile (no configuration needed)
```

Verify credentials are working:

```bash
aws sts get-caller-identity
```

---

## First-Time Setup

### 1. Clone or Navigate to the Project

```bash
cd /path/to/awslake-claude
```

### 2. Configure Variables (Optional)

The project ships with sensible defaults. To override, copy the example tfvars file and edit it:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` to set your preferred values:

```hcl
aws_region   = "us-west-2"          # AWS region to deploy into
environment  = "dev"                 # Appended to resource names
project_name = "awslake-claude"      # Prefix for all resource names

# Optional: additional Lake Formation admin ARNs
# data_lake_admins = ["arn:aws:iam::123456789012:user/admin-user"]
```

> The principal running `terraform apply` is automatically added as a Lake Formation administrator via `data.aws_caller_identity.current.arn`. You only need `data_lake_admins` if additional principals need admin access.

### 3. Initialise Terraform

```bash
terraform init
```

This downloads the `hashicorp/aws` provider (~5.x). Expected output ends with:

```
Terraform has been successfully initialized!
```

---

## Deploy

### 1. Preview the Plan

```bash
terraform plan -out=tfplan
```

Review the output. Expect approximately **20+ resources** to be created across S3, Glue, IAM, Lake Formation, and Athena. No resources should be modified or destroyed on a clean first deploy.

### 2. Apply

```bash
terraform apply tfplan
```

Terraform will create resources in dependency order. Typical completion time is **60–120 seconds**.

At the end, Terraform prints outputs:

```
Outputs:

analyst_global_role_arn                = "arn:aws:iam::123456789012:role/awslake-claude-analyst-global"
analyst_us_role_arn                    = "arn:aws:iam::123456789012:role/awslake-claude-analyst-us"
athena_results_bucket                  = "awslake-claude-dev-athena-results"
athena_workgroup_name                  = "awslake-claude-workgroup"
aws_account_id                         = "123456789012"
aws_region                             = "us-west-2"
data_lake_bucket_arn                   = "arn:aws:s3:::awslake-claude-dev-datalake"
data_lake_bucket_name                  = "awslake-claude-dev-datalake"
data_lake_s3_uri                       = "s3://awslake-claude-dev-datalake/sales/"
data_steward_role_arn                  = "arn:aws:iam::123456789012:role/awslake-claude-data-steward"
glue_database_name                     = "awslake_catalog"
glue_table_name                        = "sales_data"
lakeformation_data_cells_filter_name   = "us_no_email_filter"
lf_service_role_arn                    = "arn:aws:iam::123456789012:role/awslake-claude-lf-service-role"
```

Save these values or retrieve them at any time with `terraform output`.

---

## Load Data

Upload the sample CSV to S3 so Athena has data to query:

```bash
bash scripts/upload_data.sh
```

The script automatically reads the bucket name from `terraform output`. Alternatively, pass the bucket name directly:

```bash
bash scripts/upload_data.sh awslake-claude-dev-datalake
```

Verify the file landed in the correct S3 prefix:

```bash
BUCKET=$(terraform output -raw data_lake_bucket_name)
aws s3 ls "s3://${BUCKET}/sales/"
```

Expected output:

```
2024-xx-xx xx:xx:xx      3456 sample_sales.csv
```

---

## Verify: Run a Quick Athena Query as Each Role

Use `scripts/query_as_role.sh` to confirm each role sees the correct data. Retrieve the necessary values first:

```bash
ANALYST_US_ARN=$(terraform output -raw analyst_us_role_arn)
ANALYST_GLOBAL_ARN=$(terraform output -raw analyst_global_role_arn)
DATA_STEWARD_ARN=$(terraform output -raw data_steward_role_arn)
WORKGROUP=$(terraform output -raw athena_workgroup_name)
DATABASE=$(terraform output -raw glue_database_name)
```

### analyst-us (expect: US rows only, no email column)

```bash
bash scripts/query_as_role.sh \
  "${ANALYST_US_ARN}" \
  "${WORKGROUP}" \
  "${DATABASE}" \
  "SELECT id, name, country, revenue FROM sales_data LIMIT 5"
```

### analyst-global (expect: all rows, no email column)

```bash
bash scripts/query_as_role.sh \
  "${ANALYST_GLOBAL_ARN}" \
  "${WORKGROUP}" \
  "${DATABASE}" \
  "SELECT id, name, country, revenue FROM sales_data LIMIT 5"
```

### data-steward (expect: all rows, email column visible)

```bash
bash scripts/query_as_role.sh \
  "${DATA_STEWARD_ARN}" \
  "${WORKGROUP}" \
  "${DATABASE}" \
  "SELECT id, name, email, country FROM sales_data LIMIT 5"
```

For a full set of verification queries and the detailed expected results table, see `docs/rbac-guide.md`.

---

## Teardown

To destroy all AWS resources created by this POC:

```bash
terraform destroy
```

Type `yes` when prompted.

> **Important**: Both S3 buckets are created with `force_destroy = true`. This means `terraform destroy` will **delete the buckets and all their contents** — including any uploaded CSV data and all stored Athena query results — without requiring manual object deletion first. There is no recovery from this action.

Resources destroyed include all S3 buckets, Glue catalog entries, IAM roles and policies, Lake Formation settings and permissions, and the Athena workgroup.

---

## Cost Notes

This POC uses fully managed serverless services. Costs are minimal for a small CSV dataset but are not zero.

| Service | Pricing Model | Estimated Cost for this POC |
|---|---|---|
| **Amazon Athena** | $5.00 per TB of data scanned | Near-zero. The sample CSV is ~3 KB. A full table scan costs a fraction of a cent. Athena has a 10 MB minimum per query for billing purposes. Running 100 queries against this dataset costs well under $0.01. |
| **Amazon S3** | $0.023 per GB-month (us-east-1; ~similar in us-west-2) | Near-zero. The CSV is ~3 KB; Athena result files are kilobytes each. Monthly storage cost is effectively $0.00. Lifecycle rules expire data lake objects after 90 days and results after 30 days. |
| **AWS Glue Data Catalog** | First 1 million objects free per month | Free. This POC creates 1 database and 1 table — well within the free tier. |
| **AWS Lake Formation** | No additional charge | Free. Lake Formation is a permissions management layer; you pay for the underlying services (S3, Glue, Athena). |
| **IAM** | No charge | Free. |
| **STS AssumeRole** | No charge | Free. |

**Total estimated cost for a 1-day POC**: Less than $0.01, primarily from Athena query scans and a negligible amount of S3 PUT/GET requests.

To minimise costs further, run `terraform destroy` as soon as testing is complete.
