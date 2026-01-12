$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$log='C:\Windows\Temp\configure-sql-disks.log'
$err='C:\Windows\Temp\configure-sql-disks.err.txt'

function L([string]$m){Add-Content -Path $log -Value ((Get-Date -Format o)+" "+$m)}

function Ensure([int]$n,[string]$dl,[string]$lbl,[string]$dir){
  try{Set-Disk -Number $n -IsOffline $false -ErrorAction SilentlyContinue|Out-Null}catch{}
  try{Set-Disk -Number $n -IsReadOnly $false -ErrorAction SilentlyContinue|Out-Null}catch{}
  $d=Get-Disk -Number $n
  if($d.PartitionStyle -eq 'RAW'){Initialize-Disk -Number $n -PartitionStyle GPT|Out-Null}
  $p=Get-Partition -DiskNumber $n -ErrorAction SilentlyContinue|?{$_.Type -ne 'Reserved'}|Sort Size -Desc|Select -First 1

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
        Start-Sleep -Seconds 2
      }
      RefreshStorage
    }

    # DiskPart fallback for cases where StorageWMI flaps.
    $pp = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber -ErrorAction SilentlyContinue
    if(-not $pp -or $pp.DriveLetter -ne $letter){
      try {
        $dp = @(
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
  }

  if(-not $p){
    $p=New-Partition -DiskNumber $n -UseMaximumSize -AssignDriveLetter:$false
    EnsureLetter $n $p.PartitionNumber $dl
    if((Get-Partition -DiskNumber $n -PartitionNumber $p.PartitionNumber).DriveLetter -ne $dl){LogPartitionVolume $n $p.PartitionNumber $dl; throw "Set-Partition failed for disk $n -> ${dl}:"}
    Format-Volume -DriveLetter $dl -FileSystem NTFS -NewFileSystemLabel $lbl -Force|Out-Null
  } else {
    if($p.DriveLetter -ne $dl){
      EnsureLetter $n $p.PartitionNumber $dl
      if((Get-Partition -DiskNumber $n -PartitionNumber $p.PartitionNumber).DriveLetter -ne $dl){LogPartitionVolume $n $p.PartitionNumber $dl; throw "Set-Partition failed for disk $n -> ${dl}:"}
    }
    $v=Get-Volume -DriveLetter $dl -ErrorAction SilentlyContinue
    $needsFormat = (-not $v) -or [string]::IsNullOrWhiteSpace($v.FileSystem) -or ($v.Size -le 0)
    if($needsFormat){
      L ("format {0}: (fs='{1}' size={2})" -f $dl, ($v.FileSystem), ($v.Size))
      Format-Volume -DriveLetter $dl -FileSystem NTFS -NewFileSystemLabel $lbl -Force|Out-Null
    }
  }

  # Mount/visibility can lag behind formatting; wait and re-assert drive letter if needed.
  for($j=0;$j -lt 60;$j++){
    RefreshStorage
    $pp=Get-Partition -DiskNumber $n -PartitionNumber $p.PartitionNumber -ErrorAction SilentlyContinue
    if($pp -and $pp.DriveLetter -ne $dl){ EnsureLetter $n $p.PartitionNumber $dl }
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
  foreach($d in (gcim -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_Disk -ErrorAction SilentlyContinue)){
    if($d.IsBoot -or $d.IsSystem){continue}
    $loc=$d.Location;$lun=$null
    if($loc -match 'LUN\s*(\d+)'){$lun=[int]$Matches[1]}
    elseif($loc -match 'L(\d+)\)'){$lun=[int]$Matches[1]}
    if($lun -ne $null -and ($lun -in 0,1,2)){$m[$lun]=[int]$d.Number}
  }
  if($m.Count -lt 3){
    foreach($dd in (gcim Win32_DiskDrive -ErrorAction SilentlyContinue)){
      if($dd.Index -eq $null -or $dd.SCSILogicalUnit -eq $null){continue}
      $lun=[int]$dd.SCSILogicalUnit;$num=[int]$dd.Index
      if($lun -in 0,1,2){$m[$lun]=$num}
    }
  }
  $m
}

try{
  try{Remove-Item $log,$err -ErrorAction SilentlyContinue}catch{}
  L 'start'
  $map=@{}
  for($i=0;$i -lt 60;$i++){
    $map=GetLunMap
    if($map.ContainsKey(0) -and $map.ContainsKey(1) -and $map.ContainsKey(2)){break}
    L ("wait {0}/60 {1}/3" -f ($i+1),$map.Count); Start-Sleep -Seconds 10
  }
  foreach($lun in 0,1,2){
    if(-not $map.ContainsKey($lun)){throw "No disk for LUN $lun"}
    $n=$map[$lun];$s=$spec[$lun]
    L ("lun {0} disk {1} -> {2}:" -f $lun,$n,$s.l)
    Ensure $n $s.l $s.b $s.d
  }
  L 'ok'
  exit 0
}catch{
  $e=$_
  Add-Content -Path $err -Value ((Get-Date -Format o)+" ERROR: "+($e|Out-String))
  if($e.ScriptStackTrace){Add-Content -Path $err -Value $e.ScriptStackTrace}
  exit 1
}
