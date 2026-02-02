variable "resource_group_name" {
  description = "Specifies the resource group where the SQL IaaS resources are deployed. Decided by ADF."
  type        = string
}

variable "location" {
  description = "Azure Region."
  type        = string
}

variable "name_prefix" {
  description = "Prefix used for naming all resources to ensure uniqueness and alignment with FNZ naming conventions."
  type        = string
}

variable "is_ha" {
  description = "Determines whether the deployment is High Availability: false -> single-VM dev/test, true -> multi-VMs Always On AG"
  type        = bool
  default     = false
}

variable "is_dr" {
  description = "Indicates if the module is being deployed in the DR region."
  type        = bool
  default     = false
}

variable "vm_sku" {
  description = "Defines virtual machine size/SKU for SQL nodes."
  type        = string
}

variable "subnet_ids" {
  description = "List of Subnet IDs for SQL VMs. First one is used for single-subnet design."
  type        = list(string)
}

variable "private_endpoint_subnet_id" {
  description = "Subnet ID for private endpoints (witness storage, etc.). If not provided, uses first subnet from subnet_ids."
  type        = string
  default     = ""
}

variable "availability_zones" {
  description = "For HA deployments: zones to be used. Typically inferred from is_ha. But can be overwritten if the desired SKUs are not available in all zones."
  type        = list(number)
  default     = [1, 2, 3]
}

variable "dr_primary_nodes" {
  description = "List of SQL nodes in primary region to allow DAG creation during DR deployment. Required when is_dr = true"
  type        = list(string)
  default     = []
}

variable "sql_admin_username" {
  description = "Local Administrator username for the SQL VMs."
  type        = string
  default     = "sqladmin"
}

variable "sql_vm_admin_password" {
  description = "Password for the Local Administrator."
  type        = string
  sensitive   = true
}

variable "cluster_local_admin_username" {
  description = "Username for the cluster local admin account used for WSFC."
  type        = string
  default     = "clusteradmin"
}

variable "image_publisher" {
  type    = string
  default = "MicrosoftSQLServer"
}

variable "image_offer" {
  type    = string
  default = "sql2025-ws2025"
}

variable "image_sku" {
  type    = string
  default = "enterprise-gen2"
}

variable "image_version" {
  type    = string
  default = "latest"
}

variable "tags" {
  description = "Map of tags to apply to resources."
  type        = map(string)
  default     = {}
}

variable "data_disk_size_gb" {
  type    = number
  default = 256
}

variable "data_disk_type" {
  type    = string
  default = "Standard_LRS"
}

variable "log_disk_size_gb" {
  type    = number
  default = 128
}

variable "log_disk_type" {
  type    = string
  default = "Standard_LRS"
}

variable "tempdb_disk_size_gb" {
  type    = number
  default = 128
}

variable "tempdb_disk_type" {
  type    = string
  default = "Standard_LRS"
}

variable "failover_cluster_name" {
  description = "Name of the Failover Cluster."
  type        = string
  default     = "sql-cluster"
}

variable "vnet_id" {
  description = "VNet ID for Private DNS linking."
  type        = string
}

variable "dns_zone_name" {
  description = "Private DNS Zone name for the cluster (e.g. sql.fnz.local)."
  type        = string
  default     = "sql.internal"
}

variable "user_assigned_identity_ids" {
  description = "List of User Assigned Identity IDs to assign to the VMs."
  type        = list(string)
  default     = []
}

