# Pre-Deployment Verification Checklist

## Code Changes Review
- [x] `GrantSqlClusterAccess()` function added to create_failover_cluster.ps1 (commit 1bdbb36)
- [x] Function called AFTER cluster creation, BEFORE HADR endpoints
- [x] Proper error handling with verification step
- [x] Terraform dependency: cluster_setup → hadr_endpoint_setup confirmed

## Critical Fixes Applied
1. **Root Cause Fix**: SQL Server service account now gets cluster permissions automatically
2. **Execution Order**: Permissions granted before HADR endpoint creation
3. **Idempotency**: Script checks if cluster exists before creating

## Pre-Deployment Steps

### 1. Verify Git Status
```powershell
cd c:\Users\syguemgh\VSCRepos\FNZ\SQLPOC
git status
git log --oneline -5
```
**Expected**: Clean working tree, latest commit includes cluster access fix

### 2. Check Terraform State
```powershell
cd sqlserver
terraform workspace list
terraform state list | Select-String "cluster_setup|hadr_endpoint"
```

### 3. Backup Current State (Optional)
```powershell
terraform state pull > ../state_backup_$(Get-Date -Format 'yyyyMMdd-HHmmss').json
```

## Deployment Command

### Option A: Destroy & Recreate (RECOMMENDED)
```powershell
# From: c:\Users\syguemgh\VSCRepos\FNZ\SQLPOC\sqlserver

# 1. Destroy existing infrastructure
terraform destroy -auto-approve -var-file='env/dev-ha.tfvars'

# 2. Clean deploy with fixes
terraform apply -auto-approve -var-file='env/dev-ha.tfvars'
```

### Option B: Targeted Redeploy
```powershell
# Delete sentinels on both VMs first
az vm run-command invoke --resource-group rg-fnz-poc-sql-se --name poc-ha-sql-01 --command-id RunPowerShellScript --scripts "Remove-Item 'C:\Windows\Temp\.cluster-setup-completed' -Force" --no-wait
az vm run-command invoke --resource-group rg-fnz-poc-sql-se --name poc-ha-sql-02 --command-id RunPowerShellScript --scripts "Remove-Item 'C:\Windows\Temp\.cluster-setup-completed' -Force" --no-wait

# Redeploy cluster setup
terraform apply -auto-approve -var-file='env/dev-ha.tfvars' -target='module.sqlserver.azurerm_virtual_machine_run_command.cluster_setup'

# Then HADR endpoints
terraform apply -auto-approve -var-file='env/dev-ha.tfvars' -target='module.sqlserver.azurerm_virtual_machine_run_command.hadr_endpoint_setup'

# Finally AG
terraform apply -auto-approve -var-file='env/dev-ha.tfvars' -target='module.sqlserver.azurerm_virtual_machine_run_command.ag_setup'
```

## Post-Deployment Validation

### Auto-Validation Script
```powershell
# Save as: validate_deployment.ps1
$nodes = @("poc-ha-sql-01", "poc-ha-sql-02")
$rg = "rg-fnz-poc-sql-se"

foreach ($node in $nodes) {
    Write-Host "`n=== Validating $node ===" -ForegroundColor Cyan
    
    $result = az vm run-command invoke `
        --resource-group $rg `
        --name $node `
        --command-id RunPowerShellScript `
        --scripts @"
Write-Host '1. Cluster Access:'
`$access = Get-ClusterAccess | Where-Object { `$_.IdentityReference -eq 'NT SERVICE\MSSQLSERVER' }
if (`$access) { Write-Host '   ✓ SQL has cluster access' } else { Write-Host '   ✗ MISSING cluster access' }

Write-Host '2. Cluster Visibility:'
`$cluster = & sqlcmd -E -C -h -1 -W -Q "SET NOCOUNT ON; SELECT cluster_name FROM sys.dm_hadr_cluster" 2>&1
if (`$cluster -match 'sqlpoc') { Write-Host "   ✓ Cluster visible: `$cluster" } else { Write-Host '   ✗ Cluster NOT visible' }

Write-Host '3. HADR Endpoints:'
`$ep = & sqlcmd -E -C -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.endpoints WHERE type_desc='DATABASE_MIRRORING'" 2>&1
if (`$ep -match '^\s*1\s*$') { Write-Host "   ✓ Endpoint exists" } else { Write-Host "   ✗ NO endpoint" }

Write-Host '4. Certificates:'
`$certs = & sqlcmd -E -C -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.certificates WHERE name LIKE '%HADR%'" 2>&1
if (`$certs -match '^\s*2\s*$') { Write-Host "   ✓ 2 certificates" } else { Write-Host "   ✗ Wrong cert count: `$certs" }
"@ --query "value[0].message" -o tsv
    
    Write-Host $result
}

# Check AG
Write-Host "`n=== Checking Availability Group ===" -ForegroundColor Cyan
$agResult = az vm run-command invoke `
    --resource-group $rg `
    --name "poc-ha-sql-01" `
    --command-id RunPowerShellScript `
    --scripts "sqlcmd -E -C -Q 'SELECT ag.name AS AG, ar.replica_server_name AS Replica, ar.availability_mode_desc AS Mode, ars.role_desc AS Role FROM sys.availability_groups ag JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id'" `
    --query "value[0].message" -o tsv

Write-Host $agResult
```

### Success Criteria
- ✅ Both nodes have cluster access for `NT SERVICE\MSSQLSERVER`
- ✅ Both nodes see cluster in `sys.dm_hadr_cluster`
- ✅ Both nodes have 1 HADR endpoint (STARTED state)
- ✅ Both nodes have 2 certificates (local + partner)
- ✅ AG exists with 2 replicas (synchronous commit)
- ✅ Listener responds on port 1433

## Troubleshooting

If validation fails, check logs:
```powershell
# On each VM via Bastion/RDP:
Get-Content C:\Windows\Temp\create-failover-cluster.log -Tail 50
Get-Content C:\Windows\Temp\configure-hadr-endpoints.log -Tail 50
Get-Content C:\Windows\Temp\create-availability-group.log -Tail 50
```

## Rollback Plan
```powershell
# If deployment fails, restore from state backup:
terraform state push state_backup_TIMESTAMP.json

# Or destroy and investigate:
terraform destroy -auto-approve -var-file='env/dev-ha.tfvars'
```
