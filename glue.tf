resource "aws_glue_catalog_database" "main" {
  name        = var.glue_db_name
  description = "Lake Formation managed catalog for ${var.project_name}"
}

resource "aws_glue_catalog_table" "sales_data" {
  name          = var.glue_table_name
  database_name = aws_glue_catalog_database.main.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"         = "csv"
    "skip.header.line.count" = "1"
    "areColumnsQuoted"       = "false"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data_lake.bucket}/sales/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"
      parameters = {
        "field.delim"          = ","
        "line.delim"           = "\n"
        "serialization.format" = ","
      }
    }

    columns {
      name = "id"
      type = "int"
    }
    columns {
      name = "name"
      type = "string"
    }
    columns {
      name = "email"
      type = "string"
    }
    columns {
      name = "country"
      type = "string"
    }
    columns {
      name = "revenue"
      type = "double"
    }
    columns {
      name = "product"
      type = "string"
    }
    columns {
      name = "sale_date"
      type = "string"
    }
    columns {
      name = "region"
      type = "string"
    }
  }
}
