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

variable "object_lock_enabled" {
  type        = bool
  default     = true
  description = <<-EOT
    Enable S3 Object Lock on the backup bucket. Object Lock protects individual
    snapshot objects from deletion or overwrite for a retention period —
    defense against ransomware, insider deletion, and accidental aws s3 rm.
    Must be enabled at bucket-creation time; cannot be enabled retroactively.
  EOT
}

variable "object_lock_retention_days" {
  type        = number
  default     = 30
  description = <<-EOT
    Retention period (days) applied to every object via the default bucket
    retention rule when object_lock_enabled=true. Uses GOVERNANCE mode so
    privileged operators can override for intentional cleanup. Set to match
    your shortest snapshot-prefix retention (sync=30d by default).
  EOT
}
