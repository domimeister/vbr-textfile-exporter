BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Set-TestTimeZone

    # Builds sessions and task sessions like REST returns them. A session is
    # @{ Id; At (start, 'dd HH:mm'); Tasks = @{ vm = 'Success' }; Original; State; Canceled; Result }.
    $script:JobId = '11111111-1111-4111-8111-111111111111'
    $script:Jobs = @([pscustomobject]@{ id = $script:JobId; name = 'PVE Pool' })
    function ConvertTo-TestTime {
        param([string]$At, [int]$AddMinutes = 0)
        $parts = $At -split ' '
        return ([datetime]::ParseExact(('2026-11-{0} {1}' -f $parts[0], $parts[1]), 'yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)).AddMinutes($AddMinutes).ToString('yyyy-MM-ddTHH:mm:ss') + '+01:00'
    }
    function New-TestRun {
        param([hashtable[]]$Session)
        $sessions = New-Object System.Collections.Generic.List[object]
        $tasks = New-Object System.Collections.Generic.List[object]
        $usn = 0
        foreach ($s in $Session) {
            $usn++
            $results = @($s.Tasks.Values)
            $result = 'Success'
            if ($results -contains 'Failed') { $result = 'Failed' } elseif ($results -contains 'None') { $result = 'None' }
            if ($s.ContainsKey('Result')) { $result = $s.Result }
            $state = 'Stopped'
            if ($s.ContainsKey('State')) { $state = $s.State }
            $row = [ordered]@{
                id = $s.Id; jobId = $script:JobId; name = 'PVE Pool'; sessionType = 'PlatformBackupJob'; state = $state; usn = $usn
                creationTime = (ConvertTo-TestTime -At $s.At); endTime = (ConvertTo-TestTime -At $s.At -AddMinutes 30)
                result = [pscustomobject]@{ result = $result; message = ''; isCanceled = [bool]$s.Canceled }
            }
            if ($s.ContainsKey('Original')) { $row['originalSessionId'] = $s.Original }
            if ($s.NoTime) { $row['creationTime'] = $null }
            $sessions.Add([pscustomobject]$row)
            foreach ($vm in @($s.Tasks.Keys | Sort-Object)) {
                $usn++
                $tasks.Add([pscustomobject]@{
                        type = 'Backup'; sessionType = 'PlatformBackupJob'; sessionId = $s.Id; name = $vm; usn = $usn; state = 'Stopped'
                        creationTime = (ConvertTo-TestTime -At $s.At -AddMinutes 1); endTime = (ConvertTo-TestTime -At $s.At -AddMinutes 20)
                        result = [pscustomobject]@{ result = $s.Tasks[$vm]; message = ''; isCanceled = $false }
                        progress = [pscustomobject]@{ processedSize = 1024 }
                    })
            }
        }
        return [pscustomobject]@{ Sessions = $sessions.ToArray(); Tasks = $tasks.ToArray() }
    }
    function Get-TestObject {
        # object -> "result/last success" (day and time of the last success, or "-")
        param([hashtable[]]$Session)
        $data = New-TestRun -Session $Session
        $metrics = Get-VeeamObjectMetric -JobState $script:Jobs -JobSession $data.Sessions -TaskSession $data.Tasks
        $result = @{}
        foreach ($sample in ($metrics | Where-Object Name -EQ 'veeam_object_last_result').Samples) { $result[$sample.Labels['object']] = [string]$sample.Value + '/-' }
        foreach ($sample in ($metrics | Where-Object Name -EQ 'veeam_object_last_success_timestamp_seconds').Samples) {
            $when = [System.DateTimeOffset]::FromUnixTimeSeconds([int64]$sample.Value).ToOffset([timespan]::FromHours(1)).ToString('dd HH:mm')
            $result[$sample.Labels['object']] = ($result[$sample.Labels['object']] -replace '/-$', ('/' + $when))
        }
        return (@($result.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $result[$_] }) -join ' ')
    }
    # A nightly job on a pool: all fine on day 10.
    $script:Day10 = @{ Id = 's10'; At = '10 22:00'; Tasks = @{ vm1 = 'Success'; vm2 = 'Success'; vm3 = 'Success' } }
}

