param(
    [Parameter(Mandatory=$true)]
    [string]$AllNodeNames,  # Changed from [string[]] - will be comma-separated

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
$log = 'C:\Windows\Temp\configure-hadr-endpoints.log'
$sentinel = 'C:\Windows\Temp\.hadr-endpoint-configured'

# Split the comma-separated node names into an array
$AllNodeNamesArray = $AllNodeNames -split ',' | ForEach-Object { $_.Trim() }

function L([string]$m) {
    $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO] $m"
    Add-Content -Path $log -Value $msg
    Write-Host $msg
}

function LE([string]$m) {
    $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [ERROR] $m"
    Add-Content -Path $log -Value $msg
    Write-Error $msg
}

# Check if already completed
if (Test-Path $sentinel) {
    L "HADR endpoint already configured - exiting"
    exit 0
}

try {
    L "Starting HADR endpoint configuration for $CurrentNodeName"
    L "All nodes in cluster: $($AllNodeNamesArray -join ', ')"

    # Install and import required modules
    L "Checking for SqlServer module..."
    if (-not (Get-Module -ListAvailable -Name SqlServer)) {
        L "Installing SqlServer module..."
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser
        Install-Module -Name SqlServer -Force -AllowClobber -Scope CurrentUser -SkipPublisherCheck
        L "SqlServer module installed"
    }
    Import-Module SqlServer -ErrorAction Stop
    L "SqlServer module loaded"

    L "Checking for Az.KeyVault module..."
    if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
        L "Installing Az.KeyVault module..."
        Install-Module -Name Az.KeyVault -Force -AllowClobber -Scope CurrentUser -SkipPublisherCheck
        L "Az.KeyVault module installed"
    }
    Import-Module Az.KeyVault -ErrorAction Stop
    L "Az.KeyVault module loaded"

    # Connect to Azure using Managed Identity (specify client ID for UAMI)
    L "Connecting to Azure with Managed Identity..."
    try {
        if ($ManagedIdentityClientId) {
            L "DEBUG: Using User-Assigned Identity: $ManagedIdentityClientId"
            Connect-AzAccount -Identity -AccountId $ManagedIdentityClientId -ErrorAction Stop | Out-Null
        } else {
            L "DEBUG: Using System-Assigned Identity"
            Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        }
        L "Connected to Azure successfully"
    } catch {
        LE "Failed to connect to Azure: $_"
        throw $_
    }

    $certName = "${CurrentNodeName}_Cert"
    $certBackupPath = "C:\Temp\Certificates"
    $guidPart = (New-Guid).ToString().Replace('-', '') # Remove hyphens from GUID
    $masterKeyPassword = "${guidPart}!Sql2025" # Random GUID with complexity suffix

    # Create certificate directory
    if (-not (Test-Path $certBackupPath)) {
        New-Item -Path $certBackupPath -ItemType Directory -Force | Out-Null
        L "Created certificate directory: $certBackupPath"
    }

    # Step 1: Create Master Key if it doesn't exist
    L "Creating database master key..."
    L "DEBUG: ServerInstance = $CurrentNodeName"
    
    try {
        $masterKeyCheck = Invoke-Sqlcmd -Query "SELECT name FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##'" -ServerInstance $CurrentNodeName -Database master -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction Stop
        L "DEBUG: Master key check completed, result count: $($masterKeyCheck.Count)"
    } catch {
        L "DEBUG: Master key check failed with error: $_"
        $masterKeyCheck = $null
    }

    if (-not $masterKeyCheck) {
        L "DEBUG: No existing master key found, creating new one"
        # Use hardcoded password for testing (will generate random after this works)
        $testPassword = "ComplexTest2025!"
        L "DEBUG: Using test password, length: $($testPassword.Length)"
        
        try {
            $createQuery = "CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$testPassword'"
            L "DEBUG: Executing query: $createQuery"
            Invoke-Sqlcmd -Query $createQuery -ServerInstance $CurrentNodeName -Database master -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction Stop
            L "Master key created successfully"
        } catch {
            L "DEBUG: CREATE MASTER KEY failed with error: $_"
            throw $_
        }
        $masterKeyPassword = $testPassword  # Use same password for certificate backup
    } else {
        L "Master key already exists"
        # For existing keys, generate a password for certificate operations
        $guidPart = (New-Guid).ToString().Replace('-', '')
        $masterKeyPassword = "${guidPart}!Sql2025"
    }

    # Step 2: Create Certificate for this node
    L "Creating certificate: $certName"
    $certCheck = Invoke-Sqlcmd -Query "SELECT name FROM sys.certificates WHERE name = '$certName'" -ServerInstance $CurrentNodeName -Database master -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction SilentlyContinue

    if (-not $certCheck) {
        $createCertSQL = @"
USE master;
CREATE CERTIFICATE [$certName]
WITH SUBJECT = 'Certificate for $CurrentNodeName HADR Endpoint',
EXPIRY_DATE = '2030-12-31';
"@
        Invoke-Sqlcmd -Query $createCertSQL -ServerInstance $CurrentNodeName -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate
        L "Certificate created: $certName"

        # Backup certificate
        $certFile = Join-Path $certBackupPath "${certName}.cer"
        $keyFile = Join-Path $certBackupPath "${certName}.pvk"

        $backupCertSQL = "BACKUP CERTIFICATE [$certName] TO FILE = '$certFile' WITH PRIVATE KEY (FILE = '$keyFile', ENCRYPTION BY PASSWORD = '" + $masterKeyPassword + "');"
        Invoke-Sqlcmd -Query $backupCertSQL -ServerInstance $CurrentNodeName -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate
        L "Certificate backed up to: $certFile"
    } else {
        L "Certificate already exists: $certName"
    }

    # Upload certificate to Key Vault (always, even if cert exists)
    $certFile = Join-Path $certBackupPath "${certName}.cer"
    if (Test-Path $certFile) {
        try {
            L "Uploading certificate to Key Vault: $KeyVaultName"
            $certBytes = [System.IO.File]::ReadAllBytes($certFile)
            $certBase64 = [System.Convert]::ToBase64String($certBytes)
            $secretName = "hadr-cert-$CurrentNodeName"
            Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secretName -SecretValue (ConvertTo-SecureString -String $certBase64 -AsPlainText -Force) -ErrorAction Stop | Out-Null
            L "Certificate uploaded to Key Vault as secret: $secretName"
        } catch {
            LE "Failed to upload certificate to Key Vault: $_"
            throw $_
        }
    } else {
        LE "Certificate file not found: $certFile"
        exit 1
    }

    # Step 3: Wait for partner node certificates in Key Vault
    L "Waiting for partner node certificates in Key Vault..."
    $timeout = 300 # 5 minutes
    $elapsed = 0
    $allCertsReady = $false

    while ($elapsed -lt $timeout -and -not $allCertsReady) {
        $missingCerts = @()
        foreach ($nodeName in $AllNodeNamesArray) {
            if ($nodeName -ne $CurrentNodeName) {
                $secretName = "hadr-cert-$nodeName"
                try {
                    $secret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secretName -ErrorAction SilentlyContinue
                    if (-not $secret) {
                        $missingCerts += $nodeName
                    }
                } catch {
                    $missingCerts += $nodeName
                }
            }
        }

        if ($missingCerts.Count -eq 0) {
            $allCertsReady = $true
            L "All partner certificates are ready in Key Vault"
        } else {
            L "Waiting for certificates from: $($missingCerts -join ', ')"
            Start-Sleep -Seconds 10
            $elapsed += 10
        }
    }

    if (-not $allCertsReady) {
        LE "Timeout waiting for partner certificates in Key Vault"
        exit 1
    }

    # Step 4: Download and import partner certificates from Key Vault
    L "Downloading and importing partner certificates from Key Vault..."
    foreach ($nodeName in $AllNodeNamesArray) {
        if ($nodeName -ne $CurrentNodeName) {
            $partnerCertName = "${nodeName}_Cert"
            $partnerCertFile = Join-Path $certBackupPath "$partnerCertName.cer"

            # Check if certificate already imported
            $certExists = Invoke-Sqlcmd -Query "SELECT name FROM sys.certificates WHERE name = '$partnerCertName'" -ServerInstance $CurrentNodeName -Database master -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction SilentlyContinue

            if (-not $certExists) {
                # Download certificate from Key Vault
                try {
                    $secretName = "hadr-cert-$nodeName"
                    L "Downloading certificate from Key Vault: $secretName"
                    $secret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secretName -ErrorAction Stop
                    # Convert SecureString to plain text (PowerShell 5.1 compatible)
                    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret.SecretValue)
                    try {
                        $certBase64 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                    } finally {
                        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                    }
                    $certBytes = [System.Convert]::FromBase64String($certBase64)
                    [System.IO.File]::WriteAllBytes($partnerCertFile, $certBytes)
                    L "Certificate downloaded to: $partnerCertFile"
                } catch {
                    LE "Failed to download certificate from Key Vault: $_"
                    throw $_
                }

                # Import certificate into SQL Server
                $importCertSQL = @"
USE master;
CREATE CERTIFICATE [$partnerCertName]
FROM FILE = '$partnerCertFile';
"@
                Invoke-Sqlcmd -Query $importCertSQL -ServerInstance $CurrentNodeName -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate
                L "Imported certificate from $nodeName"
            } else {
                L "Certificate from $nodeName already imported"
            }
        }
    }

    # Step 5: Create HADR Endpoint with certificate authentication
    L "Creating HADR endpoint on port $EndpointPort..."
    $endpointName = "Hadr_endpoint"

    # Check if endpoint exists
    $endpointCheck = Invoke-Sqlcmd -Query "SELECT name FROM sys.endpoints WHERE name = '$endpointName'" -ServerInstance $CurrentNodeName -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction SilentlyContinue

    if ($endpointCheck) {
        L "Endpoint already exists, dropping it to recreate with certificate"
        Invoke-Sqlcmd -Query "DROP ENDPOINT [$endpointName]" -ServerInstance $CurrentNodeName -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate
    }

    $createEndpointSQL = @"
