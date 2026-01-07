param(
  [string]$VmName,
  [string]$VmIp,
  [string]$Domain
)

$hostsFile = "C:\Windows\System32\drivers\etc\hosts"
$hostEntry = "$VmIp`t$VmName.$Domain`t$VmName"

if (-not (Select-String -Path $hostsFile -Pattern $VmName -Quiet)) {
  Add-Content -Path $hostsFile -Value $hostEntry
}

Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\services\Tcpip\Parameters" -Name "NV Domain" -Value $Domain -Force
Rename-Computer -NewName $VmName -Force
Restart-Computer -Force