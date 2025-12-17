
variable "location" {
  type        = string
  description = "Azure region"
  default     = "centralus"
}

variable "workload_resource_group_name" {
  type        = string
  description = "Existing RG created by bootstrap where PoC resources are deployed"
}

variable "name_prefix" {
  type        = string
  description = "Name prefix for resources"
  default     = "sqlpoc"
}

variable "vnet_address_space" {
  type        = list(string)
  description = "VNet address space"
  default     = ["10.10.0.0/24"]
}

# Split subnets
variable "subnet_dc_prefix" {
  type        = string
  description = "Subnet prefix for Domain Controller VM(s)"
  default     = "10.10.0.0/26"
}

variable "subnet_sql_prefix" {
  type        = string
  description = "Subnet prefix for SQL VM(s)"
  default     = "10.10.0.64/26"
}

# Bastion Standard requires /26 or larger
variable "subnet_bastion_prefix" {
  type        = string
  description = "Subnet prefix for AzureBastionSubnet (must be /26 or larger for Standard SKU)"
  default     = "10.10.0.128/26"
}

variable "tags" {
  type        = map(string)
  description = "Extra tags"
  default     = {}
}