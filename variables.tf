variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "awslake-claude"
}

variable "data_lake_admins" {
  description = "List of IAM principal ARNs to grant Lake Formation admin access"
  type        = list(string)
  default     = []
}

variable "glue_db_name" {
  description = "Name of the Glue catalog database for the data lake"
  type        = string
  default     = "awslake_catalog"
}

variable "glue_table_name" {
  description = "Name of the Glue catalog table for sales data"
  type        = string
  default     = "sales_data"
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
