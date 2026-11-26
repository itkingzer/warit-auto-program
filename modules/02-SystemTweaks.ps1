function Invoke-SystemTweaks {
    # ค่าต่อผู้ใช้ใช้บัญชีเดียวกับที่เปิดโปรแกรม
    Set-TimeZone -Id 'SE Asia Standard Time'
    Set-Culture -CultureInfo 'th-TH'
    Set-WinHomeLocation -GeoId 227
    Set-WinSystemLocale -SystemLocale 'th-TH'

    $desktop = 'HKCU:\Control Panel\Desktop'
    # ค่าเริ่มต้นใช้ภาพ Windows ที่ติดตั้งมาพร้อมระบบ
    $wallpaperName = [string]$Config.Personalization.Wallpaper
    $wallpaperPath = Join-Path $env:SystemRoot 'Web\Wallpaper\Windows\img0.jpg'
    if ($wallpaperName) {
        $wallpaperPath = Join-Path (Join-Path $PayloadRoot 'Wallpaper') $wallpaperName
    }
    if (-not (Test-Path -LiteralPath $wallpaperPath -PathType Leaf)) {
        throw "ไม่พบไฟล์ภาพพื้นหลัง: $wallpaperPath"
    }
    if (-not ('AutoSetup.Desktop' -as [type])) {
        Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
namespace AutoSetup {
    public static class Desktop {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SystemParametersInfo(int action, int param, string value, int flags);
    }
}
"@
    }
    # ให้หน้า Personalization แสดง Picture แล้วใช้และบันทึกภาพสำหรับผู้ใช้ปัจจุบัน
    $wallpaperKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'
    New-Item -Path $wallpaperKey -Force | Out-Null
    New-ItemProperty -LiteralPath $wallpaperKey -Name BackgroundType -Value 0 -PropertyType DWord -Force | Out-Null
    if (-not [AutoSetup.Desktop]::SystemParametersInfo(20, 0, $wallpaperPath, 3)) {
        throw "ตั้งภาพพื้นหลังไม่สำเร็จ: $wallpaperPath"
    }
    Write-Log "ตั้งภาพพื้นหลังเป็น Picture: $wallpaperPath"

    $icons = @{
        Computer = '{20D04FE0-3AEA-1069-A2D8-08002B30309D}'
        User = '{59031a47-3f72-44a7-89c5-5595fe6b30ee}'
        Network = '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}'
        RecycleBin = '{645FF040-5081-101B-9F08-00AA002F954E}'
        ControlPanel = '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}'
    }
    $explorer = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
    foreach ($menu in 'NewStartPanel','ClassicStartMenu') {
        $key = "$explorer\HideDesktopIcons\$menu"
        New-Item -Path $key -Force | Out-Null
        foreach ($id in $icons.Values) { New-ItemProperty $key $id -Value 0 -PropertyType DWord -Force | Out-Null }
    }
    New-ItemProperty "$explorer\Advanced" HideIcons -Value 0 -PropertyType DWord -Force | Out-Null
    $screenSaver = Join-Path $env:SystemRoot 'System32\ssText3d.scr'
    if (Test-Path -LiteralPath $screenSaver) {
        Set-ItemProperty $desktop 'SCRNSAVE.EXE' $screenSaver
        Set-ItemProperty $desktop ScreenSaveActive '1'
        Set-ItemProperty $desktop ScreenSaveTimeOut '2700'
        $key = 'HKCU:\Software\Microsoft\ScreenSavers\Text3D'
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty $key DisplayString -Value ([string]$Config.Personalization.ScreenSaverText) -PropertyType String -Force | Out-Null
        New-ItemProperty $key DisplayTime -Value 0 -PropertyType DWord -Force | Out-Null
    } else { Write-Log "ไม่พบ $screenSaver" }
    Write-Log 'บันทึกค่าภาษาไทย เวลา และ Desktop แล้ว บางค่ามีผลเมื่อเข้าสู่ระบบอีกครั้ง'
    Enable-PublicNetworkSharing
    Set-PerformancePowerPlan
}

