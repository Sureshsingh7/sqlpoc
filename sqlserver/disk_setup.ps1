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
  if(-not $p){
    $p=New-Partition -DiskNumber $n -UseMaximumSize -AssignDriveLetter:$false
    Set-Partition -DiskNumber $n -PartitionNumber $p.PartitionNumber -NewDriveLetter $dl|Out-Null
    Format-Volume -DriveLetter $dl -FileSystem NTFS -NewFileSystemLabel $lbl -Confirm:$false -Force|Out-Null
  } else {
    if($p.DriveLetter -ne $dl){Set-Partition -DiskNumber $n -PartitionNumber $p.PartitionNumber -NewDriveLetter $dl|Out-Null}
    $v=Get-Volume -DriveLetter $dl -ErrorAction SilentlyContinue
    if(-not $v){Format-Volume -DriveLetter $dl -FileSystem NTFS -NewFileSystemLabel $lbl -Confirm:$false -Force|Out-Null}
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
