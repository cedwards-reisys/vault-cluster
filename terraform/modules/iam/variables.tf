variable "cluster_name" {
  type        = string
  description = "Name of the Vault cluster"
}

variable "kms_key_arn" {
  type        = string
  description = "ARN of the KMS key for Vault auto-unseal"
}

variable "secrets_manager_arns" {
  type        = list(string)
  description = "List of Secrets Manager secret ARNs to allow access to"
}

variable "ssm_logs_s3_bucket" {
  type        = string
  description = "S3 bucket name for SSM Session Manager logs"
}

variable "ssm_logs_log_group" {
  type        = string
  description = "CloudWatch log group for SSM Session Manager logs"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags to apply to resources"
}