function Enable-PublicNetworkSharing {
    Assert-Running
    # Stable firewall group IDs for Network Discovery and File and Printer Sharing.
    $rules = Get-NetFirewallRule -Group '@FirewallAPI.dll,-32752','@FirewallAPI.dll,-28502' |
        Where-Object { ([string]$_.Profile -split ',\s*') -contains 'Public' }
    if (-not $rules) { throw 'ไม่พบกฎไฟร์วอลล์สำหรับแชร์บนเครือข่าย Public' }
    $rules | Enable-NetFirewallRule | Out-Null
    foreach ($name in 'fdPHost','FDResPub','LanmanServer') {
        Set-Service -Name $name -StartupType Automatic
        Start-Service -Name $name
    }

    $publicPath = $env:PUBLIC
    $everyone = [Security.Principal.SecurityIdentifier]::new('S-1-1-0').Translate([Security.Principal.NTAccount]).Value
    $share = Get-SmbShare -Name Public -ErrorAction SilentlyContinue
    if ($share -and $share.Path -ne $publicPath) { throw "ชื่อแชร์ Public ถูกใช้กับโฟลเดอร์อื่น: $($share.Path)" }
    if (-not $share) {
        New-SmbShare -Name Public -Path $publicPath -ChangeAccess $everyone | Out-Null
    } elseif (-not (Get-SmbShareAccess -Name Public | Where-Object {
        $_.AccountName -eq $everyone -and $_.AccessControlType -eq 'Allow' -and $_.AccessRight -in 'Change','Full'
    })) {
        Grant-SmbShareAccess -Name Public -AccountName $everyone -AccessRight Change -Force | Out-Null
    }

    $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $key = Join-Path $lsa 'MSV1_0'
    foreach ($name in 'NtlmMinClientSec','NtlmMinServerSec') {
        $current = (Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction SilentlyContinue).$name
        New-ItemProperty -LiteralPath $key -Name $name -PropertyType DWord -Value ([int]$current -bor 0x20000000) -Force | Out-Null
    }
    $guest = Get-LocalUser | Where-Object { $_.SID.Value -match '-501$' }
    if (-not $guest) { throw 'ไม่พบบัญชี Guest สำหรับการแชร์แบบไม่ใช้รหัสผ่าน' }
    $guest | Enable-LocalUser
    New-ItemProperty -LiteralPath $lsa -Name ForceGuest -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Log 'เปิดการค้นพบเครือข่ายและแชร์ไฟล์/เครื่องพิมพ์บน Public พร้อมแชร์โฟลเดอร์ Public และตั้งค่า Guest กับการเข้ารหัส 128 บิต'
}

function Invoke-PowerCfg {
    $output = & "$env:SystemRoot\System32\powercfg.exe" @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "powercfg $($args -join ' ') ล้มเหลว: $($output -join ' ')" }
    $output
}

function Set-PerformancePowerPlan {
    Assert-Running
    $portableChassis = @(8,9,10,11,14,30,31,32)
    $portable = @(Get-CimInstance Win32_SystemEnclosure).ChassisTypes | Where-Object { $_ -in $portableChassis }
    $onBatteryCapable = $portable -or (Get-CimInstance Win32_Battery)
    $ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    $performance = '94f564b0-8b80-4453-b08c-ebaf595fa644'
    $pluggedIn = 'dddfe9f2-0973-426d-8fea-4e9d17e5084f'
    $guidPattern = '[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}'
    $schemes = Invoke-PowerCfg /list
    $active = [regex]::Match(((Invoke-PowerCfg /getactivescheme) -join ' '), $guidPattern).Value
    if (-not $active) { throw 'ไม่พบ GUID ของแผนพลังงานปัจจุบัน' }

    if (-not ($schemes -match $performance)) {
        try {
            Invoke-PowerCfg /duplicatescheme $ultimate $performance | Out-Null
            Invoke-PowerCfg /changename $performance 'Auto Setup - Ultimate Performance' | Out-Null
        } catch {
            Write-Log "ใช้แผน High Performance เนื่องจากเปิด Ultimate Performance ไม่สำเร็จ: $_"
            $performance = 'SCHEME_MIN'
        }
    }
    if (-not $onBatteryCapable) {
        Invoke-PowerCfg /setactive $performance | Out-Null
        Write-Log 'เปิดแผนพลังงานประสิทธิภาพสูงสุดสำหรับเครื่องเดสก์ท็อป'
        return
    }

    $settings = Invoke-PowerCfg /query $performance
    $acValues = @(
        foreach ($line in $settings) {
            if ($line -match "^\s*Subgroup GUID:\s*($guidPattern)") { $subgroup = $Matches[1]; $setting = $null }
            elseif ($line -match "^\s*Power Setting GUID:\s*($guidPattern)") { $setting = $Matches[1] }
            elseif ($subgroup -and $setting -and $line -match '^\s*Current AC Power Setting Index:\s*0x([0-9a-f]+)') {
                @{ Subgroup = $subgroup; Setting = $setting; Value = [Convert]::ToUInt32($Matches[1], 16) }
            }
        }
    )
    if (-not $acValues) { throw 'อ่านค่าพลังงานสำหรับโหมดเสียบปลั๊กไม่สำเร็จ' }
    if ($active -ne $pluggedIn) {
        if ($schemes -match $pluggedIn) { Invoke-PowerCfg /delete $pluggedIn | Out-Null }
        Invoke-PowerCfg /duplicatescheme $active $pluggedIn | Out-Null
        Invoke-PowerCfg /changename $pluggedIn 'Auto Setup - Performance on AC' | Out-Null
    }
    foreach ($value in $acValues) {
        Invoke-PowerCfg /setacvalueindex $pluggedIn $value.Subgroup $value.Setting $value.Value | Out-Null
    }
    Invoke-PowerCfg /setactive $pluggedIn | Out-Null
    Write-Log 'ตั้งประสิทธิภาพสูงสุดเฉพาะตอนเสียบปลั๊ก และเก็บค่าพลังงานเดิมเมื่อใช้แบตเตอรี่'
}

