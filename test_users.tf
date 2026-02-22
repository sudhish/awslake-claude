# ---------------------------------------------------------------------------
# Test IAM Users — direct Athena/Glue/S3/LF access (no Switch Role needed)
# These users are created outside Terraform; we manage their policies only.
# ---------------------------------------------------------------------------

locals {
  athena_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
          "athena:GetWorkGroup",
          "athena:ListWorkGroups",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.athena_results.arn}/*"
      },
      {
        Effect = "Allow"
        Action = ["s3:GetBucketLocation", "s3:ListBucket", "s3:GetBucketAcl"]
        Resource = aws_s3_bucket.athena_results.arn
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.data_lake.arn,
          "${aws_s3_bucket.data_lake.arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartitions",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["lakeformation:GetDataAccess"]
        Resource = "*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# lfuser-us-analyst — US rows only, no email column
# ---------------------------------------------------------------------------
resource "aws_iam_user_policy" "lfuser_us_analyst" {
  name   = "athena-lf-access"
  user   = "lfuser-us-analyst"
  policy = local.athena_policy
}

resource "aws_lakeformation_permissions" "lfuser_us_analyst_db" {
  principal   = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/lfuser-us-analyst"
  permissions = ["DESCRIBE"]
  database { name = aws_glue_catalog_database.main.name }
  depends_on = [aws_lakeformation_data_lake_settings.main]
}

resource "aws_lakeformation_permissions" "lfuser_us_analyst_table" {
  principal   = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/lfuser-us-analyst"
  permissions = ["SELECT"]

  data_cells_filter {
    database_name    = aws_glue_catalog_database.main.name
    name             = aws_lakeformation_data_cells_filter.us_no_email.table_data[0].name
    table_catalog_id = data.aws_caller_identity.current.account_id
    table_name       = aws_glue_catalog_table.sales_data.name
  }

  depends_on = [
    aws_lakeformation_data_cells_filter.us_no_email,
    aws_lakeformation_data_lake_settings.main,
  ]
}

# ---------------------------------------------------------------------------
# lfuser-global-analyst — all rows, no email column
# ---------------------------------------------------------------------------
resource "aws_iam_user_policy" "lfuser_global_analyst" {
  name   = "athena-lf-access"
  user   = "lfuser-global-analyst"
  policy = local.athena_policy
}

resource "aws_lakeformation_permissions" "lfuser_global_analyst_db" {
  principal   = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/lfuser-global-analyst"
  permissions = ["DESCRIBE"]
  database { name = aws_glue_catalog_database.main.name }
  depends_on = [aws_lakeformation_data_lake_settings.main]
}

resource "aws_lakeformation_permissions" "lfuser_global_analyst_table" {
  principal   = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/lfuser-global-analyst"
  permissions = ["SELECT"]

  table_with_columns {
    database_name = aws_glue_catalog_database.main.name
    name          = aws_glue_catalog_table.sales_data.name
    column_names  = ["id", "name", "country", "revenue", "product", "sale_date", "region"]
  }

  depends_on = [aws_lakeformation_data_lake_settings.main]
}

# ---------------------------------------------------------------------------
# lfuser-data-steward — all rows, all columns including email
# ---------------------------------------------------------------------------
resource "aws_iam_user_policy" "lfuser_data_steward" {
  name   = "athena-lf-access"
  user   = "lfuser-data-steward"
  policy = local.athena_policy
}

resource "aws_lakeformation_permissions" "lfuser_data_steward_db" {
  principal   = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/lfuser-data-steward"
  permissions = ["DESCRIBE"]
  database { name = aws_glue_catalog_database.main.name }
  depends_on = [aws_lakeformation_data_lake_settings.main]
}

resource "aws_lakeformation_permissions" "lfuser_data_steward_table" {
  principal   = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/lfuser-data-steward"
  permissions = ["SELECT"]

  table {
    database_name = aws_glue_catalog_database.main.name
    name          = aws_glue_catalog_table.sales_data.name
  }

  depends_on = [aws_lakeformation_data_lake_settings.main]
}
