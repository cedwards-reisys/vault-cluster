output "ca_cert_secret_arn" {
  description = "Secrets Manager ARN for CA certificate"
  value       = data.aws_secretsmanager_secret.ca_cert.arn
}

output "ca_key_secret_arn" {
  description = "Secrets Manager ARN for CA private key"
  value       = data.aws_secretsmanager_secret.ca_key.arn
}

output "root_token_secret_arn" {
  description = "Secrets Manager ARN for Vault root token"
  value       = aws_secretsmanager_secret.root_token.arn
}

output "recovery_keys_secret_arn" {
  description = "Secrets Manager ARN for Vault recovery keys"
  value       = aws_secretsmanager_secret.recovery_keys.arn
}
