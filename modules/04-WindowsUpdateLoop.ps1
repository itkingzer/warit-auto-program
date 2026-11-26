function Clear-UpdateResume {
    if ((Test-Path -LiteralPath $StatePath) -and
        (Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json).Mode -eq 'UpdateLoop') {
        Save-UpdateState @{ Mode = 'Idle' }
    }
    $task = Get-ScheduledTask -TaskName $ResumeTask -ErrorAction SilentlyContinue
    if ($task) { Unregister-ScheduledTask -InputObject $task -Confirm:$false }
}

function Save-UpdateRestart([object[]]$UpdateList, [hashtable]$Processed, [string]$Reason) {
    Assert-Running
    Write-Log "ต้องรีสตาร์ท Windows | $Reason | เหลือ $($UpdateList.Count) รายการในรอบนี้"
    $boot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    $bootId = $boot.ToUniversalTime().Ticks.ToString()
    $next = $UpdateList | Select-Object -First 1
    $restartKey = "$Reason|$($UpdateList.Count)|$($next.Key)"
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        $previous = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($previous.Mode -eq 'UpdateLoop' -and $previous.RestartKey -eq $restartKey -and
            ($previous.RestartFromBoot -ne $bootId -or $previous.AutoRestartBlocked -eq $true)) {
            $script:UpdateAutoRestartBlocked = $true
            Write-Log 'Windows ขอรีสตาร์ทซ้ำโดยคิวไม่เดินหน้า ระงับการรีสตาร์ทอัตโนมัติรอบนี้'
        }
    }
    # ใช้บัญชีเดิมและเปิดหน้าต่างเมื่อบัญชีนั้นเข้าสู่ระบบหลังรีสตาร์ท
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($HostedExe) {
        $action = New-ScheduledTaskAction -Execute $HostedExe -Argument '-ResumeOnly' -WorkingDirectory (Split-Path -Parent $HostedExe)
    } else {
        $launcher = Join-Path $Root 'Start-AutoSetup.vbs'
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument ('"{0}" -ResumeOnly' -f $launcher) -WorkingDirectory $Root
    }
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $ResumeTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Save-UpdateState @{
        Mode = 'UpdateLoop'
        RestartFromBoot = $bootId
        RestartKey = $restartKey
        AutoRestartBlocked = [bool]$script:UpdateAutoRestartBlocked
        UpdateList = @($UpdateList)
        ProcessedUpdateKeys = @($Processed.Keys)
        UpdateFailures = @($Processed.GetEnumerator() | Where-Object { $_.Value -is [string] } |
            ForEach-Object { @{ Key = $_.Key; Message = $_.Value } })
    }
    Write-Log 'บันทึกคิวแล้ว เมื่อเข้าบัญชีเดิมหลังรีสตาร์ทจะทำรายการที่เหลือและตรวจอัปเดตต่อ'
    $script:UpdateRestartPending = $true
}

