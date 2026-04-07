# KMS key for Vault auto-unseal
resource "aws_kms_key" "vault_unseal" {
  description             = "KMS key for Vault auto-unseal - ${var.cluster_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-unseal-key"
  })
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/${var.cluster_name}-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}
