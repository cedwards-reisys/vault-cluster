output "vault_url" {
  description = "URL to access Vault UI and API"
  value       = "https://${var.vault_domain}"
}

output "nlb_dns_name" {
  description = "NLB DNS name (point your domain CNAME here)"
  value       = module.nlb.dns_name
}

output "nlb_zone_id" {
  description = "NLB hosted zone ID (for Route53 alias records)"
  value       = module.nlb.zone_id
}

output "kms_key_id" {
  description = "KMS key ID used for Vault auto-unseal"
  value       = module.kms.key_id
}

output "kms_key_arn" {
  description = "KMS key ARN used for Vault auto-unseal"
  value       = module.kms.key_arn
}

output "vault_security_group_ids" {
  description = "All security group IDs for Vault nodes (managed + additional)"
  value       = concat([module.security_groups.vault_security_group_id], var.additional_security_group_ids)
}

output "iam_role_arn" {
  description = "IAM role ARN for Vault nodes"
  value       = module.iam.role_arn
}

output "iam_instance_profile_name" {
  description = "IAM instance profile name for Vault nodes"
  value       = module.iam.instance_profile_name
}

output "ca_cert_secret_arn" {
  description = "Secrets Manager ARN for CA certificate"
  value       = module.secrets.ca_cert_secret_arn
}

output "target_group_arn" {
  description = "NLB target group ARN for registering Vault instances"
  value       = module.nlb.target_group_arn
}

output "nlb_arn_suffix" {
  description = "NLB ARN suffix (for CloudWatch dimensions and Grafana dashboard)"
  value       = module.nlb.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix (for CloudWatch dimensions and Grafana dashboard)"
  value       = module.nlb.target_group_arn_suffix
}

output "ebs_volume_ids" {
  description = "Persistent EBS volume IDs for Vault Raft data"
  value       = module.vault_nodes.ebs_volume_ids
}

output "ebs_volume_azs" {
  description = "Availability zones of the EBS volumes"
  value       = module.vault_nodes.ebs_volume_azs
}

output "ami_id" {
  description = "AMI ID for Vault nodes"
  value       = module.vault_nodes.ami_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs for Vault nodes"
  value       = var.private_subnet_ids
}

output "instance_type" {
  description = "EC2 instance type for Vault nodes"
  value       = var.instance_type
}

output "cluster_name" {
  description = "Vault cluster name"
  value       = var.cluster_name
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "backup_s3_bucket" {
  description = "S3 bucket for Vault backups"
  value       = var.backup_enabled ? module.backup[0].bucket_name : ""
}

output "root_token_secret_arn" {
  description = "Secrets Manager ARN for Vault root token"
  value       = module.secrets.root_token_secret_arn
}

output "recovery_keys_secret_arn" {
  description = "Secrets Manager ARN for Vault recovery keys"
  value       = module.secrets.recovery_keys_secret_arn
}

output "instance_tags" {
  description = "Additional tags for Vault EC2 instances"
  value       = var.instance_tags
}

output "cloudwatch_alarm_arns" {
  description = "ARNs of all CloudWatch alarms for wiring up alerting"
  value       = module.monitoring.alarm_arns
}

output "node_management_instructions" {
  description = "Instructions for managing Vault nodes"
  value       = <<-EOT

    Vault Cluster Infrastructure Deployed!
    ======================================

    IMPORTANT: Nodes are NOT managed by Terraform. Use the scripts in ./scripts/

    1. Point your DNS (${var.vault_domain}) to the NLB:
       NLB DNS: ${module.nlb.dns_name}

    2. Deploy Vault nodes (one at a time):
       ./scripts/launch-node.sh <env> <az-index>   # 0, 1, or 2

    3. Initialize Vault (only on first deployment, after first node is running):
       vault operator init -recovery-shares=5 -recovery-threshold=3

    4. Deploy remaining nodes:
       ./scripts/launch-node.sh <env> 1
       ./scripts/launch-node.sh <env> 2

    5. Check cluster status:
       ./scripts/cluster-status.sh <env>

    For rolling updates (e.g., new Vault version):
       ./scripts/rolling-update.sh <env>

    To terminate a node gracefully:
       ./scripts/terminate-node.sh <env> <instance-id>

  EOT
}
