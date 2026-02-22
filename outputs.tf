output "data_lake_bucket_name" {
  description = "Name of the S3 data lake bucket"
  value       = aws_s3_bucket.data_lake.bucket
}

output "data_lake_bucket_arn" {
  description = "ARN of the S3 data lake bucket"
  value       = aws_s3_bucket.data_lake.arn
}

output "lakeformation_admin_role_arn" {
  description = "ARN of the Lake Formation admin IAM role"
  value       = aws_iam_role.lakeformation_admin.arn
}

output "glue_catalog_database" {
  description = "Name of the Glue catalog database"
  value       = aws_glue_catalog_database.main.name
}

output "aws_account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}
