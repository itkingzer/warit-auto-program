function Get-PartitionSplitSizes([uint64]$Offset, [uint64]$End, [ValidateRange(1,99)][int]$DataPercent) {
    if ($End -le $Offset) { throw 'ไม่พบพื้นที่ต่อเนื่องสำหรับการแบ่งพาร์ติชัน' }
    $capacityMiB = [math]::Floor(($End - $Offset) / 1MB)
    $dataMiB = [math]::Floor($capacityMiB * $DataPercent / 100)
    $windowsSize = [uint64](($capacityMiB - $dataMiB) * 1MB)
    $dataSize = [uint64]($dataMiB * 1MB)
    if ($windowsSize -lt 1GB -or $dataSize -lt 1GB) { throw 'Windows และ Data ต้องมีพื้นที่อย่างน้อยพาร์ติชันละ 1 GiB' }
    [pscustomobject]@{ WindowsSize = $windowsSize; DataSize = $dataSize; DataOffset = [uint64]($Offset + $windowsSize) }
}

function Save-DataPartitionPlan([string]$Path, [hashtable]$Plan) {
    $temporary = "$Path.tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Plan | ConvertTo-Json))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Get-DataPartitionId($Partition) {
    if ($Partition.Guid -and [guid]$Partition.Guid -ne [guid]::Empty) { return [string]$Partition.Guid }
    return [string]$Partition.ObjectId
}

