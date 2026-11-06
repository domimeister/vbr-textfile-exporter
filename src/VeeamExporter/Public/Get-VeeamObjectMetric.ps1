function Get-VeeamObjectMetric {
    <#
    .SYNOPSIS
    Objects collector: newest task session per job and object -> metrics for veeam_objects.prom.
    .DESCRIPTION
    Follows docs/metrics.md, section "Nicht gesicherte VMs (pro Objekt)":
    jobs/states for the job names, sessions and taskSessions per session type
    (one request per type, 1.2-rev1 accepts a single value only), all pages.
    Pass -JobState, -JobSession and -TaskSession to build the metrics from
    already loaded data (tests).
    #>
    [CmdletBinding(DefaultParameterSetName = 'Session')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Session')][object]$Session,
        [Parameter(ParameterSetName = 'Session')][ValidateRange(1, 90)][int]$LookbackDays = 8,
        [Parameter(ParameterSetName = 'Session')][ValidateNotNullOrEmpty()][string[]]$SessionType = @('BackupJob', 'ReplicaJob'),
        [Parameter(Mandatory = $true, ParameterSetName = 'Data')][AllowEmptyCollection()][object[]]$JobState,
        [Parameter(Mandatory = $true, ParameterSetName = 'Data')][AllowEmptyCollection()][object[]]$JobSession,
        [Parameter(Mandatory = $true, ParameterSetName = 'Data')][AllowEmptyCollection()][object[]]$TaskSession
    )
    if ($PSCmdlet.ParameterSetName -eq 'Session') {
        $taskCutoff = [System.DateTimeOffset]::UtcNow.AddDays(-$LookbackDays)
        # One extra day for sessions that started before the cutoff.
        $sessionCutoff = $taskCutoff.AddDays(-1)

        $JobState = @(Get-VeeamPagedItem -Session $Session -Path '/api/v1/jobs/states')
        $sessions = New-Object -TypeName System.Collections.Generic.List[object]
        $tasks = New-Object -TypeName System.Collections.Generic.List[object]
        foreach ($type in $SessionType) {
            $sessionQuery = [ordered]@{
                typeFilter         = $type
                createdAfterFilter = (ConvertTo-VeeamFilterTimestamp -Value $sessionCutoff)
            }
            foreach ($item in @(Get-VeeamPagedItem -Session $Session -Path '/api/v1/sessions' -Query $sessionQuery)) { $sessions.Add($item) }

            $taskQuery = [ordered]@{
                sessionTypeFilter  = $type
                createdAfterFilter = (ConvertTo-VeeamFilterTimestamp -Value $taskCutoff)
            }
            foreach ($item in @(Get-VeeamPagedItem -Session $Session -Path '/api/v1/taskSessions' -Query $taskQuery)) { $tasks.Add($item) }
        }
        $JobSession = $sessions.ToArray()
        $TaskSession = $tasks.ToArray()
    }

    $lastResult = New-PromMetric -Name 'veeam_object_last_result' -Help 'Letzter Task-Lauf: 0 Success, 1 Warning, 2 Failed, -1 None'
    $lastRun = New-PromMetric -Name 'veeam_object_last_run_timestamp_seconds' -Help 'Ende des letzten Task-Laufs als Unix-Zeit (Start, solange er laeuft)'
    $processed = New-PromMetric -Name 'veeam_object_last_processed_bytes' -Help 'Im letzten Task-Lauf verarbeitete Bytes'
    $failure = New-PromMetric -Name 'veeam_object_last_failure_info' -Help 'Meldung des letzten Task-Laufs bei Warning oder Failed (Wert immer 1)'

    $selected = @(Select-VeeamLatestObjectTask -JobState @($JobState) -JobSession @($JobSession) -TaskSession @($TaskSession))
    foreach ($entry in $selected) {
        $task = $entry.Task
        $labels = [ordered]@{ job_name = $entry.JobName; object = $entry.Object }
        $result = Get-VeeamField -InputObject $task -Name 'result'
        $code = ConvertTo-VeeamResultCode -Result (Get-VeeamField -InputObject $result -Name 'result')
        Add-PromSample -Metric $lastResult -Labels $labels -Value $code

        # End time, or the creation time while the task is still running.
        $created = ConvertTo-UnixTimestamp -Value (Get-VeeamField -InputObject $task -Name 'creationTime')
        $ended = ConvertTo-UnixTimestamp -Value (Get-VeeamField -InputObject $task -Name 'endTime')
        $runTime = $ended
        if ($null -eq $ended -or ($null -ne $created -and $ended -lt $created)) { $runTime = $created }
        Add-PromSample -Metric $lastRun -Labels $labels -Value $runTime

        $size = Get-VeeamField -InputObject (Get-VeeamField -InputObject $task -Name 'progress') -Name 'processedSize'
        if ($null -ne $size) { $size = [int64]$size }
        Add-PromSample -Metric $processed -Labels $labels -Value $size

        if ($code -eq 1 -or $code -eq 2) {
            $message = Format-VeeamResultMessage -Message (Get-VeeamField -InputObject $result -Name 'message')
            Add-PromSample -Metric $failure -Value 1 -Labels ([ordered]@{
                    job_name = $entry.JobName
                    object   = $entry.Object
                    message  = $message
                })
        }
    }

    return @($lastResult, $lastRun, $processed, $failure)
}
