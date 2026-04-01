provider "aws" {
  region = var.aws_region
}

locals {
  common_tags = merge(var.tags, {
    Project     = "vault-cluster"
    Environment = var.environment
    ManagedBy   = "opentofu"
  })
}

# Get availability zones for the subnets
data "aws_subnet" "private" {
  count = length(var.private_subnet_ids)
  id    = var.private_subnet_ids[count.index]
}

# KMS key for Vault auto-unseal
module "kms" {
  source = "./modules/kms"

  cluster_name = var.cluster_name
  tags         = local.common_tags
}

# IAM roles and policies for Vault nodes
module "iam" {
  source = "./modules/iam"

  cluster_name      = var.cluster_name
  kms_key_arn       = module.kms.key_arn
  secrets_manager_arns = concat(
    [
      module.kms.ca_cert_secret_arn,
      module.kms.ca_key_secret_arn,
    ],
    [
      module.kms.root_token_secret_arn,
      module.kms.recovery_keys_secret_arn,
    ]
  )
  ssm_logs_s3_bucket = var.ssm_logs_s3_bucket
  ssm_logs_log_group = var.ssm_logs_log_group
  tags               = local.common_tags
}

# Security group for Vault nodes
# Note: NLB does not use security groups - traffic flows directly to targets
module "security_groups" {
  source = "./modules/security-groups"

  vpc_id              = var.vpc_id
  cluster_name        = var.cluster_name
  allowed_cidr_blocks = var.allowed_cidr_blocks
  tags                = local.common_tags
}

# Network Load Balancer
module "nlb" {
  source = "./modules/nlb"

  vpc_id              = var.vpc_id
  cluster_name        = var.cluster_name
  private_subnet_ids  = var.private_subnet_ids
  acm_certificate_arn        = var.acm_certificate_arn
  enable_deletion_protection = var.enable_deletion_protection
  tags                       = local.common_tags
}

# Vault nodes - Persistent EBS volumes only
# EC2 instances are managed by scripts, not Terraform
module "vault_nodes" {
  source = "./modules/vault-nodes"

  cluster_name         = var.cluster_name
  vault_version        = var.vault_version
  vault_domain         = var.vault_domain
  instance_type        = var.instance_type
  private_subnet_ids   = var.private_subnet_ids
  availability_zones   = data.aws_subnet.private[*].availability_zone
  security_group_id    = module.security_groups.vault_security_group_id
  iam_instance_profile = module.iam.instance_profile_name
  kms_key_id           = module.kms.key_id
  ca_cert_secret_arn   = module.kms.ca_cert_secret_arn
  ca_key_secret_arn    = module.kms.ca_key_secret_arn
  aws_region           = var.aws_region
  backup_enabled       = var.backup_enabled
  backup_s3_bucket     = var.backup_s3_bucket
  tags                 = local.common_tags
}

# Monitoring — CloudWatch alarms
module "monitoring" {
  source = "./modules/monitoring"

  cluster_name            = var.cluster_name
  nlb_arn_suffix          = module.nlb.arn_suffix
  target_group_arn_suffix = module.nlb.target_group_arn_suffix
  ebs_volume_ids          = module.vault_nodes.ebs_volume_ids
  tags                    = local.common_tags
}

# SSM Parameters — operational values for Jenkins jobs and monitoring
resource "aws_ssm_parameter" "vault_url" {
  name  = "/${var.cluster_name}/config/vault-url"
  type  = "String"
  value = "https://${var.vault_domain}"
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "cluster_name" {
  name  = "/${var.cluster_name}/config/cluster-name"
  type  = "String"
  value = var.cluster_name
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "vault_config" {
  name  = "/${var.cluster_name}/config/vault-config"
  type  = "String"
  value = jsonencode({
    aws_region              = var.aws_region
    nlb_dns_name            = module.nlb.dns_name
    nlb_arn_suffix          = module.nlb.arn_suffix
    target_group_arn        = module.nlb.target_group_arn
    target_group_arn_suffix = module.nlb.target_group_arn_suffix
    kms_key_id              = module.kms.key_id
    instance_type           = var.instance_type
    private_subnet_ids      = var.private_subnet_ids
    instance_tags                 = var.instance_tags
    additional_security_group_ids = var.additional_security_group_ids
  })
  tags = local.common_tags
}

# Backup infrastructure (S3 bucket + IAM policy)
module "backup" {
  count  = var.backup_enabled ? 1 : 0
  source = "./modules/backup"

  bucket_name          = var.backup_s3_bucket
  cluster_name         = var.cluster_name
  vault_iam_role_name  = module.iam.role_name
  daily_retention_days = var.backup_retention_days
  tags                 = local.common_tags
}
