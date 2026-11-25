function Get-WindowsGenuineState([guid]$ApplicationId) {
    if (-not ('WaritAutoSetup.Licensing' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace WaritAutoSetup {
    public static class Licensing {
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("slwga.dll", ExactSpelling = true)]
        public static extern int SLIsGenuineLocal(ref Guid applicationId, out int state, IntPtr uiOptions);
    }
}
"@
    }
    $state = 0
    $result = [WaritAutoSetup.Licensing]::SLIsGenuineLocal([ref]$ApplicationId, [ref]$state, [IntPtr]::Zero)
    if ($result -eq 0) { return $state }
    return $null
}

function Get-WindowsLicenseSummary {
    $applicationId = '55c92734-d682-4d71-983e-d6ec3f16059f'
    $edition = $null
    $activation = 'ตรวจสอบไม่ได้'
    $channel = 'ระบุไม่ได้'
    $genuine = 'ยืนยันไม่ได้'
    $firmware = 'ตรวจสอบไม่ได้'

    try {
        $edition = Get-ItemPropertyValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction Stop
        if ($edition -match '^[a-zA-Z0-9_]+$') {
            $products = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID = '$applicationId' AND LicenseIsAddon = FALSE AND LicenseFamily = '$edition'" `
                -Property LicenseStatus, PartialProductKey, ProductKeyChannel, Description -OperationTimeoutSec 8 -ErrorAction Stop)
            $keyed = @($products | Where-Object PartialProductKey)
            $licensed = @($keyed | Where-Object LicenseStatus -eq 1)
            $candidates = if ($licensed.Count) { $licensed } elseif ($keyed.Count) { $keyed } else { $products }
            $statuses = @($candidates | ForEach-Object LicenseStatus | Select-Object -Unique)
            if ($statuses.Count -eq 1 -and $null -ne $statuses[0]) {
                $activation = switch ($statuses[0]) {
                    0 { 'ยังไม่เปิดใช้งาน' }
                    1 { 'เปิดใช้งานแล้ว' }
                    2 { 'ยังไม่เปิดใช้งาน (อยู่ในช่วงผ่อนผัน)' }
                    3 { 'ต้องเปิดใช้งานใหม่ (อยู่ในช่วงผ่อนผัน)' }
                    4 { 'อยู่ในช่วงผ่อนผันสำหรับสิทธิ์ที่ไม่ผ่านการตรวจสอบ' }
                    5 { 'Windows แจ้งเตือนให้เปิดใช้งาน' }
                    6 { 'อยู่ในช่วงผ่อนผันแบบขยาย' }
                    default { 'ตรวจสอบไม่ได้' }
                }
            }
            if ($keyed.Count) {
                $channels = @($candidates | ForEach-Object {
                    $value = $_.ProductKeyChannel
                    if (-not $value -and $_.Description -match ',\s*([a-zA-Z0-9_:]+)\s+channel\s*$') { $value = $Matches[1] }
                    switch -Regex ($value) {
                        '^(OEM[:_].+|OEM)$' { 'OEM'; break }
                        '^Retail$' { 'Retail'; break }
                        '^Volume[:_]?(GVLK|KMSCLIENT)$' { 'Volume (KMS)'; break }
                        '^Volume[:_]?MAK$' { 'Volume (MAK)'; break }
                        '^Volume' { 'Volume'; break }
                        default { 'ระบุไม่ได้' }
                    }
                } | Select-Object -Unique)
                if ($channels.Count -eq 1) { $channel = $channels[0] }
            } elseif ($products.Count) {
                $channel = 'ไม่พบคีย์ที่ติดตั้งสำหรับรุ่นนี้'
            }
        }
    } catch {
        $activation = 'ตรวจสอบไม่ได้'
        $channel = 'ระบุไม่ได้'
    }

    try {
        $service = Get-CimInstance -ClassName SoftwareLicensingService -Property OA3xOriginalProductKey -OperationTimeoutSec 8 -ErrorAction Stop
        if ($null -ne $service) {
            $firmware = if ([string]::IsNullOrWhiteSpace($service.OA3xOriginalProductKey)) { 'ไม่พบ' } else { 'พบ' }
        }
    } catch {
        $firmware = 'ตรวจสอบไม่ได้'
    }

    try {
        $genuine = switch (Get-WindowsGenuineState ([guid]$applicationId)) {
            0 { 'ผ่านการตรวจสอบในเครื่อง' }
            1 { 'ไม่ผ่าน: Windows รายงานว่าไม่มีสิทธิ์ที่ใช้ได้' }
            2 { 'ไม่ผ่าน: Windows รายงานว่าพบการดัดแปลงสิทธิ์' }
            default { 'ยืนยันไม่ได้' }
        }
    } catch {
        $genuine = 'ยืนยันไม่ได้'
    }

    if (-not $edition) { $edition = 'ระบุไม่ได้' }
    "รุ่น (Edition): $edition`nสถานะ Activation: $activation`nช่องทางคีย์ที่ใช้อยู่: $channel`nคีย์ OEM ในเฟิร์มแวร์: $firmware`nผลตรวจความถูกต้องในเครื่อง: $genuine"
}
