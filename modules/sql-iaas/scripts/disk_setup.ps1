param(
    [Parameter(Mandatory=$false)]
    [string[]]$NodeIPs = @(),

    [Parameter(Mandatory=$false)]
    [string[]]$NodeNames = @(),

    [Parameter(Mandatory=$false)]
    [string[]]$ClusterIPs = @(),

    [Parameter(Mandatory=$false)]
    [string]$ClusterName = "",

    [Parameter(Mandatory=$false)]
    [string]$ClusterAdminUsername = "",

    [Parameter(Mandatory=$false)]
    [string]$ClusterAdminPasswordSecure = "",

    [Parameter(Mandatory=$false)]
    [string]$PrimaryClusterDNS = "",

    [Parameter(Mandatory=$false)]
    [string]$PrimaryClusterIP = ""
)

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$log='C:\Windows\Temp\configure-sql-disks.log'
$err='C:\Windows\Temp\configure-sql-disks.err.txt'
$sentinel='C:\Windows\Temp\.disk-setup-completed'

# FAST idempotency check - if sentinel file exists, we're done
if (Test-Path $sentinel) {
    Add-Content -Path $log -Value "$(Get-Date -Format o) [OK] Disk setup already completed (sentinel file exists) - exiting"
    Write-Host "Disk setup already completed - exiting"
    exit 0
}

# Smart detection: if volumes F:, G:, T: already exist, create sentinel and exit (handles transition from old code)
try {
    $vol_f = Get-Volume -DriveLetter F -ErrorAction SilentlyContinue
    $vol_g = Get-Volume -DriveLetter G -ErrorAction SilentlyContinue
    $vol_t = Get-Volume -DriveLetter T -ErrorAction SilentlyContinue
    
    if ($vol_f -and $vol_g -and $vol_t) {
        Write-Host "Volumes F:, G:, T: already exist - creating sentinel and exiting"
        Add-Content -Path $log -Value "$(Get-Date -Format o) [OK] Volumes already configured (F:/G:/T:) - creating sentinel file and exiting"
        New-Item -Path $sentinel -ItemType File -Force | Out-Null
        exit 0
    }
} catch {
    # If volume check fails, continue with normal setup
}

# Handle comma-separated strings for array parameters (workaround for RunCommand passing single strings)
if ($NodeIPs.Count -eq 1 -and $NodeIPs[0] -like "*,*") { $NodeIPs = $NodeIPs[0] -split "," }
if ($NodeNames.Count -eq 1 -and $NodeNames[0] -like "*,*") { $NodeNames = $NodeNames[0] -split "," }
if ($ClusterIPs.Count -eq 1 -and $ClusterIPs[0] -like "*,*") { $ClusterIPs = $ClusterIPs[0] -split "," }

# Decode cluster admin password
$ClusterAdminPassword = ""
if (-not [string]::IsNullOrWhiteSpace($ClusterAdminPasswordSecure)) {
    try {
        $ClusterAdminPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($ClusterAdminPasswordSecure))
    } catch {
        $ClusterAdminPassword = $ClusterAdminPasswordSecure
    }
}

function L([string]$m){Add-Content -Path $log -Value ((Get-Date -Format o)+" "+$m)}
function LD([string]$m){L "DEBUG: $m"}
function LE([string]$m){L "ERROR: $m"}

