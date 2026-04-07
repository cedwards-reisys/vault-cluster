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
