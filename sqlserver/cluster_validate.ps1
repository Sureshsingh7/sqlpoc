param(
  [Parameter(Mandatory=$true)][string]$ClusterName,
  [Parameter(Mandatory=$true)][string]$PrimaryName,
  [Parameter(Mandatory=$true)][string]$SecondaryName
)

$ErrorActionPreference = 'Stop'

Import-Module FailoverClusters

Write-Host "Validating cluster: $ClusterName"

$cluster = Get-Cluster -Name $ClusterName -ErrorAction Stop
Write-Host "Cluster found: $($cluster.Name)"

$nodes = Get-ClusterNode -Cluster $ClusterName | Sort-Object Name
$nodeNames = $nodes.Name -join ', '
Write-Host "Nodes: $nodeNames"

$expected = @($PrimaryName, $SecondaryName)
foreach ($n in $expected) {
  if (-not ($nodes.Name -contains $n)) {
    throw "Expected cluster node '$n' not found. Found: $nodeNames"
  }
}

$down = $nodes | Where-Object { $_.State -ne 'Up' }
if ($down) {
  $downList = ($down | ForEach-Object { "$($_.Name)=$($_.State)" }) -join '; '
  throw "One or more cluster nodes not Up: $downList"
}

$quorum = Get-ClusterQuorum -Cluster $ClusterName
Write-Host ("QuorumType: {0}" -f $quorum.QuorumType)
Write-Host ("QuorumResource: {0}" -f $quorum.QuorumResource)

# Cloud Witness typically results in NodeAndCloudMajority; be tolerant but require cloud witness presence.
$qt = [string]$quorum.QuorumType
if ($qt -notmatch 'Cloud') {
  throw "QuorumType does not indicate Cloud Witness. QuorumType='$qt'"
}

Write-Host 'Cluster groups:'
Get-ClusterGroup -Cluster $ClusterName | Sort-Object Name | Format-Table -AutoSize | Out-String | Write-Host

Write-Host 'Cluster resources (non-Online):'
$badResources = Get-ClusterResource -Cluster $ClusterName | Where-Object { $_.State -ne 'Online' }
if ($badResources) {
  $badResources | Sort-Object Name | Format-Table -AutoSize | Out-String | Write-Host
  throw 'One or more cluster resources are not Online.'
}

Write-Host 'WSFC validation OK.'
