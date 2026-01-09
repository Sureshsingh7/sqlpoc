
# Generate single password for both SQL VM admin accounts
resource "random_password" "sql_vm_admin" {
  length  = 32
  special = true
}

# Store SQL VM admin password in Key Vault
resource "azurerm_key_vault_secret" "sql_vm_admin_password" {
  name         = "sql-vm-admin-password"
  value        = random_password.sql_vm_admin.result
  key_vault_id = data.terraform_remote_state.ops.outputs.ops_key_vault_id

  content_type = "SQL Server VM local admin password (shared for primary and secondary)"
}

# Locals for naming and organization
locals {
  sql_vm_count = length(var.sql_vm_names)

  # Extract subnet prefix lengths from CIDR notation (e.g., "10.10.0.0/26" → 26)
  sql1_prefix_length = tonumber(split("/", data.terraform_remote_state.network.outputs.sql_subnet_sql1_address_prefix)[1])
  sql2_prefix_length = tonumber(split("/", data.terraform_remote_state.network.outputs.sql_subnet_sql2_address_prefix)[1])

  # Calculate maximum usable host index for each subnet
  # Max hosts = 2^(32 - prefix_length) - 1, minus 4 reserved by Azure (.0, .1, .2, .3)
  sql1_max_usable_index = pow(2, 32 - local.sql1_prefix_length) - 5
  sql2_max_usable_index = pow(2, 32 - local.sql2_prefix_length) - 5

  # Dynamically calculate host indices based on subnet size
  # VM indices: 15% into usable range (ensures consistency across different subnet sizes)
  # Cluster indices: 30% and 45% into usable range
  primary_vm_host_index        = max(10, floor(local.sql1_max_usable_index * 0.15))
  secondary_vm_host_index      = max(10, floor(local.sql2_max_usable_index * 0.15))
  cluster_primary_host_index   = max(20, floor(local.sql1_max_usable_index * 0.30))
  cluster_secondary_host_index = max(20, floor(local.sql2_max_usable_index * 0.45))

  # Dynamically calculate VM IPs from subnet CIDR blocks
  primary_vm_ip   = cidrhost(data.terraform_remote_state.network.outputs.sql_subnet_sql1_address_prefix, local.primary_vm_host_index)
  secondary_vm_ip = cidrhost(data.terraform_remote_state.network.outputs.sql_subnet_sql2_address_prefix, local.secondary_vm_host_index)

  # Dynamically calculate Cluster VIPs from subnet CIDR blocks
  cluster_primary_ip   = cidrhost(data.terraform_remote_state.network.outputs.sql_subnet_sql1_address_prefix, local.cluster_primary_host_index)
  cluster_secondary_ip = cidrhost(data.terraform_remote_state.network.outputs.sql_subnet_sql2_address_prefix, local.cluster_secondary_host_index)

  tags = merge(
    {
      "project"   = "SQLPOC"
      "component" = "SQLServerVM"
      "tier"      = "Database"
    },

  )

  # Define all disk types and their configurations
  disk_types = {
    data = {
      disk_count   = var.data_disk_count
      storage_type = var.data_disk_type
      disk_size_gb = var.data_disk_size_gb
      lun_base     = 0
      name_suffix  = "datadisk"
    }
    log = {
      disk_count   = 1
      storage_type = var.log_disk_type
      disk_size_gb = var.log_disk_size_gb
      lun_base     = var.data_disk_count
      name_suffix  = "logdisk"
    }
    tempdb = {
      disk_count   = 1
      storage_type = var.tempdb_disk_type
      disk_size_gb = var.tempdb_disk_size_gb
      lun_base     = var.data_disk_count + 1
      name_suffix  = "tempdbdisk"
    }
  }

  # Create a flat list of all disks to be created
  # Format: "${vm_index}-${disk_type}-${disk_index}"
  all_disks = flatten([
    for vm_idx in range(local.sql_vm_count) : [
      for disk_type, disk_config in local.disk_types : [
        for disk_idx in range(disk_config.disk_count) : {
          key          = "${vm_idx}-${disk_type}-${disk_idx}"
          vm_index     = vm_idx
          disk_type    = disk_type
          disk_index   = disk_idx
          storage_type = disk_config.storage_type
          disk_size_gb = disk_config.disk_size_gb
          lun          = disk_config.lun_base + disk_idx
          name_suffix  = disk_config.name_suffix
        }
      ]
    ]
  ])

  # Convert to map for easy iteration with for_each
  all_disks_map = {
    for disk in local.all_disks : disk.key => disk
  }
}

