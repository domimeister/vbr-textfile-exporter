function Invoke-VeeamExporterRun {
    <#
    .SYNOPSIS
    One exporter run: log on, run each collector isolated, log off, write health.
    .DESCRIPTION
    Each collector writes its own file (veeam_<collector>.prom) and replaces it
    only on success. veeam_exporter.prom is written on every run, also when the
    logon fails. Returns an object with Success and the per-collector results.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TextfileDirectory,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Credential,
        [string]$BaseUri = 'https://localhost:9419',
        [AllowNull()][AllowEmptyString()][string]$CertificateThumbprint,
        [AllowNull()][AllowEmptyString()][string]$ApiVersion,
        [ValidateSet('jobs', 'objects')][string[]]$Collector = @('jobs', 'objects'),
        [ValidateRange(1, 90)][int]$ObjectLookbackDays = 8,
        [ValidateNotNullOrEmpty()][string[]]$ObjectSessionType = @('BackupJob', 'ReplicaJob'),
        [int]$TimeoutSec = 60
    )
    $collectorCommands = @{
        jobs    = 'Get-VeeamJobMetric'
        objects = 'Get-VeeamObjectMetric'
    }
    $collectorArguments = @{
        jobs    = @{}
        objects = @{ LookbackDays = $ObjectLookbackDays; SessionType = $ObjectSessionType }
    }

    $results = New-Object -TypeName System.Collections.Generic.List[object]
    $session = $null
    $vbrVersion = ''
    $scriptVersion = [string]$MyInvocation.MyCommand.Module.Version

    try {
        try {
            $session = Connect-VeeamServer -BaseUri $BaseUri -Credential $Credential -CertificateThumbprint $CertificateThumbprint -ApiVersion $ApiVersion -TimeoutSec $TimeoutSec
        }
        catch {
            Write-Warning ('Logon failed: {0}' -f $_.Exception.Message)
        }

        if ($null -ne $session) {
            try {
                $serverInfo = Get-VeeamServerInfo -Session $session
                $vbrVersion = [string](Get-VeeamField -InputObject $serverInfo -Name 'buildVersion')
            }
            catch {
                Write-Warning ('serverInfo failed: {0}' -f $_.Exception.Message)
            }
        }

        foreach ($name in $Collector) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $ok = $false
            try {
                if ($null -eq $session) { throw 'No session (logon failed).' }
                $extra = $collectorArguments[$name]
                $metrics = & $collectorCommands[$name] -Session $session @extra
                $text = ConvertTo-PromText -Metric $metrics
                Write-PromFile -Directory $TextfileDirectory -Name ('veeam_{0}.prom' -f $name) -Content $text
                $ok = $true
            }
            catch {
                Write-Warning ('Collector {0} failed: {1}' -f $name, $_.Exception.Message)
            }
            finally {
                $sw.Stop()
                $results.Add([pscustomobject]@{
                        Collector       = $name
                        Success         = $ok
                        DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 3)
                    })
            }
        }
    }
    finally {
        $apiVersionUsed = ''
        if ($null -ne $session) {
            $apiVersionUsed = [string]$session.ApiVersion
            try { Disconnect-VeeamServer -Session $session }
            catch { Write-Warning ('Logout failed: {0}' -f $_.Exception.Message) }
        }

        $success = New-PromMetric -Name 'veeam_exporter_collector_success' -Help '1 letzter Lauf des Collectors ok, 0 Fehler'
        $duration = New-PromMetric -Name 'veeam_exporter_collector_duration_seconds' -Help 'Laufzeit des Collectors in Sekunden'
        $info = New-PromMetric -Name 'veeam_exporter_info' -Help 'Exporter- und Server-Version (Wert immer 1)'
        foreach ($r in $results) {
            Add-PromSample -Metric $success -Labels ([ordered]@{ collector = $r.Collector }) -Value ([int]$r.Success)
            Add-PromSample -Metric $duration -Labels ([ordered]@{ collector = $r.Collector }) -Value ([double]$r.DurationSeconds)
        }
        Add-PromSample -Metric $info -Value 1 -Labels ([ordered]@{
                script_version = $scriptVersion
                api_version    = $apiVersionUsed
                vbr_version    = $vbrVersion
            })
        try {
            Write-PromFile -Directory $TextfileDirectory -Name 'veeam_exporter.prom' -Content (ConvertTo-PromText -Metric @($success, $duration, $info))
        }
        catch {
            Write-Warning ('Writing veeam_exporter.prom failed: {0}' -f $_.Exception.Message)
        }
    }

    $allOk = ($results.Count -gt 0)
    foreach ($r in $results) { if (-not $r.Success) { $allOk = $false } }
    return [pscustomobject]@{
        Success    = $allOk
        ApiVersion = $apiVersionUsed
        Collectors = $results.ToArray()
    }
}
