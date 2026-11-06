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
        # Comma lists ("jobs,objects") are accepted as well, see Split-VeeamListParameter.
        [string[]]$Collector = @('jobs', 'objects', 'repositories'),
        [ValidateRange(1, 90)][int]$ObjectLookbackDays = 8,
        [string[]]$ObjectSessionType = @('BackupJob', 'ReplicaJob'),
        [int]$TimeoutSec = 60
    )
    $collectorCommands = @{
        jobs         = 'Get-VeeamJobMetric'
        objects      = 'Get-VeeamObjectMetric'
        repositories = 'Get-VeeamRepositoryMetric'
    }
    $Collector = @(Split-VeeamListParameter -Value $Collector)
    $ObjectSessionType = @(Split-VeeamListParameter -Value $ObjectSessionType)
    foreach ($name in $Collector) {
        if (-not $collectorCommands.ContainsKey($name)) {
            throw ("Unknown collector '{0}'. Valid: {1}" -f $name, (($collectorCommands.Keys | Sort-Object) -join ', '))
        }
    }
    if ($Collector.Count -eq 0) { throw 'No collector selected.' }
    if ($ObjectSessionType.Count -eq 0) { throw 'No session type for the objects collector.' }
    $collectorArguments = @{
        jobs         = @{}
        objects      = @{ LookbackDays = $ObjectLookbackDays; SessionType = $ObjectSessionType }
        repositories = @{}
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
                # serverInfo is for Backup Administrator only (docs/metrics.md#OP-13):
                # with the Viewer role a 403 is expected, vbr_version stays empty.
                if ($_.Exception.Message -match 'HTTP 403') {
                    Write-Verbose ('serverInfo not permitted for this account: {0}' -f $_.Exception.Message)
                }
                else {
                    Write-Warning ('serverInfo failed: {0}' -f $_.Exception.Message)
                }
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

        $health = New-VeeamCollectorHealthMetric -Result $results.ToArray()
        $info = New-PromMetric -Name 'veeam_exporter_info' -Help 'Exporter- und Server-Version (Wert immer 1)'
        Add-PromSample -Metric $info -Value 1 -Labels ([ordered]@{
                script_version = $scriptVersion
                api_version    = $apiVersionUsed
                vbr_version    = $vbrVersion
            })
        try {
            Write-PromFile -Directory $TextfileDirectory -Name 'veeam_exporter.prom' -Content (ConvertTo-PromText -Metric (@($health) + @($info)))
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
