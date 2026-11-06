function Get-VeeamLicenseMetric {
    <#
    .SYNOPSIS
    License collector: VBRInstalledLicense object(s) -> metrics for veeam_license.prom.
    .DESCRIPTION
    Follows docs/metrics.md, section "License Expiration". Pure conversion; the
    license itself comes from Get-VBRInstalledLicense (Invoke-VeeamLicenseExporterRun).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$License
    )
    $items = @($License | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) { throw 'Get-VBRInstalledLicense returned no license.' }
    if ($items.Count -gt 1) {
        # ASSUMPTION: one license object; with more, the first one counts, see docs/metrics.md#OP-3
        Write-Warning ('Get-VBRInstalledLicense returned {0} objects, using the first.' -f $items.Count)
    }
    $lic = $items[0]
    $status = [string](Get-VeeamField -InputObject $lic -Name 'Status')

    $info = New-PromMetric -Name 'veeam_license_info' -Help 'Installed Veeam license (value always 1)'
    $valid = New-PromMetric -Name 'veeam_license_valid' -Help '1 if the license status is Valid, otherwise 0'
    $expiration = New-PromMetric -Name 'veeam_license_expiration_timestamp_seconds' -Help 'License expiration as Unix time (missing for perpetual licenses)'
    $support = New-PromMetric -Name 'veeam_license_support_expiration_timestamp_seconds' -Help 'Support expiration as Unix time'
    $licensed = New-PromMetric -Name 'veeam_license_instances_licensed' -Help 'Licensed instances'
    $used = New-PromMetric -Name 'veeam_license_instances_used' -Help 'Used instances'

    Add-PromSample -Metric $info -Value 1 -Labels ([ordered]@{
            edition      = [string](Get-VeeamField -InputObject $lic -Name 'Edition')
            license_type = [string](Get-VeeamField -InputObject $lic -Name 'Type')
            status       = $status
            licensed_to  = [string](Get-VeeamField -InputObject $lic -Name 'LicensedTo')
        })
    $isValid = 0
    if ($status -match '^(?i)valid$') { $isValid = 1 }
    Add-PromSample -Metric $valid -Value $isValid
    Add-PromSample -Metric $expiration -Value (ConvertTo-UnixTimestamp -Value (Get-VeeamField -InputObject $lic -Name 'ExpirationDate'))
    Add-PromSample -Metric $support -Value (ConvertTo-UnixTimestamp -Value (Get-VeeamField -InputObject $lic -Name 'SupportExpirationDate'))

    # InstanceLicenseSummary is a single object in the docs; sum in case of an array.
    $licensedSum = $null
    $usedSum = $null
    foreach ($summary in @(Get-VeeamField -InputObject $lic -Name 'InstanceLicenseSummary')) {
        if ($null -eq $summary) { continue }
        $l = Get-VeeamField -InputObject $summary -Name 'LicensedInstancesNumber'
        $u = Get-VeeamField -InputObject $summary -Name 'UsedInstancesNumber'
        if ($null -ne $l) { $licensedSum = [double]$licensedSum + [System.Convert]::ToDouble($l, [System.Globalization.CultureInfo]::InvariantCulture) }
        if ($null -ne $u) { $usedSum = [double]$usedSum + [System.Convert]::ToDouble($u, [System.Globalization.CultureInfo]::InvariantCulture) }
    }
    Add-PromSample -Metric $licensed -Value (ConvertTo-VeeamCount -Value $licensedSum)
    Add-PromSample -Metric $used -Value (ConvertTo-VeeamCount -Value $usedSum)

    return @($info, $valid, $expiration, $support, $licensed, $used)
}
