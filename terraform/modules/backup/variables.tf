variable "bucket_name" {
  type        = string
  description = "Name of the S3 bucket for Vault backups"
}

variable "cluster_name" {
  type        = string
  description = "Name of the Vault cluster"
}

variable "vault_iam_role_name" {
  type        = string
  description = "Name of the Vault IAM role to attach S3 backup policy to"
}

variable "daily_retention_days" {
  type        = number
  default     = 90
  description = "Days to retain daily backups"
}

variable "weekly_retention_days" {
  type        = number
  default     = 365
  description = "Days to retain weekly backups"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags to apply to resources"
}
