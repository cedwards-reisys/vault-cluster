variable "cluster_name" {
  type        = string
  description = "Name of the Vault cluster"
}

variable "nlb_arn_suffix" {
  type        = string
  description = "ARN suffix of the NLB (for CloudWatch dimensions)"
}

variable "target_group_arn_suffix" {
  type        = string
  description = "ARN suffix of the NLB target group"
}

variable "ebs_volume_ids" {
  type        = list(string)
  description = "EBS volume IDs for Vault data volumes"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags to apply to resources"
}
