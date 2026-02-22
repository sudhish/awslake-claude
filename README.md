# awslake-claude

Terraform IaC for AWS Lake Formation — data lake bucket, Glue catalog, and Lake Formation permissions.

## Resources

| Resource | Description |
|----------|-------------|
| `aws_s3_bucket` | Versioned, encrypted S3 bucket as the data lake store |
| `aws_iam_role` | IAM role for Lake Formation service access |
| `aws_lakeformation_data_lake_settings` | Sets Lake Formation admins |
| `aws_lakeformation_resource` | Registers the S3 bucket with Lake Formation |
| `aws_glue_catalog_database` | Glue catalog database for the data lake |
| `aws_lakeformation_permissions` | Grants admin role permissions on the catalog DB |

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

terraform init
terraform plan
terraform apply
```

## Requirements

- Terraform >= 1.5.0
- AWS provider ~> 5.0
- AWS credentials configured (`aws configure` or environment variables)

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-west-2` | AWS region |
| `environment` | `dev` | Environment tag |
| `project_name` | `awslake-claude` | Resource name prefix |
| `data_lake_admins` | `[]` | Additional IAM ARNs for LF admin |
| `glue_db_name` | `awslake_catalog` | Glue catalog DB name |