function Save-UpdateState([hashtable]$State) {
    $temp = "$StatePath.tmp"
    try {
        [IO.File]::WriteAllText($temp, ($State | ConvertTo-Json -Depth 5))
        if ([IO.File]::Exists($StatePath)) {
            [IO.File]::Replace($temp, $StatePath, [NullString]::Value)
        }
        else { [IO.File]::Move($temp, $StatePath) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function New-UpdateCallback {
    if (-not ('Warit.UpdateDownloadCallback' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;

namespace Warit {
    [ComVisible(true), InterfaceType(ComInterfaceType.InterfaceIsIDispatch)]
    public interface IUpdateDownloadCallback {
        [DispId(0)]
        void Invoke([MarshalAs(UnmanagedType.IDispatch)] object job,
                    [MarshalAs(UnmanagedType.IDispatch)] object args);
    }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None),
     ComDefaultInterface(typeof(IUpdateDownloadCallback))]
    public sealed class UpdateDownloadCallback : IUpdateDownloadCallback {
        public void Invoke(object job, object args) { }
    }
}
'@
    }
    return [Warit.UpdateDownloadCallback]::new()
}

function Publish-UpdateItem($Item, [string]$Status, [switch]$Active) {
    Publish UpdateItem @{ Key = $Item.Key; Title = $Item.Title; Status = $Status; Active = [bool]$Active }
}

function Invoke-UpdateDownload($Downloader, $Updates, $UpdateItem) {
    $callback = New-UpdateCallback
    $percentages = @{}
    for ($i = 0; $i -lt $Updates.Count; $i++) {
        $percentages[$i] = 0
        Write-Log "ดาวน์โหลด 0% — $($Updates.Item($i).Title)"
    }
    $job = $Downloader.BeginDownload($callback, $callback, '')
    if ($null -eq $job) { throw 'Windows Update ไม่คืนงานดาวน์โหลด' }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $idle = [Diagnostics.Stopwatch]::StartNew()
    $lastBytes = $null
    try {
        while (-not $job.IsCompleted) {
            Assert-Running
            if ($timer.Elapsed.TotalSeconds -ge 2700) { throw "Windows Update หมดเวลารอดาวน์โหลด (45 นาที)" }
            if ($idle.Elapsed.TotalSeconds -ge 600) { throw 'ดาวน์โหลด Windows Update ไม่มีความคืบหน้า 10 นาที' }
            $progress = $job.GetProgress()
            if ($null -eq $progress) { Start-Sleep -Milliseconds 500; continue }
            $bytes = $progress.TotalBytesDownloaded
            if ($bytes -ne $lastBytes) {
                $lastBytes = $bytes
                $idle.Restart()
            }
            $index = [int]$progress.CurrentUpdateIndex
            $percent = [int]$progress.CurrentUpdatePercentComplete
            if ($percentages.ContainsKey($index) -and $percent -gt $percentages[$index] -and $percent -lt 100) {
                $percentages[$index] = $percent
                $idle.Restart()
                Write-Log "ดาวน์โหลด $percent% — $($Updates.Item($index).Title)"
                if ($UpdateItem) { Publish-UpdateItem $UpdateItem "กำลังดาวน์โหลด $percent%" -Active }
            }
            Start-Sleep -Milliseconds 500
        }
        $result = $Downloader.EndDownload($job)
        if ($null -eq $result) { throw 'Windows Update ไม่คืนผลดาวน์โหลด' }
        for ($i = 0; $i -lt $Updates.Count; $i++) {
            $item = $result.GetUpdateResult($i)
            if ($item.ResultCode -eq 2) {
                Write-Log "ดาวน์โหลด 100% — $($Updates.Item($i).Title)"
            }
        }
        return $result
    } finally {
        Close-UpdateJob $job
    }
}

function Invoke-UpdateInstall($Installer, [string]$Phase, $UpdateItem) {
    $callback = New-UpdateCallback
    $job = $Installer.BeginInstall($callback, $callback, '')
    if ($null -eq $job) { throw 'Windows Update ไม่คืนงานติดตั้ง' }
    try {
        Wait-UpdateJob $job $Phase 5400 $UpdateItem
        $result = $Installer.EndInstall($job)
        if ($null -eq $result) { throw 'Windows Update ไม่คืนผลติดตั้ง' }
        return $result
    } finally { Close-UpdateJob $job }
}

function Wait-UpdateJob($Job, [string]$Phase, [int]$TimeoutSeconds, $UpdateItem) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastPercent = -1
    while (-not $Job.IsCompleted) {
        Assert-Running
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "Windows Update หมดเวลารอ $Phase ($TimeoutSeconds วินาที)" }
        if ($UpdateItem) {
            $progress = $Job.GetProgress()
            if ($null -eq $progress) { Start-Sleep -Milliseconds 500; continue }
            $percent = $progress.PercentComplete
            if ($percent -ne $lastPercent) {
                $lastPercent = $percent
                Write-Log "$Phase | $percent%"
                Publish-UpdateItem $UpdateItem "กำลังติดตั้ง $percent%" -Active
            }
        }
        Start-Sleep -Milliseconds 500
    }
}

