output "ebs_volume_ids" {
  description = "IDs of the persistent EBS volumes for Vault data"
  value       = aws_ebs_volume.vault_data[*].id
}

output "ebs_volume_azs" {
  description = "Availability zones of the EBS volumes"
  value       = aws_ebs_volume.vault_data[*].availability_zone
}

output "network_interface_ids" {
  description = "IDs of the persistent ENIs for Vault nodes"
  value       = aws_network_interface.vault_network[*].id
}

output "network_interface_private_ips" {
  description = "Primary private IPs of the persistent ENIs for Vault nodes"
  value       = aws_network_interface.vault_network[*].private_ip
}

output "network_interface_azs" {
  description = "Availability zones of the persistent ENIs"
  value       = var.availability_zones
}

output "ami_id" {
  description = "AMI ID for Vault nodes"
  value       = data.aws_ami.amazon_linux.id
}

output "userdata_script_path" {
  description = "Path to the generated userdata script"
  value       = local_file.userdata_template.filename
}
