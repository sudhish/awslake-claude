# Security Review: AWS Lake Formation RBAC POC

**Reviewed by:** Security Agent (Claude)
**Review Date:** 2026-02-22
**Scope:** All Terraform configuration files in `/Users/sudhish/projects/awslake-claude/`
**Project:** AWS Lake Formation RBAC Proof of Concept
**Terraform Version:** >= 1.5.0 | AWS Provider: ~> 5.0

---

## Executive Summary

This security review covers the Terraform infrastructure-as-code for an AWS Lake Formation RBAC POC. The codebase demonstrates sound foundational security thinking — S3 public access is blocked, encryption at rest is enabled, Lake Formation is correctly positioned as the primary access control layer, and sensitive files are excluded from version control. The IAM RBAC model is well-structured with distinct roles for `analyst-us`, `analyst-global`, and `data-steward` with appropriate Lake Formation column- and row-level permissions.

However, several findings require attention before this configuration is adapted for any production or sensitive environment. The most significant concerns are overly broad IAM policy resource scopes, account-root trust policies on all analyst roles, and the complete absence of audit logging infrastructure.

| Area | Status | Notes |
|------|--------|-------|
| Encryption at Rest | WARN | SSE-S3 (AES256) present; SSE-KMS preferred |
| Encryption in Transit | PASS | HTTPS enforced by AWS service defaults |
| Public Access | PASS | All four public-access-block settings enabled on both buckets |
| IAM Least Privilege | WARN | Wildcard Resource on Athena and Glue policy statements |
| Trust Policy Scoping | WARN | Account root allowed to assume all analyst/steward roles |
| Audit Logging | FAIL | No CloudTrail, no S3 access logging, no Athena audit logging |
| Secrets / Credentials | PASS | No hardcoded credentials found; tfvars excluded via .gitignore |
| Terraform State Security | FAIL | No remote backend configured; local state only |
| Data Access Control | PASS | Lake Formation is the primary control layer; row/column filters in use |
| Network Controls | WARN | No VPC endpoints for S3 or Athena |
| Data Retention / Lifecycle | INFO | Lifecycle rules present; force_destroy=true on all buckets |
| Sensitive Data in Outputs | INFO | Account ID and role ARNs exposed in outputs (acceptable for POC) |

---

## Findings Table

