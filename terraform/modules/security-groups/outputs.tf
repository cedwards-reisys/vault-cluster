output "vault_security_group_id" {
  description = "Security group ID for Vault nodes"
  value       = aws_security_group.vault.id
}
