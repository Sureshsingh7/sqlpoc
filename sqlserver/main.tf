# Generate random passwords for SQL VM admin accounts
resource "random_password" "sql_vm" {
  count   = length(var.sql_vm_names)
  length  = 32
  special = true
}

# Store SQL VM admin passwords in Key Vault
resource "azurerm_key_vault_secret" "sql_vm_admin_password" {
  count        = length(var.sql_vm_names)
  name         = "${var.sql_vm_names[count.index]}-local-admin"
  value        = random_password.sql_vm[count.index].result
  key_vault_id = data.terraform_remote_state.ops.outputs.ops_key_vault_id

  content_type = "SQL Server VM local admin password"
}

# Locals for naming and organization
locals {
  sql_vm_count = length(var.sql_vm_names)
  tags = merge(
    {
      "project"   = "SQLPOC"
      "component" = "SQLServerVM"
      "tier"      = "Database"
    },
  )

  # Disk configuration for SQL Server
  disks_per_vm = [
    { name_suffix = "data-01", disk_size_gb = var.data_disk_size_gb, storage_type = var.data_disk_type, lun = 0 },
    { name_suffix = "log-01", disk_size_gb = var.log_disk_size_gb, storage_type = var.log_disk_type, lun = 1 },
    { name_suffix = "tempdb-01", disk_size_gb = var.tempdb_disk_size_gb, storage_type = var.tempdb_disk_type, lun = 2 }
  ]

  # Flatten to create all disks across all VMs
  all_disks = flatten([
    for vm_idx in range(local.sql_vm_count) : [
      for disk in local.disks_per_vm : {
        key          = "${var.sql_vm_names[vm_idx]}-${disk.name_suffix}"
        vm_index     = vm_idx
        name         = "${var.sql_vm_names[vm_idx]}-${disk.name_suffix}"
        disk_size_gb = disk.disk_size_gb
        storage_type = disk.storage_type
        lun          = disk.lun
      }
    ]
  ])

  all_disks_map = { for disk in local.all_disks : disk.key => disk }
}

# Network interfaces for SQL VMs
resource "azurerm_network_interface" "sql_vm" {
  count                          = local.sql_vm_count
  name                           = count.index == 0 ? "sqlpoc-nic-sql-primary" : "sqlpoc-nic-sql-secondary"
  location                       = var.location
  resource_group_name            = var.sql_resource_group_name
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = count.index == 0 ? data.terraform_remote_state.network.outputs.sql_subnet_sql1_id : data.terraform_remote_state.network.outputs.sql_subnet_sql2_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.sql_private_ips[count.index]
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
  zone                = var.availability_zones[count.index % length(var.availability_zones)]

  admin_username = var.sql_admin_username
  admin_password = random_password.sql_vm[count.index].result

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

  tags = local.tags

  lifecycle {
    ignore_changes = [
      os_disk[0].name,
      admin_password
    ]
  }

  depends_on = [azurerm_network_interface.sql_vm]
}

# Create data disks for SQL Server
resource "azurerm_managed_disk" "sql_disk" {
  for_each             = local.all_disks_map
  name                 = each.value.name
  location             = var.location
  resource_group_name  = var.sql_resource_group_name
  storage_account_type = each.value.storage_type
  create_option        = "Empty"
  disk_size_gb         = each.value.disk_size_gb
  zone                 = var.availability_zones[each.value.vm_index % length(var.availability_zones)]

  tags = local.tags
}

# Attach data disks to SQL Server VMs
resource "azurerm_virtual_machine_data_disk_attachment" "sql_disk_attach" {
  for_each           = local.all_disks_map
  managed_disk_id    = azurerm_managed_disk.sql_disk[each.key].id
  virtual_machine_id = azurerm_windows_virtual_machine.sql_vm[each.value.vm_index].id
  lun                = each.value.lun
  caching            = "ReadOnly"
}

