output "role_arn" {
  description = "ARN of the IAM role for Vault nodes"
  value       = aws_iam_role.vault.arn
}

output "role_name" {
  description = "Name of the IAM role for Vault nodes"
  value       = aws_iam_role.vault.name
}

output "instance_profile_arn" {
  description = "ARN of the instance profile for Vault nodes"
  value       = aws_iam_instance_profile.vault.arn
}

output "instance_profile_name" {
  description = "Name of the instance profile for Vault nodes"
  value       = aws_iam_instance_profile.vault.name
}
