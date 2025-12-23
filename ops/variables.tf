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