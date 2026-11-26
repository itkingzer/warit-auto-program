function Get-AppUpdate([string]$CurrentVersion) {
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/itkingzer/warit-auto-program/releases/latest' -TimeoutSec 15
    if ($release.tag_name -notmatch '^app-[a-f0-9]{40}$' -or $release.name -notmatch '^build-[a-f0-9]{12}$') {
        throw 'GitHub has no compatible app release.'
    }
    if ($release.name -eq $CurrentVersion) { return }

    $assets = @($release.assets | Where-Object Name -eq 'Warit-AutoSetup-App.zip')
    if ($assets.Count -ne 1 -or $assets[0].digest -notmatch '^sha256:[a-f0-9]{64}$' -or
        $assets[0].size -lt 1 -or $assets[0].size -gt 10MB) {
        throw 'App release has no valid ZIP asset or SHA-256 digest.'
    }
    @{ Version = $release.name; Tag = $release.tag_name; Digest = $assets[0].digest.Substring(7); Size = [int]$assets[0].size }
}

function Read-AppUpdateArchive([byte[]]$Bytes, [string]$Version) {
    Add-Type -AssemblyName System.IO.Compression
    $required = @(
        'AutoSetup-GUI.ps1', 'Install-Autorun.ps1', 'Start-AutoSetup.bat', 'Start-AutoSetup.vbs',
        'README.md', 'config.json', 'version.txt', 'assets/app.ico', 'assets/app-logo.png', 'assets/icon.svg',
        'modules/00-PreFlight-AV.ps1', 'modules/01-DiskAndData.ps1', 'modules/02-SystemTweaks.ps1',
        'modules/03-InstallAllAndFix.ps1', 'modules/04-WindowsUpdateLoop.ps1', 'modules/05-HardwareAndDrivers.ps1',
        'modules/06-WindowsLicense.ps1', 'modules/07-OfficeLicense.ps1', 'modules/08-AppSelection.ps1', 'modules/09-AppUpdate.ps1'
    )
    $files = @{}
    $total = 0L
    $memory = [IO.MemoryStream]::new($Bytes, $false)
    try {
        $zip = [IO.Compression.ZipArchive]::new($memory)
        try {
            foreach ($entry in $zip.Entries) {
                $path = $entry.FullName
                $total += $entry.Length
                if (($path -cnotin $required -and $path -cnotmatch '^modules/[0-9]{2}-[A-Za-z0-9-]+\.ps1$') -or
                    $files.ContainsKey($path) -or $entry.Length -lt 1 -or $total -gt 20MB) {
                    throw "Invalid ZIP entry: $path"
                }
                $stream = $entry.Open()
                $output = [IO.MemoryStream]::new()
                try {
                    $stream.CopyTo($output)
                    if ($output.Length -ne $entry.Length) { throw "Invalid ZIP entry length: $path" }
                    $files[$path] = $output.ToArray()
                } finally {
                    $output.Dispose()
                    $stream.Dispose()
                }
            }
        } finally { $zip.Dispose() }
    } finally { $memory.Dispose() }
    foreach ($path in $required) {
        if (-not $files.ContainsKey($path)) { throw "Missing ZIP entry: $path" }
    }
    if ([Text.Encoding]::UTF8.GetString($files['version.txt']).Trim() -ne $Version) {
        throw 'App version does not match the GitHub release.'
    }
    $files.Remove('config.json')
    $files
}

function Receive-AppUpdate([string]$Version, [string]$Tag, [string]$Digest, [int]$Size) {
    if ($Tag -notmatch '^app-[a-f0-9]{40}$' -or $Digest -notmatch '^[a-f0-9]{64}$' -or $Size -lt 1 -or $Size -gt 10MB) {
        throw 'Invalid app release metadata.'
    }
    Add-Type -AssemblyName System.Net.Http
    $client = [Net.Http.HttpClient]::new()
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(45)
        $client.MaxResponseContentBufferSize = 10MB
        $uri = "https://github.com/itkingzer/warit-auto-program/releases/download/$Tag/Warit-AutoSetup-App.zip"
        $download = $client.GetByteArrayAsync($uri).GetAwaiter().GetResult()
    } finally { $client.Dispose() }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $actual = [BitConverter]::ToString($sha.ComputeHash($download)).Replace('-', '') }
    finally { $sha.Dispose() }
    if ($download.Length -ne $Size -or $actual -ne $Digest) { throw 'App download failed SHA-256 verification.' }
    Read-AppUpdateArchive $download $Version
}

function Install-AppUpdate([string]$AppRoot, [hashtable]$Files) {
    # Keep the current version marker until all app files have been replaced.
    $paths = @($Files.Keys | Where-Object { $_ -ne 'version.txt' } | Sort-Object) + 'version.txt'
    $changes = [Collections.Generic.List[object]]::new()
    try {
        foreach ($path in $paths) {
            $target = Join-Path $AppRoot $path
            $directory = Get-Item -LiteralPath (Split-Path -Parent $target) -ErrorAction Stop
            $existing = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                ($existing -and ($existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)))) {
                throw "Invalid app path: $target"
            }
            $temporary = Join-Path $directory.FullName ('.warit-update-' + [guid]::NewGuid().ToString('N'))
            $change = @{ Target = $target; Stage = "$temporary.new"; Backup = "$temporary.old"; Applied = $false }
            $changes.Add($change)
            [IO.File]::WriteAllBytes($change.Stage, $Files[$path])
        }
        foreach ($change in $changes) {
            $target = $change.Target
            if ([IO.File]::Exists($target)) {
                [IO.File]::Replace($change.Stage, $target, $change.Backup)
            } else {
                [IO.File]::Move($change.Stage, $target)
            }
            $change.Applied = $true
        }
    } catch {
        $original = $_
        $rollbackErrors = foreach ($change in $changes.ToArray()) {
            try {
                if ([IO.File]::Exists($change.Backup)) {
                    if ([IO.File]::Exists($change.Target)) {
                        [IO.File]::Replace($change.Backup, $change.Target, [NullString]::Value)
                    } else {
                        [IO.File]::Move($change.Backup, $change.Target)
                    }
                } elseif ($change.Applied) {
                    [IO.File]::Delete($change.Target)
                }
            } catch { "$($change.Target) ($($change.Backup)): $($_.Exception.Message)" }
        }
        if ($rollbackErrors) { throw "$original`nRollback failed:`n$($rollbackErrors -join [Environment]::NewLine)" }
        throw "Could not update '${target}': $($original.Exception.Message)"
    } finally {
        foreach ($change in $changes) {
            try { [IO.File]::Delete($change.Stage) } catch { Write-Warning $_.Exception.Message }
        }
    }
    foreach ($change in $changes) {
        try { [IO.File]::Delete($change.Backup) } catch { Write-Warning $_.Exception.Message }
    }
}
