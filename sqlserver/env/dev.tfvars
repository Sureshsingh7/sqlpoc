# SQL Server Deployment - Development Environment Variables
# This file is automatically loaded by Terraform (due to .auto.tfvars suffix)

# Azure context
subscription_id         = "51595cc9-4191-4785-a757-15e45165d2a4"
location                = "swedencentral"
sql_resource_group_name = "rg-fnz-poc-sql-se"

# SQL VM configuration
sql_vm_names       = ["sql-primary", "sql-secondary"]
sql_private_ips    = ["10.0.2.10", "10.0.2.11"]
sql_admin_username = "sqladmin"

# VM sizing
vm_size = "Standard_D4s_v4"

# Storage configuration
os_disk_type    = "Premium_LRS"
os_disk_size_gb = 128

data_disk_type    = "Premium_LRS"
data_disk_count   = 2
data_disk_size_gb = 256

backup_disk_type    = "Premium_LRS"
backup_disk_size_gb = 512

# SQL Server image
image_publisher = "MicrosoftSQLServer"
image_offer     = "sql2022-ws2022"
image_sku       = "enterprise"
image_version   = "latest"

# Extensions
enable_sql_extension = true

# Tags
tags = {
  environment = "dev"
  project     = "SQLPOC"
  managed_by  = "terraform"
}
