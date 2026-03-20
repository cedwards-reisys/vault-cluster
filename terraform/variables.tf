variable "aws_region" {
  type        = string
  description = "AWS region to deploy the Vault cluster"
}

variable "vpc_id" {
  type        = string
  description = "Existing VPC ID to deploy into"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "3 private subnet IDs across different AZs for Vault nodes"

  validation {
    condition     = length(var.private_subnet_ids) == 3
    error_message = "Exactly 3 private subnet IDs are required (one per AZ)."
  }
}

variable "acm_certificate_arn" {
  type        = string
  description = "ACM certificate ARN for vault.nonprod.reisys.io"
}

variable "instance_type" {
  type        = string
  default     = "m8g.medium"
  description = "EC2 instance type for Vault nodes (ARM64 Graviton recommended)"
}

variable "vault_version" {
  type        = string
  default     = "1.21.4"
  description = "HashiCorp Vault version to install"
}

variable "allowed_cidr_blocks" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDR blocks allowed to access Vault via NLB"
}

variable "cluster_name" {
  type        = string
  default     = "vault-nonprod"
  description = "Name for the Vault cluster (used in resource names and tags)"
}

variable "vault_domain" {
  type        = string
  default     = "vault.nonprod.reisys.io"
  description = "Domain name for Vault API/UI access"
}

variable "environment" {
  type        = string
  default     = "nonprod"
  description = "Environment name (nonprod, prod, etc.)"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags to apply to all resources"
}

variable "instance_tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags to apply to Vault EC2 instances (e.g. compliance, ownership, cost allocation)"
}

variable "ssm_logs_s3_bucket" {
  type        = string
  description = "S3 bucket name for SSM Session Manager logs"
}

variable "ssm_logs_log_group" {
  type        = string
  description = "CloudWatch log group for SSM Session Manager logs"
}

variable "backup_enabled" {
  type        = bool
  default     = false
  description = "Enable backup infrastructure and on-node backup automation"
}

variable "backup_s3_bucket" {
  type        = string
  default     = ""
  description = "S3 bucket name for Raft snapshot backups"
}

variable "additional_security_group_ids" {
  type        = list(string)
  default     = []
  description = "Additional pre-existing security group IDs to attach to Vault nodes (not managed by Terraform)"
}

variable "backup_retention_days" {
  type        = number
  default     = 90
  description = "Days to retain daily backups"
}
