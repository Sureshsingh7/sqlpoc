# SQL Server Deployment - Development Environment Variables
# This file is automatically loaded by Terraform (due to .auto.tfvars suffix)

# Azure context
subscription_id         = "51595cc9-4191-4785-a757-15e45165d2a4"
location                = "swedencentral"
sql_resource_group_name = "rg-fnz-poc-mirror-env-sql-se"

# SQL VM configuration
sql_vm_names       = ["sql-mirror-primary", "sql-mirror-secondary"]
sql_private_ips    = ["10.10.0.10", "10.10.0.74"]
sql_admin_username = "sqladmin"

# VM sizing
vm_size = "Standard_D4s_v4"

# Storage configuration
os_disk_type    = "Premium_LRS"
os_disk_size_gb = 128

data_disk_type    = "Premium_LRS"
data_disk_count   = 1
data_disk_size_gb = 256

log_disk_type    = "Premium_LRS"
log_disk_size_gb = 256

tempdb_disk_type    = "Premium_LRS"
tempdb_disk_size_gb = 256

backup_disk_type    = "Standard_LRS"
backup_disk_size_gb = 256

# SQL Server image
image_publisher = "microsoftsqlserver"
image_offer     = "sql2025-ws2025"
image_sku       = "standard-gen2"
image_version   = "latest"

# Extensions
enable_sql_extension = true

# Tags
tags = {
  environment = "dev"
  project     = "SQLPOC"
  managed_by  = "terraform"
}
