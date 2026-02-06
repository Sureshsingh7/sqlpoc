# Manual HADR Endpoint Setup for Node 2
# This is a one-time manual fix - future deployments will be automated

$ErrorActionPreference = 'Stop'
$log = 'C:\Windows\Temp\manual-hadr-node2.log'

function L([string]$m) {
    $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO] $m"
    Add-Content -Path $log -Value $msg -Force
    Write-Host $msg
}

try {
    L "=== Manual HADR Endpoint Setup for Node 2 ==="
    
    $nodeName = $env:COMPUTERNAME
    $kvName = "kv-fnz-poc-se"
    # Partner node determined dynamically
    $allNodes = @("poc-ha-sql-01", "poc-ha-sql-02")
    $partnerNode = ($allNodes | Where-Object { $_ -ne $nodeName })[0]
    
    L "Current node: $nodeName"
    L "Partner node: $partnerNode"
    
    # Install Az.KeyVault if needed
    L "Checking Az.KeyVault module..."
    if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
        L "Installing Az.KeyVault..."
        Install-Module -Name Az.KeyVault -Force -AllowClobber -Scope AllUsers -Repository PSGallery
    }
    Import-Module Az.KeyVault -Force
    
    # Import SqlServer module
    L "Importing SqlServer module..."
    Import-Module SqlServer -Force
    
    # Connect to Azure with Managed Identity
    L "Connecting to Azure with Managed Identity..."
    Connect-AzAccount -Identity | Out-Null
    
    # Create certificate
    L "Creating self-signed certificate..."
    $cert = New-SelfSignedCertificate `
        -Subject "CN=$nodeName-HADR" `
        -DnsName "$nodeName-HADR" `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -KeyUsage KeyEncipherment, DataEncipherment `
        -KeyExportPolicy Exportable `
        -CertStoreLocation Cert:\LocalMachine\My `
        -NotAfter (Get-Date).AddYears(5)
    
    L "Certificate created with thumbprint: $($cert.Thumbprint)"
    
    # Export certificate to Base64
    $certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $certBase64 = [System.Convert]::ToBase64String($certBytes)
    
    # Upload to Key Vault
    $secretName = "$nodeName-HADR-Cert"
    L "Uploading certificate to Key Vault as secret: $secretName"
    
    $secureString = ConvertTo-SecureString -String $certBase64 -AsPlainText -Force
    Set-AzKeyVaultSecret -VaultName $kvName -Name $secretName -SecretValue $secureString | Out-Null
    
    L "Certificate uploaded to Key Vault"
    
    # Download partner certificate from Key Vault
    $partnerSecretName = "$partnerNode-HADR-Cert"
    L "Downloading partner certificate: $partnerSecretName"
    
    $maxRetries = 12
    $retryCount = 0
    $partnerCertBase64 = $null
    
    while ($retryCount -lt $maxRetries -and $null -eq $partnerCertBase64) {
        try {
            $secret = Get-AzKeyVaultSecret -VaultName $kvName -Name $partnerSecretName -ErrorAction Stop
            # Use Marshal to convert SecureString (PS 5.1 compatible)
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret.SecretValue)
            $partnerCertBase64 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            L "Partner certificate downloaded"
        } catch {
            $retryCount++
            if ($retryCount -lt $maxRetries) {
                L "Partner certificate not available yet, retry $retryCount/$maxRetries in 10s..."
                Start-Sleep -Seconds 10
            } else {
                throw "Partner certificate not found after $maxRetries retries: $_"
            }
        }
    }
    
    # Install partner certificate
    L "Installing partner certificate..."
    $partnerCertBytes = [System.Convert]::FromBase64String($partnerCertBase64)
    $partnerCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
    $partnerCert.Import($partnerCertBytes)
    
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("My", "LocalMachine")
    $store.Open("ReadWrite")
    $store.Add($partnerCert)
    $store.Close()
    
    L "Partner certificate installed with thumbprint: $($partnerCert.Thumbprint)"
    
    # Create SQL certificates and endpoint
    L "Creating SQL Server certificates and endpoint..."
    
    $createSql = @"
-- Create certificate for local node
IF NOT EXISTS (SELECT * FROM sys.certificates WHERE name = '$nodeName-HADR-Cert')
BEGIN
    CREATE CERTIFICATE [$nodeName-HADR-Cert]
    FROM BINARY = 0x$($certBytes | ForEach-Object { $_.ToString('X2') } | Join-String)
    WITH SUBJECT = 'HADR Endpoint Certificate for $nodeName';
    PRINT 'Created certificate $nodeName-HADR-Cert';
END
ELSE
    PRINT 'Certificate $nodeName-HADR-Cert already exists';

-- Create certificate for partner node
IF NOT EXISTS (SELECT * FROM sys.certificates WHERE name = '$partnerNode-HADR-Cert')
BEGIN
    CREATE CERTIFICATE [$partnerNode-HADR-Cert]
    FROM BINARY = 0x$($partnerCertBytes | ForEach-Object { $_.ToString('X2') } | Join-String)
    WITH SUBJECT = 'HADR Endpoint Certificate for $partnerNode';
    PRINT 'Created certificate $partnerNode-HADR-Cert';
END
ELSE
    PRINT 'Certificate $partnerNode-HADR-Cert already exists';

-- Create endpoint
IF NOT EXISTS (SELECT * FROM sys.endpoints WHERE name = 'Hadr_endpoint' AND type_desc = 'DATABASE_MIRRORING')
BEGIN
    CREATE ENDPOINT [Hadr_endpoint]
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5022)
    FOR DATABASE_MIRRORING (
        AUTHENTICATION = CERTIFICATE [$nodeName-HADR-Cert],
        ENCRYPTION = REQUIRED ALGORITHM AES,
        ROLE = ALL
    );
    PRINT 'Created HADR endpoint';
END
ELSE
BEGIN
    ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;
    PRINT 'HADR endpoint already exists, started it';
END
"@
    
    Invoke-Sqlcmd -Query $createSql -ServerInstance localhost -TrustServerCertificate
    
    L "SQL certificates and endpoint created"
    
    # Verify
    $endpoint = Invoke-Sqlcmd -Query "SELECT name, state_desc, port FROM sys.tcp_endpoints WHERE type_desc='DATABASE_MIRRORING'" -ServerInstance localhost -TrustServerCertificate
    L "Endpoint verification: Name=$($endpoint.name), State=$($endpoint.state_desc), Port=$($endpoint.port)"
    
    # Create sentinel
    New-Item -Path 'C:\Windows\Temp\.hadr-endpoint-configured' -ItemType File -Force | Out-Null
    
    L "=== HADR Endpoint Setup Complete ==="
    exit 0
    
} catch {
    $errMsg = "ERROR: $_"
    Add-Content -Path $log -Value $errMsg -Force
    Write-Error $errMsg
    $_ | Out-File "C:\Windows\Temp\manual-hadr-error.txt" -Force
    exit 1
}
