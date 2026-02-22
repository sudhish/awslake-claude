# ---------------------------------------------------------------------------
# S3 Data Lake Bucket
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "data_lake" {
  bucket = "${var.project_name}-${var.environment}-datalake"
}

resource "aws_s3_bucket_versioning" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# IAM Role for Lake Formation
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "lakeformation_admin" {
  name = "${var.project_name}-lakeformation-admin"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lakeformation.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lakeformation_s3" {
  name = "lakeformation-s3-access"
  role = aws_iam_role.lakeformation_admin.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.data_lake.arn,
          "${aws_s3_bucket.data_lake.arn}/*"
        ]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Lake Formation Settings
# ---------------------------------------------------------------------------
resource "aws_lakeformation_data_lake_settings" "main" {
  admins = concat(
    [data.aws_caller_identity.current.arn],
    var.data_lake_admins
  )
}

# ---------------------------------------------------------------------------
# Lake Formation S3 Resource Registration
# ---------------------------------------------------------------------------
resource "aws_lakeformation_resource" "data_lake" {
  arn      = aws_s3_bucket.data_lake.arn
  role_arn = aws_iam_role.lakeformation_admin.arn

  depends_on = [aws_lakeformation_data_lake_settings.main]
}

# ---------------------------------------------------------------------------
# Glue Catalog Database
# ---------------------------------------------------------------------------
resource "aws_glue_catalog_database" "main" {
  name        = var.glue_db_name
  description = "Lake Formation managed catalog database"
}

# ---------------------------------------------------------------------------
# Lake Formation Permissions — Admin role on the Glue database
# ---------------------------------------------------------------------------
resource "aws_lakeformation_permissions" "admin_db" {
  principal   = aws_iam_role.lakeformation_admin.arn
  permissions = ["ALL"]

  database {
    name = aws_glue_catalog_database.main.name
  }

  depends_on = [aws_lakeformation_data_lake_settings.main]
}
