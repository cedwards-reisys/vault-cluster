output "dns_name" {
  description = "DNS name of the NLB"
  value       = aws_lb.vault.dns_name
}

output "zone_id" {
  description = "Zone ID of the NLB (for Route53 alias records)"
  value       = aws_lb.vault.zone_id
}

output "arn" {
  description = "ARN of the NLB"
  value       = aws_lb.vault.arn
}

output "target_group_arn" {
  description = "ARN of the target group"
  value       = aws_lb_target_group.vault.arn
}

output "target_group_name" {
  description = "Name of the target group"
  value       = aws_lb_target_group.vault.name
}

output "listener_arn" {
  description = "ARN of the TLS listener"
  value       = aws_lb_listener.tls.arn
}

output "arn_suffix" {
  description = "ARN suffix of the NLB (for CloudWatch dimensions)"
  value       = aws_lb.vault.arn_suffix
}

output "target_group_arn_suffix" {
  description = "ARN suffix of the target group (for CloudWatch dimensions)"
  value       = aws_lb_target_group.vault.arn_suffix
}
