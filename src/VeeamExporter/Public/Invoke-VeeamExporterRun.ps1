function Invoke-VeeamExporterRun {
    <#
    .SYNOPSIS
    One exporter run: log on, run each collector isolated, log off, write health.
    .DESCRIPTION
    Each collector writes its own file (veeam_<collector>.prom) and replaces it
    only on success. veeam_exporter.prom is written on every run, also when the
    credential cannot be read, the logon fails or the collector list is
    invalid (then the error is raised after writing it). Returns an object
    with Success and the per-collector results.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Credential')]
    param(
        [Parameter(Mandatory = $true)][string]$TextfileDirectory,
        [Parameter(Mandatory = $true, ParameterSetName = 'Credential')][System.Management.Automation.PSCredential]$Credential,
        # Clixml file with the PSCredential (DPAPI, created by the task account).
        # Read inside the run, so a credential that cannot be read is reported
        # like a failed logon and veeam_exporter.prom is still written.
        [Parameter(Mandatory = $true, ParameterSetName = 'CredentialPath')][string]$CredentialPath,
        [string]$BaseUri = 'https://localhost:9419',
        [AllowNull()][AllowEmptyString()][string]$CertificateThumbprint,
        [AllowNull()][AllowEmptyString()][string]$ApiVersion,
        # Comma lists ("jobs,objects") are accepted as well, see Split-VeeamListParameter.
        [string[]]$Collector = @('jobs', 'objects', 'repositories'),
        # 1 to 90. Checked by the run (no ValidateRange), so a value out of
        # range is a configuration error and veeam_exporter.prom is written.
        [int]$ObjectLookbackDays = 8,
        [string[]]$ObjectSessionType = @('BackupJob', 'ReplicaJob'),
        # Per HTTP request, 1 to 600 seconds; checked by the run like ObjectLookbackDays.
        [int]$TimeoutSec = 60
    )
    $collectorCommands = @{
        jobs         = 'Get-VeeamJobMetric'
        objects      = 'Get-VeeamObjectMetric'
        repositories = 'Get-VeeamRepositoryMetric'
    }
    $knownCollectors = @('jobs', 'objects', 'repositories')
    $results = New-Object -TypeName System.Collections.Generic.List[object]
    $session = $null
    $vbrVersion = ''
    $scriptVersion = [string]$MyInvocation.MyCommand.Module.Version
    $configError = $null

    # Everything that can fail runs inside this try, so the finally block
    # writes veeam_exporter.prom on every run (CLAUDE.md).
    try {
        try {
            # Collector names become file names and label values: lower case,
            # each one once ("Jobs,jobs" -> jobs).
            $Collector = @(Split-VeeamListParameter -Value $Collector | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
            $ObjectSessionType = @(Split-VeeamListParameter -Value $ObjectSessionType)
            foreach ($name in $Collector) {
                if (-not $collectorCommands.ContainsKey($name)) {
                    throw ("Unknown collector '{0}'. Valid: {1}" -f $name, ($knownCollectors -join ', '))
                }
            }
            if ($Collector.Count -eq 0) { throw 'No collector selected.' }
            if ($ObjectSessionType.Count -eq 0) { throw 'No session type for the objects collector.' }
            if ($ObjectLookbackDays -lt 1 -or $ObjectLookbackDays -gt 90) { throw ('ObjectLookbackDays must be between 1 and 90, got {0}.' -f $ObjectLookbackDays) }
            # Windows PowerShell 5.1 would take 0 as "no timeout", PowerShell 7
            # refuses it; the REST task is stopped after 10 minutes anyway.
            if ($TimeoutSec -lt 1 -or $TimeoutSec -gt 600) { throw ('TimeoutSec must be between 1 and 600 seconds, got {0}.' -f $TimeoutSec) }
        }
        catch {
            # Configuration error: no collector runs. The requested known
            # collectors (all of them if none is known) count as failed; the
            # error is raised again after the health file is written.
            $configError = $_
            $failed = @($knownCollectors | Where-Object { @($Collector) -contains $_ })
            if ($failed.Count -eq 0) { $failed = $knownCollectors }
            foreach ($name in $failed) { $results.Add([pscustomobject]@{ Collector = $name; Success = $false; DurationSeconds = 0 }) }
        }

        # Read locally, independent of the REST role (docs/metrics.md#OP-13),
        # but only if the REST data come from this machine as well.
        if (Test-VeeamLocalBaseUri -BaseUri $BaseUri) {
            try {
                $vbrVersion = Get-VeeamLocalServerVersion
            }
            catch {
                Write-Warning ('VBR version not readable: {0}' -f $_.Exception.Message)
            }
        }
        else {
            Write-Verbose ('{0} is not this machine; vbr_version stays empty.' -f $BaseUri)
        }

        if ($null -eq $configError) {
            $collectorArguments = @{
                jobs         = @{}
                objects      = @{ LookbackDays = $ObjectLookbackDays; SessionType = $ObjectSessionType }
                repositories = @{}
            }
            if ($PSCmdlet.ParameterSetName -eq 'CredentialPath') {
                $Credential = $null
                try {
                    $imported = Import-Clixml -LiteralPath $CredentialPath
                    if (-not ($imported -is [System.Management.Automation.PSCredential])) {
                        throw "$CredentialPath does not contain a PSCredential."
                    }
                    $Credential = $imported
                }
                catch {
                    Write-Warning ('Cannot read credential {0}: {1}' -f $CredentialPath, $_.Exception.Message)
                }
            }
            if ($null -ne $Credential) {
                try {
                    $session = Connect-VeeamServer -BaseUri $BaseUri -Credential $Credential -CertificateThumbprint $CertificateThumbprint -ApiVersion $ApiVersion -TimeoutSec $TimeoutSec
                }
                catch {
                    Write-Warning ('Logon failed: {0}' -f $_.Exception.Message)
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
    }
    finally {
        $apiVersionUsed = ''
        if ($null -ne $session) {
            $apiVersionUsed = [string]$session.ApiVersion
            try { Disconnect-VeeamServer -Session $session }
            catch { Write-Warning ('Logout failed: {0}' -f $_.Exception.Message) }
        }

        $health = New-VeeamCollectorHealthMetric -Result $results.ToArray()
        $info = New-PromMetric -Name 'veeam_exporter_info' -Help 'Exporter and server version (value always 1)'
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

    if ($null -ne $configError) { throw $configError }

    $allOk = ($results.Count -gt 0)
    foreach ($r in $results) { if (-not $r.Success) { $allOk = $false } }
    return [pscustomobject]@{
        Success    = $allOk
        ApiVersion = $apiVersionUsed
        Collectors = $results.ToArray()
    }
}
