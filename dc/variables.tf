variable "tenant_id" {
  type        = string
  description = "Azure Tenant ID"
  default     = "0ebb4727-213e-46b9-8c4a-6611a5f157b0"
}

variable "subscription_id" {
  type        = string
  description = "Azure Subscription ID for OPS resources"
  default     = "51595cc9-4191-4785-a757-15e45165d2a4"
}
variable "location" {
  type    = string
  default = "swedencentral"
}

variable "sql_resource_group_name" {
  type        = string
  description = "Existing RG created by bootstrap where PoC resources are deployed"
  default     = "rg-fnz-poc-sql-se"
}

variable "domain_admin_username" {
  type    = string
  default = "azureuser"
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
  default     = { project = "SQLPOC" }
}