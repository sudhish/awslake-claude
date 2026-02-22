# Architecture: AWS Lake Formation RBAC POC

## Overview

This proof-of-concept demonstrates **Row-Level Security (RLS) and Column-Level Security (CLS)** using AWS Lake Formation on top of a serverless data lake stack. Three IAM roles represent real-world analyst personas, each with different data visibility enforced entirely by Lake Formation — without any application-level filtering. The same Athena query submitted under different roles returns different rows and columns based on Lake Formation permissions, proving the RBAC model works at the data platform layer.

Key capabilities demonstrated:

- **Row-level filtering**: `analyst-us` sees only rows where `country = 'US'` via a Lake Formation Data Cells Filter.
- **Column-level filtering**: both analyst roles have the `email` column excluded; only `data-steward` can access PII.
- **IAM role assumption**: `query_as_role.sh` assumes each role via STS to simulate real users with different job functions.
- **Encryption and access blocking**: all S3 buckets use AES-256 SSE and block all public access.
- **Athena workgroup enforcement**: query results are forced to a dedicated encrypted S3 prefix; per-query output location overrides are not allowed.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AWS Account                                    │
│                                                                             │
│  ┌──────────────────────┐       ┌──────────────────────────────────────┐   │
│  │   S3: Data Lake      │       │      AWS Glue Data Catalog           │   │
│  │  (sales/sample_      │──────▶│  Database: awslake_catalog           │   │
│  │   sales.csv)         │       │  Table:    sales_data (8 columns)    │   │
│  │  AES-256 encrypted   │       │  Type:     EXTERNAL_TABLE / CSV      │   │
│  │  Versioning enabled  │       └──────────────────┬───────────────────┘   │
│  │  90-day lifecycle    │                          │                        │
│  └──────────────────────┘                          ▼                        │
│                                  ┌─────────────────────────────────────┐   │
│  ┌──────────────────────┐        │       AWS Lake Formation            │   │
│  │  LF Service Role     │──────▶ │                                     │   │
│  │  (register S3 loc.)  │        │  Settings   → Admin: caller IAM ARN │   │
│  └──────────────────────┘        │  Resource   → S3 bucket registered  │   │
│                                  │  Data Cells → us_no_email_filter    │   │
│                                  │               (country='US',        │   │
│                                  │                exclude email col)   │   │
│                                  │  Permissions→ per-role grants       │   │
│                                  └──────────────────┬───────────────────┘  │
│                                                     │ enforces at query time│
│                                                     ▼                       │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    Amazon Athena                                    │   │
│  │  Workgroup: awslake-claude-workgroup                                │   │
│  │  Results:  s3://awslake-claude-<env>-athena-results/results/        │   │
│  │  Encryption: SSE_S3  |  CloudWatch metrics: enabled                 │   │
│  └──────────────────────────────────┬────────────────────────────────-─┘   │
│                                     │                                       │
│              ┌──────────────────────┼──────────────────────┐               │
│              ▼                      ▼                       ▼               │
│   ┌─────────────────┐   ┌─────────────────┐   ┌──────────────────────┐    │
│   │  analyst-us     │   │  analyst-global  │   │   data-steward       │    │
│   │  IAM Role       │   │  IAM Role        │   │   IAM Role           │    │
│   │                 │   │                  │   │                      │    │
│   │  Rows: US only  │   │  Rows: ALL        │   │  Rows: ALL           │    │
│   │  Cols: no email │   │  Cols: no email   │   │  Cols: ALL (PII ok)  │    │
│   └─────────────────┘   └─────────────────┘   └──────────────────────┘    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Table

