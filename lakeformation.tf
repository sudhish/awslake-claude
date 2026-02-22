# Data lake settings — register current caller + any extra admins
# NOTE: After first apply, manually revoke IAMAllowedPrincipals from the Glue
# database and table so Lake Formation is the sole access control plane:
#   aws lakeformation revoke-permissions \
#     --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
#     --resource '{"Database":{"Name":"awslake_catalog"}}' --permissions ALL
#   aws lakeformation revoke-permissions \
#     --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
#     --resource '{"Table":{"DatabaseName":"awslake_catalog","Name":"sales_data"}}' --permissions ALL
resource "aws_lakeformation_data_lake_settings" "main" {
  admins = concat(
    [data.aws_caller_identity.current.arn],
    var.data_lake_admins
  )
}

# Register the S3 data lake location
resource "aws_lakeformation_resource" "data_lake" {
  arn      = aws_s3_bucket.data_lake.arn
  role_arn = aws_iam_role.lakeformation_service.arn
  depends_on = [aws_lakeformation_data_lake_settings.main]
}

# ---- Glue DB permissions (DESCRIBE) for all analyst roles ----
resource "aws_lakeformation_permissions" "analyst_us_db" {
  principal   = aws_iam_role.analyst_us.arn
  permissions = ["DESCRIBE"]
  database { name = aws_glue_catalog_database.main.name }
  depends_on  = [aws_lakeformation_data_lake_settings.main]
}

resource "aws_lakeformation_permissions" "analyst_global_db" {
  principal   = aws_iam_role.analyst_global.arn
  permissions = ["DESCRIBE"]
  database { name = aws_glue_catalog_database.main.name }
  depends_on  = [aws_lakeformation_data_lake_settings.main]
}

resource "aws_lakeformation_permissions" "data_steward_db" {
  principal   = aws_iam_role.data_steward.arn
  permissions = ["DESCRIBE"]
  database { name = aws_glue_catalog_database.main.name }
  depends_on  = [aws_lakeformation_data_lake_settings.main]
}

# ---- Data cells filter: US rows only, email column excluded ----
resource "aws_lakeformation_data_cells_filter" "us_no_email" {
  table_data {
    database_name    = aws_glue_catalog_database.main.name
    name             = "us_no_email_filter"
    table_catalog_id = data.aws_caller_identity.current.account_id
    table_name       = aws_glue_catalog_table.sales_data.name

    row_filter {
      filter_expression = "country = 'US'"
    }

    column_wildcard {
      excluded_column_names = ["email"]
    }
  }
  depends_on = [aws_lakeformation_data_lake_settings.main]
}

# ---- analyst-us: SELECT via data cells filter (country=US, no email) ----
resource "aws_lakeformation_permissions" "analyst_us_table" {
  principal   = aws_iam_role.analyst_us.arn
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

# ---- analyst-global: SELECT on all rows, all columns EXCEPT email ----
resource "aws_lakeformation_permissions" "analyst_global_table" {
  principal   = aws_iam_role.analyst_global.arn
  permissions = ["SELECT"]

  table_with_columns {
    database_name = aws_glue_catalog_database.main.name
    name          = aws_glue_catalog_table.sales_data.name
    column_names  = ["id", "name", "country", "revenue", "product", "sale_date", "region"]
  }

  depends_on = [aws_lakeformation_data_lake_settings.main]
}

# ---- data-steward: SELECT on all rows, ALL columns including email ----
# Use `table` (not table_with_columns) to grant access to all columns without restriction
resource "aws_lakeformation_permissions" "data_steward_table" {
  principal   = aws_iam_role.data_steward.arn
  permissions = ["SELECT"]

  table {
    database_name = aws_glue_catalog_database.main.name
    name          = aws_glue_catalog_table.sales_data.name
  }

  depends_on = [aws_lakeformation_data_lake_settings.main]
}