function ConfigureVMPrerequisites {
    L "Configuring VM prerequisites"

    $hostsFile = "C:\Windows\System32\drivers\etc\hosts"
    $domainName = "sqlpoc.local"

    if ($NodeIPs.Count -gt 0 -and $NodeNames.Count -eq $NodeIPs.Count) {
        for ($i = 0; $i -lt $NodeIPs.Count; $i++) {
            $ip = $NodeIPs[$i]
            $name = $NodeNames[$i]
            $entry = "$ip`t$name.$domainName`t$name"

            if (-not (Select-String -Path $hostsFile -Pattern $name -Quiet)) {
                LD "Adding hosts entry: $entry"
                Add-Content -Path $hostsFile -Value $entry
            }
        }
    }

    LD "Setting NV Domain to $domainName"
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\services\Tcpip\Parameters" -Name "NV Domain" -Value $domainName -Force

    LD "Setting LocalAccountTokenFilterPolicy for remote admin"
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "LocalAccountTokenFilterPolicy" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null

    LD "Configuring ICMP firewall rule"
    $existingRule = netsh advfirewall firewall show rule name="Allow ICMPv4" 2>$null
    if ($LASTEXITCODE -ne 0) {
        netsh advfirewall firewall add rule name="Allow ICMPv4" protocol=icmpv4 dir=in action=allow | Out-Null
    }

    LD "Installing Failover Clustering feature"
    Import-Module ServerManager
    $feature = Get-WindowsFeature -Name Failover-Clustering -ErrorAction SilentlyContinue
    if ($null -eq $feature -or -not $feature.Installed) {
        Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools | Out-Null
        L "Failover Clustering installed"
    } else {
        LD "Failover Clustering already installed"
    }

    LD "Configuring WinRM for Workgroup Auth"
    Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction SilentlyContinue | Out-Null
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value ($NodeIPs -join ',') -Force
    Restart-Service WinRM

    LD "Creating specific WinRM Firewall rule for cluster node subnet connectivity"
    if ($NodeIPs.Count -gt 0) {
        $ruleName = "Allow_WinRM_Cluster_Nodes"
        Remove-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue

        New-NetFirewallRule -Name $ruleName `
            -DisplayName "Allow WinRM from Cluster Nodes" `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort 5985,5986 `
            -RemoteAddress $NodeIPs `
            -Profile Any `
            -ErrorAction Stop | Out-Null
        LD "Firewall rule '$ruleName' created for IPs: $($NodeIPs -join ', ')"
    }
}

function CreateClusterAdminLocal {
    L "Creating local cluster admin user '$ClusterAdminUsername' on $env:COMPUTERNAME"
    if ([string]::IsNullOrWhiteSpace($ClusterAdminUsername) -or [string]::IsNullOrWhiteSpace($ClusterAdminPassword)) {
        L "Skipping user creation (missing credentials)"
        return
    }

    try {
        $existingUser = Get-LocalUser -Name $ClusterAdminUsername -ErrorAction SilentlyContinue
        $securePassword = ConvertTo-SecureString $ClusterAdminPassword -AsPlainText -Force

        if ($existingUser) {
            LD "User '$ClusterAdminUsername' already exists locally"
            Set-LocalUser -Name $ClusterAdminUsername -Password $securePassword -ErrorAction Stop
        } else {
            New-LocalUser -Name $ClusterAdminUsername -Password $securePassword -FullName "Cluster Admin User" -Description "User for failover cluster operations" -PasswordNeverExpires -ErrorAction Stop
            L "User '$ClusterAdminUsername' created locally"
        }

        $adminGroup = Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*\$ClusterAdminUsername" }
        if (-not $adminGroup) {
            Add-LocalGroupMember -Group "Administrators" -Member $ClusterAdminUsername -ErrorAction Stop
            L "User '$ClusterAdminUsername' added to Administrators group"
        }
    } catch {
        LE "Failed to create/update local admin user: $_"
        throw
    }
}

function ConfigureHostsFile {
    if ($ClusterIPs.Count -eq 0 -or [string]::IsNullOrWhiteSpace($ClusterName)) { return }

    LD "Configuring cluster hosts file entries"
    $hostsFile = "C:\Windows\System32\drivers\etc\hosts"
    $hostsContent = Get-Content $hostsFile -Raw -ErrorAction SilentlyContinue
    if ($null -eq $hostsContent) { $hostsContent = "" }

    foreach ($clusterIP in $ClusterIPs) {
        $line = "$clusterIP`t$ClusterName"
        if ($hostsContent -notmatch [regex]::Escape($clusterIP)) {
            LD "Adding hosts entry: $line"
            Add-Content -Path $hostsFile -Value $line -Force
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($PrimaryClusterIP) -and -not [string]::IsNullOrWhiteSpace($PrimaryClusterDNS)) {
        $line = "$PrimaryClusterIP`t$PrimaryClusterDNS"
        if ($hostsContent -notmatch [regex]::Escape($PrimaryClusterIP)) {
            LD "Adding DR hosts entry: $line"
            Add-Content -Path $hostsFile -Value $line -Force
        }
    }
    ipconfig /flushdns | Out-Null
}

function Ensure([int]$n,[string]$dl,[string]$lbl,[string]$dir){
  L "Processing Disk $n for drive $dl (label: $lbl)"
  
  # Verify disk exists and is accessible
  $d = $null
  for($retry=0; $retry -lt 5; $retry++){
    try{
      Set-Disk -Number $n -IsOffline $false -ErrorAction SilentlyContinue | Out-Null
      Set-Disk -Number $n -IsReadOnly $false -ErrorAction SilentlyContinue | Out-Null
      $d = Get-Disk -Number $n -ErrorAction Stop
      if($d){
        L "Disk $n found: Size=$($d.Size) PartitionStyle=$($d.PartitionStyle) Status=$($d.OperationalStatus)"
        break
      }
    }catch{
      L "Disk $n access attempt $($retry+1)/5 failed: $_"
      Update-HostStorageCache -ErrorAction SilentlyContinue | Out-Null
      Start-Sleep -Seconds 2
    }
  }
  
  if(-not $d){
    throw "Disk $n not accessible after 5 retries"
  }
  
  if($d.PartitionStyle -eq 'RAW'){Initialize-Disk -Number $n -PartitionStyle GPT|Out-Null}
  $p=Get-Partition -DiskNumber $n -ErrorAction SilentlyContinue | Where-Object { $_.Type -ne 'Reserved' } | Sort-Object Size -Desc | Select-Object -First 1

  function RefreshStorage(){
    try { Update-HostStorageCache | Out-Null } catch {}
  }

  function LogPartitionVolume([int]$diskNumber,[int]$partitionNumber,[string]$letter){
    try {
      $pp = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber -ErrorAction SilentlyContinue
      if($pp){ L ("partition disk {0} part {1} letter={2} access={3}" -f $diskNumber,$partitionNumber,$pp.DriveLetter,($pp.AccessPaths -join ';')) }
    } catch {}
    try {
      $vv = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
      if($vv){ L ("volume {0}: fs={1} label={2} health={3} size={4}" -f $letter,$vv.FileSystem,$vv.FileSystemLabel,$vv.HealthStatus,$vv.Size) }
      else { L ("volume {0}: not found" -f $letter) }
    } catch {}
  }

  function EnsureLetter([int]$diskNumber,[int]$partitionNumber,[string]$letter){
    # Some environments have automount disabled; make sure it's enabled.
    try { cmd /c "mountvol /E" | Out-Null } catch {}

    function FreeLetter([string]$l){
      try { cmd /c "mountvol ${l}:\\ /D" 2>$null | Out-Null } catch {}
      try { cmd /c "net use ${l}: /delete /y" 2>$null | Out-Null } catch {}
      try { cmd /c "subst ${l}: /D" 2>$null | Out-Null } catch {}

      # Clear stale mount manager mappings that can cause "access path already in use"
      try {
        $regPath = 'HKLM:\SYSTEM\MountedDevices'
        $valName = "\\DosDevices\\${l}:"
        if(Test-Path $regPath){
          $props = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
          if($props -and ($props.PSObject.Properties.Name -contains $valName)){
            L ("clearing MountedDevices mapping: {0}" -f $valName)
            Remove-ItemProperty -Path $regPath -Name $valName -ErrorAction SilentlyContinue
          }
        }
      } catch {
        L ("failed to clear MountedDevices: {0}" -f ($_.Exception.Message))
      }

      # Remove stale mount points for volumes no longer present
      try { cmd /c "mountvol /R" | Out-Null } catch {}
    }

    function MountLetterToVolume([string]$l,[string]$vol){
      # $vol is like \\?\Volume{GUID}\
      FreeLetter $l
      try {
        L ("mountvol {0}: -> {1}" -f $l,$vol)
        $out = cmd /c "mountvol ${l}:\\ \"$vol\"" 2>&1
        if($out){ L ("mountvol output: {0}" -f (($out | Out-String).Trim())) }
      } catch {
        L ("mountvol failed: {0}" -f ($_.Exception.Message))
      }
      RefreshStorage
    }

    function DescribeLetter([string]$l){
      try {
        $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${l}:'" -ErrorAction SilentlyContinue
        if($ld){ L ("logicaldisk {0}: type={1} size={2} fs={3}" -f $l,$ld.DriveType,$ld.Size,$ld.FileSystem) }
        else { L ("logicaldisk {0}: not present" -f $l) }
      } catch {}
      try {
        $vol = Get-CimInstance Win32_Volume -Filter "DriveLetter='${l}:'" -ErrorAction SilentlyContinue
        if($vol){ L ("win32_volume {0}: label={1} fs={2} name={3}" -f $l,$vol.Label,$vol.FileSystem,$vol.Name) }
      } catch {}
    }

    DescribeLetter $letter

    # Proactively free the requested drive letter before trying to assign it.
    FreeLetter $letter

    # If any partition currently claims this drive letter/access path, remove it.
    try {
      $claiming = Get-Partition -ErrorAction SilentlyContinue | Where-Object {
        ($_.DriveLetter -eq $letter) -or ($_.AccessPaths -contains "${letter}:\\")
      }
      foreach($c in $claiming){
        if($c.DiskNumber -eq $diskNumber -and $c.PartitionNumber -eq $partitionNumber){ continue }
        try{ Remove-PartitionAccessPath -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber -AccessPath "${letter}:\\" -ErrorAction SilentlyContinue | Out-Null }catch{}
        try{ Set-Partition -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber -NewDriveLetter $null -ErrorAction SilentlyContinue | Out-Null }catch{}
      }
    } catch {}

    # Remove any conflicting drive letter use (both other partitions holding our target letter,
    # and our target partition holding a different letter).
    $x=Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
    if($x -and ($x.DiskNumber -ne $diskNumber -or $x.PartitionNumber -ne $partitionNumber)){
      try{Remove-PartitionAccessPath -DiskNumber $x.DiskNumber -PartitionNumber $x.PartitionNumber -AccessPath "${letter}:\\" -ErrorAction SilentlyContinue|Out-Null}catch{}
    }

    try {
      $cur = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber -ErrorAction SilentlyContinue
      if($cur){
        if($cur.DriveLetter -and $cur.DriveLetter -ne $letter){
          try{Remove-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $partitionNumber -AccessPath "${($cur.DriveLetter)}:\\" -ErrorAction SilentlyContinue|Out-Null}catch{}
        }
        foreach($ap in ($cur.AccessPaths|Where-Object {$_ -match '^[A-Z]:\\$'})){
          if($ap.Substring(0,1) -ne $letter){
            try{Remove-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $partitionNumber -AccessPath $ap -ErrorAction SilentlyContinue|Out-Null}catch{}
          }
        }
      }
    } catch {}

    for($k=0;$k -lt 20;$k++){
      try{
        Set-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber -NewDriveLetter $letter -ErrorAction Stop|Out-Null
        break
      }catch{
        L ("Set-Partition retry {0}/20 failed: {1}" -f ($k+1), ($_.Exception.Message))
        FreeLetter $letter
        Start-Sleep -Seconds 2
      }
      RefreshStorage
    }

    # DiskPart fallback for cases where StorageWMI flaps.
    $pp = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber -ErrorAction SilentlyContinue
    if(-not $pp -or $pp.DriveLetter -ne $letter){
      try {
        $dp = @(
          "select volume $letter",
          "remove letter=$letter noerr",
          "select disk $diskNumber",
          "select partition $partitionNumber",
          "assign letter=$letter noerr",
          "exit"
        ) -join "`r`n"
        $dpFile = Join-Path $env:TEMP "diskpart-assign-$diskNumber-$partitionNumber-$letter.txt"
        Set-Content -Path $dpFile -Value $dp -Encoding ASCII
        L ("diskpart assign fallback: {0}" -f $dpFile)
        cmd /c "diskpart /s \"$dpFile\"" | Out-Null
        RefreshStorage
      } catch {
        L ("diskpart fallback failed: {0}" -f ($_.Exception.Message))
      }
    }

    # Mountvol fallback: directly mount the target volume GUID to the requested drive letter.
    $pp = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber -ErrorAction SilentlyContinue
    $volGuid = $null
    try { $volGuid = ($pp.AccessPaths | Where-Object { $_ -like '\\?\Volume{*}\' } | Select-Object -First 1) } catch {}
    if($volGuid){
      MountLetterToVolume $letter $volGuid
    }

    # Success criteria: the path exists (mountvol-based mounts may not set Partition.DriveLetter).
    for($i=0;$i -lt 15 -and -not (Test-Path "${letter}:\\");$i++){
      RefreshStorage
      Start-Sleep -Seconds 1
    }
    if(Test-Path "${letter}:\\"){ return }

    DescribeLetter $letter
  }

  if(-not $p){
    $p=New-Partition -DiskNumber $n -UseMaximumSize -AssignDriveLetter:$false
    EnsureLetter $n $p.PartitionNumber $dl
    # A newly-assigned drive letter on a RAW volume may not be browseable yet (Test-Path can fail)
    # until after formatting. Use the partition object to format and then validate availability.
    LogPartitionVolume $n $p.PartitionNumber $dl
    $part = Get-Partition -DiskNumber $n -PartitionNumber $p.PartitionNumber -ErrorAction SilentlyContinue
    if($part){
      Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel $lbl -Force | Out-Null
    } else {
      Format-Volume -DriveLetter $dl -FileSystem NTFS -NewFileSystemLabel $lbl -Force | Out-Null
    }
  } else {
    if($p.DriveLetter -ne $dl){
      EnsureLetter $n $p.PartitionNumber $dl
    }
    $v=Get-Volume -DriveLetter $dl -ErrorAction SilentlyContinue
    $needsFormat = (-not $v) -or [string]::IsNullOrWhiteSpace($v.FileSystem) -or ($v.Size -le 0)
    if($needsFormat){
      L ("format {0}: (fs='{1}' size={2})" -f $dl, ($v.FileSystem), ($v.Size))
      $part = Get-Partition -DiskNumber $n -PartitionNumber $p.PartitionNumber -ErrorAction SilentlyContinue
      if($part){
        Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel $lbl -Force | Out-Null
      } else {
        Format-Volume -DriveLetter $dl -FileSystem NTFS -NewFileSystemLabel $lbl -Force | Out-Null
      }
    }
  }

  # Mount/visibility can lag behind formatting; wait and re-assert drive letter if needed.
  for($j=0;$j -lt 60;$j++){
    RefreshStorage
    $pp=Get-Partition -DiskNumber $n -PartitionNumber $p.PartitionNumber -ErrorAction SilentlyContinue
    if($pp -and -not (Test-Path "${dl}:\\")){ EnsureLetter $n $p.PartitionNumber $dl }
    if(Test-Path "${dl}:\\"){break}
    Start-Sleep -Seconds 2
  }
  if(-not (Test-Path "${dl}:\\")){
    LogPartitionVolume $n $p.PartitionNumber $dl
    throw "Drive ${dl}: missing after format"
  }
  New-Item -ItemType Directory -Path $dir -Force|Out-Null
}

$spec=@{0=@{l='F';b='DATA';d='F:\Data'};1=@{l='G';b='LOG';d='G:\Log'};2=@{l='T';b='TEMPDB';d='T:\TempDB'}}

function GetLunMap(){
  $m=@{}
  
  # Method 1: MSFT_Disk CIM (most reliable with LUN info)
  foreach($d in (Get-CimInstance -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_Disk -ErrorAction SilentlyContinue)){
    if($d.IsBoot -or $d.IsSystem){continue}
    if($null -eq $d.Number){
      LD "Skipping disk with null Number: Location=$($d.Location)"
      continue
    }
    $loc=$d.Location;$lun=$null
    if($loc -match 'LUN\s*(\d+)'){$lun=[int]$Matches[1]}
    elseif($loc -match 'L(\d+)\)'){$lun=[int]$Matches[1]}
    if($null -ne $lun -and ($lun -in 0,1,2)){
      LD "LUN $lun -> Disk $($d.Number) (MSFT_Disk)"
      $m[$lun]=[int]$d.Number
    }
  }
  
  # Method 2: Win32_DiskDrive (fallback for disks with no Number in MSFT_Disk)
  if($m.Count -lt 3){
    foreach($dd in (Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue)){
      if($null -eq $dd.Index -or $null -eq $dd.SCSILogicalUnit){continue}
      $lun=[int]$dd.SCSILogicalUnit;$num=[int]$dd.Index
      if(($lun -in 0,1,2) -and -not $m.ContainsKey($lun)){
        LD "LUN $lun -> Disk $num (Win32_DiskDrive fallback)"
        $m[$lun]=$num
      }
    }
  }
  
  $m
}

try{
  try{Remove-Item $log,$err -ErrorAction SilentlyContinue}catch{}
  L 'start'
  
  # Force storage rescan and bring all disks online before mapping LUNs
  L 'Forcing storage rescan and disk online...'
  try { Update-HostStorageCache -ErrorAction SilentlyContinue | Out-Null } catch {}
  try { 
    Get-Disk -ErrorAction SilentlyContinue | Where-Object {$_.OperationalStatus -eq 'Offline'} | ForEach-Object {
      L "Bringing disk $($_.Number) online"
      Set-Disk -Number $_.Number -IsOffline $false -ErrorAction SilentlyContinue | Out-Null
      Set-Disk -Number $_.Number -IsReadOnly $false -ErrorAction SilentlyContinue | Out-Null
    }
  } catch {
    L "Disk online check failed: $_"
  }
  Start-Sleep -Seconds 5
  
  $map=@{}
  for($i=0;$i -lt 60;$i++){
    # Rescan storage on each retry to ensure stable disk enumeration
    try { Update-HostStorageCache -ErrorAction SilentlyContinue | Out-Null } catch {}
    
    $map=GetLunMap
    if($map.ContainsKey(0) -and $map.ContainsKey(1) -and $map.ContainsKey(2)){
      L "Found all 3 LUNs: LUN0->Disk$($map[0]), LUN1->Disk$($map[1]), LUN2->Disk$($map[2])"
      break
    }
    L ("wait {0}/60 {1}/3" -f ($i+1),$map.Count); Start-Sleep -Seconds 10
  }
  foreach($lun in 0,1,2){
    if(-not $map.ContainsKey($lun)){throw "No disk for LUN $lun"}
    $n=$map[$lun];$s=$spec[$lun]
    L ("lun {0} disk {1} -> {2}:" -f $lun,$n,$s.l)
    Ensure $n $s.l $s.b $s.d
  }

  if ($NodeIPs.Count -gt 0) {
      ConfigureVMPrerequisites
      # NOTE: ConfigureHostsFile removed - using Private DNS Zone (sql.internal) with A records instead
  }
  if (-not [string]::IsNullOrWhiteSpace($ClusterAdminUsername)) {
      CreateClusterAdminLocal
  }

  # Validate all drives are accessible and writable before marking complete
  L 'Validating drive accessibility and write permissions...'
  $drives = @('F','G','T')
  foreach($drive in $drives){
    if(-not (Test-Path "${drive}:\")){
      throw "CRITICAL: Drive ${drive}: not accessible after setup"
    }
    L "Drive ${drive}: accessible"
    
    # Verify write access with test file
    try {
      $testFile = "${drive}:\test-disksetup-$(Get-Date -Format 'yyyyMMddHHmmss').tmp"
      "validation test" | Out-File $testFile -ErrorAction Stop
      Remove-Item $testFile -Force -ErrorAction Stop
      L "Drive ${drive}: write permission verified"
    } catch {
      throw "CRITICAL: Drive ${drive}: write test failed - $_"
    }
  }
  L '[OK] All drives validated successfully (accessible and writable)'

  # Create sentinel file to mark completion
  New-Item -Path $sentinel -ItemType File -Force | Out-Null
  L '[OK] Disk setup completed successfully - sentinel file created'
  
  L 'ok'
  exit 0
}catch{
  $e=$_
  Add-Content -Path $err -Value ((Get-Date -Format o)+" ERROR: "+($e|Out-String))
  if($e.ScriptStackTrace){Add-Content -Path $err -Value $e.ScriptStackTrace}
  exit 1
}