function Close-UpdateJob($Job) {
    if ($null -eq $Job) { return }
    try {
        if ($Job.IsCompleted) { $Job.CleanUp(); return }
        $Job.RequestAbort()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not $Job.IsCompleted -and $timer.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 250 }
        if ($Job.IsCompleted) { $Job.CleanUp() }
        else { Write-Log 'ส่งคำขอหยุดแล้ว Windows Update ยังไม่ยืนยันว่าหยุด ตรวจสถานะใน Settings ก่อนเริ่มงานใหม่' }
    } catch {
        Write-Log "ปิดงาน Windows Update ไม่สำเร็จ: $($_.Exception.Message)"
    }
}

function Search-SetupUpdates($Session, [switch]$Online, [switch]$DriversOnly) {
    $searcher = $Session.CreateUpdateSearcher()
    $searcher.Online = [bool]$Online
    $callback = New-UpdateCallback
    $criteria = '(IsInstalled=0 and IsHidden=0 and BrowseOnly=0) or (IsInstalled=0 and IsHidden=0 and BrowseOnly=1)'
    if ($DriversOnly) { $criteria = "IsInstalled=0 and IsHidden=0 and Type='Driver'" }
    $phase = if ($Online) { 'ค้นหาออนไลน์' } else { 'ตรวจรายการที่บันทึกกับแคช Windows Update' }
    Write-Log "Windows Update: $phase"
    Publish UpdateActivity "กำลัง$phase"
    Assert-Running
    $job = $searcher.BeginSearch($criteria, $callback, '')
    if ($null -eq $job) { throw 'Windows Update ไม่คืนงานค้นหา' }
    try {
        Wait-UpdateJob $job $phase 600
        $result = $searcher.EndSearch($job)
        Assert-Running
        if ($result.ResultCode -ne 2) { throw "ค้นหา Windows Update ไม่สำเร็จ (ResultCode $($result.ResultCode))" }
        Write-Log "Windows Update: $phase จบ พบ $($result.Updates.Count) รายการ"
        return $result
    } finally { Close-UpdateJob $job }
}

function Test-PreviewUpdateTitle([string]$Title) {
    return $Title -match '\bPreview\b|ตัวอย่าง'
}

function Get-SetupUpdateList([ref]$ManualTitles, [ref]$PreviewTitles) {
    $session = New-Object -ComObject Microsoft.Update.Session
    $search = Search-SetupUpdates $session -Online
    foreach ($update in $search.Updates) {
        Assert-Running
        if (Test-PreviewUpdateTitle $update.Title) {
            Write-Log "ข้ามอัปเดต Preview: $($update.Title)"
            if ($null -ne $PreviewTitles) { $PreviewTitles.Value += [string]$update.Title }
            continue
        }
        if ($update.InstallationBehavior.CanRequestUserInput) {
            Write-Log "ข้ามรายการที่ต้องตอบโต้: $($update.Title)"
            if ($null -ne $ManualTitles) { $ManualTitles.Value += [string]$update.Title }
            continue
        }
        $key = "$($update.Identity.UpdateID)/$($update.Identity.RevisionNumber)"
        Write-Log "พบ $($update.Title) | $key"
        [pscustomobject]@{ Key = $key; Title = [string]$update.Title }
    }
}