| ID | Severity | Category | Finding | File:Line | Recommendation |
|----|----------|----------|---------|-----------|----------------|
| F-01 | HIGH | IAM Policy | Athena actions use `Resource = "*"`, granting access to all workgroups and query executions in the account | `iam.tf:87`, `iam.tf:168`, `iam.tf:259` | Scope to the specific Athena workgroup ARN: `arn:aws:athena:<region>:<account>:workgroup/<name>` |
| F-02 | HIGH | IAM Policy | Glue actions (`GetDatabase`, `GetTable`, `GetPartitions`, `GetDatabases`, `GetTables`) use `Resource = "*"`, allowing read of all Glue catalogs and databases in the account | `iam.tf:125`, `iam.tf:210`, `iam.tf:298` | Scope to specific catalog, database, and table ARNs for the project |
| F-03 | HIGH | IAM Policy | `lakeformation:GetDataAccess` uses `Resource = "*"` across all three analyst/steward roles | `iam.tf:129`, `iam.tf:215`, `iam.tf:303` | While LF does not support finer resource scoping for this action today, add an explicit condition block using `aws:ResourceTag` to limit blast radius where feasible |
| F-04 | MEDIUM | IAM Trust Policy | All three analyst roles (`analyst-us`, `analyst-global`, `data-steward`) trust the account root principal (`arn:aws:iam::<account_id>:root`), meaning any IAM identity in the account with `sts:AssumeRole` permission can assume them | `iam.tf:62`, `iam.tf:147`, `iam.tf:233` | Replace the root principal with specific IAM user, group, or role ARNs that legitimately need to assume each role. Add a condition requiring MFA: `"Condition": {"Bool": {"aws:MultiFactorAuthPresent": "true"}}` |
| F-05 | HIGH | Audit Logging | No AWS CloudTrail trail is configured. All API calls to Lake Formation, Glue, Athena, S3, and IAM go unrecorded | None | Create an `aws_cloudtrail` resource with `include_global_service_events = true`, `is_multi_region_trail = true`, and S3/CloudWatch Logs delivery |
| F-06 | MEDIUM | Audit Logging | S3 server access logging is not enabled on either `aws_s3_bucket.data_lake` or `aws_s3_bucket.athena_results` | `s3.tf:4`, `s3.tf:52` | Add `aws_s3_bucket_logging` resources pointing to a dedicated logging bucket |
| F-07 | MEDIUM | Audit Logging | The Athena workgroup has `publish_cloudwatch_metrics_enabled = true`, but no CloudWatch log group or metric alarms are configured. Metrics without alerting provide limited security value | `athena.tf:8` | Create CloudWatch alarms for abnormal query volumes or scan sizes; configure Athena query-level logging |
| F-08 | HIGH | Terraform State | No remote backend is declared in `provider.tf`. Terraform state is stored locally, which means it is unencrypted on disk, not shared between team members, and has no state locking | `provider.tf:1-9` | Configure an S3 + DynamoDB remote backend with server-side encryption and state locking |
| F-09 | MEDIUM | Encryption | Both S3 buckets and the Athena workgroup use SSE-S3 (AES256). This means AWS manages the key entirely with no customer visibility into key rotation, usage audit, or revocation capability | `s3.tf:22`, `s3.tf:62`, `athena.tf:13` | Switch to SSE-KMS using an `aws_kms_key` resource with key rotation enabled (`enable_key_rotation = true`) and a restrictive key policy |
| F-10 | MEDIUM | Network | No VPC endpoints are configured for S3 or Athena. Traffic from Athena query execution and Lake Formation to S3 traverses the AWS public network fabric rather than a private path | None | Create `aws_vpc_endpoint` resources for `com.amazonaws.<region>.s3` (Gateway type) and `com.amazonaws.<region>.athena` (Interface type) if resources will ever run inside a VPC |
| F-11 | LOW | Destructions | `force_destroy = true` is set on `aws_s3_bucket.data_lake`, `aws_s3_bucket.athena_results`, and `aws_athena_workgroup.main`. This allows `terraform destroy` to delete non-empty buckets irreversibly | `s3.tf:6`, `s3.tf:54`, `athena.tf:4` | Acceptable for a POC. Must be set to `false` (or removed, defaulting to false) before any production use or when storing data with retention obligations |
| F-12 | LOW | IAM | The `lakeformation_service` role policy grants `s3:DeleteObject` on the data lake bucket. Lake Formation's data registration use case typically requires only read access for query serving | `iam.tf:35` | Remove `s3:DeleteObject` unless a specific Lake Formation workflow (e.g., governed table compaction) requires it |
| F-13 | LOW | Outputs | `outputs.tf` exposes `aws_account_id` as a plain output. While the account ID is not a secret per se, exposing it in CI/CD logs or shared state can aid reconnaissance | `outputs.tf:57` | Mark the output `sensitive = true` or remove it if not needed downstream |
| F-14 | LOW | Versioning | The `aws_s3_bucket.athena_results` bucket does not have versioning enabled, unlike `aws_s3_bucket.data_lake` | `s3.tf:52-87` | Enable versioning on the Athena results bucket as well, to support recovery of overwritten query results |
| F-15 | INFO | IAM | The deploying caller identity is automatically added as a Lake Formation admin (`data.aws_caller_identity.current.arn`). This means whoever runs `terraform apply` permanently holds LF admin rights until manually removed | `lakeformation.tf:4` | Document this behavior. In production, replace with a named break-glass role and remove the automation identity from LF admins post-deploy |
| F-16 | INFO | Data Classification | The Glue table schema includes an `email` column. The Lake Formation data cells filter correctly excludes `email` from `analyst-us` access, and `analyst-global` does not include it in `column_names`. However, there is no data classification tag applied to the column at the Glue or LF level | `glue.tf:33`, `lakeformation.tf:51` | Apply Lake Formation LF-Tags to the `email` column with a classification such as `pii=true` to enable policy-as-code governance at scale |
| F-17 | INFO | Terraform | No provider version pinning beyond the `~> 5.0` constraint. A breaking change within the 5.x minor range could alter resource behavior | `provider.tf:6` | Pin to a specific patch version (e.g., `= 5.82.0`) in a production lock file and commit `terraform.lock.hcl` to source control |
| F-18 | INFO | Secrets Management | `terraform.tfvars` is correctly excluded from git via `.gitignore`. The `.gitignore` also correctly excludes `terraform.tfstate`, `*.tfplan`, and `*.auto.tfvars` | `.gitignore:5-16` | No action required. Continue this pattern. |

