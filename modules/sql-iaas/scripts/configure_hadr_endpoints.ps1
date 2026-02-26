#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up SQL Server HADR certificates and endpoints on EACH VM separately.
    Certificates are exchanged between nodes via Azure Key Vault.
.PARAMETER AllNodeNames
    Comma-separated list of all SQL node hostnames
.PARAMETER CurrentNodeName
    Hostname of the current node
.PARAMETER EndpointPort
    Port for the HADR endpoint (default: 5022)
.PARAMETER SqlAdminUsername
    SQL admin username for SQL authentication
.PARAMETER SqlAdminPassword
    SQL admin password for SQL authentication
.PARAMETER KeyVaultName
    Name of the Azure Key Vault used to store/retrieve HADR certificates
.PARAMETER ManagedIdentityClientId
    Client ID of the User-Assigned Managed Identity for Key Vault access
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$AllNodeNames,

    [Parameter(Mandatory=$true)]
    [string]$CurrentNodeName,

    [Parameter(Mandatory=$false)]
    [int]$EndpointPort = 5022,

    [Parameter(Mandatory=$true)]
    [string]$SqlAdminUsername,

    [Parameter(Mandatory=$true)]
    [string]$SqlAdminPassword,

    [Parameter(Mandatory=$true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory=$false)]
    [string]$ManagedIdentityClientId = ""
)

$ErrorActionPreference = 'Stop'
$script:LogFile = 'C:\Windows\Temp\configure-hadr-endpoints.log'
$script:StartTime = Get-Date
$sentinel = 'C:\Windows\Temp\.hadr-endpoint-configured'

# Split comma-separated node names
$AllNodeNamesArray = $AllNodeNames -split ',' | ForEach-Object { $_.Trim() }

# Determine partner
$PartnerNodes = $AllNodeNamesArray | Where-Object { $_ -ne $CurrentNodeName }
$LocalCertName = "${CurrentNodeName}_HADR_Cert"
$EndpointName = "HADR_Endpoint"
$CertPath = "C:\Certificates"
$MasterKeyPassword = "Hk!$([guid]::NewGuid().ToString('N'))$([guid]::NewGuid().ToString('N'))"

#region Logging
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $elapsed = ((Get-Date) - $script:StartTime).ToString('mm\:ss')
    $entry = "$timestamp [$elapsed] [$Level] $Message"
    Add-Content -Path $script:LogFile -Value $entry -ErrorAction SilentlyContinue
    Write-Host $entry
}

function L([string]$m) { Write-Log $m "INFO" }
function LD([string]$m) { Write-Log $m "DEBUG" }
function LW([string]$m) { Write-Log $m "WARN" }
function LE([string]$m) { Write-Log $m "ERROR" }
function Write-Step([int]$Number, [string]$Title) { L ""; L ("=" * 55); L "STEP ${Number}: $Title"; L ("=" * 55) }
#endregion

#region SQL Execution
function Invoke-SqlQuery {
    param(
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$Description,
        [string]$ServerInstance = "localhost",
        [int]$QueryTimeout = 30,
        [switch]$Safe
    )

    L "  SQL: $Description"
    $startTime = Get-Date

    try {
        $result = Invoke-Sqlcmd -ServerInstance $ServerInstance -Username $SqlAdminUsername -Password $SqlAdminPassword -Query $Query -QueryTimeout $QueryTimeout -ErrorAction Stop
        $elapsedMs = [int]((Get-Date) - $startTime).TotalMilliseconds
        L "  Done: $Description (${elapsedMs}ms)"
        return $result
    } catch {
        if ($Safe) {
            LW "  Skipped: $Description - $($_.Exception.Message)"
            return $null
        }
        LE "  SQL Failed: $Description - $($_.Exception.Message)"
        throw
    }
}
#endregion

#region Steps
function Initialize-CertificateFolder {
    L "  Creating certificate folder: $CertPath"
    if (-not (Test-Path $CertPath)) {
        New-Item -ItemType Directory -Path $CertPath -Force | Out-Null
    }
    # Grant SQL Server service account access to cert folder
    icacls $CertPath /grant "NT SERVICE\MSSQLSERVER:(OI)(CI)M" 2>&1 | Out-Null
    L "  Folder ready with SQL Server permissions"
}

