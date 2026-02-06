# Extract and upload node 1's HADR certificate to Key Vault
$ErrorActionPreference = 'Stop'

try {
    Write-Host "=== Uploading Node 1 Certificate to Key Vault ==="
    
    $nodeName = $env:COMPUTERNAME
    $kvName = "kv-fnz-poc-se"
    
    # Install Az.KeyVault
    if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
        Install-Module -Name Az.KeyVault -Force -AllowClobber -Scope AllUsers -Repository PSGallery
    }
    Import-Module Az.KeyVault -Force
    
    # Connect to Azure
    Connect-AzAccount -Identity | Out-Null
    Write-Host "Connected to Azure"
    
    # Find the certificate in LocalMachine\My store
    $certs = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -like "*$nodeName*HADR*" -or $_.DnsNameList -like "*$nodeName*HADR*" }
    
    if ($certs.Count -eq 0) {
        Write-Host "No HADR certificate found in certificate store"
        Write-Host "Listing all certificates:"
        Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, Thumbprint, DnsNameList | Format-Table
        exit 1
    }
    
    $cert = $certs[0]
    Write-Host "Found certificate: Subject=$($cert.Subject), Thumbprint=$($cert.Thumbprint)"
    
    # Export to Base64
    $certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $certBase64 = [System.Convert]::ToBase64String($certBytes)
    
    # Upload to Key Vault
    $secretName = "$nodeName-HADR-Cert"
    Write-Host "Uploading to Key Vault as: $secretName"
    
    $secureString = ConvertTo-SecureString -String $certBase64 -AsPlainText -Force
    Set-AzKeyVaultSecret -VaultName $kvName -Name $secretName -SecretValue $secureString | Out-Null
    
    Write-Host "SUCCESS: Certificate uploaded to Key Vault"
    exit 0
    
} catch {
    Write-Error "ERROR: $_"
    exit 1
}
