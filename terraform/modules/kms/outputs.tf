output "key_id" {
  description = "KMS key ID for Vault auto-unseal"
  value       = aws_kms_key.vault_unseal.key_id
}

output "key_arn" {
  description = "KMS key ARN for Vault auto-unseal"
  value       = aws_kms_key.vault_unseal.arn
}

output "key_alias" {
  description = "KMS key alias"
  value       = aws_kms_alias.vault_unseal.name
}

output "ca_cert_secret_arn" {
  description = "Secrets Manager ARN for CA certificate"
  value       = aws_secretsmanager_secret.ca_cert.arn
}

output "ca_key_secret_arn" {
  description = "Secrets Manager ARN for CA private key"
  value       = aws_secretsmanager_secret.ca_key.arn
}

output "ca_cert_pem" {
  description = "CA certificate PEM (for reference)"
  value       = tls_self_signed_cert.ca.cert_pem
  sensitive   = true
}

output "root_token_secret_arn" {
  description = "Secrets Manager ARN for Vault root token"
  value       = aws_secretsmanager_secret.root_token.arn
}

output "recovery_keys_secret_arn" {
  description = "Secrets Manager ARN for Vault recovery keys"
  value       = aws_secretsmanager_secret.recovery_keys.arn
}