CREATE ENDPOINT [$endpointName]
STATE = STARTED
AS TCP (
    LISTENER_PORT = $EndpointPort,
    LISTENER_IP = ALL
)
FOR DATABASE_MIRRORING (
    AUTHENTICATION = CERTIFICATE [$certName],
    ENCRYPTION = REQUIRED ALGORITHM AES,
    ROLE = ALL
);
"@
    Invoke-Sqlcmd -Query $createEndpointSQL -ServerInstance $CurrentNodeName -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate
    L "HADR endpoint created with certificate authentication"

    # Step 6: Grant CONNECT permission to partner certificates
    L "Granting CONNECT permissions to partner certificates..."
    foreach ($nodeName in $AllNodeNamesArray) {
        if ($nodeName -ne $CurrentNodeName) {
            $partnerCertName = "${nodeName}_Cert"
            $loginName = "${nodeName}_Login"

            # Check if login exists
            $loginExists = Invoke-Sqlcmd -Query "SELECT name FROM sys.server_principals WHERE name = '$loginName'" -ServerInstance $CurrentNodeName -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction SilentlyContinue

            if (-not $loginExists) {
                # Create login from certificate
                $createLoginSQL = "USE master; CREATE LOGIN [" + $loginName + "] FROM CERTIFICATE [" + $partnerCertName + "];"
                Invoke-Sqlcmd -Query $createLoginSQL -ServerInstance $CurrentNodeName -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate
                L "Created login for ${nodeName}: $loginName"
            }
            # Grant CONNECT permission to endpoint
            $grantSQL = "GRANT CONNECT ON ENDPOINT ::[" + $endpointName + "] TO [" + $loginName + "];"
            Invoke-Sqlcmd -Query $grantSQL -ServerInstance $CurrentNodeName -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate
            L "Granted CONNECT permission to $loginName"
        }
    }

    # Verify endpoint is running
    $endpointStatus = Invoke-Sqlcmd -Query "SELECT state_desc FROM sys.endpoints WHERE name = '$endpointName'" -ServerInstance $CurrentNodeName -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate
    L "Endpoint status: $($endpointStatus.state_desc)"

    L "HADR endpoint configuration completed successfully"
    New-Item -Path $sentinel -ItemType File -Force | Out-Null

} catch {
    LE "Error configuring HADR endpoint: $_"
    $_ | Out-File "C:\Windows\Temp\configure-hadr-endpoints.err.txt" -Force
    exit 1
}

