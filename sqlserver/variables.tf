variable "subscription_id" {
  type        = string
  description = "Azure Subscription ID"
}

variable "use_msi" {
  type        = bool
  description = "Use managed identity to access remote Terraform state. Set false for local runs."
  default     = true
}

variable "disk_setup_sas" {
  type        = string
  description = "Optional SAS token (no leading '?') for downloading scripts/disk_setup.ps1 from the TFSTATE storage container. Leave empty to use managed identity."
  sensitive   = true
  default     = ""
}

variable "manage_disk_setup_extension" {
  type        = bool
  description = "Whether Terraform should manage the disk setup CustomScriptExtension. Set to false after disks are configured to avoid repeated extension updates."
  default     = true
}

variable "enable_failover_cluster" {
  type        = bool
  description = "Whether to run the create_failover_cluster.ps1 script inside the CustomScriptExtension."
  default     = true
}

variable "location" {
  type        = string
  description = "Azure region for SQL VM deployment"
}

variable "sql_resource_group_name" {
  type        = string
  description = "Resource group name where SQL VMs will be deployed"
}

# VM Configuration using map of objects (key = VM name)
variable "sql_vms" {
  type = map(object({
    private_ip          = string
    subnet_id           = string
    availability_zone   = string
    vm_size             = optional(string)
    cluster_ip          = optional(string, "")
    os_disk_size_gb     = optional(number)
    data_disk_size_gb   = optional(number)
    log_disk_size_gb    = optional(number)
    tempdb_disk_size_gb = optional(number)
    tags                = optional(map(string), {})
  }))
  description = "Map of SQL Server VM configurations. Key is the VM name (max 15 chars). Note: Used only for legacy compat; new sql-iaas module auto-generates names."
  default = {
    "sqlpoc-primary" = {
      private_ip        = "10.10.0.10"
      subnet_id         = "primary"
      availability_zone = "1"
      cluster_ip        = "10.10.0.12"
    }
  }
}

variable "failover_cluster_sas" {
  type        = string
  description = "User delegation SAS token (no leading '?') for downloading scripts/create_failover_cluster.ps1 from the TFSTATE storage container"
  sensitive   = true
  default     = ""
}

variable "sql_admin_username" {
  type        = string
  description = "Admin username for SQL VMs (cannot be 'Administrator', 'admin', or 'root')"
  sensitive   = true
  validation {
    condition     = !contains(["administrator", "admin", "root"], lower(var.sql_admin_username))
    error_message = "Admin username cannot be 'Administrator', 'admin', or 'root'."
  }
}

variable "sql_vm_user_assigned_identity_ids" {
  type        = set(string)
  description = "User-assigned managed identity resource IDs to attach to each SQL VM (keeps UAMIs from being removed)."
  default     = []
}

variable "sql_vm_user_assigned_identity_client_id" {
  type        = string
  description = "Client ID of the user-assigned identity to use for CustomScriptExtension managedIdentity (avoids needing read on the UAMI resource)."
  default     = ""
}

variable "vm_size" {
  type        = string
  description = "VM size for SQL Server (recommended: Standard_D4s_v4 or larger for production)"
  default     = "Standard_D4s_v4"
  validation {
    condition     = can(regex("Standard_D[4-9].*|Standard_E[4-9].*", var.vm_size))
    error_message = "VM size must be at least D4s_v4 or E4s_v4 for SQL Server."
  }
}

variable "cluster_local_admin_username" {
  type        = string
  description = "Local user to create on both SQL VMs for workgroup WSFC administration"
  default     = "clusteradmin"
}

variable "dr_cluster_local_admin_username" {
  type        = string
  description = "Local user to create on DR SQL VMs for workgroup WSFC administration (defaults to cluster_local_admin_username if not set)"
  default     = ""
}

variable "witness_storage_security_control_tag_value" {
  type        = string
  description = "Value for the SecurityControl tag to bypass the org policy that disables Shared Key access on storage accounts"
  default     = "ignore"
}

# Storage configuration
variable "os_disk_type" {
  type        = string
  description = "OS disk storage type"
  default     = "Standard_LRS"
}

variable "os_disk_size_gb" {
  type        = number
  description = "OS disk size in GB"
  default     = 128
}

variable "data_disk_type" {
  type        = string
  description = "SQL data disk storage type (Standard_LRS for production)"
  default     = "Standard_LRS"
}

