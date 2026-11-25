function Clear-UpdateResume {
    if ((Test-Path -LiteralPath $StatePath) -and
        (Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json).Mode -eq 'UpdateLoop') {
        $boot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
        Save-UpdateState @{ Mode = 'Idle'; UpdateBoot = $boot.ToUniversalTime().Ticks.ToString() }
    }
    $task = Get-ScheduledTask -TaskName $ResumeTask -ErrorAction SilentlyContinue
    if ($task) { Unregister-ScheduledTask -InputObject $task -Confirm:$false }
}

function Save-UpdateRestart([switch]$AutoRestart) {
    Assert-Running
    # ใช้บัญชีเดิมและเปิดหน้าต่างเมื่อบัญชีนั้นเข้าสู่ระบบหลังรีสตาร์ท
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $launcher = Join-Path $Root 'Start-AutoSetup.vbs'
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument ('"{0}" -ResumeOnly' -f $launcher) -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $ResumeTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Save-UpdateState @{ Mode = 'UpdateLoop'; AutoRestart = [bool]$AutoRestart }
    Write-Log 'บันทึกสถานะสำหรับทำ Windows Update ต่อหลังรีสตาร์ทแล้ว'
    $script:UpdateRestartPending = $true
}

function Save-UpdateState([hashtable]$State) {
    $temp = "$StatePath.tmp"
    try {
        [IO.File]::WriteAllText($temp, ($State | ConvertTo-Json))
        if ([IO.File]::Exists($StatePath)) {
            [IO.File]::Replace($temp, $StatePath, [NullString]::Value)
        }
        else { [IO.File]::Move($temp, $StatePath) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Invoke-WindowsUpdateLoop([switch]$AutoRestart) {
    # เลือกอัปเดตที่แหล่ง Windows Update ของเครื่องเสนอและยังไม่ได้ติดตั้ง
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.Online = $true
    $seen = @{}
    while ($true) {
        Assert-Running
        $systemInfo = New-Object -ComObject Microsoft.Update.SystemInfo
        if ($systemInfo.RebootRequired) { Save-UpdateRestart -AutoRestart:$AutoRestart; return }
        Write-Log 'กำลังค้นหา Windows Update รวมอัปเดตเสริมและไดรเวอร์'
        $search = $searcher.Search('(IsInstalled=0 and IsHidden=0 and BrowseOnly=0) or (IsInstalled=0 and IsHidden=0 and BrowseOnly=1)')
        if ($search.ResultCode -ne 2) { throw "ค้นหา Windows Update ไม่สำเร็จ (ResultCode $($search.ResultCode))" }
        Assert-Running
        if ($search.Updates.Count -eq 0) {
            Clear-UpdateResume
            Write-Log 'ไม่มี Windows Update ที่เข้าเงื่อนไขเหลือแล้ว'
            return
        }
        $updates = New-Object -ComObject Microsoft.Update.UpdateColl
        # แยกอัปเดตที่ WUA กำหนดให้ลงทีละตัวออกจากชุดรวม
        $exclusive = $false
        foreach ($update in $search.Updates) {
            $isExclusive = $update.InstallationBehavior.Impact -eq 2
            if ($update.InstallationBehavior.CanRequestUserInput -or ($isExclusive -and $updates.Count -gt 0) -or $exclusive) { continue }
            $key = "$($update.Identity.UpdateID)/$($update.Identity.RevisionNumber)"
            if ($seen.ContainsKey($key)) { throw "Windows Update เสนอรายการเดิมหลังติดตั้ง: $($update.Title)" }
            $seen[$key] = $true
            if (-not $update.EulaAccepted) { $update.AcceptEula() }
            [void]$updates.Add($update)
            $exclusive = $isExclusive
            Write-Log "เลือกอัปเดต $($update.Title)"
        }
        if ($updates.Count -eq 0) { throw 'อัปเดตที่เหลือต้องการการโต้ตอบจากผู้ใช้' }
        $download = $session.CreateUpdateDownloader()
        $download.Updates = $updates
        Write-Log "กำลังดาวน์โหลด $($updates.Count) รายการ"
        Assert-Running
        # Run the synchronous WUA download on the setup worker.
        $downloadResult = $download.Download()
        Assert-Running
        if ($downloadResult.ResultCode -ne 2) {
            for ($i = 0; $i -lt $updates.Count; $i++) {
                Write-Log ('ดาวน์โหลด {0} HRESULT {1:X8}' -f $updates.Item($i).Title, $downloadResult.GetUpdateResult($i).HResult)
            }
            throw "ดาวน์โหลด Windows Update ไม่สำเร็จ (ResultCode $($downloadResult.ResultCode))"
        }
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $updates
        $installer.AllowSourcePrompts = $false
        $installer.ForceQuiet = $true
        if ($installer.RebootRequiredBeforeInstallation) { Save-UpdateRestart -AutoRestart:$AutoRestart; return }
        Write-Log 'กำลังติดตั้ง Windows Update'
        $result = $installer.Install()
        for ($i = 0; $i -lt $updates.Count; $i++) {
            $item = $result.GetUpdateResult($i)
            Write-Log ('{0} ResultCode {1}, HRESULT {2:X8}' -f $updates.Item($i).Title,$item.ResultCode,$item.HResult)
        }
        Assert-Running
        if ($result.RebootRequired) { Save-UpdateRestart -AutoRestart:$AutoRestart; return }
        if ($result.ResultCode -ne 2) { throw "ติดตั้ง Windows Update ไม่สำเร็จ (ResultCode $($result.ResultCode))" }
    }
}
