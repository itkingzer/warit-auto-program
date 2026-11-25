$defenderRead = $false
try {
    $defender = Get-MpComputerStatus -ErrorAction Stop
    if ($null -eq $defender.RealTimeProtectionEnabled) { throw 'Defender status unavailable' }
    $defenderRead = $true
    $status = if ($defender.RealTimeProtectionEnabled) { 'เปิด' } else { 'ปิด' }
} catch {
    $status = 'ตรวจสถานะไม่ได้'
}
[pscustomobject]@{
    Detail = "Microsoft Defender (การป้องกันแบบเรียลไทม์) — $status"
    RealtimeEnabled = $defenderRead -and [bool]$defender.RealTimeProtectionEnabled
    SecurityCenterActive = $false
}

try {
    $products = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntivirusProduct -OperationTimeoutSec 5 -ErrorAction Stop
    foreach ($product in $products) {
        $isDefender = $product.displayName -match '^(Microsoft|Windows) Defender( Antivirus)?$'
        if ($isDefender -and $defenderRead) { continue }

        $status = 'ไม่ทราบสถานะ'
        if ($null -ne $product.productState) {
            $status = switch (([int]$product.productState -shr 8) -band 0xFF) {
                0x00 { 'ปิด' }
                0x01 { 'พักการป้องกัน' }
                0x10 { 'เปิด' }
                0x11 { 'หมดอายุ' }
                default { 'ไม่ทราบสถานะ' }
            }
        }
        [pscustomobject]@{
            Detail = "$($product.displayName) (Windows Security Center) — $status"
            RealtimeEnabled = $false
            SecurityCenterActive = $status -eq 'เปิด'
        }
    }
} catch {
    [pscustomobject]@{
        Detail = 'ตรวจสถานะจาก Windows Security Center ไม่ได้'
        RealtimeEnabled = $false
        SecurityCenterActive = $false
    }
}
