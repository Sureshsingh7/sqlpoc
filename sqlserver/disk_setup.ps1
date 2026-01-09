$ErrorActionPreference = 'Stop'

$lunToSpec = @{
  0 = @{ Letter = 'F'; Label = 'DATA';   Dir = 'F:\Data' }
  1 = @{ Letter = 'G'; Label = 'LOG';    Dir = 'G:\Log' }
  2 = @{ Letter = 'T'; Label = 'TEMPDB'; Dir = 'T:\TempDB' }
}

$osDiskNums = @(Get-Disk | Where-Object { $_.IsBoot -or $_.IsSystem } | Select-Object -ExpandProperty Number)

$candidates = @(Get-CimInstance Win32_DiskDrive |
  Where-Object { $osDiskNums -notcontains [int]$_.Index -and $null -ne $_.SCSILogicalUnit } |
  ForEach-Object { [pscustomobject]@{ DiskNumber = [int]$_.Index; Lun = [int]$_.SCSILogicalUnit } } |
  Sort-Object Lun, DiskNumber)

foreach ($lun in 0, 1, 2) {
  $row = $candidates | Where-Object { $_.Lun -eq $lun } | Select-Object -First 1
  if (-not $row) { throw "No disk found for LUN $lun" }

  $spec   = $lunToSpec[$lun]
  $letter = $spec.Letter
  $label  = $spec.Label

  $disk = Get-Disk -Number $row.DiskNumber

  if ($disk.PartitionStyle -eq 'RAW') {
    Initialize-Disk -Number $row.DiskNumber -PartitionStyle GPT | Out-Null
    $p = New-Partition -DiskNumber $row.DiskNumber -UseMaximumSize -AssignDriveLetter:$false
    Set-Partition -DiskNumber $row.DiskNumber -PartitionNumber $p.PartitionNumber -NewDriveLetter $letter | Out-Null
    Format-Volume -DriveLetter $letter -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force | Out-Null
  }
  else {
    $p = Get-Partition -DiskNumber $row.DiskNumber |
      Where-Object { $_.Type -ne 'Reserved' } |
      Sort-Object Size -Descending |
      Select-Object -First 1

    if (-not $p) { throw "No usable partition found on disk $($row.DiskNumber)" }

    if ($p.DriveLetter -ne $letter) {
      Set-Partition -DiskNumber $row.DiskNumber -PartitionNumber $p.PartitionNumber -NewDriveLetter $letter | Out-Null
    }
  }

  New-Item -ItemType Directory -Path $spec.Dir -Force | Out-Null
}
