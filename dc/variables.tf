variable "subscription_id" {
  type        = string
  description = "Azure Subscription ID for OPS resources"
}
variable "location" {
  type = string
}

variable "sql_resource_group_name" {
  type        = string
  description = "Existing RG created by bootstrap where PoC resources are deployed"
}

variable "domain_admin_username" {
  type = string
}

variable "vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "dc_names" {
  type    = list(string)
  default = ["dc1", "dc2"]
}

variable "zones" {
  type    = list(string)
  default = ["1", "2"]
}

variable "tags" {
  type        = map(string)
  description = "Extra tags"
  default     = {}
}