function Invoke-WindowsUpdateBatch([object[]]$UpdateList, [hashtable]$Processed) {
    Assert-Running
    if (-not $UpdateList.Count) { return }
    $systemInfo = New-Object -ComObject Microsoft.Update.SystemInfo
    if ($systemInfo.RebootRequired) {
        Save-UpdateRestart $UpdateList $Processed 'Windows Update แจ้งว่ามีงานก่อนหน้ารอรีสตาร์ท'
        return
    }
    $session = New-Object -ComObject Microsoft.Update.Session
    $search = Search-SetupUpdates $session
    $available = @{}
    $skipped = 0
    foreach ($update in $search.Updates) {
        $available["$($update.Identity.UpdateID)/$($update.Identity.RevisionNumber)"] = $update
    }
    if ($UpdateList | Where-Object { -not $available.ContainsKey($_.Key) } | Select-Object -First 1) {
        Write-Log 'บางรายการหายจากแคช ตรวจความพร้อมออนไลน์อีกครั้ง โดยคงรายการและรุ่นที่ยืนยันไว้'
        $search = Search-SetupUpdates $session -Online
        $available.Clear()
        foreach ($update in $search.Updates) {
            $available["$($update.Identity.UpdateID)/$($update.Identity.RevisionNumber)"] = $update
        }
    }
    for ($i = 0; $i -lt $UpdateList.Count; $i++) {
        Assert-Running
        $item = $UpdateList[$i]
        $update = $available[$item.Key]
        $itemStatus = "รายการ $($i + 1)/$($UpdateList.Count) — $($item.Title)"
        Write-Log "Windows Update | $itemStatus"
        Publish-UpdateItem $item 'กำลังเตรียมรายการ' -Active
        if ((Test-PreviewUpdateTitle $item.Title) -or ($update -and (Test-PreviewUpdateTitle $update.Title))) {
            $skipped++
            $Processed[$item.Key] = $true
            Write-Log "ข้ามอัปเดต Preview: $($item.Title)"
            Publish-UpdateItem $item 'ข้าม Preview'
            continue
        }
        if (-not $update -or $update.IsInstalled -or $update.InstallationBehavior.CanRequestUserInput) {
            $skipped++
            $Processed[$item.Key] = $true
            Write-Log 'ข้ามรายการนี้ เพราะติดตั้งแล้วหรือไม่มีรายการรุ่นเดิมที่ติดตั้งอัตโนมัติได้ในแคช'
            Publish-UpdateItem $item 'ข้ามรายการ (ดู Log)'
            continue
        }
        $restartBefore = $false
        $needsRestart = $false
        try {
            $updates = New-Object -ComObject Microsoft.Update.UpdateColl
            [void]$updates.Add($update)
            if (-not $update.EulaAccepted) { $update.AcceptEula() }
            if ($update.IsDownloaded) { Write-Log "ดาวน์โหลด 100% — $($item.Title) (มีไฟล์แล้ว)" }
            else {
                Publish-UpdateItem $item 'กำลังดาวน์โหลด' -Active
                $download = $session.CreateUpdateDownloader()
                $download.Updates = $updates
                $downloadResult = Invoke-UpdateDownload $download $updates $item
                $downloadItem = $downloadResult.GetUpdateResult(0)
                if ($downloadItem.ResultCode -ne 2) {
                    $failure = 'ดาวน์โหลด {0} ไม่สำเร็จ | ResultCode {1} | HRESULT {2:X8}' -f
                        $item.Title,$downloadItem.ResultCode,$downloadItem.HResult
                    $Processed[$item.Key] = $failure
                    Write-Log $failure
                    Publish-UpdateItem $item ('ดาวน์โหลดไม่สำเร็จ (0x{0:X8})' -f $downloadItem.HResult)
                    continue
                }
            }
            Assert-Running
            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $updates
            $installer.AllowSourcePrompts = $false
            $installer.ForceQuiet = $true
            if ($installer.RebootRequiredBeforeInstallation) {
                $restartBefore = $true
            } else {
                Write-Log "กำลังติดตั้ง $($item.Title)"
                Publish-UpdateItem $item 'กำลังติดตั้ง' -Active
                $result = Invoke-UpdateInstall $installer "กำลังติดตั้ง $itemStatus" $item
                $installed = $result.GetUpdateResult(0)
                Write-Log ('{0} | ResultCode {1} | HRESULT {2:X8} | รีสตาร์ท {3}' -f $item.Title,$installed.ResultCode,$installed.HResult,$result.RebootRequired)
                $Processed[$item.Key] = if ($installed.ResultCode -eq 2) { $true } else {
                    'ติดตั้ง {0} ไม่สำเร็จ | ResultCode {1} | HRESULT {2:X8}' -f $item.Title,$installed.ResultCode,$installed.HResult
                }
                $needsRestart = $result.RebootRequired -or $installed.RebootRequired
                $itemResult = if ($installed.ResultCode -ne 2) { 'ติดตั้งไม่สำเร็จ (0x{0:X8})' -f $installed.HResult }
                    elseif ($needsRestart) { 'ติดตั้งแล้ว รอรีสตาร์ต' }
                    else { 'ติดตั้งเสร็จแล้ว' }
                Publish-UpdateItem $item $itemResult
            }
        } catch [OperationCanceledException] {
            throw
        } catch {
            $failure = '{0} | {1} | HRESULT {2:X8}' -f $item.Title,$_.Exception.Message,$_.Exception.HResult
            $Processed[$item.Key] = $failure
            Write-Log $failure
            if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace }
            Publish-UpdateItem $item 'ดำเนินการไม่สำเร็จ (ดู Log)'
        }
        if ($restartBefore) {
            Publish-UpdateItem $item 'รอรีสตาร์ตก่อนติดตั้ง'
            Save-UpdateRestart @($UpdateList | Select-Object -Skip $i) $Processed "ต้องรีสตาร์ทก่อนติดตั้ง $($item.Title)"
            return
        }
        if ($needsRestart) {
            Save-UpdateRestart @($UpdateList | Select-Object -Skip ($i + 1)) $Processed "ผลการติดตั้ง $($item.Title) แจ้งว่าต้องรีสตาร์ท"
            return
        }
    }
    Write-Log "ประมวลผลครบตามรายการที่ตรวจไว้ | ข้าม $skipped รายการ"
}

