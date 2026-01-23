# SQL Server Deployment - Development Environment Variables
# This file is automatically loaded by Terraform (due to .auto.tfvars suffix)

# Azure context
subscription_id         = "51595cc9-4191-4785-a757-15e45165d2a4"
location                = "swedencentral"
sql_resource_group_name = "rg-fnz-poc-sql-se"

# SQL VM configuration
sql_vm_names       = ["sql-primary", "sql-secondary"]
sql_private_ips    = ["10.10.0.10", "10.10.0.74"]
cluster_ips        = ["10.10.0.11", "10.10.0.75"]
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

backup_disk_type    = "Premium_LRS"
backup_disk_size_gb = 512

manage_disk_setup_extension = false

# SQL Server image
image_publisher = "microsoftsqlserver"
image_offer     = "sql2025-ws2025"
image_sku       = "enterprise-gen2"
image_version   = "latest"

# Extensions
enable_sql_extension = true

# Keep the built-in UAMI attached to SQL VMs
sql_vm_user_assigned_identity_ids = [
  "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/Built-In-Identity-RG/providers/Microsoft.ManagedIdentity/userAssignedIdentities/Built-In-Identity-swedencentral"
]
sql_vm_user_assigned_identity_client_id = ""

# Tags
tags = {
  environment = "dev"
  project     = "SQLPOC"
  managed_by  = "terraform"
}
