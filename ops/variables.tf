variable "subscription_id" {
  type        = string
  description = "Azure Subscription ID for OPS resources"
}

variable "ops_resource_group_name" {
  type        = string
  description = "Resource group where OPS workloads (runner) are deployed"
}

variable "location" {
  type = string
}

variable "vm_admin_username" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "tags" {
  type        = map(string)
  description = "Extra tags"
  default     = {}
}

variable "tenant_id" {
  type        = string
  description = "Azure Tenant ID"
}

variable "terraform_uami_principal_id" {
  description = "Principal ID of the Managed Identity used by Terraform"
  type        = string
}

variable "suresh_principal_id" {
  description = "AAD Object ID of Suresh"
  type        = string
}
