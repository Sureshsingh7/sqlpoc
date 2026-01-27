# Core configuration
variable "resource_group_name" {
  type        = string
  description = "Resource group name where SQL VMs will be deployed (destination RG)"
}

variable "location" {
  type        = string
  description = "Azure region for SQL VM deployment"
}

variable "vm_size" {
  type        = string
  description = "VM size for SQL Server (SKU of the DB VM)"
  default     = "Standard_D4s_v4"
  validation {
    condition     = can(regex("Standard_D[4-9].*|Standard_E[4-9].*", var.vm_size))
    error_message = "VM size must be at least D4s_v4 or E4s_v4 for SQL Server."
  }
}

variable "manage_disk_setup_extension" {
  type        = bool
  description = "Whether to run disk setup script"
  default     = true
}

variable "enable_failover_cluster" {
  type        = bool
  description = "Whether to configure Availability Group / Failover Cluster."
  default     = true
}

# Network Dependencies (passed from caller)
variable "subnet_id_primary" {
  type        = string
  description = "Subnet ID for the first SQL VM"
}

variable "subnet_id_secondary" {
  type        = string
  description = "Subnet ID for the second SQL VM"
}

# Private Endpoint subnet
variable "subnet_id_private_endpoint" {
  type        = string
  description = "Subnet ID for private endpoints (e.g. Witness storage)"
}

variable "vnet_id" {
  type        = string
  description = "Virtual Network ID (for Private DNS Zone links)"
}

# Security
variable "sql_admin_username" {
  type        = string
  description = "Admin username for SQL VMs"
  sensitive   = true
  default     = "sqlAdmin"
}

variable "sql_vm_admin_password" {
  type        = string
  description = "Admin password for SQL VMs"
  sensitive   = true
}

variable "cluster_local_admin_username" {
  type        = string
  description = "Local user to create on both SQL VMs for workgroup WSFC administration"
  default     = "clusteradmin"
}

variable "sql_vm_user_assigned_identity_ids" {
  type        = set(string)
  description = "User-assigned managed identity resource IDs to attach to each SQL VM."
  default     = []
}

variable "sql_vm_user_assigned_identity_client_id" {
  type        = string
  description = "Client ID of the user-assigned identity to use for CustomScriptExtension managedIdentity."
  default     = ""
}

# Script Access
variable "disk_setup_sas" {
  type        = string
  description = "Optional SAS token for disk_setup.ps1 download."
  sensitive   = true
  default     = ""
}

variable "failover_cluster_sas" {
  type        = string
  description = "SAS token for crate_failover_cluster.ps1 download."
  sensitive   = true
  default     = ""
}

# VM Configuration (optional overrides)
variable "sql_vm_names" {
  type        = list(string)
  description = "Names of SQL Server VMs to deploy"
  default     = ["sqlpoc-primary", "sqlpoc-secondary"]
}

variable "sql_private_ips" {
  type        = list(string)
  description = "Static private IP addresses for SQL Server VMs"
  default     = ["10.10.0.10", "10.10.0.74"]
}

variable "cluster_ips" {
  type        = list(string)
  description = "Static IP addresses for the failover cluster [cluster_primary_ip, cluster_secondary_ip]"
  default     = ["10.10.0.12", "10.10.0.76"]
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones for SQL VMs"
  default     = ["1", "2"]
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to resources"
  default     = {}
}

# Storage Config
variable "os_disk_type" { default = "Premium_LRS" }
variable "os_disk_size_gb" { default = 128 }
variable "data_disk_type" { default = "Premium_LRS" }
variable "data_disk_count" { default = 1 }
variable "data_disk_size_gb" { default = 256 }
variable "log_disk_type" { default = "Premium_LRS" }
variable "log_disk_size_gb" { default = 256 }
variable "tempdb_disk_type" { default = "Premium_LRS" }
variable "tempdb_disk_size_gb" { default = 256 }
variable "witness_storage_security_control_tag_value" { default = "ignore" }

# Image Config
variable "image_publisher" { default = "MicrosoftSQLServer" }
variable "image_offer" { default = "sql2025-ws2022" }
variable "image_sku" { default = "standard" }
variable "image_version" { default = "latest" }
variable "enable_sql_extension" { default = true }

# Cluster Config
variable "failover_cluster_name" {
  type        = string
  description = "Name of the SQL Server Failover Cluster"
  default     = "sqlpoc-cluster"
}

# DR Configuration
variable "primary_cluster_dns" {
  type        = string
  description = "DNS name of the Primary Cluster (for DR region awareness)"
  default     = ""
}

variable "primary_cluster_ip" {
  type        = string
  description = "IP address of the Primary Cluster listener (for DR region awareness)"
  default     = ""
}
