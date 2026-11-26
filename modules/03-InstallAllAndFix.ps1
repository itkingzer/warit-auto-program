# อ่านรายการ Programs and Features จาก Windows ทั้งแบบติดตั้งให้ทุกคนและบัญชีปัจจุบัน
function Get-InstalledProgramRecords {
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
        if (Test-Path -LiteralPath $key) {
            Get-ChildItem -LiteralPath $key | ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath } |
                Where-Object DisplayName | Select-Object DisplayName, DisplayVersion
        }
    }
    $officeKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    if (Test-Path -LiteralPath $officeKey) {
        $office = Get-ItemProperty -LiteralPath $officeKey
        if (($office.ProductReleaseIds -split ',\s*') -contains 'ProPlus2024Retail') {
            [pscustomobject]@{ DisplayName = 'Microsoft Office Professional Plus 2024 Retail'; DisplayVersion = $office.VersionToReport }
        }
    }
}

function Find-InstalledProgram($Entry, $Programs) {
    if ($Entry.DetectName) {
        $Programs | Where-Object { $_.DisplayName -match $Entry.DetectName } | Select-Object -First 1
    }
    elseif ($Entry.Name) {
        $Programs | Where-Object DisplayName -eq $Entry.Name | Select-Object -First 1
    }
}

function Get-LocalInstallerProblem($File, [string]$Group, $Entry) {
    if ($File.Attributes -band [IO.FileAttributes]::ReparsePoint) { return 'ไม่รองรับไฟล์ลิงก์' }
    if ($File.Extension -notin '.exe','.msi','.cmd','.bat','.ps1','.reg') { return 'ไม่รองรับชนิดไฟล์' }
    if ($File.Length -eq 0) { return 'ไฟล์ติดตั้งว่างเปล่า' }
    if ($Group -eq 'Apps' -and $File.Extension -eq '.exe' -and $Entry.InstallMode -ne 'Cmd' -and
        [string]::IsNullOrWhiteSpace($Entry.Arguments)) {
        return 'ยังไม่ได้กำหนดพารามิเตอร์ติดตั้งแบบเงียบ'
    }
}

function Resolve-AppRecipeSteps($Entry, $MainFile, [string]$Folder) {
    if ($Entry.InstallMode -notin 'Silent','Cmd' -or
        @($Entry.Steps | Where-Object { $_.Main -eq $true }).Count -ne 1 -or
        [string]$Entry.Arguments -match '[\r\n]') {
        throw 'การตั้งค่าลำดับติดตั้งไม่ถูกต้อง'
    }
    foreach ($step in $Entry.Steps) {
        $name = [string]$step.File
        if (-not $name -or $name -in '.','..' -or $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "ชื่อไฟล์ในขั้นตอนไม่ถูกต้อง: $name"
        }
        $file = Get-Item -LiteralPath (Join-Path $Folder $name) -ErrorAction SilentlyContinue
        if (-not $file -or $file.PSIsContainer -or (Get-LocalInstallerProblem $file '' $Entry)) {
            throw "ขาดไฟล์หรือไฟล์ใช้ไม่ได้: $name"
        }
        $kind = if ($step.Main -eq $true) {
            if ($file.FullName -ne $MainFile.FullName -or
                ($Entry.InstallMode -eq 'Silent' -and $file.Extension -notin '.exe','.msi') -or
                ($Entry.InstallMode -eq 'Cmd' -and $file.Extension -notin '.exe','.cmd','.bat')) {
                throw "ชนิดไฟล์หลักไม่ตรงกับวิธีติดตั้ง: $name"
            }
            $Entry.InstallMode
        } elseif ($file.Extension -eq '.reg') { 'Registry' }
        elseif ($file.Extension -in '.cmd','.bat') { 'Cmd' }
        else { throw "ชนิดไฟล์ขั้นตอนเพิ่มเติมไม่ถูกต้อง: $name" }
        if ($kind -eq 'Cmd' -and $file.FullName.Contains('%')) { throw "พาธสำหรับ CMD มีเครื่องหมาย %: $name" }
        [pscustomobject]@{ File = $file; Kind = $kind; Main = $step.Main -eq $true }
    }
}