# Custom script to format and configure disks
resource "azurerm_virtual_machine_extension" "sql_disk_setup" {
  count                      = local.sql_vm_count
  name                       = "configure-sql-disks"
  virtual_machine_id         = azurerm_windows_virtual_machine.sql_vm[count.index].id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    commandToExecute = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"$ErrorActionPreference='Stop'; $log='C:\\Windows\\Temp\\configure-sql-disks.log'; $err='C:\\Windows\\Temp\\configure-sql-disks.err.txt'; Start-Transcript -Path 'C:\\Windows\\Temp\\configure-sql-disks.transcript.txt' -Force | Out-Null; try { function Ensure-Drive([int]$diskNumber,[string]$letter,[string]$label){ $disk=Get-Disk -Number $diskNumber; $existingVol=Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue; if($existingVol -and $existingVol.DriveType -ne 'CD-ROM'){ $parts=Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue; if(-not $parts -or $parts[0].DiskNumber -ne $diskNumber){ throw \"Drive letter $letter already in use by another disk\" } }; if($disk.PartitionStyle -eq 'RAW'){ Initialize-Disk -Number $diskNumber -PartitionStyle GPT -PassThru | Out-Null; $p=New-Partition -DiskNumber $diskNumber -UseMaximumSize -AssignDriveLetter:$false; Set-Partition -DiskNumber $diskNumber -PartitionNumber $p.PartitionNumber -NewDriveLetter $letter | Out-Null; Format-Volume -DriveLetter $letter -FileSystem NTFS -NewFileSystemLabel $label -Confirm:`$false -Force | Out-Null } else { $parts=Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue; $usable=@(); foreach($pp in $parts){ if($pp.Type -ne 'Reserved'){ $usable += $pp } }; $usable = Sort-Object -InputObject $usable -Property Size -Descending; if($usable.Count -lt 1){ throw \"No usable partition found on disk $diskNumber\" }; $p=$usable[0]; if($p.DriveLetter -ne $letter){ Set-Partition -DiskNumber $diskNumber -PartitionNumber $p.PartitionNumber -NewDriveLetter $letter | Out-Null } } }; $map=@{0='F';1='G';2='T'}; $labelMap=@{0='DATA';1='LOG';2='TEMPDB'}; $osNums=@(); foreach($d in (Get-Disk)){ if($d.IsBoot -or $d.IsSystem){ $osNums += [int]$d.Number } }; $drives=Get-CimInstance Win32_DiskDrive; $candidates=@(); foreach($dd in $drives){ $idx=[int]$dd.Index; if($osNums -contains $idx){ continue }; $lun=$dd.SCSILogicalUnit; if($lun -eq $null){ continue }; $candidates += [pscustomobject]@{ Number=$idx; Lun=[int]$lun; Model=$dd.Model; Size=$dd.Size } }; $candidates = Sort-Object -InputObject $candidates -Property Lun,Number; $out = ($candidates | Format-Table -AutoSize | Out-String); $out | Out-File -FilePath $log -Append; for($r=0; $r -lt 30; $r++){ $countWanted=0; foreach($row in $candidates){ if($row.Lun -eq 0 -or $row.Lun -eq 1 -or $row.Lun -eq 2){ $countWanted++ } }; if($countWanted -ge 3){ break }; Start-Sleep -Seconds 10; $drives=Get-CimInstance Win32_DiskDrive; $candidates=@(); foreach($dd in $drives){ $idx=[int]$dd.Index; if($osNums -contains $idx){ continue }; $lun=$dd.SCSILogicalUnit; if($lun -eq $null){ continue }; $candidates += [pscustomobject]@{ Number=$idx; Lun=[int]$lun; Model=$dd.Model; Size=$dd.Size } }; $candidates = Sort-Object -InputObject $candidates -Property Lun,Number }; foreach($lun in 0,1,2){ $row=$null; foreach($c in $candidates){ if($c.Lun -eq $lun){ $row=$c; break } }; if($null -eq $row){ break }; Ensure-Drive $row.Number $map[$lun] $labelMap[$lun] }; if(-not (Test-Path 'F:\\') -or -not (Test-Path 'G:\\') -or -not (Test-Path 'T:\\')){ $fallback=Sort-Object -InputObject (Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem }) -Property Number; if($fallback.Count -ge 3){ Ensure-Drive $fallback[0].Number 'F' 'DATA'; Ensure-Drive $fallback[1].Number 'G' 'LOG'; Ensure-Drive $fallback[2].Number 'T' 'TEMPDB' } else { throw \"Not enough data disks detected (need 3).\" } }; foreach($p in @('F:\\Data','G:\\Log','T:\\TempDB')){ if(Test-Path ($p.Substring(0,3))){ New-Item -ItemType Directory -Path $p -Force | Out-Null } }; \"OK $(Get-Date -Format o)\" | Out-File -FilePath $log -Append; Stop-Transcript | Out-Null; exit 0 } catch { $_ | Out-String | Out-File -FilePath $err -Append; try { Stop-Transcript | Out-Null } catch {}; exit 1 }\""
  })

  depends_on = [azurerm_virtual_machine_data_disk_attachment.sql_disk_attach]
}

