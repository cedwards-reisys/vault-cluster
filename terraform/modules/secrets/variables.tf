variable "cluster_name" {
  type        = string
  description = "Name of the Vault cluster"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags to apply to resources"
}