# Network interfaces for SQL VMs
resource "azurerm_network_interface" "sql_vm" {
  count               = local.sql_vm_count
  name                = count.index == 0 ? "sqlpoc-nic-sql-primary" : "sqlpoc-nic-sql-secondary"
  location            = var.location
  resource_group_name = var.sql_resource_group_name
  # dns_servers                    = dBata.terraform_remote_state.dc.outputs.dc_nic_private_ips
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = count.index == 0 ? data.terraform_remote_state.network.outputs.sql_subnet_sql1_id : data.terraform_remote_state.network.outputs.sql_subnet_sql2_id
    private_ip_address_allocation = "Static"
    private_ip_address            = count.index == 0 ? local.primary_vm_ip : local.secondary_vm_ip
  }

  tags = local.tags
}

# SQL Server VMs
resource "azurerm_windows_virtual_machine" "sql_vm" {
  count               = local.sql_vm_count
  name                = var.sql_vm_names[count.index]
  location            = var.location
  resource_group_name = var.sql_resource_group_name
  size                = var.vm_size
  zone                = var.availability_zones[floor(count.index / var.data_disk_count) % length(var.availability_zones)]

  admin_username = var.sql_admin_username
  admin_password = random_password.sql_vm_admin.result

  network_interface_ids = [
    azurerm_network_interface.sql_vm[count.index].id
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }

  identity {
    type = "SystemAssigned"
  }

  provisioner "local-exec" {
    when    = create
    command = "az vm run-command invoke --resource-group ${var.sql_resource_group_name} --name ${var.sql_vm_names[count.index]} --command-id RunPowerShellScript --scripts 'if (-not (Select-String -Path C:\\\\Windows\\\\System32\\\\drivers\\\\etc\\\\hosts -Pattern ${var.sql_vm_names[0]} -Quiet)) { Add-Content -Path C:\\\\Windows\\\\System32\\\\drivers\\\\etc\\\\hosts -Value \"${local.primary_vm_ip} `t${var.sql_vm_names[0]}.sqlpoc.local `t${var.sql_vm_names[0]}\" }; if (-not (Select-String -Path C:\\\\Windows\\\\System32\\\\drivers\\\\etc\\\\hosts -Pattern ${var.sql_vm_names[1]} -Quiet)) { Add-Content -Path C:\\\\Windows\\\\System32\\\\drivers\\\\etc\\\\hosts -Value \"${local.secondary_vm_ip} `t${var.sql_vm_names[1]}.sqlpoc.local `t${var.sql_vm_names[1]}\" }; Set-ItemProperty -Path \"HKLM:\\\\SYSTEM\\\\CurrentControlSet\\\\services\\\\Tcpip\\\\Parameters\" -Name \"NV Domain\" -Value \"sqlpoc.local\" -Force; New-ItemProperty -Path \"HKLM:\\\\SOFTWARE\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Policies\\\\System\" -Name \"LocalAccountTokenFilterPolicy\" -Value 1 -PropertyType DWord -Force; Write-Host \"Enabling ICMP in Windows Firewall...\"; netsh advfirewall firewall add rule name=\"Allow ICMPv4\" protocol=icmpv4 dir=in action=allow; Write-Host \"ICMP enabled successfully\"; Write-Host \"Installing Failover Clustering...\"; Import-Module ServerManager; Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools -Restart; Write-Host \"Failover Clustering installed successfully\"'"
  }
  tags = local.tags

  lifecycle {
    ignore_changes = [
      os_disk[0].name,
      admin_password
    ]
  }

  depends_on = [
    azurerm_network_interface.sql_vm,
    azurerm_key_vault_secret.sql_vm_admin_password
  ]
}