---

## Positive Findings

The following security controls are correctly implemented and should be preserved:

**S3 Public Access Blocking**
Both `aws_s3_bucket.data_lake` and `aws_s3_bucket.athena_results` have all four public access block settings enabled (`block_public_acls`, `block_public_policy`, `ignore_public_acls`, `restrict_public_buckets`). This is the correct posture for a data lake bucket.
Reference: `s3.tf:27-34`, `s3.tf:67-74`

**Lake Formation as the Primary Access Control Layer**
The use of `aws_lakeformation_data_lake_settings` and explicit `aws_lakeformation_permissions` resources makes Lake Formation — not S3 bucket policies — the authoritative access control boundary. This is the AWS-recommended architecture for fine-grained data lake access control.
Reference: `lakeformation.tf:1-101`

**Row-Level and Column-Level Security**
The `aws_lakeformation_data_cells_filter.us_no_email` correctly implements row filtering (`country = 'US'`) combined with column exclusion (`email`) for `analyst-us`. The `analyst-global` role uses an explicit `column_names` allowlist that excludes `email`. This demonstrates mature data-level access control.
Reference: `lakeformation.tf:39-73`, `lakeformation.tf:76-87`

**Encryption at Rest on All Buckets**
SSE-S3 (AES256) is applied to both S3 buckets and the Athena workgroup result location. No unencrypted storage paths exist.
Reference: `s3.tf:17-25`, `s3.tf:57-65`, `athena.tf:12-15`

**S3 Versioning on the Data Lake**
`aws_s3_bucket_versioning.data_lake` is enabled, providing recovery capability for accidental overwrites or deletions of source data.
Reference: `s3.tf:9-15`

**Lifecycle Management**
Both buckets have lifecycle expiration rules (90 days for data lake objects, 30 days for Athena results), reducing the window of exposure for stale query results and minimizing storage cost.
Reference: `s3.tf:36-47`, `s3.tf:76-87`

**Athena Workgroup Enforcement**
`enforce_workgroup_configuration = true` ensures all queries submitted to the workgroup use the configured output location and encryption setting, preventing users from redirecting results to arbitrary S3 locations.
Reference: `athena.tf:7`

**No Hardcoded Credentials**
No AWS access keys, secret keys, passwords, or tokens appear anywhere in the Terraform source files. The provider block correctly uses implicit credential chain resolution.
Reference: `provider.tf:11-20`

**Sensitive Files Excluded from Version Control**
The `.gitignore` correctly excludes `terraform.tfstate`, `terraform.tfstate.backup`, `terraform.tfvars`, `*.auto.tfvars`, and `*.tfplan`. This is essential for preventing credential and state leakage.
Reference: `.gitignore:1-16`

**Lake Formation Service Role Scoped to Specific Bucket**
Unlike the analyst role policies, the `aws_iam_role_policy.lakeformation_service_s3` policy is scoped precisely to the data lake bucket ARN — not a wildcard — for both object-level and bucket-level actions.
Reference: `iam.tf:37-47`

**Resource Tagging**
Default tags (`Project`, `ManagedBy`, `Environment`) are applied to all resources via the provider `default_tags` block, supporting cost attribution and policy enforcement via tag-based conditions.
Reference: `provider.tf:13-18`

---

## Recommendations by Priority

### P1 — Fix Before Production (Required)

These findings represent gaps that could result in unauthorized access, data loss, or undetected incidents in any environment handling real data.

