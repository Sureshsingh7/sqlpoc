param(
  [Parameter(Mandatory=$true)][string]$ClusterName,
  [Parameter(Mandatory=$true)][string]$PrimaryName,
  [Parameter(Mandatory=$true)][string]$SecondaryName,
  [Parameter(Mandatory=$true)][string]$WitnessStorageAccountName,
  [Parameter(Mandatory=$true)][string]$WitnessStorageAccountKeyB64
)

$ErrorActionPreference = 'Stop'

Import-Module FailoverClusters

function Cluster-Exists {
  param([string]$Name)
  try {
    $null = Get-Cluster -Name $Name -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

if (-not (Cluster-Exists -Name $ClusterName)) {
  Write-Host "Creating workgroup cluster '$ClusterName'..."
  # AD-less cluster; no computer object / cluster DNS name required.
  New-Cluster -Name $ClusterName -Node $PrimaryName,$SecondaryName -NoStorage -Force -AdministrativeAccessPoint None | Out-Null

  # Give the cluster a moment to settle
  Start-Sleep -Seconds 20
}

Write-Host 'Configuring Cloud Witness quorum...'
$witnessKey = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($WitnessStorageAccountKeyB64))
Set-ClusterQuorum -CloudWitness -AccountName $WitnessStorageAccountName -AccessKey $witnessKey

Write-Host 'Cluster create/quorum complete.'
