$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$destination = Join-Path $root 'dist'
$archive = Join-Path $destination 'Warit-AutoSetup-App.zip'
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
$entries += Get-ChildItem -LiteralPath (Join-Path $root 'modules') -Filter '*.ps1' -File |
    ForEach-Object { 'modules/' + $_.Name }

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
New-Item -Path $destination -ItemType Directory -Force | Out-Null
try {
    $zip = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entry in $entries) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, (Join-Path $root $entry), $entry, [IO.Compression.CompressionLevel]::Optimal)
        }
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
