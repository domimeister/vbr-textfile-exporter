function New-OrdinalDictionary {
    # Case-sensitive dictionary: label values are case-sensitive, PowerShell
    # hashtables are not.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()
    return (New-Object -TypeName 'System.Collections.Generic.Dictionary[string,object]' -ArgumentList ([System.StringComparer]::Ordinal))
}

function Get-VeeamGuidKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][object]$Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim().ToLowerInvariant()
}

function Select-VeeamLatestObjectTask {
    <#
    Joins task sessions to jobs and returns one entry per job and object that
    is in the current scope of its job: the newest task (Task) and the newest
    task that ended with Success or Warning (LastSuccess, $null if there is
    none in the data).
    Job name: name from jobs/states via jobId; for jobIds missing there the
    name of the newest session of that job. Tasks whose session is unknown or
    that have no object name are skipped. Output is sorted ordinally by job
    name, then object, so the file content is stable.

    Scope (docs/metrics.md, "Unprotected VMs"): the sessions of a job form
    runs. A retry belongs to the run it retries: it carries the id of the
    first session of the run (originalSessionId), or it only processes objects
    that failed in the run so far (a retry session contains just the failed
    objects). The scope of a job is what its newest run processed; while that
    run is still open (first session running or cancelled), the run before it
    counts as well. Sessions without tasks never change the scope, so a job
    that fails before it processes anything keeps its objects. A job whose
    sessions cannot be put in order keeps all its objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$JobState,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$JobSession,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$TaskSession
    )
    $jobNames = New-OrdinalDictionary
    foreach ($job in $JobState) {
        $id = Get-VeeamGuidKey -Value (Get-VeeamField -InputObject $job -Name 'id')
        $name = [string](Get-VeeamField -InputObject $job -Name 'name')
        if ($id -and $name) { $jobNames[$id] = $name }
    }

    # sessionId -> jobId, per jobId the name of its newest session, and what
    # the scope needs of every session.
    $sessionJob = New-OrdinalDictionary
    $sessionInfo = New-OrdinalDictionary
    $fallbackName = New-OrdinalDictionary
    $fallbackTime = New-OrdinalDictionary
    foreach ($s in $JobSession) {
        $sid = Get-VeeamGuidKey -Value (Get-VeeamField -InputObject $s -Name 'id')
        $jid = Get-VeeamGuidKey -Value (Get-VeeamField -InputObject $s -Name 'jobId')
        if (-not $sid -or -not $jid) { continue }
        $sessionJob[$sid] = $jid
        $created = ConvertTo-VeeamFieldValue -Value (Get-VeeamField -InputObject $s -Name 'creationTime') -Field 'creationTime' -Item ('Session {0}' -f $sid) `
            -Conversion { param($v) ConvertTo-VeeamDateTimeOffset -Value $v }
        $sessionResult = Get-VeeamField -InputObject $s -Name 'result'
        $sessionUsn = [int64]-1
        try { $rawUsn = Get-VeeamField -InputObject $s -Name 'usn'; if ($null -ne $rawUsn) { $sessionUsn = [int64]$rawUsn } }
        catch { Write-Verbose ('Session {0}: usn not readable for ordering.' -f $sid) }
        # Open: no result yet (running), or cancelled before it was through.
        $state = [string](Get-VeeamField -InputObject $s -Name 'state')
        $open = ((ConvertTo-VeeamResultCode -Result (Get-VeeamField -InputObject $sessionResult -Name 'result')) -eq -1) -or
            ($state -and $state -ne 'Stopped') -or ((Get-VeeamField -InputObject $sessionResult -Name 'isCanceled') -eq $true)
        $sessionInfo[$sid] = [pscustomobject]@{
            Id       = $sid
            JobId    = $jid
            Created  = $created
            Usn      = $sessionUsn
            # ASSUMPTION: originalSessionId names the first session of the run for retries, see docs/metrics.md#OP-16
            Original = Get-VeeamGuidKey -Value (Get-VeeamField -InputObject $s -Name 'originalSessionId')
            Open     = [bool]$open
        }
        $name = [string](Get-VeeamField -InputObject $s -Name 'name')
        if (-not $name) { continue }
        $isNewer = -not $fallbackTime.ContainsKey($jid)
        if (-not $isNewer -and $null -ne $created) {
            $known = $fallbackTime[$jid]
            $isNewer = ($null -eq $known) -or ($created -gt $known)
        }
        if ($isNewer) {
            $fallbackName[$jid] = $name
            $fallbackTime[$jid] = $created
        }
    }

    $latest = New-OrdinalDictionary
    $latestSuccess = New-OrdinalDictionary
    # sessionId -> object -> $true if its newest task in that session did not end with Success or Warning
    $sessionObjects = New-OrdinalDictionary
    $sessionObjectOrder = New-OrdinalDictionary
    $skipped = 0
    foreach ($task in $TaskSession) {
        # Hot loop over every task session of the lookback (tens of thousands
        # in a large environment): fields are read inline, not through
        # Get-VeeamField/Get-VeeamGuidKey/ConvertTo-VeeamFieldValue. Under
        # Windows PowerShell 5.1 every function call costs about 0.1 ms.
        $props = $task.PSObject.Properties
        $sid = ''
        $p = $props['sessionId']
        if ($null -ne $p -and $null -ne $p.Value) { $sid = ([string]$p.Value).Trim().ToLowerInvariant() }
        $object = ''
        $p = $props['name']
        if ($null -ne $p -and $null -ne $p.Value) { $object = [string]$p.Value }
        if (-not $sid -or -not $sessionJob.ContainsKey($sid) -or -not $object) {
            $skipped++
            continue
        }
        $jid = $sessionJob[$sid]
        $jobName = $null
        if ($jobNames.ContainsKey($jid)) { $jobName = $jobNames[$jid] }
        elseif ($fallbackName.ContainsKey($jid)) { $jobName = $fallbackName[$jid] }
        if (-not $jobName) {
            $skipped++
            continue
        }

        # A creation time or usn that cannot be read only weakens the choice of
        # the newest task; it is reported once with the object (Get-VeeamObjectMetric).
        $created = $null
        $p = $props['creationTime']
        if ($null -ne $p -and $null -ne $p.Value) {
            try { $created = ConvertTo-VeeamDateTimeOffset -Value $p.Value }
            catch { Write-Verbose ("Task '{0}' in job '{1}': creationTime not readable for ordering." -f $object, $jobName) }
        }
        $usn = [int64]-1
        $p = $props['usn']
        if ($null -ne $p -and $null -ne $p.Value) {
            try { $usn = [int64]$p.Value }
            catch { Write-Warning ("Task '{0}' in job '{1}': field usn skipped: {2}" -f $object, $jobName, $_.Exception.Message) }
        }
        # Success and Warning leave a restore point; everything else (Failed,
        # None while running, unknown values) does not count as a backup.
        $good = $false
        $p = $props['result']
        if ($null -ne $p -and $null -ne $p.Value) {
            $r = $p.Value.PSObject.Properties['result']
            if ($null -ne $r -and $null -ne $r.Value) {
                $text = ([string]$r.Value).Trim()
                $good = [string]::Equals($text, 'Success', [System.StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($text, 'Warning', [System.StringComparison]::OrdinalIgnoreCase)
            }
        }

        # What the session processed, with the state of the newest task per object.
        if (-not $sessionObjects.ContainsKey($sid)) {
            $sessionObjects[$sid] = New-OrdinalDictionary
            $sessionObjectOrder[$sid] = New-OrdinalDictionary
        }
        $order = $sessionObjectOrder[$sid]
        $replace = -not $order.ContainsKey($object)
        if (-not $replace) {
            $known = $order[$object]
            if ($null -eq $known.Created) { $replace = ($null -ne $created) -or ($usn -gt $known.Usn) }
            elseif ($null -ne $created) { $replace = ($created -gt $known.Created) -or ($created -eq $known.Created -and $usn -gt $known.Usn) }
        }
        if ($replace) {
            $order[$object] = [pscustomobject]@{ Created = $created; Usn = $usn }
            $sessionObjects[$sid][$object] = (-not $good)
        }

        $key = $jobName + [char]0 + $object
        $entry = $null
        foreach ($target in @($latest, $latestSuccess)) {
            if ([object]::ReferenceEquals($target, $latestSuccess) -and -not $good) { continue }
            if ($target.ContainsKey($key)) {
                $current = $target[$key]
                $newer = $false
                if ($null -eq $current.Created) { $newer = ($null -ne $created) -or ($usn -gt $current.Usn) }
                elseif ($null -ne $created) {
                    if ($created -gt $current.Created) { $newer = $true }
                    elseif ($created -eq $current.Created -and $usn -gt $current.Usn) { $newer = $true }
                }
                if (-not $newer) { continue }
            }
            if ($null -eq $entry) {
                $entry = [pscustomobject]@{
                    JobName     = $jobName
                    Object      = $object
                    Created     = $created
                    Usn         = $usn
                    Task        = $task
                    LastSuccess = $null
                }
            }
            $target[$key] = $entry
        }
    }
    if ($skipped -gt 0) { Write-Verbose "Objects: skipped $skipped task sessions without known session, job or object name." }

    # Scope per job: the objects of its newest run.
    $jobSessions = New-OrdinalDictionary
    foreach ($sid in $sessionObjects.Keys) {
        $info = $sessionInfo[$sid]
        if (-not $jobSessions.ContainsKey($info.JobId)) { $jobSessions[$info.JobId] = New-Object -TypeName 'System.Collections.Generic.List[object]' }
        $jobSessions[$info.JobId].Add($info)
    }
    $inScope = New-OrdinalDictionary
    $unfiltered = New-OrdinalDictionary
    foreach ($jid in $jobSessions.Keys) {
        $jobName = $null
        if ($jobNames.ContainsKey($jid)) { $jobName = $jobNames[$jid] }
        elseif ($fallbackName.ContainsKey($jid)) { $jobName = $fallbackName[$jid] }
        if (-not $jobName) { continue }
        $list = $jobSessions[$jid]
        if (@($list | Where-Object { $null -eq $_.Created }).Count -gt 0) {
            $unfiltered[$jobName] = $true
            continue
        }
        $ordered = @($list | Sort-Object -Property @{ Expression = { $_.Created } }, @{ Expression = { $_.Usn } })
        $previous = $null
        $run = $null
        foreach ($info in $ordered) {
            $objects = $sessionObjects[$info.Id]
            $continues = $false
            if ($null -ne $run) {
                if ($info.Original -and $info.Original -ne $info.Id -and $info.Original -eq $run.Key) { $continues = $true }
                else {
                    $continues = $true
                    foreach ($object in $objects.Keys) {
                        if (-not $run.Failed.ContainsKey($object) -or -not $run.Failed[$object]) { $continues = $false; break }
                    }
                }
            }
            if (-not $continues) {
                $previous = $run
                $key = $info.Id
                if ($info.Original) { $key = $info.Original }
                $run = [pscustomobject]@{ Key = $key; Open = $info.Open; Failed = (New-OrdinalDictionary) }
            }
            foreach ($object in $objects.Keys) { $run.Failed[$object] = $objects[$object] }
        }
        $runs = @($run)
        if ($run.Open -and $null -ne $previous) { $runs += $previous }
        foreach ($r in $runs) {
            foreach ($object in $r.Failed.Keys) { $inScope[$jobName + [char]0 + $object] = $true }
        }
    }

    $keys = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $dropped = 0
    foreach ($k in $latest.Keys) {
        if ($inScope.ContainsKey($k) -or $unfiltered.ContainsKey($latest[$k].JobName)) { $keys.Add($k) }
        else { $dropped++ }
    }
    if ($dropped -gt 0) { Write-Verbose "Objects: left out $dropped objects that the newest run of their job did not process." }
    $keys.Sort([System.StringComparer]::Ordinal)
    foreach ($k in $keys) {
        $entry = $latest[$k]
        $success = $null
        if ($latestSuccess.ContainsKey($k)) { $success = $latestSuccess[$k].Task }
        [pscustomobject]@{
            JobName     = $entry.JobName
            Object      = $entry.Object
            Created     = $entry.Created
            Usn         = $entry.Usn
            Task        = $entry.Task
            LastSuccess = $success
        }
    }
}
