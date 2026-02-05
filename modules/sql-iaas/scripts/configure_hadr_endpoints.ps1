param(
    [Parameter(Mandatory=$true)]
    [string[]]$AllNodeNames,

    [Parameter(Mandatory=$true)]
    [string]$CurrentNodeName,

    [Parameter(Mandatory=$false)]
    [int]$EndpointPort = 5022
)

$ErrorActionPreference = 'Stop'
$log = 'C:\Windows\Temp\configure-hadr-endpoints.log'
$sentinel = 'C:\Windows\Temp\.hadr-endpoint-configured'

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
    L "All nodes in cluster: $($AllNodeNames -join ', ')"

    # Install and import SQL Server module
    L "Checking for SqlServer module..."
    if (-not (Get-Module -ListAvailable -Name SqlServer)) {
        L "Installing SqlServer module..."
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser
        Install-Module -Name SqlServer -Force -AllowClobber -Scope CurrentUser -SkipPublisherCheck
        L "SqlServer module installed"
    }
    Import-Module SqlServer -ErrorAction Stop
    L "SqlServer module loaded"

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
    $masterKeyCheck = Invoke-Sqlcmd -Query "SELECT name FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##'" -ServerInstance $CurrentNodeName -Database master -ErrorAction SilentlyContinue

    if (-not $masterKeyCheck) {
        # Use hardcoded password for testing (will generate random after this works)
        $testPassword = "ComplexTest2025!"
        L "DEBUG: Using test password for master key creation"
        Invoke-Sqlcmd -Query "CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$testPassword';" -ServerInstance $CurrentNodeName -Database master
        L "Master key created successfully"
        $masterKeyPassword = $testPassword  # Use same password for certificate backup
    } else {
        L "Master key already exists"
        # For existing keys, generate a password for certificate operations
        $guidPart = (New-Guid).ToString().Replace('-', '')
        $masterKeyPassword = "${guidPart}!Sql2025"
    }

    # Step 2: Create Certificate for this node
    L "Creating certificate: $certName"
    $certCheck = Invoke-Sqlcmd -Query "SELECT name FROM sys.certificates WHERE name = '$certName'" -ServerInstance $CurrentNodeName -Database master -ErrorAction SilentlyContinue

    if (-not $certCheck) {
        $createCertSQL = @"
USE master;
CREATE CERTIFICATE [$certName]
WITH SUBJECT = 'Certificate for $CurrentNodeName HADR Endpoint',
EXPIRY_DATE = '2030-12-31';
"@
        Invoke-Sqlcmd -Query $createCertSQL -ServerInstance $CurrentNodeName
        L "Certificate created: $certName"

        # Backup certificate
        $certFile = Join-Path $certBackupPath "${certName}.cer"
        $keyFile = Join-Path $certBackupPath "${certName}.pvk"

        $backupCertSQL = "BACKUP CERTIFICATE [$certName] TO FILE = '$certFile' WITH PRIVATE KEY (FILE = '$keyFile', ENCRYPTION BY PASSWORD = '" + $masterKeyPassword + "');"
        Invoke-Sqlcmd -Query $backupCertSQL -ServerInstance $CurrentNodeName
        L "Certificate backed up to: $certFile"
    } else {
        L "Certificate already exists: $certName"
    }

    # Step 3: Wait for all nodes to create their certificates
    L "Waiting for partner node certificates..."
    $timeout = 300 # 5 minutes
    $elapsed = 0
    $allCertsReady = $false

    while ($elapsed -lt $timeout -and -not $allCertsReady) {
        $missingCerts = @()
        foreach ($nodeName in $AllNodeNames) {
            if ($nodeName -ne $CurrentNodeName) {
                $partnerCertFile = Join-Path $certBackupPath "${nodeName}_Cert.cer"
                if (-not (Test-Path $partnerCertFile)) {
                    $missingCerts += $nodeName
                }
            }
        }

        if ($missingCerts.Count -eq 0) {
            $allCertsReady = $true
            L "All partner certificates are ready"
        } else {
            L "Waiting for certificates from: $($missingCerts -join ', ')"
            Start-Sleep -Seconds 10
            $elapsed += 10
        }
    }

    if (-not $allCertsReady) {
        LE "Timeout waiting for partner certificates"
        exit 1
    }

    # Step 4: Import partner certificates
    L "Importing partner certificates..."
    foreach ($nodeName in $AllNodeNames) {
        if ($nodeName -ne $CurrentNodeName) {
            $partnerCertName = "${nodeName}_Cert"
            $partnerCertFile = Join-Path $certBackupPath "$partnerCertName.cer"

            # Check if certificate already imported
            $certExists = Invoke-Sqlcmd -Query "SELECT name FROM sys.certificates WHERE name = '$partnerCertName'" -ServerInstance $CurrentNodeName -Database master -ErrorAction SilentlyContinue

            if (-not $certExists) {
                $importCertSQL = @"
USE master;
CREATE CERTIFICATE [$partnerCertName]
FROM FILE = '$partnerCertFile';
"@
                Invoke-Sqlcmd -Query $importCertSQL -ServerInstance $CurrentNodeName
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
    $endpointCheck = Invoke-Sqlcmd -Query "SELECT name FROM sys.endpoints WHERE name = '$endpointName'" -ServerInstance $CurrentNodeName -ErrorAction SilentlyContinue

    if ($endpointCheck) {
        L "Endpoint already exists, dropping it to recreate with certificate"
        Invoke-Sqlcmd -Query "DROP ENDPOINT [$endpointName]" -ServerInstance $CurrentNodeName
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
    Invoke-Sqlcmd -Query $createEndpointSQL -ServerInstance $CurrentNodeName
    L "HADR endpoint created with certificate authentication"

    # Step 6: Grant CONNECT permission to partner certificates
    L "Granting CONNECT permissions to partner certificates..."
    foreach ($nodeName in $AllNodeNames) {
        if ($nodeName -ne $CurrentNodeName) {
            $partnerCertName = "${nodeName}_Cert"
            $loginName = "${nodeName}_Login"

            # Check if login exists
            $loginExists = Invoke-Sqlcmd -Query "SELECT name FROM sys.server_principals WHERE name = '$loginName'" -ServerInstance $CurrentNodeName -ErrorAction SilentlyContinue

            if (-not $loginExists) {
                # Create login from certificate
                $createLoginSQL = "USE master; CREATE LOGIN [" + $loginName + "] FROM CERTIFICATE [" + $partnerCertName + "];"
                Invoke-Sqlcmd -Query $createLoginSQL -ServerInstance $CurrentNodeName
                L "Created login for ${nodeName}: $loginName"
            }
            # Grant CONNECT permission to endpoint
            $grantSQL = "GRANT CONNECT ON ENDPOINT ::[" + $endpointName + "] TO [" + $loginName + "];"
            Invoke-Sqlcmd -Query $grantSQL -ServerInstance $CurrentNodeName
            L "Granted CONNECT permission to $loginName"
        }
    }

    # Verify endpoint is running
    $endpointStatus = Invoke-Sqlcmd -Query "SELECT state_desc FROM sys.endpoints WHERE name = '$endpointName'" -ServerInstance $CurrentNodeName
    L "Endpoint status: $($endpointStatus.state_desc)"

    L "HADR endpoint configuration completed successfully"
    New-Item -Path $sentinel -ItemType File -Force | Out-Null

} catch {
    LE "Error configuring HADR endpoint: $_"
    $_ | Out-File "C:\Windows\Temp\configure-hadr-endpoints.err.txt" -Force
    exit 1
}

