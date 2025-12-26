variable "subscription_id" {
  type        = string
  description = "Azure Subscription ID for OPS resources"
}

variable "location" {
  type        = string
  description = "Azure region"
  default     = "swedencentral"
}

variable "sql_resource_group_name" {
  type        = string
  description = "Existing RG created by bootstrap where PoC resources are deployed"
}

variable "sql_name_prefix" {
  type        = string
  description = "Name prefix for resources"
  default     = "sqlpoc"
}

variable "sql_vnet_address_space" {
  type        = list(string)
  description = "VNet address space"
  default     = ["10.10.0.0/24"]
}

# Split subnets
variable "sql_subnet_dc_prefix" {
  type        = string
  description = "Subnet prefix for Domain Controller VM(s)"
  default     = "10.10.0.0/26"
}

variable "sql_subnet_sql1_prefix" {
  type        = string
  description = "Subnet prefix for SQL VM(s)"
  default     = "10.10.0.64/26"
}

variable "sql_subnet_sql2_prefix" {
  type        = string
  description = "Subnet prefix for SQL VM(s)"
  default     = "10.10.0.128/26"
}

variable "sql_subnet_pep_prefix" {
  type        = string
  description = "Subnet prefix for Private Endpoints"
  default     = "10.10.0.192/27"
}

variable "ops_resource_group_name" {
  type        = string
  description = "Existing RG created by bootstrap where PoC resources are deployed"
}

variable "ops_name_prefix" {
  type        = string
  description = "Name prefix for resources"
  default     = "opspoc"
}

variable "ops_vnet_address_space" {
  type        = list(string)
  description = "VNet address space"
  default     = ["10.20.0.0/24"]
}

# Split subnets
variable "ops_subnet_runner_prefix" {
  type        = string
  description = "Subnet prefix for Domain Controller VM(s)"
  default     = "10.20.0.0/26"
}

# Bastion Standard requires /26 or larger
variable "subnet_bastion_prefix" {
  type        = string
  description = "Subnet prefix for AzureBastionSubnet (must be /26 or larger for Standard SKU)"
  default     = "10.20.0.64/26"
}

variable "tags" {
  type        = map(string)
  description = "Extra tags"
  default     = {}
}