| Resource | Name Pattern | Terraform File | Purpose |
|---|---|---|---|
| S3 Bucket (data lake) | `awslake-claude-<env>-datalake` | `s3.tf` | Stores raw CSV data at `sales/` prefix; AES-256 encrypted, versioned, 90-day object lifecycle |
| S3 Bucket (Athena results) | `awslake-claude-<env>-athena-results` | `s3.tf` | Stores Athena query output at `results/` prefix; AES-256 encrypted, 30-day lifecycle |
| Glue Catalog Database | `awslake_catalog` (var) | `glue.tf` | Logical namespace in the Glue Data Catalog for the data lake tables |
| Glue Catalog Table | `sales_data` (var) | `glue.tf` | External table definition pointing to `s3://.../sales/`; schema defines 8 CSV columns |
| LF Data Lake Settings | (singleton) | `lakeformation.tf` | Designates the deploying IAM principal (and any extra ARNs in `data_lake_admins`) as Lake Formation administrators |
| LF Resource Registration | (data lake bucket) | `lakeformation.tf` | Registers the S3 bucket with Lake Formation so it manages access to that location |
| LF Data Cells Filter | `us_no_email_filter` | `lakeformation.tf` | Combines row filter (`country = 'US'`) and column exclusion (`email`) into a reusable filter object |
| LF Permissions (analyst-us) | data cells filter grant | `lakeformation.tf` | Grants `analyst-us` SELECT via the `us_no_email_filter`; enforces both RLS and CLS simultaneously |
| LF Permissions (analyst-global) | table_with_columns grant | `lakeformation.tf` | Grants `analyst-global` SELECT on all rows but only 7 named columns (email excluded) |
| LF Permissions (data-steward) | table block grant | `lakeformation.tf` | Grants `data-steward` SELECT on all rows and all columns including email (uses `table {}` block, not `table_with_columns`, to avoid unsupported column_wildcard syntax) |
| IAM User Policies (lfuser-*) | athena-lf-access inline policy | `test_users.tf` | Grants `lfuser-us-analyst`, `lfuser-global-analyst`, `lfuser-data-steward` direct Athena/Glue/S3/LF permissions for AWS Console testing without Switch Role |
| LF Permissions (lfuser-*) | per-user DB + table grants | `test_users.tf` | Mirrors the role-based LF permissions for each `lfuser-*` IAM user (same data cells filter / column list / table block as their role counterparts) |
| LF DB Permissions (all roles) | DESCRIBE grant | `lakeformation.tf` | Allows all three analyst roles to introspect the Glue database metadata |
| IAM Role: LF Service | `awslake-claude-lf-service-role` | `iam.tf` | Assumed by the Lake Formation service to read/write S3 data lake objects on behalf of queries |
| IAM Role: analyst-us | `awslake-claude-analyst-us` | `iam.tf` | Assumable by account principals; Athena + Glue + LF GetDataAccess permissions scoped to the two S3 buckets |
| IAM Role: analyst-global | `awslake-claude-analyst-global` | `iam.tf` | Same IAM policy shape as analyst-us; row/column differences are enforced purely by Lake Formation |
| IAM Role: data-steward | `awslake-claude-data-steward` | `iam.tf` | Same IAM policy shape; full column access granted by Lake Formation |
| Athena Workgroup | `awslake-claude-workgroup` | `athena.tf` | Enforces result output to the dedicated results bucket; enables CloudWatch metrics; SSE_S3 encryption on results |

---

## Data Flow

```
1. Data Ingestion
   scripts/upload_data.sh
   └── aws s3 cp data/sample_sales.csv
       └── s3://awslake-claude-<env>-datalake/sales/sample_sales.csv

2. Catalog Registration
   Glue Catalog Table (sales_data)
   └── Points to s3://.../sales/ prefix
       └── Schema: 8 columns, CSV, comma-delimited, skip header line

3. Lake Formation Registration
   LF Data Lake Settings (admin set)
   └── LF Resource (S3 bucket registered)
       └── LF Data Cells Filter (us_no_email_filter defined)
           └── LF Permissions (per-role grants applied)

4. Query Execution (via query_as_role.sh or Athena console)
   Caller assumes IAM Role via STS AssumeRole
   └── Athena receives query (workgroup: awslake-claude-workgroup)
       └── Athena calls lakeformation:GetDataAccess
           └── Lake Formation evaluates permissions for the assumed role
               └── Returns filtered data view (rows + columns) to Athena
                   └── Results written to s3://.../athena-results/results/
                       └── Caller reads results via GetQueryResults
```

The critical step is `lakeformation:GetDataAccess`. When Athena executes a query, it does not read S3 directly — it asks Lake Formation for a vended credential scoped to only the rows and columns the calling principal is permitted to see. Lake Formation enforces this before any data is returned.

---

## RBAC Model

