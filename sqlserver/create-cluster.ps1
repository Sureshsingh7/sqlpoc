param(
    [string]$AdminUsername = "azureuser",
    [string]$AdminPassword,
    [string]$PrimaryVmName,
    [string]$SecondaryVmName,
    [string]$ClusterName = "sqlpoc-cluster",
    [string]$ClusterPrimaryIp,
    [string]$ClusterSecondaryIp
)

# If parameters not provided via Terraform, read from environment or use defaults
if (-not $AdminPassword) {
    throw "AdminPassword is required"
}

if (-not $PrimaryVmName) {
    $PrimaryVmName = "sql-primary"
}

if (-not $SecondaryVmName) {
    $SecondaryVmName = "sql-secondary"
}

if (-not $ClusterPrimaryIp) {
    $ClusterPrimaryIp = "10.10.0.20"
}

if (-not $ClusterSecondaryIp) {
    $ClusterSecondaryIp = "10.10.0.45"
}

try {
    Write-Host "=== Cluster Creation Script ===" -ForegroundColor Green
    Write-Host "Primary VM: $PrimaryVmName"
    Write-Host "Secondary VM: $SecondaryVmName"
    Write-Host "Cluster Name: $ClusterName"
    Write-Host "Cluster IPs: $ClusterPrimaryIp, $ClusterSecondaryIp"
    Write-Host ""

    # Create PSCredential object with sqladmin account
    $secPassword = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($AdminUsername, $secPassword)

    # Define the cluster creation script block
    $clusterScriptBlock = {
        param($PrimaryVm, $SecondaryVm, $ClusterName, $ClusterPrimaryIp, $ClusterSecondaryIp)

        Write-Host "Waiting for secondary node initialization..." -ForegroundColor Yellow
        Start-Sleep -Seconds 60

        Write-Host "Creating failover cluster: $ClusterName" -ForegroundColor Yellow
        $clusterParams = @{
            Name                      = $ClusterName
            Node                      = $PrimaryVm, $SecondaryVm
            AdministrativeAccessPoint = "DNS"
            StaticAddress             = $ClusterPrimaryIp, $ClusterSecondaryIp
            NoStorage                 = $true
            Force                     = $true
            WarningAction             = "SilentlyContinue"
        }
        
        New-Cluster @clusterParams
        Write-Host "Failover cluster created successfully" -ForegroundColor Green

        Write-Host "Validating cluster configuration..." -ForegroundColor Yellow
        Test-Cluster -Node $PrimaryVm, $SecondaryVm `
            -ReportName "C:\ClusterValidationReport.htm" `
            -WarningAction SilentlyContinue

        Write-Host "Cluster validation completed. Report saved to C:\ClusterValidationReport.htm" -ForegroundColor Green
        Write-Host "Restarting computer to finalize cluster..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        Restart-Computer -Force
    }

    # Execute the script block on the primary VM using the sqladmin credentials
    Write-Host "Invoking cluster creation on $PrimaryVmName with sqladmin credentials..." -ForegroundColor Cyan
    Invoke-Command -ScriptBlock $clusterScriptBlock `
        -ArgumentList $PrimaryVmName, $SecondaryVmName, $ClusterName, $ClusterPrimaryIp, $ClusterSecondaryIp `
        -Credential $credential `
        -ComputerName $PrimaryVmName `
        -ErrorAction Stop

    Write-Host "Cluster creation completed successfully" -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "ERROR: Cluster creation failed" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}
