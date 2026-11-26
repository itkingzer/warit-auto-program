param([switch]$AutoInstall)

$ErrorActionPreference = 'Stop'
$startup = [Environment]::GetFolderPath('Startup')
if (-not $startup) { return }
$path = Join-Path $startup 'Warit Auto Setup.lnk'
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($path)
$launcher = Join-Path $PSScriptRoot 'Start-AutoSetup.vbs'
$gui = Join-Path $PSScriptRoot 'AutoSetup-GUI.ps1'
$scriptArguments = '"{0}" -StartupLaunch' -f $launcher
$powershellArguments = '-NoProfile -STA -ExecutionPolicy RemoteSigned -File "{0}" -StartupLaunch' -f $gui
$legacyArguments = @($scriptArguments, "$scriptArguments -AutoInstall",
    $powershellArguments, "$powershellArguments -AutoInstall")
if ($shortcut.Arguments -in $legacyArguments) {
    Remove-Item -LiteralPath $path -ErrorAction Stop
}
