param([string]$OutputPath = (Join-Path $PSScriptRoot 'dist/Warit-AutoSetup-App.zip'))

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$archive = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$destination = Split-Path -Parent $archive
$temporary = Join-Path $destination ('app-' + [guid]::NewGuid().ToString('N') + '.zip')

$entries = @(
    'Start-AutoSetup.bat'
    'Start-AutoSetup.vbs'
    'AutoSetup-GUI.ps1'
    'Install-Autorun.ps1'
    'config.json'
    'README.md'
    'assets/app.ico'
    'assets/app-logo.png'
    'assets/icon.svg'
)
$entries += Get-ChildItem -LiteralPath (Join-Path $root 'modules') -Filter '*.ps1' -File | Sort-Object Name |
    ForEach-Object { 'modules/' + $_.Name }

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$fingerprint = foreach ($entry in $entries) {
    '{0} {1}' -f $entry, (Get-FileHash -LiteralPath (Join-Path $root $entry) -Algorithm SHA256).Hash
}
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($fingerprint -join "`n")))
    $version = 'build-' + [BitConverter]::ToString($digest).Replace('-', '').Substring(0, 12).ToLowerInvariant()
} finally { $sha.Dispose() }

New-Item -Path $destination -ItemType Directory -Force | Out-Null
try {
    $zip = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entry in $entries) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, (Join-Path $root $entry), $entry, [IO.Compression.CompressionLevel]::Optimal)
        }
        $writer = [IO.StreamWriter]::new($zip.CreateEntry('version.txt').Open())
        try { $writer.WriteLine($version) } finally { $writer.Dispose() }
    } finally {
        $zip.Dispose()
    }

    if ([IO.File]::Exists($archive)) {
        [IO.File]::Replace($temporary, $archive, [NullString]::Value)
    } else {
        [IO.File]::Move($temporary, $archive)
    }
    Get-Item -LiteralPath $archive
} finally {
    if ([IO.File]::Exists($temporary)) {
        [IO.File]::Delete($temporary)
    }
}
