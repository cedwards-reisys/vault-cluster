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

# Generate self-signed CA for internal TLS
resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem = tls_private_key.ca.private_key_pem

  subject {
    common_name         = "${var.cluster_name} CA"
    organization        = "Vault Cluster"
    organizational_unit = var.cluster_name
  }

  validity_period_hours = 87600 # 10 years
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]
}

# Store CA certificate in Secrets Manager
resource "aws_secretsmanager_secret" "ca_cert" {
  name                    = "${var.cluster_name}/tls/ca-cert"
  description             = "CA certificate for Vault cluster internal TLS"
  recovery_window_in_days = 7

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ca-cert"
  })
}

resource "aws_secretsmanager_secret_version" "ca_cert" {
  secret_id     = aws_secretsmanager_secret.ca_cert.id
  secret_string = tls_self_signed_cert.ca.cert_pem
}

# Store CA private key in Secrets Manager (encrypted)
resource "aws_secretsmanager_secret" "ca_key" {
  name                    = "${var.cluster_name}/tls/ca-key"
  description             = "CA private key for Vault cluster internal TLS"
  recovery_window_in_days = 7

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ca-key"
  })
}

resource "aws_secretsmanager_secret_version" "ca_key" {
  secret_id     = aws_secretsmanager_secret.ca_key.id
  secret_string = tls_private_key.ca.private_key_pem
}

# Secrets Manager secret for Vault root token (placeholder - populated by scripts)
resource "aws_secretsmanager_secret" "root_token" {
  name                    = "${var.cluster_name}/vault/root-token"
  description             = "Vault root token for ${var.cluster_name}"
  recovery_window_in_days = 7

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-root-token"
  })

  lifecycle {
    ignore_changes = [description]
  }
}

# Secrets Manager secret for Vault recovery keys (placeholder - populated by scripts)
resource "aws_secretsmanager_secret" "recovery_keys" {
  name                    = "${var.cluster_name}/vault/recovery-keys"
  description             = "Vault recovery keys for ${var.cluster_name}"
  recovery_window_in_days = 7

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-recovery-keys"
  })

  lifecycle {
    ignore_changes = [description]
  }
}