Describe 'Objects: last success per object and the scope of a job' {
    It 'keeps every object when one fails, although the last sessions are retries with the failed one only (<Case>)' -TestCases @(
        @{ Case = 'retries marked with originalSessionId'; Marked = $true }
        @{ Case = 'retries not marked'; Marked = $false }
    ) {
        param($Case, $Marked)
        $retry1 = @{ Id = 'r1'; At = '11 22:40'; Tasks = @{ vm2 = 'Failed' } }
        $retry2 = @{ Id = 'r2'; At = '11 23:20'; Tasks = @{ vm2 = 'Failed' } }
        if ($Marked) { $retry1.Original = 's11'; $retry2.Original = 's11' }
        Get-TestObject -Session @(
            $script:Day10
            @{ Id = 's11'; At = '11 22:00'; Tasks = @{ vm1 = 'Success'; vm2 = 'Failed'; vm3 = 'Success' } }
            $retry1, $retry2
        ) | Should -BeExactly 'vm1=0/11 22:20 vm2=2/10 22:20 vm3=0/11 22:20'
    }

    It 'takes the success of a retry' {
        Get-TestObject -Session @(
            $script:Day10
            @{ Id = 's11'; At = '11 22:00'; Tasks = @{ vm1 = 'Success'; vm2 = 'Failed'; vm3 = 'Success' } }
            @{ Id = 'r1'; At = '11 22:40'; Tasks = @{ vm2 = 'Success' } }
        ) | Should -BeExactly 'vm1=0/11 22:20 vm2=0/11 23:00 vm3=0/11 22:20'
    }

    It 'counts Warning as a backup that exists' {
        Get-TestObject -Session @(
            @{ Id = 's11'; At = '11 22:00'; Tasks = @{ vm1 = 'Warning'; vm2 = 'Failed' } }
        ) | Should -BeExactly 'vm1=1/11 22:20 vm2=2/-'
    }

    It 'has no last success for an object that never succeeded in the data' {
        $data = New-TestRun -Session @(@{ Id = 's11'; At = '11 22:00'; Tasks = @{ vm1 = 'Failed' } })
        $text = ConvertTo-PromText -Metric (Get-VeeamObjectMetric -JobState $script:Jobs -JobSession $data.Sessions -TaskSession $data.Tasks)
        $text | Should -Match 'veeam_object_last_result\{job_name="PVE Pool",object="vm1"\} 2'
        $text | Should -Not -Match 'veeam_object_last_success_timestamp_seconds'
    }

    It 'keeps an excluded object until the next regular run, and leaves it out from then on' {
        $failedNight = @(
            $script:Day10
            @{ Id = 's11'; At = '11 22:00'; Tasks = @{ vm1 = 'Success'; vm2 = 'Failed'; vm3 = 'Success' } }
            @{ Id = 'r1'; At = '11 22:40'; Tasks = @{ vm2 = 'Failed' }; Original = 's11' }
        )
        Get-TestObject -Session $failedNight | Should -BeExactly 'vm1=0/11 22:20 vm2=2/10 22:20 vm3=0/11 22:20'
        # vm2 is taken out of the job; the next night runs without it.
        Get-TestObject -Session ($failedNight + @(@{ Id = 's12'; At = '12 22:00'; Tasks = @{ vm1 = 'Success'; vm3 = 'Success' } })) |
            Should -BeExactly 'vm1=0/12 22:20 vm3=0/12 22:20'
    }

    It 'takes a manual start of the whole job as a new run' {
        Get-TestObject -Session @(
            @{ Id = 's11'; At = '11 22:00'; Tasks = @{ vm1 = 'Success'; vm2 = 'Failed'; vm3 = 'Success' } }
            @{ Id = 'm1'; At = '12 09:00'; Tasks = @{ vm1 = 'Success'; vm3 = 'Success' } }
        ) | Should -BeExactly 'vm1=0/12 09:20 vm3=0/12 09:20'
    }

    It 'adds a new object of the pool with the run that processes it' {
        Get-TestObject -Session @(
            $script:Day10
            @{ Id = 's11'; At = '11 22:00'; Tasks = @{ vm1 = 'Success'; vm2 = 'Success'; vm3 = 'Success'; vm4 = 'Failed' } }
        ) | Should -BeExactly 'vm1=0/11 22:20 vm2=0/11 22:20 vm3=0/11 22:20 vm4=2/-'
    }

    It 'keeps the objects of the run before while the new run is still <Case>' -TestCases @(
        @{ Case = 'running'; Change = @{ State = 'Working'; Result = 'None' }; Expected = 'vm1=0/11 22:20 vm2=0/10 22:20 vm3=0/10 22:20' }
        @{ Case = 'without a result'; Change = @{ Result = 'None' }; Expected = 'vm1=0/11 22:20 vm2=0/10 22:20 vm3=0/10 22:20' }
        @{ Case = 'cancelled half way'; Change = @{ Canceled = $true; Result = 'Failed' }; Expected = 'vm1=0/11 22:20 vm2=0/10 22:20 vm3=0/10 22:20' }
    ) {
        param($Case, $Change, $Expected)
        $open = @{ Id = 's11'; At = '11 22:00'; Tasks = @{ vm1 = 'Success' } }
        foreach ($key in $Change.Keys) { $open[$key] = $Change[$key] }
        Get-TestObject -Session @($script:Day10, $open) | Should -BeExactly $Expected
    }

    It 'shows a task that is still running as None and keeps the last success' {
        Get-TestObject -Session @(
            $script:Day10
            @{ Id = 's11'; At = '11 22:00'; Tasks = @{ vm1 = 'None'; vm2 = 'Success' }; State = 'Working' }
        ) | Should -BeExactly 'vm1=-1/10 22:20 vm2=0/11 22:20 vm3=0/10 22:20'
    }

    It 'keeps all objects when a run fails before it processes anything (session without tasks)' {
        Get-TestObject -Session @(
            $script:Day10
            @{ Id = 's11'; At = '11 22:00'; Tasks = @{}; Result = 'Failed' }
            @{ Id = 's12'; At = '12 22:00'; Tasks = @{}; Result = 'Failed' }
        ) | Should -BeExactly 'vm1=0/10 22:20 vm2=0/10 22:20 vm3=0/10 22:20'
    }

    It 'keeps all objects of a job whose sessions cannot be put in order' {
        Get-TestObject -Session @(
            $script:Day10
            @{ Id = 's11'; At = '11 22:00'; Tasks = @{ vm1 = 'Success' }; NoTime = $true }
        ) | Should -BeExactly 'vm1=0/11 22:20 vm2=0/10 22:20 vm3=0/10 22:20'
    }

    It 'treats a job of one object that fails every night as one run, and a success ends it' {
        Get-TestObject -Session @(
            @{ Id = 's10'; At = '10 22:00'; Tasks = @{ vm1 = 'Success' } }
            @{ Id = 's11'; At = '11 22:00'; Tasks = @{ vm1 = 'Failed' } }
            @{ Id = 's12'; At = '12 22:00'; Tasks = @{ vm1 = 'Failed' } }
        ) | Should -BeExactly 'vm1=2/10 22:20'
    }

    It 'does not mix the runs of two jobs' {
        $data = New-TestRun -Session @($script:Day10, @{ Id = 's11'; At = '11 22:00'; Tasks = @{ vm1 = 'Success'; vm3 = 'Success' } })
        $otherJob = '22222222-2222-4222-8222-222222222222'
        $sessions = @($data.Sessions) + @([pscustomobject]@{ id = 'o1'; jobId = $otherJob; name = 'Other'; state = 'Stopped'; usn = 99; creationTime = '2026-11-09T20:00:00+01:00'; result = [pscustomobject]@{ result = 'Success' } })
        $tasks = @($data.Tasks) + @([pscustomobject]@{ sessionId = 'o1'; name = 'vm2'; usn = 100; creationTime = '2026-11-09T20:01:00+01:00'; endTime = '2026-11-09T20:10:00+01:00'; result = [pscustomobject]@{ result = 'Success' } })
        $jobs = @($script:Jobs) + @([pscustomobject]@{ id = $otherJob; name = 'Other' })
        $text = ConvertTo-PromText -Metric (Get-VeeamObjectMetric -JobState $jobs -JobSession $sessions -TaskSession $tasks)
        $text | Should -Match 'veeam_object_last_result\{job_name="Other",object="vm2"\} 0'
        $text | Should -Not -Match 'job_name="PVE Pool",object="vm2"'
    }

    It 'writes the last success as the end of that task in Unix time' {
        $data = New-TestRun -Session @($script:Day10)
        $text = ConvertTo-PromText -Metric (Get-VeeamObjectMetric -JobState $script:Jobs -JobSession $data.Sessions -TaskSession $data.Tasks)
        # 2026-11-10 22:20 +01:00
        $text | Should -Match 'veeam_object_last_success_timestamp_seconds\{job_name="PVE Pool",object="vm1"\} 1794345600'
    }
}

