# Cluster creation via az vm run-command with sqladmin credentials
# This runs independently after VMs and disks are ready
# Execute with: terraform apply -target=null_resource.sql_cluster_creation

resource "null_resource" "sql_cluster_creation" {
  triggers = {
    primary_vm_id   = azurerm_windows_virtual_machine.sql_vm[0].id
    secondary_vm_id = azurerm_windows_virtual_machine.sql_vm[1].id
    password_hash   = random_password.sql_vm_admin.result
  }

  provisioner "local-exec" {
    command = "az vm run-command invoke --resource-group ${var.sql_resource_group_name} --name ${var.sql_vm_names[0]} --command-id RunPowerShellScript --scripts '$secPassword = ConvertTo-SecureString \"${random_password.sql_vm_admin.result}\" -AsPlainText -Force; $cred = New-Object System.Management.Automation.PSCredential(\"${var.sql_admin_username}\", $secPassword); $scriptBlock = { Write-Host \"Waiting for secondary node initialization...\" -ForegroundColor Yellow; Start-Sleep -Seconds 60; Write-Host \"Creating failover cluster: sqlpoc-cluster\" -ForegroundColor Yellow; New-Cluster -Name sqlpoc-cluster -Node \"${var.sql_vm_names[0]}\",\"${var.sql_vm_names[1]}\" -AdministrativeAccessPoint DNS -StaticAddress \"${local.cluster_primary_ip}\",\"${local.cluster_secondary_ip}\" -NoStorage -Force -WarningAction SilentlyContinue | Out-Null; Write-Host \"Failover cluster created successfully\" -ForegroundColor Green; Write-Host \"Validating cluster configuration...\" -ForegroundColor Yellow; Test-Cluster -Node \"${var.sql_vm_names[0]}\",\"${var.sql_vm_names[1]}\" -ReportName \"C:\\ClusterValidationReport.htm\" -WarningAction SilentlyContinue | Out-Null; Write-Host \"Cluster validation completed\" -ForegroundColor Green; Get-Cluster | Format-List Name, @{Name=\"Status\"; Expression={$_.Status}}; Get-ClusterNode | Format-Table Name, Status }; Invoke-Command -ScriptBlock $scriptBlock -Credential $cred'"
  }

  depends_on = [
    azurerm_windows_virtual_machine.sql_vm,
    azurerm_virtual_machine_extension.sql_disk_setup,
    azurerm_mssql_virtual_machine.sql_vm
  ]
}
