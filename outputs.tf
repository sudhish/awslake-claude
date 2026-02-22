output "data_lake_bucket_name" {
  description = "Name of the S3 data lake bucket"
  value       = aws_s3_bucket.data_lake.bucket
}

output "data_lake_bucket_arn" {
  description = "ARN of the S3 data lake bucket"
  value       = aws_s3_bucket.data_lake.arn
}

output "data_lake_s3_uri" {
  description = "S3 URI for the sales data prefix in the data lake bucket"
  value       = "s3://${aws_s3_bucket.data_lake.bucket}/sales/"
}

output "athena_results_bucket" {
  description = "Name of the S3 bucket used for Athena query results"
  value       = aws_s3_bucket.athena_results.bucket
}

output "glue_database_name" {
  description = "Name of the Glue catalog database"
  value       = aws_glue_catalog_database.main.name
}

output "glue_table_name" {
  description = "Name of the Glue catalog table for sales data"
  value       = aws_glue_catalog_table.sales_data.name
}

output "athena_workgroup_name" {
  description = "Name of the Athena workgroup"
  value       = aws_athena_workgroup.main.name
}

output "analyst_us_role_arn" {
  description = "ARN of the analyst-us IAM role"
  value       = aws_iam_role.analyst_us.arn
}

output "analyst_global_role_arn" {
  description = "ARN of the analyst-global IAM role"
  value       = aws_iam_role.analyst_global.arn
}

output "data_steward_role_arn" {
  description = "ARN of the data-steward IAM role"
  value       = aws_iam_role.data_steward.arn
}

output "lf_service_role_arn" {
  description = "ARN of the Lake Formation service IAM role"
  value       = aws_iam_role.lakeformation_service.arn
}

output "aws_account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "AWS region where resources are deployed"
  value       = var.aws_region
}

output "lakeformation_data_cells_filter_name" {
  description = "Name of the Lake Formation data cells filter for US rows with email excluded"
  value       = aws_lakeformation_data_cells_filter.us_no_email.table_data[0].name
}
