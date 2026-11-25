function Get-PartitionSplitSizes([uint64]$Offset, [uint64]$End, [ValidateRange(1,99)][int]$DataPercent) {
    if ($End -le $Offset) { throw 'ไม่พบพื้นที่ต่อเนื่องสำหรับการแบ่งพาร์ติชัน' }
    $capacityMiB = [math]::Floor(($End - $Offset) / 1MB)
    $dataMiB = [math]::Floor($capacityMiB * $DataPercent / 100)
    $windowsSize = [uint64](($capacityMiB - $dataMiB) * 1MB)
    $dataSize = [uint64]($dataMiB * 1MB)
    if ($windowsSize -lt 1GB -or $dataSize -lt 1GB) { throw 'Windows และ Data ต้องมีพื้นที่อย่างน้อยพาร์ติชันละ 1 GiB' }
    [pscustomobject]@{ WindowsSize = $windowsSize; DataSize = $dataSize; DataOffset = [uint64]($Offset + $windowsSize) }
}

function Invoke-DiskAndData {
    param([Parameter(Mandatory)][ValidateRange(1,99)][int]$DataPercent)
    # จำกัดการแบ่งพาร์ติชันไว้ที่ดิสก์ของ Windows ปัจจุบัน
    $os = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':'))
    $disk = Get-Disk -Number $os.DiskNumber
    $source = Join-Path $Root 'payloads\ใส่ให้ลูกค้า'
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "ไม่พบ $source" }
    $data = @(Get-Partition -DiskNumber $disk.Number | Where-Object {
        $volume = $_ | Get-Volume -ErrorAction SilentlyContinue
        $volume -and $volume.FileSystemLabel -eq 'Data'
    })
    if ($data.Count -gt 1) { throw 'พบ Volume ชื่อ Data มากกว่าหนึ่งรายการบนดิสก์ Windows' }
    if ($data.Count -eq 1) {
        if ($data[0].PartitionNumber -eq $os.PartitionNumber -or -not $data[0].DriveLetter) {
            throw 'Volume Data ต้องเป็นพาร์ติชันแยกที่มีอักษรไดรฟ์'
        }
        $partition = $data[0]
    } else {
        if ($disk.IsOffline -or $disk.IsReadOnly -or $disk.PartitionStyle -notin @('GPT','MBR')) {
            throw 'ดิสก์ Windows ไม่รองรับการแบ่งพาร์ติชันจากโปรแกรมนี้'
        }
        $next = Get-Partition -DiskNumber $disk.Number | Where-Object Offset -gt $os.Offset |
            Sort-Object Offset | Select-Object -First 1
        $end = if ($next) { $next.Offset } else { $disk.Size - 1MB }
        $plan = Get-PartitionSplitSizes -Offset $os.Offset -End $end -DataPercent $DataPercent
        $target = $plan.WindowsSize
        $limit = Get-PartitionSupportedSize -DriveLetter $os.DriveLetter
        if ($os.Size -lt $target -or $target -lt $limit.SizeMin -or $target -gt $limit.SizeMax) {
            throw ('แบ่งตามสัดส่วนนี้ไม่ได้: Windows ต้องเหลือ {0:N1} GiB และย่อได้ต่ำสุด {1:N1} GiB แอปจะไม่ขยายพาร์ติชัน Windows' -f ($target / 1GB), ($limit.SizeMin / 1GB))
        }
        Assert-Running
        Write-Log ('สัดส่วนที่ยืนยัน: Windows {0}% · Data {1}%' -f (100 - $DataPercent), $DataPercent)
        if ($os.Size -gt $target) {
            Write-Log "ย่อ $($os.DriveLetter): เป็น $target ไบต์"
            Resize-Partition -DriveLetter $os.DriveLetter -Size $target
        }
        Write-Log "สร้าง Data ขนาด $($plan.DataSize) ไบต์"
        try {
            $partition = New-Partition -DiskNumber $disk.Number -Offset $plan.DataOffset -Size $plan.DataSize -AssignDriveLetter
        } catch {
            throw "ย่อ Windows สำเร็จ แต่สร้าง Data ไม่สำเร็จ ให้ตรวจ Disk Management ก่อนลองอีกครั้ง: $_"
        }
        try {
            $partition | Format-Volume -FileSystem NTFS -NewFileSystemLabel Data -Confirm:$false | Out-Null
        } catch {
            throw "สร้างพาร์ติชันแล้ว แต่ฟอร์แมตไม่สำเร็จ ให้ตรวจ Disk Management: $_"
        }
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
    Write-Log "ตรวจสำเนา Data แล้ว $count ไฟล์ รวม $bytes ไบต์ ที่ $destination"
}
