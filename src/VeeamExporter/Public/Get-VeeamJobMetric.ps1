function Get-VeeamJobMetric {
    <#
    .SYNOPSIS
    Jobs collector: GET /api/v1/jobs/states (all pages) -> metrics for veeam_jobs.prom.
    .DESCRIPTION
    Metric names, labels and value codes follow docs/metrics.md, section
    "Jobs & Resultate". Pass -JobState to build metrics from already loaded
    states (tests).
    #>
    [CmdletBinding(DefaultParameterSetName = 'Session')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Session')][object]$Session,
        [Parameter(Mandatory = $true, ParameterSetName = 'State')][AllowEmptyCollection()][object[]]$JobState
    )
    if ($PSCmdlet.ParameterSetName -eq 'Session') {
        $JobState = @(Get-VeeamPagedItem -Session $Session -Path '/api/v1/jobs/states')
    }

    $info = New-PromMetric -Name 'veeam_job_info' -Help 'Veeam Job (Wert immer 1)'
    $lastResult = New-PromMetric -Name 'veeam_job_last_result' -Help 'Resultat des letzten Laufs: 0 Success, 1 Warning, 2 Failed, -1 None'
    $enabled = New-PromMetric -Name 'veeam_job_enabled' -Help '1 Job aktiv, 0 deaktiviert'
    $running = New-PromMetric -Name 'veeam_job_running' -Help '1 wenn der Job gerade aktiv ist (running, starting, stopping)'
    $lastRun = New-PromMetric -Name 'veeam_job_last_run_timestamp_seconds' -Help 'Start des letzten Laufs als Unix-Zeit'
    $nextRun = New-PromMetric -Name 'veeam_job_next_run_timestamp_seconds' -Help 'Naechster geplanter Lauf als Unix-Zeit (fehlt bei verketteten Jobs)'
    $objects = New-PromMetric -Name 'veeam_job_objects' -Help 'Anzahl Objekte im Job'

    foreach ($job in $JobState) {
        $name = [string](Get-VeeamField -InputObject $job -Name 'name')
        $type = [string](Get-VeeamField -InputObject $job -Name 'type')
        $status = [string](Get-VeeamField -InputObject $job -Name 'status')

        Add-PromSample -Metric $info -Value 1 -Labels ([ordered]@{
                job_name   = $name
                job_id     = [string](Get-VeeamField -InputObject $job -Name 'id')
                job_type   = $type
                workload   = [string](Get-VeeamField -InputObject $job -Name 'workload')
                repository = [string](Get-VeeamField -InputObject $job -Name 'repositoryName')
            })

        Add-PromSample -Metric $lastResult -Labels ([ordered]@{ job_name = $name; job_type = $type }) `
            -Value (ConvertTo-VeeamResultCode -Result (Get-VeeamField -InputObject $job -Name 'lastResult'))

        $isEnabled = 1
        if ($status -match '^(?i)disabled$') { $isEnabled = 0 }
        Add-PromSample -Metric $enabled -Labels ([ordered]@{ job_name = $name }) -Value $isEnabled

        $isRunning = 0
        if ($status -match '^(?i)(running|starting|stopping)$') { $isRunning = 1 }
        Add-PromSample -Metric $running -Labels ([ordered]@{ job_name = $name }) -Value $isRunning

        # ANNAHME: no lastRun means the series is missing, see docs/metrics.md#OP-10
        Add-PromSample -Metric $lastRun -Labels ([ordered]@{ job_name = $name }) `
            -Value (ConvertTo-UnixTimestamp -Value (Get-VeeamField -InputObject $job -Name 'lastRun'))
        Add-PromSample -Metric $nextRun -Labels ([ordered]@{ job_name = $name }) `
            -Value (ConvertTo-UnixTimestamp -Value (Get-VeeamField -InputObject $job -Name 'nextRun'))

        $count = Get-VeeamField -InputObject $job -Name 'objectsCount'
        if ($null -ne $count) { $count = [int64]$count }
        Add-PromSample -Metric $objects -Labels ([ordered]@{ job_name = $name }) -Value $count
    }

    return @($info, $lastResult, $enabled, $running, $lastRun, $nextRun, $objects)
}