function New-MasterKeyAndCertificate {
    L "  Creating Master Key..."
    Invoke-SqlQuery "USE master; IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name='##MS_DatabaseMasterKey##') CREATE MASTER KEY ENCRYPTION BY PASSWORD='$MasterKeyPassword';" "Create Master Key" -Safe

    L "  Creating Certificate: $LocalCertName"
    $certStartDate = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    $certExpiryDate = (Get-Date).AddYears(5).ToString('yyyy-MM-ddTHH:mm:ss')

    Invoke-SqlQuery @"
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name='$LocalCertName')
    CREATE CERTIFICATE [$LocalCertName] WITH SUBJECT = '$CurrentNodeName HADR Certificate',
        START_DATE = '$certStartDate',
        EXPIRY_DATE = '$certExpiryDate';
"@ "Create Certificate" -Safe
    L "  Master key and certificate ready"
}

function Backup-Certificate {
    $certFile = "$CertPath\$LocalCertName.cer"
    if (Test-Path $certFile) {
        L "  Certificate backup already exists: $certFile"
        return
    }
    L "  Backing up certificate to: $certFile"
    Invoke-SqlQuery "BACKUP CERTIFICATE [$LocalCertName] TO FILE='$certFile';" "Backup Certificate" -Safe

    # Wait for file to appear
    $waitTime = 0
    while ($waitTime -lt 30 -and -not (Test-Path $certFile)) {
        Start-Sleep -Seconds 2
        $waitTime += 2
    }
    if (Test-Path $certFile) {
        L "  Certificate backed up ($((Get-Item $certFile).Length) bytes)"
    } else {
        LE "  Certificate file not found after backup"
        throw "Certificate backup failed"
    }
}

function New-HadrEndpoint {
    L "  Creating HADR endpoint on port $EndpointPort..."
    Invoke-SqlQuery @"
IF NOT EXISTS (SELECT 1 FROM sys.endpoints WHERE name='$EndpointName')
    CREATE ENDPOINT [$EndpointName]
        STATE = STARTED AS TCP (LISTENER_PORT = $EndpointPort)
        FOR DATABASE_MIRRORING (
            AUTHENTICATION = CERTIFICATE [$LocalCertName],
            ENCRYPTION = REQUIRED ALGORITHM AES,
            ROLE = ALL);
ELSE IF EXISTS (SELECT 1 FROM sys.endpoints WHERE name='$EndpointName' AND state_desc!='STARTED')
    ALTER ENDPOINT [$EndpointName] STATE = STARTED;
"@ "Create/Start Endpoint" -Safe

    $endpoint = Invoke-SqlQuery "SELECT name, port, state_desc FROM sys.tcp_endpoints WHERE name='$EndpointName';" "Verify Endpoint" -Safe
    if ($endpoint) {
        L "  Endpoint ready: $($endpoint.name) on port $($endpoint.port) - $($endpoint.state_desc)"
    }
}

function Get-AzAccessToken {
    # Get an access token for Key Vault using the VM's Managed Identity
    $resource = "https://vault.azure.net"
    $imdsUrl = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$resource"
    if ($ManagedIdentityClientId -ne "") {
        $imdsUrl += "&client_id=$ManagedIdentityClientId"
    }
    $response = Invoke-RestMethod -Uri $imdsUrl -Headers @{ Metadata = "true" } -ErrorAction Stop
    return $response.access_token
}

function Upload-CertToKeyVault {
    param([string]$CertFile, [string]$SecretName)

    $certBytes = [System.IO.File]::ReadAllBytes($CertFile)
    $certBase64 = [Convert]::ToBase64String($certBytes)
    $token = Get-AzAccessToken

    $uri = "https://$KeyVaultName.vault.azure.net/secrets/${SecretName}?api-version=7.4"
    $body = @{ value = $certBase64; contentType = "application/x-certificate" } | ConvertTo-Json

    Invoke-RestMethod -Uri $uri -Method PUT -Headers @{
        Authorization  = "Bearer $token"
        "Content-Type" = "application/json"
    } -Body $body -ErrorAction Stop | Out-Null
    L "  Uploaded certificate to Key Vault: $SecretName"
}

function Download-CertFromKeyVault {
    param([string]$SecretName, [string]$DestFile)

    $token = Get-AzAccessToken
    $uri = "https://$KeyVaultName.vault.azure.net/secrets/${SecretName}?api-version=7.4"

    $response = Invoke-RestMethod -Uri $uri -Method GET -Headers @{
        Authorization = "Bearer $token"
    } -ErrorAction Stop

    $certBytes = [Convert]::FromBase64String($response.value)
    [System.IO.File]::WriteAllBytes($DestFile, $certBytes)
    L "  Downloaded certificate from Key Vault: $SecretName -> $DestFile"
}

