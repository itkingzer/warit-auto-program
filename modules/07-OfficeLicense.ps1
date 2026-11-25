function Get-OfficeLicenseSummary {
    $configurationKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $configuration = if (Test-Path -LiteralPath $configurationKey) { Get-ItemProperty -LiteralPath $configurationKey -ErrorAction Stop }
    if (($configuration.ProductReleaseIds -split ',\s*') -notcontains 'ProPlus2024Retail') {
        return @{ Text = 'ยังไม่พบ Office Professional Plus 2024 Retail'; CanInstall = $true }
    }
    @{ Text = 'ติดตั้ง Office Professional Plus 2024 Retail แล้ว · ตรวจสถานะการเปิดใช้งานได้ที่ File > Account ในแอป Office'; CanInstall = $false }
}
