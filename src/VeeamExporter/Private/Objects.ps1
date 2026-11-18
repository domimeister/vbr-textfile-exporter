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
    none in the data). Objects of the same name in one session count as one:
    the worst result wins, and the session is a backup only if none failed.
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
            # First session of the run for a retry of a file share job (lab, VBR 13.1).
            # Proxmox VE retries have their own id here (production server), the
            # second rule of the scope catches them.
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
    # job and object -> sessionId -> newest task of that session with Success or Warning
    $successBySession = New-OrdinalDictionary
    # sessionId -> object -> $true if a task of that object in that session did not end with Success or Warning
    $sessionObjects = New-OrdinalDictionary
    # job and object names that came more than once in one session
    $duplicates = New-OrdinalDictionary
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
        # Rank: how bad the result is, for objects that come twice in one session.
        $good = $false
        $rank = 2
        $p = $props['result']
        if ($null -ne $p -and $null -ne $p.Value) {
            $r = $p.Value.PSObject.Properties['result']
            if ($null -ne $r -and $null -ne $r.Value) {
                $text = ([string]$r.Value).Trim()
                if ([string]::Equals($text, 'Success', [System.StringComparison]::OrdinalIgnoreCase)) { $good = $true; $rank = 0 }
                # ASSUMPTION: a task with Warning left a restore point, see docs/metrics.md#OP-16
                elseif ([string]::Equals($text, 'Warning', [System.StringComparison]::OrdinalIgnoreCase)) { $good = $true; $rank = 1 }
                elseif ([string]::Equals($text, 'Failed', [System.StringComparison]::OrdinalIgnoreCase)) { $rank = 3 }
            }
        }
        $key = $jobName + [char]0 + $object

        # What the session processed. Two objects of the same name in one
        # session (two Proxmox VE VMs with the same name, seen on a production
        # server) cannot be told apart in REST: the name counts as failed in
        # that session if one of them failed.
        if ($sessionObjects.ContainsKey($sid)) { $flags = $sessionObjects[$sid] }
        else {
            $flags = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,object]' -ArgumentList ([System.StringComparer]::Ordinal)
            $sessionObjects[$sid] = $flags
        }
        if ($flags.ContainsKey($object)) {
            $duplicates[$key] = $true
            $flags[$object] = $flags[$object] -or (-not $good)
        }
        else { $flags[$object] = (-not $good) }

        # Newest task per job and object. Within one session the worst result wins.
        $newer = $true
        if ($latest.ContainsKey($key)) {
            $current = $latest[$key]
            $newer = $false
            if ($current.Sid -eq $sid) { $newer = ($rank -gt $current.Rank) }
            elseif ($null -eq $current.Created) { $newer = ($null -ne $created) -or ($usn -gt $current.Usn) }
            elseif ($null -ne $created) {
                if ($created -gt $current.Created) { $newer = $true }
                elseif ($created -eq $current.Created -and $usn -gt $current.Usn) { $newer = $true }
            }
        }
        if ($newer) { $latest[$key] = [pscustomobject]@{ JobName = $jobName; Object = $object; Created = $created; Usn = $usn; Task = $task; Sid = $sid; Rank = $rank } }

        # Newest task with a backup per session; which session counts is decided
        # after the loop, when it is known whether a twin failed in it.
        if ($good) {
            if ($successBySession.ContainsKey($key)) { $perSession = $successBySession[$key] }
            else {
                $perSession = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,object]' -ArgumentList ([System.StringComparer]::Ordinal)
                $successBySession[$key] = $perSession
            }
            $newer = $true
            if ($perSession.ContainsKey($sid)) {
                $current = $perSession[$sid]
                $newer = ($null -ne $created) -and (($null -eq $current.Created) -or ($created -gt $current.Created))
            }
            if ($newer) { $perSession[$sid] = [pscustomobject]@{ Created = $created; Usn = $usn; Task = $task } }
        }
    }
    if ($skipped -gt 0) { Write-Verbose "Objects: skipped $skipped task sessions without known session, job or object name." }
    foreach ($k in $duplicates.Keys) {
        $parts = $k.Split([char]0)
        Write-Warning ("Objects: job '{0}' processed several objects named '{1}' in one session. REST does not tell them apart: they are reported as one object, the worst result counts, and a session counts as a backup only if none of them failed." -f $parts[0], $parts[1])
    }

    # Last backup per job and object: the newest session in which the object
    # (all objects of that name) ended with Success or Warning.
    $latestSuccess = New-OrdinalDictionary
    foreach ($k in $successBySession.Keys) {
        $object = $k.Split([char]0)[1]
        $best = $null
        foreach ($pair in $successBySession[$k].GetEnumerator()) {
            if ($sessionObjects[$pair.Key][$object]) { continue }
            $candidate = $pair.Value
            if ($null -eq $best) { $best = $candidate; continue }
            if ($null -eq $best.Created) { if (($null -ne $candidate.Created) -or ($candidate.Usn -gt $best.Usn)) { $best = $candidate } }
            elseif ($null -ne $candidate.Created) {
                if (($candidate.Created -gt $best.Created) -or ($candidate.Created -eq $best.Created -and $candidate.Usn -gt $best.Usn)) { $best = $candidate }
            }
        }
        if ($null -ne $best) { $latestSuccess[$k] = $best }
    }

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