1. **[F-08] Configure a remote Terraform backend.**
   Add an S3 + DynamoDB backend block to `provider.tf`. Enable server-side encryption on the state bucket (SSE-KMS preferred). This is a prerequisite for team collaboration and prevents plaintext state from residing on a developer's laptop.

   ```hcl
   # provider.tf
   terraform {
     backend "s3" {
       bucket         = "<your-tfstate-bucket>"
       key            = "awslake-claude/terraform.tfstate"
       region         = "us-west-2"
       encrypt        = true
       kms_key_id     = "<kms-key-arn>"
       dynamodb_table = "<lock-table-name>"
     }
   }
   ```

2. **[F-05] Deploy a CloudTrail trail.**
   Create an `aws_cloudtrail` resource covering all regions and global services. Deliver logs to a dedicated, access-logging-enabled S3 bucket with object lock enabled. Without CloudTrail, there is no audit record of who accessed or modified data, roles, or Lake Formation permissions.

3. **[F-04] Scope trust policies to specific principals and require MFA.**
   Replace all three `arn:aws:iam::<account_id>:root` trust principals with the specific IAM entities (users, groups, or roles) that need to assume each role. Add an MFA condition to prevent non-interactive assumption.

4. **[F-01] [F-02] Scope Athena and Glue IAM policy resources.**
   Replace `Resource = "*"` on Athena statements with the specific workgroup ARN. Replace `Resource = "*"` on Glue statements with the catalog, database, and table ARNs specific to this project. This limits blast radius if a role is ever compromised.

5. **[F-11] Remove `force_destroy = true` from S3 buckets.**
   Set `force_destroy = false` (or remove the attribute) on `aws_s3_bucket.data_lake` and `aws_s3_bucket.athena_results` before deploying to any environment containing real data. A misconfigured `terraform destroy` would permanently delete all data lake contents.

### P2 — Recommended (Strong)

These findings materially improve the security posture and are considered standard practice for production data platforms.

6. **[F-09] Upgrade to SSE-KMS.**
   Create a customer-managed KMS key with annual auto-rotation enabled. Apply it to both S3 buckets and the Athena workgroup. This provides key usage visibility in CloudTrail, the ability to revoke access by disabling the key, and separation of the encryption key from the data.

7. **[F-06] Enable S3 server access logging.**
   Add `aws_s3_bucket_logging` to both the data lake and Athena results buckets. Deliver logs to a separate, dedicated logging bucket that is not accessible to analyst roles.

8. **[F-12] Remove `s3:DeleteObject` from the Lake Formation service role.**
   The Lake Formation service role requires read access for query serving. The `s3:DeleteObject` permission should only be granted if governed table compaction or a specific write-back workflow is required.

9. **[F-14] Enable versioning on the Athena results bucket.**
   Add an `aws_s3_bucket_versioning` resource for `aws_s3_bucket.athena_results` to match the data lake bucket's protection level.

10. **[F-16] Apply LF-Tags to classify PII columns.**
    Tag the `email` column (and any future PII columns such as `name`) with Lake Formation tag-based access control (`aws_lakeformation_tag` and `aws_lakeformation_resource_lf_tags`). This makes PII governance declarative and scalable across tables.

### P3 — Nice to Have (Defense in Depth)

11. **[F-10] Add VPC endpoints for S3 and Athena.**
    If compute resources (Lambda, Glue jobs, SageMaker) will be deployed inside a VPC in the future, create Gateway and Interface endpoints to ensure traffic does not leave the AWS network fabric.

12. **[F-07] Create CloudWatch alarms on Athena metrics.**
    Alert on `TotalExecutionTime`, `ProcessedBytes`, or failed query counts to detect anomalous query behavior (e.g., runaway scans or unauthorized enumeration attempts).

13. **[F-13] Mark `aws_account_id` output as sensitive.**
    Add `sensitive = true` to the `aws_account_id` output in `outputs.tf` to prevent it from appearing in CI/CD logs.

14. **[F-15] Document and restrict LF admin assignment.**
    Document that the identity running `terraform apply` is granted permanent Lake Formation admin rights. In production, use a dedicated deployment role (not a human user ARN) and remove it from LF admins via a post-deploy lifecycle hook.

