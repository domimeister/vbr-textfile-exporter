function Get-VeeamObjectMetric {
    <#
    .SYNOPSIS
    Objects collector: newest task session per job and object -> metrics for veeam_objects.prom.
    .DESCRIPTION
    Follows docs/metrics.md, section "Unprotected VMs (per object)":
    jobs/states for the job names, sessions per session type (one request per
    type), task sessions once for the lookback and filtered by their sessionId,
    all pages.
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
        $sessionIds = New-OrdinalDictionary
        foreach ($type in $SessionType) {
            $sessionQuery = [ordered]@{
                typeFilter         = $type
                createdAfterFilter = (ConvertTo-VeeamFilterTimestamp -Value $sessionCutoff)
            }
            foreach ($item in @(Get-VeeamPagedItem -Session $Session -Path '/api/v1/sessions' -Query $sessionQuery)) {
                $sessions.Add($item)
                $sid = Get-VeeamGuidKey -Value (Get-VeeamField -InputObject $item -Name 'id')
                if ($sid) { $sessionIds[$sid] = $true }
            }
        }

        # Task sessions once, without sessionTypeFilter: on VBR 13.1 the filter
        # matches no file share tasks, although they report sessionType BackupJob
        # (lab test, #21). Keep the tasks whose session was loaded above.
        $taskQuery = [ordered]@{ createdAfterFilter = (ConvertTo-VeeamFilterTimestamp -Value $taskCutoff) }
        $tasks = New-Object -TypeName System.Collections.Generic.List[object]
        foreach ($item in @(Get-VeeamPagedItem -Session $Session -Path '/api/v1/taskSessions' -Query $taskQuery)) {
            $sid = Get-VeeamGuidKey -Value (Get-VeeamField -InputObject $item -Name 'sessionId')
            if ($sid -and $sessionIds.ContainsKey($sid)) { $tasks.Add($item) }
        }
        $JobSession = $sessions.ToArray()
        $TaskSession = $tasks.ToArray()
    }

    $lastResult = New-PromMetric -Name 'veeam_object_last_result' -Help 'Last task run: 0 Success, 1 Warning, 2 Failed, -1 None'
    $lastRun = New-PromMetric -Name 'veeam_object_last_run_timestamp_seconds' -Help 'End of the last task run as Unix time (start while it is running)'
    $processed = New-PromMetric -Name 'veeam_object_last_processed_bytes' -Help 'Bytes processed in the last task run'
    $failure = New-PromMetric -Name 'veeam_object_last_failure_info' -Help 'Message of the last task run on Warning or Failed (value always 1)'

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