function Sync-PartnerCertificate {
    param([string]$PartnerServer)

    $localCertFile = "$CertPath\$LocalCertName.cer"
    $partnerCertName = "${PartnerServer}_HADR_Cert"
    $partnerCertFile = "$CertPath\$partnerCertName.cer"
    $maxWaitSeconds = 300  # 5 minutes max

    # Wait for local certificate to be ready
    L "  Waiting for local certificate to be ready..."
    $waitTime = 0
    while ($waitTime -lt 60 -and -not (Test-Path $localCertFile)) {
        L "  Local certificate not ready yet, waiting... ($waitTime/60s)"
        Start-Sleep -Seconds 5
        $waitTime += 5
    }
    if (-not (Test-Path $localCertFile)) {
        throw "Local certificate must exist before exchange: $localCertFile"
    }
    L "  Local certificate ready: $localCertFile"

    # Upload local cert to Key Vault
    $localSecretName = "hadr-cert-$($CurrentNodeName.ToLower())"
    L "  Uploading local certificate to Key Vault as '$localSecretName'..."
    Upload-CertToKeyVault -CertFile $localCertFile -SecretName $localSecretName

    if (Test-Path $partnerCertFile) {
        L "  Partner certificate already exists locally: $partnerCertFile"
        return
    }

    L "  Waiting for partner certificate in Key Vault..."
    L "  Will wait up to $($maxWaitSeconds/60) minutes for partner certificate..."

    $partnerSecretName = "hadr-cert-$($PartnerServer.ToLower())"
    $waitTime = 0
    $downloaded = $false

    while ($waitTime -lt $maxWaitSeconds -and -not $downloaded) {
        try {
            Download-CertFromKeyVault -SecretName $partnerSecretName -DestFile $partnerCertFile
            $downloaded = $true
            L "  Partner certificate downloaded from Key Vault"
        } catch {
            L "  Partner cert not in Key Vault yet ($waitTime/${maxWaitSeconds}s): $($_.Exception.Message)"
        }
        if (-not $downloaded) {
            Start-Sleep -Seconds 10
            $waitTime += 10
        }
    }

    if (-not $downloaded) {
        throw "Failed to download partner certificate from Key Vault after $($maxWaitSeconds/60) minutes - ensure script is running on both VMs"
    }
    L "  Certificate exchange via Key Vault complete"
    L "    Local cert: $localCertFile ($((Get-Item $localCertFile).Length) bytes)"
    L "    Partner cert: $partnerCertFile ($((Get-Item $partnerCertFile).Length) bytes)"
}

function Import-PartnerCertificate {
    param([string]$PartnerServer)

    $partnerCertName = "${PartnerServer}_HADR_Cert"
    $partnerCertFile = "$CertPath\$partnerCertName.cer"
    $importedCertName = "${PartnerServer}_Imported_Cert"
    $hadrLoginName = "${PartnerServer}_HADR_Login"

    if (-not (Test-Path $partnerCertFile)) {
        throw "Partner certificate not found: $partnerCertFile"
    }

    L "  Importing partner certificate from $PartnerServer..."
    Invoke-SqlQuery "IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name='$importedCertName') CREATE CERTIFICATE [$importedCertName] FROM FILE='$partnerCertFile';" "Import Certificate" -Safe
    Invoke-SqlQuery "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name='$hadrLoginName') CREATE LOGIN [$hadrLoginName] FROM CERTIFICATE [$importedCertName];" "Create Login from Certificate" -Safe
    Invoke-SqlQuery "GRANT CONNECT ON ENDPOINT::[$EndpointName] TO [$hadrLoginName];" "Grant CONNECT on Endpoint" -Safe
    L "  Partner certificate imported, login configured for handshake"
}

