$ErrorActionPreference = 'Stop'

function Test-SsmsInstalled {
  $candidates = @(
    'C:\Program Files\Microsoft SQL Server Management Studio 20\Common7\IDE\Ssms.exe',
    'C:\Program Files (x86)\Microsoft SQL Server Management Studio 20\Common7\IDE\Ssms.exe',
    'C:\Program Files\Microsoft SQL Server Management Studio 19\Common7\IDE\Ssms.exe',
    'C:\Program Files (x86)\Microsoft SQL Server Management Studio 19\Common7\IDE\Ssms.exe'
  )
  foreach ($p in $candidates) {
    if (Test-Path $p) { return $true }
  }
  return $false
}

if (Test-SsmsInstalled) {
  Write-Host 'SSMS already installed.'
  exit 0
}

$winget = Get-Command winget -ErrorAction SilentlyContinue
if ($null -ne $winget) {
  Write-Host 'Installing SSMS via winget...'
  winget install --id Microsoft.SQLServerManagementStudio -e --accept-package-agreements --accept-source-agreements
} else {
  Write-Host 'winget not available; downloading SSMS installer...'
  $uri = 'https://aka.ms/ssmsfullsetup'
  $out = Join-Path $env:TEMP 'SSMS-Setup.exe'
  Invoke-WebRequest -Uri $uri -OutFile $out
  Write-Host 'Installing SSMS silently...'
  Start-Process -FilePath $out -ArgumentList '/install /quiet /norestart' -Wait
}

if (Test-SsmsInstalled) {
  Write-Host 'SSMS installation completed.'
  exit 0
}

Write-Warning 'SSMS install step ran but SSMS was not detected afterwards.'
exit 0
