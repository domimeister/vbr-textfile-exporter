function Invoke-VeeamLicenseExporterRun {
    <#
    .SYNOPSIS
    License task run: Veeam PowerShell module -> veeam_license.prom, health -> veeam_exporter_license.prom.
    .DESCRIPTION
    Runs as SYSTEM or a local account with the Backup Administrator role on
    the VBR server, without a stored password. veeam_license.prom is replaced
    only on success; veeam_exporter_license.prom is written on every run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TextfileDirectory,
        [string]$ModuleName = 'Veeam.Backup.PowerShell'
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $false
    try {
        Import-VeeamBackupModule -Name $ModuleName
        $connected = Connect-VeeamLocalServer
        try {
            $license = Get-VeeamInstalledLicense
            $metrics = Get-VeeamLicenseMetric -License $license
            Write-PromFile -Directory $TextfileDirectory -Name 'veeam_license.prom' -Content (ConvertTo-PromText -Metric $metrics)
            $ok = $true
        }
        finally {
            if ($connected) {
                try { Disconnect-VeeamLocalServer }
                catch { Write-Warning ('Disconnect-VBRServer failed: {0}' -f $_.Exception.Message) }
            }
        }
    }
    catch {
        Write-Warning ('Collector license failed: {0}' -f $_.Exception.Message)
    }
    finally {
        $sw.Stop()
        $result = [pscustomobject]@{
            Collector       = 'license'
            Success         = $ok
            DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 3)
        }
        try {
            $health = New-VeeamCollectorHealthMetric -Result @($result)
            Write-PromFile -Directory $TextfileDirectory -Name 'veeam_exporter_license.prom' -Content (ConvertTo-PromText -Metric $health)
        }
        catch {
            Write-Warning ('Writing veeam_exporter_license.prom failed: {0}' -f $_.Exception.Message)
        }
    }
    return [pscustomobject]@{
        Success    = $ok
        Collectors = @($result)
    }
}