function Get-PackagePayloadStatus([string]$Group, $Entry, [string]$Folder) {
    if ($Entry.Enabled -eq $false) { return 'ปิดใน config' }
    $files = @(if (Test-Path -LiteralPath $Folder -PathType Container) {
        Get-ChildItem -LiteralPath $Folder -File | Where-Object Name -like $Entry.File
    })
    if ($files.Count -eq 0) { return 'ขาดตัวติดตั้ง' }
    if ($files.Count -gt 1) { return 'พบไฟล์หลายตัว' }
    $problem = Get-LocalInstallerProblem $files[0] $Group $Entry
    if ($problem) { return $problem }
    if ($Group -eq 'Apps' -and $Entry.InstallMode) {
        try { $null = @(Resolve-AppRecipeSteps $Entry $files[0] $Folder) }
        catch { return $_.Exception.Message }
    }
    if ($Group -eq 'Office' -and $Entry.File -eq 'office-install.cmd') {
        if (-not (Test-Path -LiteralPath (Join-Path $Folder 'office-retail-2024.xml') -PathType Leaf)) {
            return 'ขาด office-retail-2024.xml'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Folder 'setup.exe') -PathType Leaf)) {
            return 'ดาวน์โหลดจาก Microsoft เมื่อติดตั้ง'
        }
    }
    if ($Group -eq 'Runtimes' -and $files[0].Name -eq 'DXSETUP.exe' -and
        -not (Get-ChildItem -LiteralPath $Folder -Filter '*.cab' -File | Select-Object -First 1)) {
        return 'ขาดไฟล์ CAB ของ DirectX'
    }
    if ($Group -eq 'Runtimes' -and $files[0].Name -eq 'netfx35.cmd' -and
        [Environment]::OSVersion.Version.Build -ge 28000 -and
        -not (Test-Path -LiteralPath (Join-Path $Folder 'DotNet35Setup.exe') -PathType Leaf)) {
        return 'ขาด DotNet35Setup.exe สำหรับ Windows รุ่นนี้'
    }
    if ($Group -eq 'ACDSee') {
        try { $null = @(Get-ACDSeePostInstallFiles $Folder) }
        catch { return 'ขาด Host.cmd หรือ LL.reg หรือไฟล์ใช้ไม่ได้' }
    }
    'พร้อมติดตั้ง'
}

function Get-PayloadReport {
    $path = Join-Path $Root 'payloads'
    "ตำแหน่ง: $path"
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        'ไม่พบโฟลเดอร์ payloads ให้วางไว้ข้าง Start-AutoSetup.vbs แล้วกดตรวจใหม่'
        return
    }
    foreach ($group in 'Apps','Runtimes','LINE','Office','Foxit','ACDSee') {
        ''
        "$group · $($PayloadFolders[$group])"
        foreach ($entry in $Config.Packages.$group | Where-Object { $_ }) {
            $folder = Get-PayloadEntryFolder $group $entry
            $status = Get-PackagePayloadStatus $group $entry $folder
            $file = if ($entry.Subfolder) { Join-Path $entry.Subfolder $entry.File } else { $entry.File }
            "• $($entry.Name) — $status ($file)"
        }
    }

    ''
    'ไฟล์ประกอบ'
    $printer = Join-Path (Join-Path $path $PayloadFolders.Printer) 'Code error 709'
    foreach ($name in '1.gpedit.bat','2.RPC.reg') {
        $file = Get-Item -LiteralPath (Join-Path $printer $name) -ErrorAction SilentlyContinue
        $status = if ($file -and -not $file.PSIsContainer -and $file.Length -gt 0 -and
            -not ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { 'พบไฟล์' } else { 'ขาดไฟล์หรือใช้ไม่ได้' }
        "• Printer 709 — $name — $status"
    }
    $fonts = @(Get-LocalFontFiles)
    "• ฟอนต์ (++Front) — พบ $($fonts.Count) ไฟล์"
    $data = if (Test-Path -LiteralPath (Join-Path $path 'ใส่ให้ลูกค้า') -PathType Container) {
        'พบโฟลเดอร์'
    } else { 'ไม่พบโฟลเดอร์' }
    "• ใส่ให้ลูกค้า — $data"
}