15. **[F-17] Pin the AWS provider to a specific patch version.**
    Change `version = "~> 5.0"` to a specific version (e.g., `version = "= 5.82.0"`) and commit `.terraform.lock.hcl` to version control for reproducible builds.

---

## POC vs. Production Delta

The table below summarizes the specific changes required to evolve this POC configuration into a production-ready deployment. No changes are required purely for POC functionality.

| Dimension | Current POC State | Production Requirement |
|-----------|-------------------|------------------------|
| Terraform State | Local state file, unencrypted | S3 + DynamoDB remote backend with SSE-KMS and state locking |
| Audit Logging | None | CloudTrail (multi-region, global events), S3 access logs, CloudWatch metric alarms |
| Encryption | SSE-S3 (AES256), AWS-managed key | SSE-KMS with customer-managed CMK, annual key rotation, key usage audit via CloudTrail |
| IAM Trust Policy | Account root principal | Specific named principals (roles/users/groups) with MFA condition |
| IAM Resource Scope | Wildcard `*` on Athena and Glue actions | Specific resource ARNs scoped to project workgroup, catalog, database, and table |
| Data Destruction | `force_destroy = true` on all S3 buckets | `force_destroy = false`; implement a formal data deletion runbook |
| Lake Formation Admin | Deploying caller identity auto-assigned | Named break-glass role; automation identity removed post-deploy |
| PII Governance | Email excluded by name in LF permissions | LF-Tag-based PII classification; tag policy enforcement via AWS Organizations SCP |
| Network | No VPC endpoints | VPC endpoints for S3 (Gateway) and Athena (Interface) if compute moves inside VPC |
| S3 Access Logging | Not configured | Dedicated logging bucket with Object Lock (compliance mode) |
| Athena Results Versioning | Not enabled | Enable `aws_s3_bucket_versioning` on the results bucket |
| LF Service Role Permissions | Includes `s3:DeleteObject` | Remove unless a specific governed table workflow requires it |
| Provider Pinning | `~> 5.0` minor constraint | Exact version pin; `.terraform.lock.hcl` committed to source control |
| Secrets Management | `terraform.tfvars` gitignored (correct) | Consider AWS Secrets Manager or SSM Parameter Store for any runtime secrets |
| MFA Enforcement | Not enforced on role assumption | `aws:MultiFactorAuthPresent: true` condition on all analyst role trust policies |

---

## File Reference Map

| File | Key Resources | Security-Relevant Notes |
|------|---------------|------------------------|
| `provider.tf` | Provider block, Terraform version constraint | No remote backend; no hardcoded credentials |
| `variables.tf` | All input variables | No sensitive defaults; `data_lake_admins` defaults to empty list |
| `s3.tf` | `aws_s3_bucket.data_lake`, `aws_s3_bucket.athena_results` | Public access blocked; SSE-S3; versioning on data_lake only; `force_destroy = true` |
| `glue.tf` | `aws_glue_catalog_database.main`, `aws_glue_catalog_table.sales_data` | Schema includes `email` (PII); no classification tags |
| `iam.tf` | 4 IAM roles, 4 inline policies | Wildcard Resource on Athena/Glue; account root trust on analyst roles |
| `lakeformation.tf` | LF settings, permissions, data cells filter | Well-structured; row/column filters correctly applied |
| `athena.tf` | `aws_athena_workgroup.main` | Workgroup config enforced; SSE-S3; `force_destroy = true` |
| `outputs.tf` | 12 output values | No secrets in outputs; `aws_account_id` exposed as plain output |
| `.gitignore` | Exclusion rules | Correctly excludes `terraform.tfstate`, `terraform.tfvars`, `*.tfplan` |
| `terraform.tfvars.example` | Example variable values | Contains no secrets; safe to commit |

---

*This document was generated by automated security review of Terraform source files. Findings are based on static analysis and known AWS security best practices. Runtime behavior, IAM policy evaluation, and network-level controls should be validated with dynamic testing (e.g., `aws iam simulate-principal-policy`) before production deployment.*