Describe 'Objects: session types' {
    BeforeEach {
        $script:Empty = '{"data":[],"pagination":{"total":0,"count":0,"skip":0,"limit":200}}'
        $script:Rejected = @('PlatformBackupJob')
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest {
            if ($Path -eq '/api/v1/sessions' -and $script:Rejected -contains $Query['typeFilter']) { return New-HttpResponse -StatusCode 400 -Content '' }
            New-HttpResponse -StatusCode 200 -Content $script:Empty
        }
    }

    It 'asks for platform jobs (Proxmox VE) by default' {
        $script:Rejected = @()
        $null = Get-VeeamObjectMetric -Session (New-TestSession)
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/v1/sessions' -and $Query['typeFilter'] -eq 'PlatformBackupJob' }
    }

    It 'skips a session type the server does not know, with a warning' {
        $null = Get-VeeamObjectMetric -Session (New-TestSession) -WarningVariable w -WarningAction SilentlyContinue
        @($w | Where-Object { "$_" -like "*does not accept the session type 'PlatformBackupJob'*" }).Count | Should -Be 1
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/v1/taskSessions' }
    }

    It 'fails when the server accepts none of the session types' {
        $script:Rejected = @('BackupJob', 'ReplicaJob', 'PlatformBackupJob')
        { Get-VeeamObjectMetric -Session (New-TestSession) -WarningAction SilentlyContinue } | Should -Throw '*accepts none of the session types: BackupJob, ReplicaJob, PlatformBackupJob*'
    }

    It 'still fails on any other error of a session request' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 500 -Content '{"message":"boom"}' } -ParameterFilter { $Path -eq '/api/v1/sessions' }
        { Get-VeeamObjectMetric -Session (New-TestSession) -WarningAction SilentlyContinue } | Should -Throw '*HTTP 500*'
    }
}