function Invoke-DiskAndData {
    param([Parameter(Mandatory)][ValidateRange(1,99)][int]$DataPercent)
    # จำกัดการแบ่งพาร์ติชันไว้ที่ดิสก์ของ Windows ปัจจุบัน
    $os = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':'))
    $disk = Get-Disk -Number $os.DiskNumber
    $source = Join-Path $Root 'payloads\ใส่ให้ลูกค้า'
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "ไม่พบ $source" }
    $planDirectory = Join-Path $env:ProgramData 'WaritAutoSetup'
    $planPath = Join-Path $planDirectory 'data-partition.json'
    $saved = if (Test-Path -LiteralPath $planPath -PathType Leaf) {
        Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    if ($saved -and ($saved.DiskId -ne $disk.UniqueId -or $saved.WindowsOffset -ne $os.Offset)) {
        throw "แผน Data ที่ค้างไว้เป็นของดิสก์อื่น ตรวจ $planPath ก่อนดำเนินการ"
    }
    $partitions = @(Get-Partition -DiskNumber $disk.Number)
    $data = @($partitions | Where-Object {
        $volume = $_ | Get-Volume -ErrorAction SilentlyContinue
        $volume -and $volume.FileSystemLabel -eq 'Data'
    })
    if ($data.Count -gt 1) { throw 'พบ Volume ชื่อ Data มากกว่าหนึ่งรายการบนดิสก์ Windows' }
    if ($data.Count -eq 1) {
        if ($data[0].PartitionNumber -eq $os.PartitionNumber -or -not $data[0].DriveLetter) {
            throw 'Volume Data ต้องเป็นพาร์ติชันแยกที่มีอักษรไดรฟ์'
        }
        if ($saved -and (-not $saved.DataId -or $saved.DataId -ne (Get-DataPartitionId $data[0]) -or
            $saved.DataOffset -ne $data[0].Offset -or $saved.DataSize -ne $data[0].Size)) {
            throw 'พบ Volume Data แต่ไม่ตรงกับแผนที่ค้างไว้ ให้ตรวจ Disk Management'
        }
        $partition = $data[0]
    } else {
        if ($disk.IsOffline -or $disk.IsReadOnly -or -not $disk.UniqueId -or $disk.PartitionStyle -notin @('GPT','MBR')) {
            throw 'ดิสก์ Windows ไม่รองรับการแบ่งพาร์ติชันจากโปรแกรมนี้'
        }
        if ($saved) {
            $plan = @{
                DiskId = $saved.DiskId; WindowsOffset = [uint64]$saved.WindowsOffset
                WindowsOriginalSize = [uint64]$saved.WindowsOriginalSize; WindowsSize = [uint64]$saved.WindowsSize
                DataOffset = [uint64]$saved.DataOffset; DataSize = [uint64]$saved.DataSize; DataId = $saved.DataId
            }
            if ($os.Size -notin @($plan.WindowsOriginalSize, $plan.WindowsSize) -or
                $plan.WindowsSize -lt 1GB -or $plan.DataSize -lt 1GB -or
                $plan.DataOffset -ne ($os.Offset + $plan.WindowsSize) -or $plan.DataOffset + $plan.DataSize -gt $disk.Size) {
                throw 'ตำแหน่งหรือขนาดพาร์ติชัน Windows ไม่ตรงกับแผน Data ที่ค้างไว้ ให้ตรวจ Disk Management'
            }
            Write-Log "ทำแผน Data เดิมต่อ ขนาด Windows $($plan.WindowsSize) และ Data $($plan.DataSize) ไบต์"
        } else {
            $next = $partitions | Where-Object Offset -gt $os.Offset | Sort-Object Offset | Select-Object -First 1
            $end = if ($next) { $next.Offset } else { $disk.Size - 1MB }
            $sizes = Get-PartitionSplitSizes -Offset $os.Offset -End $end -DataPercent $DataPercent
            $plan = @{
                DiskId = $disk.UniqueId; WindowsOffset = $os.Offset; WindowsOriginalSize = $os.Size
                WindowsSize = $sizes.WindowsSize; DataOffset = $sizes.DataOffset; DataSize = $sizes.DataSize; DataId = $null
            }
        }
        $target = $plan.WindowsSize
        $partition = $partitions | Where-Object {
            $_.PartitionNumber -ne $os.PartitionNumber -and $_.Offset -lt ($plan.DataOffset + $plan.DataSize) -and
            ($_.Offset + $_.Size) -gt $plan.DataOffset
        }
        if ($partition -or $plan.DataId) {
            if (@($partition | Where-Object { $_ }).Count -ne 1 -or -not $plan.DataId -or
                (Get-DataPartitionId $partition) -ne $plan.DataId -or $partition.Offset -ne $plan.DataOffset -or
                $partition.Size -ne $plan.DataSize -or $os.Size -ne $target) {
                throw 'พบพาร์ติชันที่ไม่ตรงกับแผน Data ที่ค้างไว้ ให้ตรวจ Disk Management'
            }
        } else {
            $limit = Get-PartitionSupportedSize -DriveLetter $os.DriveLetter
            if ($os.Size -lt $target -or $target -lt $limit.SizeMin -or $target -gt $limit.SizeMax) {
                throw ('แบ่งตามสัดส่วนนี้ไม่ได้: Windows ต้องเหลือ {0:N1} GiB และย่อได้ต่ำสุด {1:N1} GiB' -f ($target / 1GB), ($limit.SizeMin / 1GB))
            }
            Assert-Running
            New-Item -ItemType Directory -Path $planDirectory -Force | Out-Null
            Save-DataPartitionPlan $planPath $plan
            if ($os.Size -gt $target) {
                Resize-Partition -DriveLetter $os.DriveLetter -Size $target
                Write-Log "ย่อ $($os.DriveLetter): เป็น $target ไบต์แล้ว"
            }
            Assert-Running
            $partition = New-Partition -DiskNumber $disk.Number -Offset $plan.DataOffset -Size $plan.DataSize -AssignDriveLetter
            if (-not (Get-DataPartitionId $partition) -or $partition.Offset -ne $plan.DataOffset -or $partition.Size -ne $plan.DataSize) {
                throw 'สร้างพาร์ติชันแล้ว แต่ตรวจยืนยันตัวตนหรือขนาดไม่ได้ ให้ตรวจ Disk Management'
            }
            $plan.DataId = Get-DataPartitionId $partition
            Save-DataPartitionPlan $planPath $plan
            Write-Log "สร้างพาร์ติชัน Data $($partition.PartitionNumber) แล้ว"
        }
        Assert-Running
        $volume = $partition | Get-Volume -ErrorAction Stop
        if (-not $partition.DriveLetter -or -not $volume -or [string]$volume.FileSystemType -notin @('Unknown','RAW')) {
            throw 'พาร์ติชันที่ค้างไว้ไม่ได้อยู่ในสถานะ RAW หรือไม่มีอักษรไดรฟ์ ให้ตรวจ Disk Management'
        }
        $partition | Format-Volume -FileSystem NTFS -NewFileSystemLabel Data -Confirm:$false | Out-Null
        Write-Log 'ฟอร์แมต Data เป็น NTFS แล้ว'
    }

    Assert-Running
    $destination = Join-Path ('{0}:\' -f $partition.DriveLetter) (Split-Path $source -Leaf)
    Invoke-Program -File "$env:SystemRoot\System32\robocopy.exe" -Arguments ('"{0}" "{1}" /E /XJ /IM /R:2 /W:2 /NP /XF .gitkeep' -f $source,$destination) -Timeout 7200 -SuccessCodes (0..7)
    # นับเฉพาะรายการต้นทางและยืนยันขนาดของทุกไฟล์ที่ปลายทาง
    $count = 0L
    $bytes = 0L
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($source)
    while ($pending.Count) {
        Assert-Running
        foreach ($item in Get-ChildItem -LiteralPath ($pending.Pop()) -Force) {
            if ($item.Name -eq '.gitkeep' -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            $copy = Get-Item -LiteralPath (Join-Path $destination $item.FullName.Substring($source.Length + 1))
            if ($copy.PSIsContainer -or $copy.Length -ne $item.Length) { throw "ขนาดไฟล์ไม่ตรง: $($item.FullName)" }
            $count++
            $bytes += $item.Length
        }
    }
    if (Test-Path -LiteralPath $planPath -PathType Leaf) { Remove-Item -LiteralPath $planPath -ErrorAction Stop }
    Write-Log "ตรวจสำเนา Data แล้ว $count ไฟล์ รวม $bytes ไบต์ ที่ $destination"
}