| Role | IAM Role Name | Row Access | Column Access | CAN See | CANNOT See |
|---|---|---|---|---|---|
| `analyst-us` | `awslake-claude-analyst-us` | `country = 'US'` only (via Data Cells Filter) | All columns **except** `email` | US customers: id, name, country, revenue, product, sale_date, region | Non-US rows; `email` column |
| `analyst-global` | `awslake-claude-analyst-global` | All rows (all countries) | All columns **except** `email` (explicit 7-column list) | Every country: id, name, country, revenue, product, sale_date, region | `email` column only |
| `data-steward` | `awslake-claude-data-steward` | All rows (all countries) | All columns including `email` (table block grant) | Everything — full fidelity data including PII | Nothing restricted |

### How the Restrictions are Implemented

- **analyst-us**: Lake Formation `data_cells_filter` permission using the `us_no_email_filter` object. A single filter object combines both the row predicate (`country = 'US'`) and the column exclusion (`email`). This is the most expressive Lake Formation permission type.
- **analyst-global**: Lake Formation `table_with_columns` permission with an explicit `column_names` list of 7 columns. No row filter is applied, so all rows are visible. The `email` column is simply omitted from the allowed list.
- **data-steward**: Lake Formation `table` permission (plain `table {}` block, not `table_with_columns`). No row filter applied. Full access to all columns including `email`. The `table_with_columns { column_wildcard {} }` syntax is unsupported by the AWS Terraform provider v5 — using a bare `table {}` block is the correct way to grant unrestricted column access.

All three roles share an identical IAM policy — the differentiation is **entirely** in Lake Formation, not in IAM. This is the key design point the POC is demonstrating.

---

## Data Schema

The `sales_data` table schema is defined in `glue.tf` and matches the CSV header in `data/sample_sales.csv`.

| Column | Glue Type | Description | Sample Values | Sensitivity |
|---|---|---|---|---|
| `id` | `int` | Unique integer identifier for each sale record | 1, 2, 3 ... 60 | Low |
| `name` | `string` | Full name of the customer | "James Anderson", "Sarah Mitchell" | Medium (PII) |
| `email` | `string` | Email address of the customer | "james.anderson@example.com" | **High (PII — restricted)** |
| `country` | `string` | Two-letter ISO country code of the sale | US, UK, DE, FR, CA, AU | Low |
| `revenue` | `double` | Sale revenue amount in USD | 1250.00, 3400.50 | Medium |
| `product` | `string` | Product or service sold | "Widget A", "Gadget X", "Service Z" | Low |
| `sale_date` | `string` | Date of the sale in YYYY-MM-DD format | "2024-01-05", "2024-09-06" | Low |
| `region` | `string` | Geographic sales region grouping | AMERICAS, EMEA, APAC | Low |

The sample dataset contains 60 rows spanning January through September 2024 across 6 countries (US, UK, DE, FR, CA, AU) and 3 regions (AMERICAS, EMEA, APAC).

---

## Resource Dependencies

Lake Formation requires resources to be created in a strict order. The `depends_on` clauses in `lakeformation.tf` enforce this.

```
aws_lakeformation_data_lake_settings.main          (step 1: must exist first)
│
├──▶ aws_lakeformation_resource.data_lake           (step 2: register S3 location)
│
├──▶ aws_lakeformation_data_cells_filter.us_no_email  (step 3: define filter)
│       │
│       └──▶ aws_lakeformation_permissions.analyst_us_table  (step 4: grant via filter)
│
├──▶ aws_lakeformation_permissions.analyst_us_db      (step 4: DB describe grants)
├──▶ aws_lakeformation_permissions.analyst_global_db
├──▶ aws_lakeformation_permissions.data_steward_db
│
├──▶ aws_lakeformation_permissions.analyst_global_table  (step 4: table column grants)
└──▶ aws_lakeformation_permissions.data_steward_table

Supporting resources (no LF dependency order required):
├── aws_s3_bucket.data_lake              ← referenced by LF resource and Glue table
├── aws_s3_bucket.athena_results         ← referenced by Athena workgroup
├── aws_glue_catalog_database.main       ← referenced by all LF permissions
├── aws_glue_catalog_table.sales_data    ← referenced by LF filter and permissions
├── aws_athena_workgroup.main            ← standalone, references athena_results bucket
└── aws_iam_role.lakeformation_service   ← referenced by LF resource registration
```

If `aws_lakeformation_data_lake_settings.main` does not exist when other Lake Formation resources are created, Terraform will receive API errors because the calling identity is not yet recognised as a Lake Formation administrator. All `aws_lakeformation_*` resources declare `depends_on = [aws_lakeformation_data_lake_settings.main]` to prevent this race condition.
