# Get latest Amazon Linux 2023 ARM64 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# Persistent EBS volumes for Vault Raft data — one per AZ.
# These volumes persist across instance replacements (see ADR-008).
#
# lifecycle.prevent_destroy is intentionally hardcoded to true. Terraform
# does not allow prevent_destroy to be a variable, by design — it's a
# safety fence, not a runtime toggle.
#
# LEGITIMATE DESTROY PROCEDURE (when an operator really must destroy a
# volume, e.g., full environment teardown, AZ retirement, corruption):
#
#   1. Confirm you actually want to lose the data. This volume holds Raft
#      state — destroying it is irreversible without a snapshot restore.
#   2. Remove it from Terraform state (tells TF to stop managing it):
#        tofu state rm 'module.vault-nodes.aws_ebs_volume.vault_data[N]'
#      where N is the AZ index (0, 1, 2).
#   3. Delete the volume via AWS CLI or console:
#        aws ec2 delete-volume --volume-id vol-xxx --region <region>
#   4. Next `tofu apply` will create a fresh replacement (which userdata
#      will treat as an empty volume — writes a fresh sentinel, starts
#      fresh Raft state on first mount).
#
# See docs/operations.md §Destroying an EBS Volume for the full runbook.
resource "aws_ebs_volume" "vault_data" {
  count = length(var.private_subnet_ids)

  availability_zone = var.availability_zones[count.index]
  size              = 200
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  encrypted         = true

  tags = merge(var.tags, {
    Name            = "${var.cluster_name}-vault-data-${var.availability_zones[count.index]}"
    "vault-cluster" = var.cluster_name
    "vault-az"      = var.availability_zones[count.index]
    "vault-role"    = "raft-data"
  })

  lifecycle {
    prevent_destroy = true
  }
}

# Generate userdata script content for use by operational scripts
resource "local_file" "userdata_template" {
  content = templatefile("${path.module}/templates/userdata.sh.tpl", {
    cluster_name       = var.cluster_name
    vault_version      = var.vault_version
    vault_domain       = var.vault_domain
    aws_region         = var.aws_region
    kms_key_id         = var.kms_key_id
    ca_cert_secret_arn = var.ca_cert_secret_arn
    ca_key_secret_arn  = var.ca_key_secret_arn
    backup_enabled     = var.backup_enabled
    backup_s3_bucket   = var.backup_s3_bucket
  })
  filename = "${path.module}/generated/userdata.sh"
}