function Enable-GraveAccentLanguageSwitch {
    Assert-Running
    $languageList = Get-WinUserLanguageList
    $languageTags = $languageList.LanguageTag
    $changed = $false
    if (-not ($languageTags -like 'en-*')) {
        $languageList.Add('en-US')
        $changed = $true
    }
    if ('th-TH' -notin $languageTags) {
        $languageList.Add('th-TH')
        $changed = $true
    }
    if ($changed) { Set-WinUserLanguageList -LanguageList $languageList -Force }

    $toggleKey = 'HKCU:\Keyboard Layout\Toggle'
    if (-not (Test-Path -LiteralPath $toggleKey)) { New-Item -Path $toggleKey -Force | Out-Null }
    foreach ($property in 'Hotkey','Language Hotkey') {
        New-ItemProperty -LiteralPath $toggleKey -Name $property -Value '4' -PropertyType String -Force | Out-Null
    }
    Write-Log 'ตั้งปุ่ม ` (Grave Accent) สำหรับสลับภาษาของบัญชีนี้แล้ว ให้ออกจากระบบแล้วเข้าใหม่เพื่อใช้งาน'
}

function Enable-SmbFileSharing {
    Assert-Running
    # Windows มี SMB 2/3 ในตัวอยู่แล้ว เปิดบริการและอนุญาตเฉพาะเครือข่าย Private ภายใน subnet
    if (-not (Get-SmbServerConfiguration).EnableSMB2Protocol) {
        Set-SmbServerConfiguration -EnableSMB2Protocol $true -Force
    }
    foreach ($name in 'LanmanWorkstation','LanmanServer') {
        Set-Service -Name $name -StartupType Automatic
        Start-Service -Name $name
    }
    $ruleName = 'WaritAutoSetup-SMB-Private'
    $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    if ($rule) {
        Set-NetFirewallRule -InputObject $rule -Enabled True -Profile Private -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -RemoteAddress LocalSubnet | Out-Null
    } else {
        New-NetFirewallRule -Name $ruleName -DisplayName 'Windows Auto Setup SMB (Private LAN)' -Profile Private -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -RemoteAddress LocalSubnet | Out-Null
    }
    Write-Log 'เปิด SMB 2/3 แล้ว กฎ Firewall อนุญาต TCP 445 บน Private เฉพาะ Local Subnet'
}

function Enable-SetupWindowsFeatures([string[]]$FeatureNames) {
    Assert-Running
    $available = @{}
    foreach ($feature in Get-WindowsOptionalFeature -Online) {
        $available[$feature.FeatureName] = $feature.State
    }
    foreach ($name in $FeatureNames) {
        Assert-Running
        if (-not $available.ContainsKey($name)) {
            Write-Log "Windows Features: รุ่นนี้ไม่มี $name"
            continue
        }
        if ($available[$name] -eq 'Enabled') {
            Write-Log "Windows Features: เปิด $name ไว้แล้ว"
            continue
        }
        if ($available[$name] -eq 'EnablePending') {
            $script:WindowsFeatureRestartRequired = $true
            Write-Log "Windows Features: $name รอรีสตาร์ท"
            continue
        }
        Write-Log "Windows Features: กำลังเปิด $name"
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart
        if ($result.RestartNeeded) {
            $script:WindowsFeatureRestartRequired = $true
            Write-Log "Windows Features: $name รอรีสตาร์ท"
        } else {
            Write-Log "Windows Features: เปิด $name แล้ว"
        }
    }
}