# SQL Server disks - unified resource for all disk types (data, log, tempdb)
resource "azurerm_managed_disk" "sql_disk" {
  for_each             = local.all_disks_map
  name                 = each.value.disk_type == "data" ? "${var.sql_vm_names[each.value.vm_index]}-${each.value.name_suffix}-${each.value.disk_index + 1}" : "${var.sql_vm_names[each.value.vm_index]}-${each.value.name_suffix}"
  location             = var.location
  resource_group_name  = var.sql_resource_group_name
  storage_account_type = each.value.storage_type
  create_option        = "Empty"
  disk_size_gb         = each.value.disk_size_gb
  zone                 = var.availability_zones[each.value.vm_index % length(var.availability_zones)]

  tags = local.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "sql_disk_attach" {
  for_each           = local.all_disks_map
  managed_disk_id    = azurerm_managed_disk.sql_disk[each.key].id
  virtual_machine_id = azurerm_windows_virtual_machine.sql_vm[each.value.vm_index].id
  lun                = each.value.lun
  caching            = "ReadOnly"
}

# Null resource to trigger failover cluster creation via local-exec provisioner
resource "null_resource" "sql_failover_cluster" {
  triggers = {
    cluster_name    = var.failover_cluster_name
    primary_node    = "${var.sql_vm_names[0]}"
    secondary_node  = "${var.sql_vm_names[1]}"
    cluster_ip_1    = local.cluster_primary_ip
    cluster_ip_2    = local.cluster_secondary_ip
    primary_vm_id   = azurerm_windows_virtual_machine.sql_vm[0].id
    secondary_vm_id = azurerm_windows_virtual_machine.sql_vm[1].id
  }

  provisioner "local-exec" {
    when    = create
    command = "az vm run-command invoke --resource-group ${var.sql_resource_group_name} --name ${var.sql_vm_names[0]} --command-id RunPowerShellScript --scripts 'Write-Host \"Waiting for secondary node to be ready...\"; Start-Sleep -Seconds 120; Write-Host \"Checking if failover cluster already exists...\"; $clusterExists = $null; try { $clusterExists = Get-Cluster -Name ${self.triggers.cluster_name} -ErrorAction Stop; } catch { Write-Host \"Cluster does not exist, will create it now...\"; }; if ($clusterExists) { Write-Host \"Failover cluster ${self.triggers.cluster_name} already exists. Skipping cluster creation.\"; } else { Write-Host \"Creating failover cluster...\"; New-Cluster -Name ${self.triggers.cluster_name} -Node ${self.triggers.primary_node}, ${self.triggers.secondary_node} -AdministrativeAccessPoint DNS -StaticAddress ${self.triggers.cluster_ip_1}, ${self.triggers.cluster_ip_2} -Force -WarningAction SilentlyContinue; Write-Host \"Failover cluster created successfully\"; }'"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "Write-Host \"Cluster resources will be retained. To remove, manually delete the cluster from the primary node.\""
  }

  depends_on = [
    azurerm_virtual_machine_data_disk_attachment.sql_disk_attach,
    azurerm_windows_virtual_machine.sql_vm
  ]
}

# Extension 1: Run common setup on both VMs (commented out - scripts not yet created)
# resource "azurerm_virtual_machine_extension" "sql_setup" {
#   count                      = local.sql_vm_count
#   name                       = "sql-setup-${count.index + 1}"
#   virtual_machine_id         = azurerm_windows_virtual_machine.sql_vm[count.index].id
#   publisher                  = "Microsoft.Compute"
#   type                       = "CustomScriptExtension"
#   type_handler_version       = "1.10"
#   auto_upgrade_minor_version = true

#   protected_settings = jsonencode({
#     commandToExecute = "powershell -ExecutionPolicy Unrestricted -File C:/scripts/setup-vm-${count.index}.ps1"
#   })

#   depends_on = [azurerm_virtual_machine_data_disk_attachment.sql_disk_attach]
# }

# Install Failover Clustering on SQL VMs and create cluster on primary
# resource "azurerm_virtual_machine_extension" "sql_setup" {
#   count                      = local.sql_vm_count
#   name                       = "sql-setup-${count.index + 1}"
#   virtual_machine_id         = azurerm_windows_virtual_machine.sql_vm[count.index].id
#   publisher                  = "Microsoft.Compute"
#   type                       = "CustomScriptExtension"
#   type_handler_version       = "1.10"
#   auto_upgrade_minor_version = true

#   protected_settings = jsonencode({
#     commandToExecute = "powershell -Command \"$ErrorActionPreference='Stop'; $dcPassword='${data.azurerm_key_vault_secret.dc_admin_password.value}'; Write-Host 'Checking domain membership...'; if ((Get-WmiObject -Class Win32_ComputerSystem).PartOfDomain -eq $false) { Write-Host 'Joining domain...'; Add-Computer -DomainName 'sqlpoc.local' -Credential (New-Object System.Management.Automation.PSCredential('sqlpoc\\\\azureuser', (ConvertTo-SecureString $dcPassword -AsPlainText -Force))) -Restart -Force } else { Write-Host 'Already domain-joined' }; Start-Sleep -Seconds 30; Write-Host 'Adding domain admin to local admins...'; Add-LocalGroupMember -Group 'Administrators' -Member 'sqlpoc\\\\azureuser' -ErrorAction SilentlyContinue; Write-Host 'Installing WSFC...'; Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools -Restart; if ('${var.sql_vm_names[count.index]}' -eq '${var.sql_vm_names[0]}') { Write-Host 'Primary node: Waiting for secondary node to be ready...'; Start-Sleep -Seconds 120; Write-Host 'Creating failover cluster...'; New-Cluster -Name sqlpoc-cluster -Node '${var.sql_vm_names[0]}.sqlpoc.local','${var.sql_vm_names[1]}.sqlpoc.local' -StaticAddress 10.10.0.20 -NoStorage -Force -WarningAction SilentlyContinue; Write-Host 'Running cluster validation...'; Test-Cluster -Node '${var.sql_vm_names[0]}.sqlpoc.local','${var.sql_vm_names[1]}.sqlpoc.local' -ReportName 'C:\\\\ClusterValidationReport.htm' -WarningAction SilentlyContinue; Write-Host 'Cluster creation complete' }; Write-Host 'Setup complete'\""
#   })

#   depends_on = [azurerm_virtual_machine_data_disk_attachment.sql_data_disk_attach]
# }

# Install SQL Server Developer Edition and Configuration Manager
# resource "azurerm_virtual_machine_extension" "sql_server_install" {
#   count                      = local.sql_vm_count
#   name                       = "install-sql-dev-${count.index + 1}"
#   virtual_machine_id         = azurerm_windows_virtual_machine.sql_vm[count.index].id
#   publisher                  = "Microsoft.Compute"
#   type                       = "CustomScriptExtension"
#   type_handler_version       = "1.10"
#   auto_upgrade_minor_version = true

#   protected_settings = jsonencode({
#     commandToExecute = "powershell -Command \"$ErrorActionPreference='Stop'; Write-Host 'Installing SQL Server Developer Edition...'; $sqlpath='C:\\SQLServerMedia'; New-Item -ItemType Directory -Path $sqlpath -Force | Out-Null; $sqliso='${var.sql_server_iso_url}'; if($sqliso) { Write-Host 'Downloading SQL Server ISO...'; Import-Module BitsTransfer; Start-BitsTransfer -Source $sqliso -Destination $sqlpath\\\\sql.iso; $mount = Mount-DiskImage -ImagePath $sqlpath\\\\sql.iso -PassThru; $drive = ($mount | Get-Volume).DriveLetter; Start-Process -FilePath ($drive+':\\\\setup.exe') -ArgumentList '/Q /ACTION=Install /INSTANCENAME=MSSQLSERVER /FEATURES=SQL,Tools /SQLSYSADMINACCOUNTS=\\\"${var.domain_name}\\\\${var.sql_server_admin}\\\" /AGTSVCACCOUNT=\\\"${var.domain_name}\\\\${var.sql_server_admin}\\\" /AGTSVCPASSWORD=\\\"${var.sql_server_admin_password}\\\" /SQLSVCACCOUNT=\\\"${var.domain_name}\\\\${var.sql_server_admin}\\\" /SQLSVCPASSWORD=\\\"${var.sql_server_admin_password}\\\" /IACCEPTSQLSERVERLICENSETERMS' -Wait -PassThru; Dismount-DiskImage -ImagePath $sqlpath\\\\sql.iso; Write-Host 'SQL Server installation completed'; } else { Write-Host 'SQL Server ISO URL not provided'; exit 1 }; Write-Host 'SQL Server Developer Edition and Configuration Manager installed successfully'\""
#   })

#   depends_on = [azurerm_virtual_machine_extension.sql_domain_join]
# }