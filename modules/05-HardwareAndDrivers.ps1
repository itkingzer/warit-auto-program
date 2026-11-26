function Get-MachineSpecs {
    $computer = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $processors = @(Get-CimInstance Win32_Processor | ForEach-Object { $_.Name.Trim() })
    $graphics = @(Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name)
    $drives = @(Get-CimInstance Win32_DiskDrive | ForEach-Object { '{0} · {1:N0} GB' -f $_.Model, ($_.Size / 1e9) })
    [pscustomobject]@{
        Model = "$($computer.Manufacturer) $($computer.Model)"
        Windows = "$($os.Caption) · Build $($os.BuildNumber) · $($os.OSArchitecture)"
        CPU = $processors -join [Environment]::NewLine
        RAM = '{0:N1} GiB' -f ($computer.TotalPhysicalMemory / 1GB)
        GPU = $graphics -join [Environment]::NewLine
        Storage = $drives -join [Environment]::NewLine
    }
}

function Get-MissingDriverDevices {
    Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode = 28' | Where-Object { $_.Present -ne $false }
}

function Invoke-DriverCheck([switch]$Install) {
    Assert-Running
    $missing = @(Get-MissingDriverDevices)
    $missingIds = @($missing | ForEach-Object { $_.HardwareID; $_.CompatibleID } | Where-Object { $_ })
    Publish DriverDevices @($missing | ForEach-Object { if ($_.Name) { $_.Name } else { $_.PNPDeviceID } })
    Write-Log 'กำลังค้นหาไดรเวอร์ผ่านแหล่ง Windows Update ของเครื่อง'
    $session = New-Object -ComObject Microsoft.Update.Session
    $result = Search-SetupUpdates $session -Online -DriversOnly
    Assert-Running
    $candidates = @(foreach ($update in $result.Updates) {
        $eligible = -not $update.InstallationBehavior.CanRequestUserInput -and
            (-not $update.BrowseOnly -or $update.DriverHardwareID -in $missingIds)
        [pscustomobject]@{ Update = $update; Eligible = $eligible }
    })
    $selected = @($candidates | Where-Object Eligible)
    $names = @($candidates | ForEach-Object {
        $badge = if ($_.Eligible) { 'พร้อมติดตั้ง' } else { 'ไม่ติดตั้งอัตโนมัติ' }
        "$badge · $($_.Update.Title)"
    })
    Publish DriverUpdates $names
    if (-not $Install) { return }
    if (-not $selected) { Write-Log 'ไม่มีไดรเวอร์ที่เข้าเงื่อนไขติดตั้งอัตโนมัติ'; return }

    $systemInfo = New-Object -ComObject Microsoft.Update.SystemInfo
    $failed = 0
    foreach ($candidate in $selected) {
        Assert-Running
        if ($systemInfo.RebootRequired) { $script:DriverRestartRequired = $true; break }
        $update = $candidate.Update
        try {
            if (-not $update.EulaAccepted) { $update.AcceptEula() }
            $collection = New-Object -ComObject Microsoft.Update.UpdateColl
            [void]$collection.Add($update)
            $downloader = $session.CreateUpdateDownloader()
            $downloader.Updates = $collection
            Write-Log "ดาวน์โหลด $($update.Title)"
            $download = Invoke-UpdateDownload $downloader $collection
            if ($download.ResultCode -ne 2) { throw ('ดาวน์โหลดไม่สำเร็จ: HRESULT {0:X8}' -f $download.GetUpdateResult(0).HResult) }
            Assert-Running
            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $collection
            $installer.AllowSourcePrompts = $false
            $installer.ForceQuiet = $true
            if ($installer.RebootRequiredBeforeInstallation) { $script:DriverRestartRequired = $true; break }
            $installResult = Invoke-UpdateInstall $installer "กำลังติดตั้ง $($update.Title)"
            if ($installResult.RebootRequired) { $script:DriverRestartRequired = $true }
            $item = $installResult.GetUpdateResult(0)
            if ($item.ResultCode -ne 2) { throw ('ติดตั้งไม่สำเร็จ: HRESULT {0:X8}' -f $item.HResult) }
            Write-Log "ติดตั้งแล้ว: $($update.Title)"
        } catch [OperationCanceledException] { throw } catch {
            $failed++
            Write-Log "$($update.Title): $($_.Exception.Message)"
        }
        if ($script:DriverRestartRequired) { break }
    }
    if ($script:DriverRestartRequired) {
        Publish DriverStatus 'ต้องรีสตาร์ทเครื่อง แล้วตรวจไดรเวอร์ใหม่เพื่อดูรายการที่เหลือ'
    } else {
        Publish DriverStatus 'สิ้นสุดการติดตั้ง กดตรวจไดรเวอร์ใหม่เพื่ออัปเดตรายการ'
    }
    if ($failed) { throw "ติดตั้งไดรเวอร์ไม่สำเร็จ $failed รายการ ดูรายละเอียดใน Log" }
}