function Invoke-WindowsUpdateLoop([object[]]$UpdateList, [string[]]$ProcessedUpdateKeys, [object[]]$UpdateFailures) {
    $processed = @{}
    foreach ($key in $ProcessedUpdateKeys) { $processed[$key] = $true }
    foreach ($failure in $UpdateFailures) { $processed[$failure.Key] = [string]$failure.Message }
    $round = 0
    while ($true) {
        Assert-Running
        if ($UpdateList.Count) {
            $round++
            Write-Log "Windows Update รอบ $round | $($UpdateList.Count) รายการ"
            Publish UpdateQueued $UpdateList
            Invoke-WindowsUpdateBatch $UpdateList $processed
            if ($script:UpdateRestartPending) { return }
        }

        $systemInfo = New-Object -ComObject Microsoft.Update.SystemInfo
        if ($systemInfo.RebootRequired) {
            Save-UpdateRestart @() $processed 'Windows Update แจ้งว่าต้องรีสตาร์ทก่อนตรวจรอบถัดไป'
            return
        }
        $checking = 'กำลังตรวจ Windows Update อีกครั้งเพื่อหาอัปเดตที่เหลือ'
        Write-Log $checking
        $manualTitles = @()
        $previewTitles = @()
        $offered = @(Get-SetupUpdateList ([ref]$manualTitles) ([ref]$previewTitles))
        $UpdateList = @($offered | Where-Object {
            if ($processed.ContainsKey($_.Key)) { Write-Log "Windows ยังเสนอรายการเดิม: $($_.Title) | ข้ามการลองซ้ำ" }
            else { $true }
        })
        if (-not $UpdateList.Count) {
            Clear-UpdateResume
            Publish ResumeCleared $true
            $failures = @($processed.Values | Where-Object { $_ -is [string] })
            foreach ($failure in $failures) { Write-Log "สรุปข้อผิดพลาด: $failure" }
            if ($failures.Count) { throw "Windows Update ประมวลผลรายการอื่นต่อแล้ว แต่มี $($failures.Count) รายการที่ไม่สำเร็จ ดูรายละเอียดใน Log" }
            if ($offered.Count) { throw 'Windows Update ยังเสนอเฉพาะรายการเดิม หยุดวนซ้ำ ดูชื่อรายการใน Log' }
            Write-Log 'ตรวจซ้ำแล้วไม่พบอัปเดตที่ติดตั้งอัตโนมัติได้ ปิดการเปิดต่อหลังรีสตาร์ทแล้ว'
            return [pscustomobject]@{ ManualTitles = $manualTitles; PreviewTitles = $previewTitles }
        }
    }
}