function Test-HadrSetup {
    L "  Verifying HADR endpoint setup..."

    $endpointStatus = Invoke-SqlQuery "SELECT name, protocol_desc, port, state_desc FROM sys.tcp_endpoints WHERE type_desc = 'DATABASE_MIRRORING';" "Check Endpoint Status" -Safe
    if ($endpointStatus) {
        L "    Endpoint: $($endpointStatus.name) | Port: $($endpointStatus.port) | State: $($endpointStatus.state_desc)"
    }

    $certificates = Invoke-SqlQuery "SELECT name, subject, start_date, expiry_date FROM sys.certificates WHERE name LIKE '%HADR%' OR name LIKE '%Imported%';" "Check Certificates" -Safe
    if ($certificates) {
        @($certificates) | ForEach-Object { L "    Cert: $($_.name) | Subject: $($_.subject) | Expires: $($_.expiry_date)" }
    }

    $permissions = Invoke-SqlQuery @"
SELECT
    p.name AS Login_Name,
    c.name AS Certificate_Mapped,
    sp.permission_name AS Permission,
    sp.state_desc AS Permission_State
FROM sys.server_principals p
JOIN sys.certificates c ON p.sid = c.sid
JOIN sys.server_permissions sp ON p.principal_id = sp.grantee_principal_id
JOIN sys.database_mirroring_endpoints e ON sp.major_id = e.endpoint_id
WHERE p.type = 'C' AND e.name = '$EndpointName';
"@ "Check Endpoint Permissions" -Safe
    if ($permissions) {
        @($permissions) | ForEach-Object { L "    Login: $($_.Login_Name) | Cert: $($_.Certificate_Mapped) | Permission: $($_.Permission) ($($_.Permission_State))" }
    }

    $certCount = @($certificates).Count
    $hasEndpoint = $null -ne $endpointStatus
    $hasPermissions = $null -ne $permissions
    L "  Summary: Endpoint=$(if($hasEndpoint){'OK'}else{'MISSING'}), Certificates=$certCount, Permissions=$(if($hasPermissions){'OK'}else{'MISSING'})"

    if ($hasEndpoint -and $certCount -ge 2 -and $hasPermissions) {
        L "  All components verified - Handshake ready"
    } else {
        LW "  Some components may be missing - verify manually"
    }
}
#endregion

#region Main
try {
    Remove-Item $script:LogFile -Force -ErrorAction SilentlyContinue

    L ("=" * 55)
    L "SQL SERVER HADR ENDPOINT SETUP"
    L ("=" * 55)
    L "Local: $CurrentNodeName | Partners: $($PartnerNodes -join ', ')"
    L "Endpoint: $EndpointName (Port $EndpointPort)"
    L "Certificate Path: $CertPath"
    L "Admin User: $ClusterAdminUsername"
    L ("=" * 55)

    # Check if already completed
    if (Test-Path $sentinel) {
        L "HADR endpoint already configured - exiting"
        exit 0
    }

    Write-Step 0 "Checking SQL Permissions"
    L "  Current Windows user: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    try {
        $sqlUser = Invoke-Sqlcmd -ServerInstance localhost -Username $SqlAdminUsername -Password $SqlAdminPassword -Query "SELECT SUSER_SNAME() AS CurrentUser, IS_SRVROLEMEMBER('sysadmin') AS IsSysadmin;" -ErrorAction Stop
        L "  SQL User: $($sqlUser.CurrentUser) | Sysadmin: $(if($sqlUser.IsSysadmin -eq 1){'YES'}else{'NO'})"
    } catch {
        LE "  Could not query SQL user: $($_.Exception.Message)"
        throw
    }

    Write-Step 1 "Create Certificate Folder"
    Initialize-CertificateFolder

    Write-Step 2 "Setup Master Key & Certificate"
    New-MasterKeyAndCertificate

    Write-Step 3 "Backup Certificate to File"
    Backup-Certificate

    Write-Step 4 "Create HADR Endpoint"
    New-HadrEndpoint

    Write-Step 5 "Exchange Certificates with Partners via Key Vault"
    foreach ($partner in $PartnerNodes) {
        L "  --- Exchanging with $partner ---"
        Sync-PartnerCertificate -PartnerServer $partner
    }

    Write-Step 6 "Import Partner Certificates & Create Logins"
    foreach ($partner in $PartnerNodes) {
        Import-PartnerCertificate -PartnerServer $partner
    }

    Write-Step 7 "Verify Setup"
    Test-HadrSetup

    # Mark as complete
    New-Item -Path $sentinel -ItemType File -Force | Out-Null

    $duration = (Get-Date) - $script:StartTime
    L ""
    L ("=" * 55)
    L "COMPLETED (Duration: $($duration.ToString('mm\:ss')))"
    L "Log: $script:LogFile"
    L ("=" * 55)
    exit 0

} catch {
    LE "SCRIPT EXECUTION FAILED: $($_.Exception.Message)"
    LE "Stack Trace: $($_.ScriptStackTrace)"
    $duration = (Get-Date) - $script:StartTime
    L ("=" * 55)
    L "SCRIPT FAILED (Duration: $($duration.ToString('mm\:ss')))"
    L "Log: $script:LogFile"
    L ("=" * 55)
    exit 1
}
#endregion

