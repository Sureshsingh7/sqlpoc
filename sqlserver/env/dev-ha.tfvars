# SQL Server Deployment - Development Environment Variables (HA Variant)
# This file is automatically loaded by Terraform (due to .auto.tfvars suffix) or explicitly via -var-file

# Azure context
subscription_id         = "51595cc9-4191-4785-a757-15e45165d2a4"
location                = "swedencentral"
sql_resource_group_name = "rg-fnz-poc-sql-se"

# Naming Prefix with 'ha'
sql_name_prefix = "poc-ha"

# SQL VM configuration (map of objects)
# Note: For HA deployment, define primary and secondary.
sql_vms = {
  "poc-ha-sql-01" = {
    private_ip        = "10.10.0.10"
    subnet_id         = "primary"
    availability_zone = "1"
    cluster_ip        = "10.10.0.12"
  },
  "poc-ha-sql-02" = {
    private_ip        = "10.10.0.11"
    subnet_id         = "primary"
    availability_zone = "2"
    cluster_ip        = "10.10.0.12"
  }
}

sql_admin_username = "sqladmin"

# VM sizing (default for all VMs, can be overridden per-VM in sql_vms)
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

manage_disk_setup_extension = true
enable_failover_cluster     = true

# Update Cluster Name for HA
failover_cluster_name = "sqlpoc-ha-cl"

# SQL Server image
image_publisher = "microsoftsqlserver"
image_offer     = "sql2022-ws2022"
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
  tier        = "database"
  ha_enabled  = "true"
}