# SQL IaaS Agent Extension - SQL Server configuration only (no storage config)
resource "azurerm_mssql_virtual_machine" "sql_vm" {
  count                            = local.sql_vm_count
  virtual_machine_id               = azurerm_windows_virtual_machine.sql_vm[count.index].id
  sql_license_type                 = "PAYG"
  sql_connectivity_port            = 1433
  sql_connectivity_type            = "PRIVATE"
  sql_connectivity_update_password = random_password.sql_vm[count.index].result
  sql_connectivity_update_username = var.sql_admin_username

  # SQL Server instance configuration
  sql_instance {
    collation                            = "SQL_Latin1_General_CP1_CI_AS"
    max_dop                              = 0
    min_server_memory_mb                 = 0
    max_server_memory_mb                 = 12288  # 12GB for D4s_v4 (16GB RAM), leaves 4GB for OS
    adhoc_workloads_optimization_enabled = true
    instant_file_initialization_enabled  = true
  }

  # Automated patching configuration
  auto_patching {
    day_of_week                            = "Sunday"
    maintenance_window_duration_in_minutes = 60
    maintenance_window_starting_hour       = 2
  }

  tags = local.tags

  timeouts {
    create = "30m"
    update = "30m"
  }

  depends_on = [
    azurerm_windows_virtual_machine.sql_vm,
    azurerm_virtual_machine_extension.sql_disk_setup
  ]
}

# Future: Failover Clustering Configuration
# Uncomment and configure once VMs are domain-joined and basic SQL setup is complete

# resource "azurerm_virtual_machine_extension" "sql_cluster_setup" {
#   count                      = local.sql_vm_count
#   name                       = "sql-cluster-setup-${count.index + 1}"
#   virtual_machine_id         = azurerm_windows_virtual_machine.sql_vm[count.index].id
#   publisher                  = "Microsoft.Compute"
#   type                       = "CustomScriptExtension"
#   type_handler_version       = "1.10"
#   auto_upgrade_minor_version = true
#
#   protected_settings = jsonencode({
#     commandToExecute = "powershell -Command \"$ErrorActionPreference='Stop'; Write-Host 'Installing WSFC...'; Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools; if ('${var.sql_vm_names[count.index]}' -eq '${var.sql_vm_names[0]}') { Write-Host 'Primary node: Creating failover cluster...'; Start-Sleep -Seconds 120; New-Cluster -Name sqlpoc-cluster -Node '${var.sql_vm_names[0]}','${var.sql_vm_names[1]}' -StaticAddress 10.10.0.20 -NoStorage -Force }; Write-Host 'Cluster setup complete'\""
#   })
#
#   depends_on = [azurerm_mssql_virtual_machine.sql_vm]
# }
