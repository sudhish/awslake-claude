resource "aws_athena_workgroup" "main" {
  name          = "${var.project_name}-workgroup"
  description   = "Athena workgroup for ${var.project_name} RBAC POC"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}
