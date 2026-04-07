# CA cert and key — created out-of-band by generate-ca.sh, read-only here
data "aws_secretsmanager_secret" "ca_cert" {
  name = "${var.cluster_name}/tls/ca-cert"
}

data "aws_secretsmanager_secret" "ca_key" {
  name = "${var.cluster_name}/tls/ca-key"
}

# Vault root token — placeholder, populated by operator after init
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

# Vault recovery keys — placeholder, populated by operator after init
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
