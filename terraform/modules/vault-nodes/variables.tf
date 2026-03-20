variable "cluster_name" {
  type        = string
  description = "Name of the Vault cluster"
}

variable "vault_version" {
  type        = string
  description = "Vault version to install"
}

variable "vault_domain" {
  type        = string
  description = "Domain name for Vault (used in api_addr)"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for Vault nodes"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for Vault nodes (one per AZ)"
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones corresponding to the subnets"
}

variable "security_group_id" {
  type        = string
  description = "Security group ID for Vault nodes"
}

variable "iam_instance_profile" {
  type        = string
  description = "IAM instance profile name for Vault nodes"
}

variable "kms_key_id" {
  type        = string
  description = "KMS key ID for auto-unseal"
}

variable "ca_cert_secret_arn" {
  type        = string
  description = "Secrets Manager ARN for CA certificate"
}

variable "ca_key_secret_arn" {
  type        = string
  description = "Secrets Manager ARN for CA private key"
}

variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "backup_enabled" {
  type        = bool
  default     = false
  description = "Enable backup automation on nodes"
}

variable "backup_s3_bucket" {
  type        = string
  default     = ""
  description = "S3 bucket name for Raft snapshot backups"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags to apply to resources"
}
