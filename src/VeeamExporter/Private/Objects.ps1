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
    Joins task sessions to jobs and keeps the newest task per job and object.
    Job name: name from jobs/states via jobId; for jobIds missing there the
    name of the newest session of that job. Tasks whose session is unknown or
    that have no object name are skipped. Output is sorted ordinally by job
    name, then object, so the file content is stable.
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

    # sessionId -> jobId, and per jobId the name of its newest session.
    $sessionJob = New-OrdinalDictionary
    $fallbackName = New-OrdinalDictionary
    $fallbackTime = New-OrdinalDictionary
    foreach ($s in $JobSession) {
        $sid = Get-VeeamGuidKey -Value (Get-VeeamField -InputObject $s -Name 'id')
        $jid = Get-VeeamGuidKey -Value (Get-VeeamField -InputObject $s -Name 'jobId')
        if (-not $sid -or -not $jid) { continue }
        $sessionJob[$sid] = $jid
        $created = ConvertTo-VeeamFieldValue -Value (Get-VeeamField -InputObject $s -Name 'creationTime') -Field 'creationTime' -Item ('Session {0}' -f $sid) `
            -Conversion { param($v) ConvertTo-VeeamDateTimeOffset -Value $v }
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
    $skipped = 0
    foreach ($task in $TaskSession) {
        $sid = Get-VeeamGuidKey -Value (Get-VeeamField -InputObject $task -Name 'sessionId')
        $object = [string](Get-VeeamField -InputObject $task -Name 'name')
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
        try { $created = ConvertTo-VeeamDateTimeOffset -Value (Get-VeeamField -InputObject $task -Name 'creationTime') }
        catch { Write-Verbose ("Task '{0}' in job '{1}': creationTime not readable for ordering." -f $object, $jobName) }
        $usn = ConvertTo-VeeamFieldValue -Value (Get-VeeamField -InputObject $task -Name 'usn') -Field 'usn' -Item ("Task '{0}' in job '{1}'" -f $object, $jobName) `
            -Conversion { param($v) if ($null -ne $v) { [int64]$v } }
        if ($null -eq $usn) { $usn = -1 }
        $candidate = [pscustomobject]@{
            JobName = $jobName
            Object  = $object
            Created = $created
            Usn     = [int64]$usn
            Task    = $task
        }

        $key = $jobName + [char]0 + $object
        if (-not $latest.ContainsKey($key)) {
            $latest[$key] = $candidate
            continue
        }
        $current = $latest[$key]
        $newer = $false
        if ($null -eq $current.Created) { $newer = ($null -ne $created) -or ($candidate.Usn -gt $current.Usn) }
        elseif ($null -ne $created) {
            if ($created -gt $current.Created) { $newer = $true }
            elseif ($created -eq $current.Created -and $candidate.Usn -gt $current.Usn) { $newer = $true }
        }
        if ($newer) { $latest[$key] = $candidate }
    }
    if ($skipped -gt 0) { Write-Verbose "Objects: skipped $skipped task sessions without known session, job or object name." }

    $keys = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($k in $latest.Keys) { $keys.Add($k) }
    $keys.Sort([System.StringComparer]::Ordinal)
    foreach ($k in $keys) { $latest[$k] }
}
