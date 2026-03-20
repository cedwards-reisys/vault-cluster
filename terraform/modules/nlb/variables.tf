variable "vpc_id" {
  type        = string
  description = "VPC ID for the target group"
}

variable "cluster_name" {
  type        = string
  description = "Name of the Vault cluster"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the internal NLB"
}

variable "acm_certificate_arn" {
  type        = string
  description = "ACM certificate ARN for TLS listener"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags to apply to resources"
}
