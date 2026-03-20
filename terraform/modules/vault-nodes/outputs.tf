output "ebs_volume_ids" {
  description = "IDs of the persistent EBS volumes for Vault data"
  value       = aws_ebs_volume.vault_data[*].id
}

output "ebs_volume_azs" {
  description = "Availability zones of the EBS volumes"
  value       = aws_ebs_volume.vault_data[*].availability_zone
}

output "ami_id" {
  description = "AMI ID for Vault nodes"
  value       = data.aws_ami.amazon_linux.id
}

output "userdata_script_path" {
  description = "Path to the generated userdata script"
  value       = local_file.userdata_template.filename
}
