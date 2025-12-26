variable "subscription_id" {
  type        = string
  description = "Azure Subscription ID"
}

# variable "location" {
#   type        = string
#   description = "Azure region for SQL VM deployment"
# }

# variable "sql_resource_group_name" {
#   type        = string
#   description = "Resource group name where SQL VMs will be deployed"
# }

variable "sql_vm_names" {
  type        = list(string)
  description = "Names of SQL Server VMs to deploy"
  default     = ["sql-primary", "sql-secondary"]
  validation {
    condition     = alltrue([for name in var.sql_vm_names : length(name) > 0 && length(name) <= 15])
    error_message = "Each VM name must be between 1 and 15 characters."
  }
}

# variable "sql_private_ips" {
#   type        = list(string)
#   description = "Static private IP addresses for SQL VMs (must be in sql1 subnet range)"
#   default     = ["10.0.2.10", "10.0.2.11"]
#   validation {
#     condition     = length(var.sql_private_ips) >= 1
#     error_message = "At least one private IP address must be provided."
#   }
# }

# variable "sql_admin_username" {
#   type        = string
#   description = "Admin username for SQL VMs (cannot be 'Administrator', 'admin', or 'root')"
#   sensitive   = true
#   validation {
#     condition     = !contains(["administrator", "admin", "root"], lower(var.sql_admin_username))
#     error_message = "Admin username cannot be 'Administrator', 'admin', or 'root'."
#   }
# }

# variable "vm_size" {
#   type        = string
#   description = "VM size for SQL Server (recommended: Standard_D4s_v4 or larger for production)"
#   default     = "Standard_D4s_v4"
#   validation {
#     condition     = can(regex("Standard_D[4-9].*|Standard_E[4-9].*", var.vm_size))
#     error_message = "VM size must be at least D4s_v4 or E4s_v4 for SQL Server."
#   }
# }

# # Storage configuration
# variable "os_disk_type" {
#   type        = string
#   description = "OS disk storage type"
#   default     = "Premium_LRS"
# }

# variable "os_disk_size_gb" {
#   type        = number
#   description = "OS disk size in GB"
#   default     = 128
# }

# variable "data_disk_type" {
#   type        = string
#   description = "SQL data disk storage type (Premium_LRS for production)"
#   default     = "Premium_LRS"
# }

# variable "data_disk_count" {
#   type        = number
#   description = "Number of data disks to attach"
#   default     = 2
#   validation {
#     condition     = var.data_disk_count >= 1 && var.data_disk_count <= 8
#     error_message = "Data disk count must be between 1 and 8."
#   }
# }

# variable "data_disk_size_gb" {
#   type        = number
#   description = "Size of each data disk in GB"
#   default     = 256
# }

# variable "backup_disk_type" {
#   type        = string
#   description = "Backup disk storage type"
#   default     = "Premium_LRS"
# }

# variable "backup_disk_size_gb" {
#   type        = number
#   description = "Backup disk size in GB"
#   default     = 512
# }

# # SQL Server image configuration
# variable "image_publisher" {
#   type        = string
#   description = "Image publisher for SQL Server"
#   default     = "MicrosoftSQLServer"
# }

# variable "image_offer" {
#   type        = string
#   description = "Image offer (e.g., sql2022-ws2022 for SQL Server 2022 on Windows Server 2022)"
#   default     = "sql2022-ws2022"
# }

# variable "image_sku" {
#   type        = string
#   description = "Image SKU (enterprise, standard, express, or web)"
#   default     = "enterprise"
#   validation {
#     condition     = contains(["enterprise", "standard", "express", "web"], var.image_sku)
#     error_message = "Image SKU must be one of: enterprise, standard, express, or web."
#   }
# }

# variable "image_version" {
#   type        = string
#   description = "Image version"
#   default     = "latest"
# }

# variable "enable_sql_extension" {
#   type        = bool
#   description = "Enable SQL Server IaaS Agent Extension for advanced SQL Server management"
#   default     = true
# }

variable "tags" {
  type        = map(string)
  description = "Additional tags to apply to all resources"
  default     = {}
}
