$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$logPath = 'C:\Windows\Temp\configure-sql-disks.log'
$errPath = 'C:\Windows\Temp\configure-sql-disks.err.txt'
$transcriptPath = 'C:\Windows\Temp\configure-sql-disks.transcript.txt'

function Write-Log([string]$message) {
  $line = "{0} {1}" -f (Get-Date -Format o), $message
  Add-Content -Path $logPath -Value $line
}

function Get-LunFromLocation([string]$location) {
  if ([string]::IsNullOrWhiteSpace($location)) { return $null }

  $m = [regex]::Match($location, 'LUN\s*(\d+)', 'IgnoreCase')
  if ($m.Success) { return [int]$m.Groups[1].Value }

  # Common Windows Storage location format includes ...SCSI(...L00)
  $m2 = [regex]::Match($location, 'SCSI\([^\)]*L(\d+)\)', 'IgnoreCase')
  if ($m2.Success) { return [int]$m2.Groups[1].Value }

  return $null
}

function Ensure-Drive([int]$diskNumber, [string]$letter, [string]$label, [string]$dirPath) {
  $disk = Get-Disk -Number $diskNumber

  if ($disk.PartitionStyle -eq 'RAW') {
    Initialize-Disk -Number $diskNumber -PartitionStyle GPT | Out-Null
    $p = New-Partition -DiskNumber $diskNumber -UseMaximumSize -AssignDriveLetter:$false
    Set-Partition -DiskNumber $diskNumber -PartitionNumber $p.PartitionNumber -NewDriveLetter $letter | Out-Null
    Format-Volume -DriveLetter $letter -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force | Out-Null
  }
  else {
    $p = Get-Partition -DiskNumber $diskNumber |
      Where-Object { $_.Type -ne 'Reserved' } |
      Sort-Object Size -Descending |
      Select-Object -First 1

    if (-not $p) { throw "No usable partition found on disk $diskNumber" }

    if ($p.DriveLetter -ne $letter) {
      Set-Partition -DiskNumber $diskNumber -PartitionNumber $p.PartitionNumber -NewDriveLetter $letter | Out-Null
    }
  }

  New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
}

$lunToSpec = @{
  0 = @{ Letter = 'F'; Label = 'DATA';   Dir = 'F:\Data' }
  1 = @{ Letter = 'G'; Label = 'LOG';    Dir = 'G:\Log' }
  2 = @{ Letter = 'T'; Label = 'TEMPDB'; Dir = 'T:\TempDB' }
}

try {
  Start-Transcript -Path $transcriptPath -Force | Out-Null
  Write-Log "Starting disk configuration"

  $candidates = $null
  for ($i = 0; $i -lt 30; $i++) {
    $disks = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem })
    $candidates = @(
      foreach ($d in $disks) {
        $lun = Get-LunFromLocation -location $d.Location
        if ($null -ne $lun) {
          [pscustomobject]@{ DiskNumber = [int]$d.Number; Lun = [int]$lun; Location = $d.Location; PartitionStyle = $d.PartitionStyle; OperationalStatus = ($d.OperationalStatus -join ',') }
        }
      }
    )

    $ready = @($candidates | Where-Object { $_.Lun -in 0, 1, 2 })
    if ($ready.Count -ge 3) { break }

    Write-Log ("Waiting for data disks... found {0} candidates; retry {1}/30" -f $ready.Count, ($i + 1))
    Start-Sleep -Seconds 10
  }

  Write-Log "Detected candidate disks:" 
  ($candidates | Sort-Object Lun, DiskNumber | Format-Table -AutoSize | Out-String) | Add-Content -Path $logPath

  foreach ($lun in 0, 1, 2) {
    $row = $candidates | Where-Object { $_.Lun -eq $lun } | Select-Object -First 1
    if (-not $row) { throw "No disk found for LUN $lun" }

    $spec = $lunToSpec[$lun]
    Write-Log ("Configuring LUN {0} -> Disk {1} -> {2}: ({3})" -f $lun, $row.DiskNumber, $spec.Letter, $row.Location)
    Ensure-Drive -diskNumber $row.DiskNumber -letter $spec.Letter -label $spec.Label -dirPath $spec.Dir
  }

  Write-Log "OK"
  exit 0
}
catch {
  $msg = $_ | Out-String
  Add-Content -Path $errPath -Value ("{0} ERROR: {1}" -f (Get-Date -Format o), $msg)
  exit 1
}
finally {
  try { Stop-Transcript | Out-Null } catch {}
}
