# nonprod environment
# Same AWS account as nonprod-test

aws_region = "us-east-1"

# VPC Configuration
vpc_id = "vpc-xxxxxxxxx"

# Subnet Configuration
private_subnet_ids = [
  "subnet-aaaaaaaa", # us-east-1a
  "subnet-bbbbbbbb", # us-east-1b
  "subnet-cccccccc", # us-east-1c
]

# TLS Certificate
acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Vault Configuration
cluster_name  = "vault-nonprod"
vault_domain  = "vault.nonprod.example.io"
vault_version = "1.21.4"
environment   = "nonprod"

# Instance Configuration
instance_type = "m8g.medium"

# Access Control
allowed_cidr_blocks = ["0.0.0.0/0"]

# SSM Session Manager Logging
ssm_logs_s3_bucket = "ssm-session-logs-nonprod"
ssm_logs_log_group = "/aws/ssm/session-logs"

# Backup Configuration
backup_enabled   = true
backup_s3_bucket = "vault-nonprod-backups"

# EC2 Instance Tags (applied to Vault nodes at launch)
instance_tags = {
  "Application"       = ""
  "Owner"             = ""
  "CostCenter"        = ""
  "DataClass"         = ""
  "Compliance"        = ""
  "BackupSchedule"    = ""
  "PatchGroup"        = ""
  "MaintenanceWindow" = ""
}

# Tags (applied to all Terraform-managed resources)
tags = {
  Team       = "platform"
  CostCenter = "infrastructure"
}