variable "data_disk_count" {
  type        = number
  description = "Number of data disks to attach"
  default     = 1
  validation {
    condition     = var.data_disk_count >= 1 && var.data_disk_count <= 8
    error_message = "Data disk count must be between 1 and 8."
  }
}

variable "data_disk_size_gb" {
  type        = number
  description = "Size of each data disk in GB"
  default     = 256
}

variable "log_disk_type" {
  type        = string
  description = "SQL log disk storage type (Standard_LRS recommended for production)"
  default     = "Standard_LRS"
}

variable "log_disk_size_gb" {
  type        = number
  description = "Size of log disk in GB"
  default     = 256
}

variable "tempdb_disk_type" {
  type        = string
  description = "SQL tempdb disk storage type (Standard_LRS recommended for production)"
  default     = "Standard_LRS"
}

variable "tempdb_disk_size_gb" {
  type        = number
  description = "Size of tempdb disk in GB"
  default     = 256
}

variable "backup_disk_type" {
  type        = string
  description = "Backup disk storage type"
  default     = "standard_LRS"
}

variable "backup_disk_size_gb" {
  type        = number
  description = "Backup disk size in GB"
  default     = 512
}

# SQL Server image configuration
variable "image_publisher" {
  type        = string
  description = "Image publisher for SQL Server"
  default     = "MicrosoftSQLServer"
}

variable "image_offer" {
  type        = string
  description = "Image offer (e.g., sql2022-ws2022 for SQL Server 2022 on Windows Server 2022)"
  default     = "sql2025-ws2022"
}

variable "image_sku" {
  type        = string
  description = "Image SKU (enterprise, standard, express, or web)"
  default     = "standard"
  validation {
    condition     = contains(["enterprise", "standard", "express", "web", "stddev-gen2", "standard-gen2", "enterprise-gen2"], var.image_sku)
    error_message = "Image SKU must be one of: enterprise, standard, express, web, stddev-gen2, standard-gen2, enterprise-gen2."
  }
}

variable "image_version" {
  type        = string
  description = "Image version"
  default     = "latest"
}

variable "enable_sql_extension" {
  type        = bool
  description = "Enable SQL Server IaaS Agent Extension for advanced SQL Server management"
  default     = true
}

variable "domain_name" {
  type        = string
  description = "Active Directory domain to join SQL VMs to"
  default     = "sqlpoc.local"
}

variable "domain_username" {
  type        = string
  description = "Domain admin username for domain join (will be used with domain_name)"
  sensitive   = true
  default     = "azureuser"
}

variable "domain_password" {
  type        = string
  description = "Domain admin password for domain join (fetched from Key Vault)"
  sensitive   = true
  default     = ""
}

variable "sql_server_iso_url" {
  type        = string
  description = "URL to SQL Server Developer Edition ISO (e.g., https://..../SQLServer2022-x64-ENU-Dev.iso)"
  sensitive   = true
  default     = ""
}

variable "sql_server_admin" {
  type        = string
  description = "SQL Server admin username"
  sensitive   = true
  default     = "sqlAdmin"
}

variable "tags" {
  type        = map(string)
  description = "Additional tags to apply to all resources"
  default     = {}
}

variable "enable_dr" {
  type        = bool
  description = "Enable Disaster Recovery deployment"
  default     = false
}

variable "dr_location" {
  type        = string
  description = "Azure region for DR"
  default     = "swedencentral"
}

variable "dr_sql_resource_group_name" {
  type        = string
  description = "Resource Group for DR SQL resources"
  default     = "rg-fnz-poc-sql-dr-swc"
}

# Used to configure DR node to talk to Primary Cluster
variable "primary_cluster_dns" {
  type        = string
  description = "DNS Name of the Primary Cluster (for DR setup)"
  default     = ""
}

variable "primary_cluster_ip" {
  type        = string
  description = "IP Address of the Primary Cluster Load Balancer (for DR setup)"
  default     = ""
}

variable "sql_name_prefix" {
  type        = string
  description = "Prefix used for naming SQL resources (VMs, LB, etc.). Defaults to 'sqlpoc'. Override for HA variants (e.g. 'sqlpoc-ha')."
  default     = "sqlpoc"
}

# Cluster configuration variables
variable "failover_cluster_name" {
  type        = string
  description = "Name of the SQL Server Failover Cluster"
  default     = "sqlpoc-cluster"
}