function Get-PackageInventory {
    $programs = @(Get-InstalledProgramRecords)
    foreach ($group in 'Apps','Runtimes','Foxit','ACDSee','LINE','Office') {
        foreach ($entry in $Config.Packages.$group) {
            $folder = Get-PayloadEntryFolder $group $entry
            $installed = Find-InstalledProgram $entry $programs
            $availability = Get-PackagePayloadStatus $group $entry $folder
            $status = if ($installed) { 'ติดตั้งแล้ว' } elseif ($entry.DetectName) { 'ไม่พบในระบบ' } else { 'ไม่มีข้อมูลตรวจจับ' }
            [pscustomobject]@{
                Name = $entry.Name
                Status = $status
                Version = if ($installed) { [string]$installed.DisplayVersion } else { '' }
                Payload = $availability
            }
        }
    }
}

function Assert-MicrosoftOfficeInstaller([string]$Path) {
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'ไฟล์ติดตั้ง Office ไม่ถูกต้อง' }
    $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.GetNameInfo('SimpleName', $false) -ne 'Microsoft Corporation') {
        throw 'ยืนยันลายเซ็น Microsoft ของตัวติดตั้ง Office ไม่ได้'
    }
}

function Initialize-OfficeDeploymentTool([string]$Folder) {
    $setup = Join-Path $Folder 'setup.exe'
    if (Test-Path -LiteralPath $setup) {
        Assert-MicrosoftOfficeInstaller $setup
        return
    }
    $tempRoot = (Get-Item -LiteralPath ([IO.Path]::GetTempPath())).FullName.TrimEnd('\')
    $temporary = Join-Path $tempRoot ('Warit-ODT-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $temporary
    try {
        $package = Join-Path $temporary 'odt.exe'
        $url = 'https://download.microsoft.com/download/6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/officedeploymenttool_20527-20150.exe'
        Write-Log 'กำลังดาวน์โหลด Office Deployment Tool จาก Microsoft'
        Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $package -TimeoutSec 120
        Assert-Running
        Assert-MicrosoftOfficeInstaller $package
        Invoke-Program $package ('/quiet /extract:"{0}"' -f $temporary) 120 @(0) -WorkingDirectory $temporary
        $extractedSetup = Join-Path $temporary 'setup.exe'
        Assert-MicrosoftOfficeInstaller $extractedSetup
        Copy-Item -LiteralPath $extractedSetup -Destination $setup
    } finally {
        $resolved = (Resolve-Path -LiteralPath $temporary).ProviderPath
        if ([IO.Path]::GetDirectoryName($resolved) -eq $tempRoot -and $resolved -eq $temporary) {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ACDSeePostInstallFiles([string]$Folder) {
    foreach ($name in 'Host.cmd','LL.reg') {
        $file = Get-Item -LiteralPath (Join-Path $Folder $name) -ErrorAction Stop
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Invalid ACDSee payload: $name"
        }
        $file
    }
}

function Invoke-ACDSeePostInstall($Files, [string]$Folder, [int]$Timeout) {
    Invoke-Program "$env:SystemRoot\System32\cmd.exe" ('/d /s /c ""{0}""' -f $Files[0].FullName) $Timeout @(0) -WorkingDirectory $Folder -SuppressOutput
    Invoke-Program "$env:SystemRoot\System32\reg.exe" ('import "{0}"' -f $Files[1].FullName) $Timeout @(0) -WorkingDirectory $Folder -SuppressOutput
    Write-Log 'ลงhost กับ ll ให้ acdsee แล้ว'
}

function Assert-ACDSeeInstallerSignature([string]$Path, [string]$Publisher) {
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "ไฟล์ติดตั้ง ACDSee ไม่ถูกต้อง: $Path" }
    $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.GetNameInfo('SimpleName', $false) -ne $Publisher) {
        throw "ยืนยันลายเซ็น $Publisher ไม่ได้: $($file.Name)"
    }
}

function Test-ACDSeeWebViewRuntime {
    $client = 'Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    foreach ($key in "HKLM:\SOFTWARE\WOW6432Node\$client", "HKLM:\SOFTWARE\$client", "HKCU:\SOFTWARE\$client") {
        $installedVersion = Get-ItemProperty -LiteralPath $key -Name pv -ErrorAction SilentlyContinue
        if ($installedVersion.pv -and $installedVersion.pv -ne '0.0.0.0') { return $true }
    }
    return $false
}

function Install-ACDSeeSilently([string]$Package, [int]$Timeout) {
    Assert-ACDSeeInstallerSignature $Package 'ACD Systems International Inc.'
    $sevenZip = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (-not (Test-Path -LiteralPath $sevenZip -PathType Leaf)) { throw 'ต้องติดตั้ง 7-Zip ก่อนใช้งาน ACDSee แบบอัตโนมัติ' }
    $tempRoot = (Get-Item -LiteralPath ([IO.Path]::GetTempPath())).FullName.TrimEnd('\')
    $temporary = Join-Path $tempRoot ('Warit-ACDSee-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $temporary
    try {
        $productMsi = 'ACDSee Photo Studio Ultimate 2027.msi'
        $extract = 'e "{0}" "-o{1}" "-ir!{2}" -ir!webview2.exe -ir!vc_redist.exe -ir!bonjour.msi -y' -f $Package,$temporary,$productMsi
        Invoke-Program $sevenZip $extract $Timeout @(0) -WorkingDirectory $temporary -SuppressOutput
        $product = Join-Path $temporary $productMsi
        $webView = Join-Path $temporary 'webview2.exe'
        $runtime = Join-Path $temporary 'vc_redist.exe'
        $bonjour = Join-Path $temporary 'bonjour.msi'
        Assert-ACDSeeInstallerSignature $product 'ACD Systems International Inc.'
        Assert-ACDSeeInstallerSignature $webView 'Microsoft Corporation'
        Assert-ACDSeeInstallerSignature $runtime 'Microsoft Corporation'
        Assert-ACDSeeInstallerSignature $bonjour 'Apple Inc.'
        $msiexec = "$env:SystemRoot\System32\msiexec.exe"
        if (-not (Test-ACDSeeWebViewRuntime)) {
            Invoke-Program $webView '/silent /install' $Timeout @(0,3010) -WorkingDirectory $temporary -SuppressOutput
        }
        Invoke-Program $runtime '/quiet /install /norestart' $Timeout @(0,3010,1638,-2147023258) -WorkingDirectory $temporary -SuppressOutput
        Invoke-Program $msiexec ('/i "{0}" /qn /norestart' -f $bonjour) $Timeout @(0,3010,1638) -WorkingDirectory $temporary -SuppressOutput
        Invoke-Program $msiexec ('/i "{0}" /qn /norestart' -f $product) $Timeout @(0,3010) -WorkingDirectory $temporary -SuppressOutput
    } finally {
        $resolved = (Resolve-Path -LiteralPath $temporary).ProviderPath
        if ([IO.Path]::GetDirectoryName($resolved) -eq $tempRoot -and $resolved -eq $temporary) {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-PayloadEntryFolder([string]$Group, $Entry) {
    $folder = Join-Path $Root ('payloads\' + $PayloadFolders[$Group])
    if ($Group -eq 'Apps' -and $Entry.Subfolder) {
        $subfolder = [string]$Entry.Subfolder
        if ($subfolder -in '.', '..' -or $subfolder.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "Invalid Apps subfolder: $subfolder"
        }
        return Join-Path $folder $subfolder
    }
    return $folder
}

function Invoke-AppRecipe($Entry, [object[]]$Steps, [int]$Timeout, [string]$Folder) {
    $name = $Entry.Name
    Write-Log "เริ่มติดตั้ง $name ($($Entry.InstallMode))"
    $mainCompleted = $false
    $restart = $false
    $index = 0
    foreach ($step in $Steps) {
        $index++
        $file = $step.File
        $arguments = if ($step.Main) { [string]$Entry.Arguments } else { '' }
        Write-Log "$name | ขั้นตอน $index/$($Steps.Count): $($file.Name) ($($step.Kind))"
        $run = @{ File = $file.FullName; Arguments = $arguments; Timeout = $Timeout
            SuccessCodes = @(0,3010,1641); WorkingDirectory = $Folder; PassExitCode = $true
            AllowSkip = $step.Main -and $step.Kind -eq 'Silent' }
        switch ($step.Kind) {
            'Cmd' {
                $run.File = "$env:SystemRoot\System32\cmd.exe"
                $run.Arguments = '/d /v:off /s /c ""{0}" {1}"' -f $file.FullName, $arguments
            }
            'Registry' {
                $run.File = "$env:SystemRoot\System32\reg.exe"
                $run.Arguments = 'import "{0}"' -f $file.FullName
                $run.SuccessCodes = @(0)
            }
            'Silent' {
                if ($file.Extension -eq '.msi') {
                    $run.File = "$env:SystemRoot\System32\msiexec.exe"
                    $run.Arguments = '/i "{0}" /qn /norestart {1}' -f $file.FullName, $arguments
                }
            }
        }
        try {
            $code = Invoke-Program @run
            if ($code -in 3010,1641) { $restart = $true }
            if ($step.Main) { $mainCompleted = $true }
            Write-Log "$name | $($file.Name) สำเร็จ (Exit Code $code)"
        } catch [OperationCanceledException] {
            Write-Log "จบ ${name}: ยกเลิกที่ขั้นตอน $($file.Name)"
            throw
        } catch {
            if ($_.Exception.Data['InstallerSkipped']) { throw }
            $outcome = if ($mainCompleted) { 'ติดตั้งโปรแกรมสำเร็จ แต่ขั้นตอนหลังติดตั้งล้มเหลว' }
                else { 'ติดตั้งไม่สำเร็จ' }
            if ($restart) { $outcome += ' และมีขั้นตอนที่แจ้งให้รีสตาร์ท' }
            Write-Log "จบ ${name}: $outcome | $($file.Name) | $($_.Exception.Message)"
            throw
        }
    }
    $outcome = if ($restart) { 'ติดตั้งสำเร็จ รอรีสตาร์ท' } else { 'ติดตั้งสำเร็จ' }
    Write-Log "จบ ${name}: $outcome"
}

function Invoke-PayloadGroup([string]$Group, [switch]$SkipUnavailable, [switch]$SkipMissing, [ref]$UnavailableCount, $AppFailures, [string[]]$RetryApps) {
    # รันเฉพาะรายการที่กำหนดใน config.json และใช้โฟลเดอร์ไฟล์เป็น Working Directory
    $entries = @($Config.Packages.$Group | Where-Object { $_ -and $_.Enabled -ne $false })
    if ($RetryApps.Count) { $entries = @($entries | Where-Object Name -in $RetryApps) }
    if (-not $entries) { Write-Log "ข้าม $Group เนื่องจากไม่มีรายการที่เปิดใช้ใน config.json"; return }
    $programs = @(Get-InstalledProgramRecords)
    $chromeOffline = if ($Group -eq 'Apps') {
        $entries | Where-Object { $_.Name -eq 'Google Chrome' -and $_.File -eq 'ChromeStandaloneSetup64.exe' } | Select-Object -First 1
    }
    if ($chromeOffline -and -not (Test-Path -LiteralPath (Join-Path (Get-PayloadEntryFolder $Group $chromeOffline) $chromeOffline.File) -PathType Leaf)) {
        $chromeOffline = $null
    }
    $chromeAttempted = $false
    foreach ($entry in $entries) {
        Assert-Running
        try {
            $installed = Find-InstalledProgram $entry $programs
            $folder = Get-PayloadEntryFolder $Group $entry
            $timeout = if ($entry.TimeoutSeconds -gt 0) { [int]$entry.TimeoutSeconds } else { [int]$Config.InstallerTimeoutSeconds }
            $isChrome = $Group -eq 'Apps' -and ($entry.Name -in 'Chrome','Google Chrome' -or
                $entry.File -match '^(Chrome|ChromeSetup|chrome_installer|ChromeStandaloneSetup(?:64)?|GoogleChromeStandaloneEnterprise(?:64)?)\.(exe|msi)$')
            if ($isChrome) {
                if ($chromeAttempted -or ($chromeOffline -and -not [object]::ReferenceEquals($entry, $chromeOffline))) {
                    Write-Log "ข้าม $($entry.Name): มีรายการ Google Chrome ในคิวแล้ว"
                    continue
                }
                $installed = $programs | Where-Object DisplayName -eq 'Google Chrome' | Select-Object -First 1
                $timeout = [Math]::Min($timeout, 300)
            }
            if ($installed -and $entry.Reinstall -ne $true) {
                if ($Group -eq 'ACDSee') {
                    if ($SkipMissing -and -not (Test-Path -LiteralPath $folder -PathType Container)) {
                        if ($null -ne $UnavailableCount) { $UnavailableCount.Value++ }
                        Write-Log "ข้าม $($entry.Name) เนื่องจากไม่พบโฟลเดอร์ $folder"
                        continue
                    }
                    Invoke-ACDSeePostInstall @(Get-ACDSeePostInstallFiles $folder) $folder $timeout
                }
                else { Write-Log "ข้าม $($entry.Name) เพราะติดตั้งแล้ว: $($installed.DisplayName) $($installed.DisplayVersion)" }
                continue
            }
            $files = @(if ((-not $SkipUnavailable -and -not $SkipMissing) -or
                (Test-Path -LiteralPath $folder -PathType Container)) {
                Get-ChildItem -LiteralPath $folder -File | Where-Object { $_.Name -like $entry.File }
            })
            if ($files.Count -ne 1) {
                $message = "$($entry.Name): รูปแบบ $($entry.File) ต้องตรงกับไฟล์เดียวใน $folder (พบ $($files.Count))"
                if (-not $SkipUnavailable -and -not ($SkipMissing -and $files.Count -eq 0)) { throw $message }
                if ($null -ne $UnavailableCount) { $UnavailableCount.Value++ }
                $prefix = if ($SkipUnavailable) { 'Autorun: ' } else { '' }
                Write-Log "${prefix}ข้าม $message"
                continue
            }
            $file = $files[0]
            if ($Group -in 'Apps','Runtimes','LINE') {
                $problem = Get-LocalInstallerProblem $file $Group $entry
                if (-not $problem -and $Group -eq 'Apps' -and $entry.InstallMode) {
                    try { $steps = @(Resolve-AppRecipeSteps $entry $file $folder) }
                    catch { $problem = $_.Exception.Message }
                }
                if ($problem) {
                    $message = "$($entry.Name): $problem ($($file.Name))"
                    if (-not $SkipUnavailable) { throw $message }
                    if ($null -ne $UnavailableCount) { $UnavailableCount.Value++ }
                    $prefix = if ($SkipUnavailable) { 'Autorun: ' } else { '' }
                    Write-Log "${prefix}ข้าม $message"
                    continue
                }
            } elseif ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "ไม่รองรับลิงก์: $file" }
            if ($isChrome) { $chromeAttempted = $true }
            try {
                if ($Group -eq 'Apps' -and $entry.InstallMode) {
                    Invoke-AppRecipe $entry $steps $timeout $folder
                    continue
                }
                if ($Group -eq 'ACDSee') {
                    $postInstallFiles = @(Get-ACDSeePostInstallFiles $folder)
                    Install-ACDSeeSilently $file.FullName $timeout
                    if (-not (Find-InstalledProgram $entry @(Get-InstalledProgramRecords))) {
                        throw 'ไม่พบ ACDSee ในรายการโปรแกรมหลังติดตั้ง จึงยังไม่ทำขั้นตอนถัดไป'
                    }
                    Invoke-ACDSeePostInstall $postInstallFiles $folder $timeout
                    continue
                }
                if ($installed -and $entry.Reinstall -eq $true) {
                    Write-Log "เริ่มติดตั้งทับ $($entry.Name) (เดิม $($installed.DisplayVersion))"
                } else {
                    Write-Log "เริ่ม $($entry.Name)"
                }
                $codes = if ($null -ne $entry.SuccessCodes) { @($entry.SuccessCodes) } else { @(0,3010,1641) }
                $arguments = [string]$entry.Arguments
                if ($Group -eq 'Office' -and $file.Name -eq 'office-install.cmd') {
                    $xml = Join-Path $folder 'office-retail-2024.xml'
                    if (-not (Test-Path -LiteralPath $xml -PathType Leaf)) {
                        if (-not ($SkipMissing -or $SkipUnavailable)) { throw 'ไม่พบ office-retail-2024.xml' }
                        if ($null -ne $UnavailableCount) { $UnavailableCount.Value++ }
                        Write-Log "ข้าม $($entry.Name) เนื่องจากไม่พบ office-retail-2024.xml"
                        continue
                    }
                    Initialize-OfficeDeploymentTool $folder
                    Invoke-Program (Join-Path $folder 'setup.exe') ('/configure "{0}"' -f $xml) $timeout $codes -WorkingDirectory $folder
                    continue
                }
                switch ($file.Extension.ToLowerInvariant()) {
                    '.exe' {
                        $skipCodes = @(if ($SkipUnavailable -and $Group -eq 'Apps') { $entry.AutorunSkipExitCodes })
                        $exitCode = Invoke-Program $file.FullName $arguments $timeout (@($codes) + $skipCodes) -WorkingDirectory $folder -PassExitCode -AllowSkip:($Group -eq 'Apps')
                        if ($exitCode -notin $codes) {
                            if ($null -ne $UnavailableCount) { $UnavailableCount.Value++ }
                            Write-Log "Autorun: ติดตั้ง $($entry.Name) ไม่สำเร็จ (Exit Code $exitCode) ข้ามไปทำรายการถัดไป"
                        }
                    }
                    '.msi' { Invoke-Program "$env:SystemRoot\System32\msiexec.exe" ('/i "{0}" /qn /norestart {1}' -f $file.FullName,$arguments) $timeout $codes -WorkingDirectory $folder -AllowSkip:($Group -eq 'Apps') }
                    { $_ -in '.cmd','.bat' } { Invoke-Program "$env:SystemRoot\System32\cmd.exe" ('/d /s /c ""{0}" {1}"' -f $file.FullName,$arguments) $timeout $codes -WorkingDirectory $folder }
                    '.ps1' { Invoke-Program "$PSHOME\powershell.exe" ('-NoProfile -NonInteractive -File "{0}" {1}' -f $file.FullName,$arguments) $timeout $codes -WorkingDirectory $folder }
                    '.reg' { Invoke-Program "$env:SystemRoot\System32\reg.exe" ('import "{0}"' -f $file.FullName) $timeout $codes -WorkingDirectory $folder }
                    default { throw "ไม่รองรับชนิดไฟล์ $($file.Extension)" }
                }
            } catch {
                if (-not $_.Exception.Data['InstallerSkipped']) { throw }
                if ($null -ne $UnavailableCount) { $UnavailableCount.Value++ }
                Write-Log "ข้าม $($entry.Name) ตามคำสั่งผู้ใช้"
            }
        } catch [OperationCanceledException] {
            throw
        } catch {
            if ($Group -ne 'Apps' -or $null -eq $AppFailures) { throw }
            $failure = "$($entry.Name): $($_.Exception.Message)"
            $AppFailures[$entry.Name] = $failure
            Write-Log "ติดตั้งไม่สำเร็จ: $failure"
        }
    }
}

function Invoke-PrinterFix([switch]$ChangeSmbSigning) {
    if (-not ($Config.Packages.Printer | Where-Object { $_.Enabled -ne $false })) {
        Write-Log 'ข้าม Printer เพราะปิดไว้ใน config.json'
        return $true
    }

    Assert-Running
    try {
        $folderName = $PayloadFolders.Printer
        $source = Join-Path $Root ('payloads\' + $folderName)
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "ไม่พบโฟลเดอร์ Printer: $source" }
        $fixSubfolder = 'Code error 709'
        $sourceFixFolder = Join-Path $source $fixSubfolder
        foreach ($name in '1.gpedit.bat','2.RPC.reg') {
            $path = Join-Path $sourceFixFolder $name
            $file = Get-Item -LiteralPath $path -ErrorAction Stop
            if ($file.PSIsContainer -or -not $file.Length -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "ไฟล์ Printer ไม่พร้อมใช้งาน: $path"
            }
        }
        $destinationRoot = Join-Path $env:ProgramData 'WaritAutoSetup'
        New-Item -ItemType Directory -Path $destinationRoot -Force -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $source -Destination $destinationRoot -Recurse -Force -ErrorAction Stop
        $destination = Join-Path $destinationRoot $folderName
        $fixFolder = Join-Path $destination $fixSubfolder
        $registry = Join-Path $fixFolder '2.RPC.reg'
        Write-Log "Printer: คัดลอกไฟล์ไปที่ $destination แล้ว"
    } catch {
        Write-Log "Printer: คัดลอกไฟล์ไม่สำเร็จ: $($_.Exception.Message)"
        Write-Log 'Printer: ไม่เปลี่ยนการตั้งค่า SMB client signing เนื่องจากคัดลอกไฟล์ไม่สำเร็จ'
        return $false
    }

    $timeout = [int]$Config.InstallerTimeoutSeconds
    $phase = 'GPEDIT'
    try {
        Write-Log 'Printer: เริ่ม 1.gpedit.bat'
        Invoke-Program "$env:SystemRoot\System32\cmd.exe" '/d /c .\1.gpedit.bat' $timeout @(0,3010) -WorkingDirectory $fixFolder -PressEnterWhenIdle
        $phase = 'RPC'
        Write-Log 'Printer: นำเข้า 2.RPC.reg'
        Invoke-Program "$env:SystemRoot\System32\reg.exe" ('import "{0}"' -f $registry) $timeout @(0) -WorkingDirectory $fixFolder
        if ($ChangeSmbSigning) {
            $phase = 'SMB client signing'
            Assert-Running
            $previous = [bool](Get-SmbClientConfiguration -ErrorAction Stop).RequireSecuritySignature
            Write-Log "Printer: SMB client RequireSecuritySignature เดิม = $previous"
            if ($previous) {
                Write-Log 'Printer: คืนค่าได้จาก PowerShell (ผู้ดูแล): Set-SmbClientConfiguration -RequireSecuritySignature $true -Confirm:$false'
                Set-SmbClientConfiguration -RequireSecuritySignature $false -Confirm:$false -ErrorAction Stop | Out-Null
                Write-Log 'Printer: ยกเลิกการบังคับ SMB client signing แล้ว'
            }
        }
    } catch [OperationCanceledException] {
        throw
    } catch {
        Write-Log "Printer: ขั้นตอน ${phase} ไม่สำเร็จ ข้ามขั้นตอน Printer ที่เหลือ: $($_.Exception.Message)"
        return $false
    }

    Write-Log 'Printer: จบขั้นตอนแล้ว รอทดสอบพิมพ์จริง'
    return $true
}

function Get-LocalFontFiles {
    $source = Join-Path $Root 'payloads\++Front'
    if (Test-Path -LiteralPath $source -PathType Container) {
        Get-ChildItem -LiteralPath $source -File | Where-Object Extension -in '.ttf','.otf','.ttc'
    }
}

function Install-LocalFonts {
    Add-Type -AssemblyName System.Drawing
    $registry = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $folder = Join-Path $env:SystemRoot Fonts
    $files = @(Get-LocalFontFiles)
    if (-not $files) { Write-Log 'ยังไม่มีไฟล์ฟอนต์'; return }
    foreach ($file in $files) {
        Assert-Running
        $fonts = [Drawing.Text.PrivateFontCollection]::new()
        try {
            $fonts.AddFontFile($file.FullName)
            $families = @($fonts.Families | ForEach-Object Name | Select-Object -Unique)
            if (-not $families) { throw "อ่านชื่อฟอนต์ไม่ได้: $($file.Name)" }
            # ชื่อ Registry ใช้ชื่อเต็มจาก WPF เมื่ออ่าน metadata ของฟอนต์ได้
            try {
                $typeface = [Windows.Media.GlyphTypeface]::new([uri]$file.FullName)
                $face = @($typeface.Win32FaceNames.Values)[0]
                if ($face -and $face -ne 'Regular' -and $families.Count -eq 1) { $families[0] += " $face" }
            } catch { Write-Log "ใช้ชื่อ Font Family สำหรับ $($file.Name)" }
            $kind = if ($file.Extension -eq '.otf') { 'OpenType' } else { 'TrueType' }
            $name = ($families -join ' & ') + " ($kind)"
            $destination = Join-Path $folder $file.Name
            if (Test-Path -LiteralPath $destination) {
                if ((Get-FileHash -LiteralPath $destination).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash) {
                    throw "มีฟอนต์ชื่อไฟล์เดียวกันอยู่แล้ว: $destination"
                }
            } else {
                Copy-Item -LiteralPath $file.FullName -Destination $destination
            }
            $registered = (Get-Item -LiteralPath $registry).GetValue($name)
            if ($registered -and $registered -ne $file.Name) { $name = "$name [$($file.BaseName)]" }
            New-ItemProperty $registry $name -Value $file.Name -PropertyType String -Force | Out-Null
            Write-Log "ลงทะเบียนฟอนต์ $name"
        } finally { $fonts.Dispose() }
    }
    Write-Log 'โปรแกรมที่เปิดอยู่จะเห็นฟอนต์ใหม่หลังเปิดโปรแกรมใหม่หรือออกแล้วเข้าระบบ'
}
