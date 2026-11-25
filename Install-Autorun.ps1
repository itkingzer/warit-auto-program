param([switch]$AutoInstall)

$ErrorActionPreference = 'Stop'
$gui = Join-Path $PSScriptRoot 'AutoSetup-GUI.ps1'
if (-not (Test-Path -LiteralPath $gui -PathType Leaf)) { throw 'AutoSetup-GUI.ps1 not found.' }
$launcher = Join-Path $PSScriptRoot 'Start-AutoSetup.vbs'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Start-AutoSetup.vbs not found.' }

$startup = [Environment]::GetFolderPath('Startup', 'Create')
if (-not $startup) { throw 'Windows Startup folder not found.' }

$path = Join-Path $startup 'Warit Auto Setup.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($path)
$shortcut.TargetPath = "$env:SystemRoot\System32\wscript.exe"
$shortcut.Arguments = '"{0}" -StartupLaunch' -f $launcher
if ($AutoInstall) { $shortcut.Arguments += ' -AutoInstall' }
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.IconLocation = '{0},0' -f (Join-Path $PSScriptRoot 'assets\app.ico')
$shortcut.Save()
Write-Output $path
