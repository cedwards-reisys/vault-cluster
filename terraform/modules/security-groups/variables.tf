variable "vpc_id" {
  type        = string
  description = "VPC ID to create security groups in"
}

variable "cluster_name" {
  type        = string
  description = "Name of the Vault cluster"
}

variable "allowed_cidr_blocks" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDR blocks allowed to access Vault via NLB"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags to apply to resources"
}
