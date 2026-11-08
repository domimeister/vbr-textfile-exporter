BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Set-TestTimeZone

    function Get-DocObjectText {
        param([string]$Version)
        $metrics = Get-VeeamObjectMetric -JobState (Get-FixtureData -Name 'objects-doc-jobs-states.json') `
            -JobSession (Get-FixtureData -Name 'objects-doc-sessions.json') `
            -TaskSession (Get-FixtureData -Name "doc/$Version/taskSessions.json")
        return ConvertTo-PromText -Metric $metrics
    }

    function Set-ObjectApiMock {
        $script:DocTasks = Get-FixtureText -Name 'doc/1.3-rev0/taskSessions.json'
        $script:DocSessions = Get-FixtureText -Name 'objects-doc-sessions.json'
        $script:DocJobs = Get-FixtureText -Name 'objects-doc-jobs-states.json'
        $script:Empty = '{"data":[],"pagination":{"total":0,"count":0,"skip":0,"limit":200}}'
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest {
            switch ($Path) {
                '/api/v1/jobs/states' { return New-HttpResponse -StatusCode 200 -Content $script:DocJobs }
                '/api/v1/sessions' {
                    if ($Query['typeFilter'] -eq 'BackupJob') { return New-HttpResponse -StatusCode 200 -Content $script:DocSessions }
                    return New-HttpResponse -StatusCode 200 -Content $script:Empty
                }
                '/api/v1/taskSessions' {
                    if ($Query.Contains('sessionTypeFilter')) { throw 'sessionTypeFilter must not be used (#21)' }
                    # the doc example reports total 52 for 6 items; serve one complete page
                    return New-HttpResponse -StatusCode 200 -Content ($script:DocTasks -replace '"total": 52', '"total": 6')
                }
            }
            throw "Unexpected request: $Method $Path"
        }
    }
}

Describe 'Objects collector: output' {
    It 'generates veeam_objects.prom line by line from the doc example <Version>' -TestCases @(
        @{ Version = '1.3-rev0' }, @{ Version = '1.3-rev1' }, @{ Version = '1.3-rev2' }
    ) {
        param($Version)
        Assert-PromText -Actual (Get-DocObjectText -Version $Version) -Expected (Get-ExpectedText -Name "doc/$Version/veeam_objects.prom")
    }

    It 'covers retries, running tasks, escaping, truncation and deleted jobs' {
        $metrics = Get-VeeamObjectMetric -JobState (Get-FixtureData -Name 'objects-edge-jobs-states.json') `
            -JobSession (Get-FixtureData -Name 'objects-edge-sessions.json') `
            -TaskSession (Get-FixtureData -Name 'objects-edge-taskSessions.json')
        Assert-PromText -Actual (ConvertTo-PromText -Metric $metrics) -Expected (Get-ExpectedText -Name 'veeam_objects_edgecases.prom')
    }

    It 'writes failure_info only for Warning and Failed' {
        $text = Get-ExpectedText -Name 'veeam_objects_edgecases.prom'
        $metrics = Get-VeeamObjectMetric -JobState (Get-FixtureData -Name 'objects-edge-jobs-states.json') `
            -JobSession (Get-FixtureData -Name 'objects-edge-sessions.json') `
            -TaskSession (Get-FixtureData -Name 'objects-edge-taskSessions.json')
        $failure = $metrics | Where-Object Name -EQ 'veeam_object_last_failure_info'
        $result = $metrics | Where-Object Name -EQ 'veeam_object_last_result'
        $expectedObjects = @($result.Samples | Where-Object { $_.Value -eq 1 -or $_.Value -eq 2 } | ForEach-Object { $_.Labels['object'] }) -join ','
        (@($failure.Samples | ForEach-Object { $_.Labels['object'] }) -join ',') | Should -BeExactly $expectedObjects
        $text | Should -Not -Match 'object="vm01",message='
    }

    It 'returns empty text without task sessions' {
        $metrics = Get-VeeamObjectMetric -JobState @() -JobSession @() -TaskSession @()
        ConvertTo-PromText -Metric $metrics | Should -BeExactly ''
    }

    It 'uses the time zone of the server for timestamps as strings (Windows PowerShell 5.1)' {
        $sessions = @([pscustomobject]@{ id = 'S1'; jobId = 'J1'; name = 'Job A'; creationTime = '2024-11-13T21:59:00' })
        $tasks = @(
            [pscustomobject]@{ sessionId = 'S1'; name = 'vm1'; creationTime = '2024-11-13T22:00:00.5'; endTime = '2024-11-13T22:10:00'; result = [pscustomobject]@{ result = 'Failed'; message = 'x' } }
            [pscustomobject]@{ sessionId = 'S1'; name = 'vm1'; creationTime = '2024-11-13T22:00:00.75'; endTime = '2024-11-13T22:20:00'; result = [pscustomobject]@{ result = 'Success'; message = '' } }
        )
        $text = ConvertTo-PromText -Metric (Get-VeeamObjectMetric -JobState @() -JobSession $sessions -TaskSession $tasks)
        # 22:20 at +01:00 = 21:20Z
        $text | Should -Match 'veeam_object_last_run_timestamp_seconds\{job_name="Job A",object="vm1"\} 1731532800'
        $text | Should -Match 'veeam_object_last_result\{job_name="Job A",object="vm1"\} 0'
    }
}

Describe 'Objects collector: REST queries' {
    BeforeEach { Set-ObjectApiMock }

    It 'reads jobs/states, sessions and taskSessions and generates the same output' {
        $text = ConvertTo-PromText -Metric (Get-VeeamObjectMetric -Session (New-TestSession))
        Assert-PromText -Actual $text -Expected (Get-ExpectedText -Name 'doc/1.3-rev0/veeam_objects.prom')
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/v1/jobs/states' }
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
    }

    It 'queries sessions per type and task sessions once without a type filter' {
        $null = Get-VeeamObjectMetric -Session (New-TestSession)
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 2 -Exactly -ParameterFilter { $Path -eq '/api/v1/sessions' }
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/v1/sessions' -and $Query['typeFilter'] -eq 'BackupJob' }
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/v1/sessions' -and $Query['typeFilter'] -eq 'ReplicaJob' }
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/v1/taskSessions' }
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly -ParameterFilter { $Query -and $Query.Contains('sessionTypeFilter') }
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly -ParameterFilter { $Query -and $Query['typeFilter'] -like '*,*' }
    }

    It 'keeps file share tasks and drops tasks of other session types (real VBR 13.1 responses)' {
        $script:LabSessions = Get-FixtureData -Name 'lab/vbr-13.1/sessions.json'
        $script:LabTasks = Get-FixtureText -Name 'lab/vbr-13.1/taskSessions.json'
        $script:LabJobs = Get-FixtureText -Name 'lab/vbr-13.1/jobs-states.json'
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest {
            switch ($Path) {
                '/api/v1/jobs/states' { return New-HttpResponse -StatusCode 200 -Content $script:LabJobs }
                '/api/v1/sessions' {
                    # the server filters by type
                    $data = @($script:LabSessions | Where-Object { $_.sessionType -eq $Query['typeFilter'] })
                    $body = ConvertTo-Json -Depth 8 -InputObject @{ data = $data; pagination = @{ total = $data.Count; count = $data.Count; skip = 0; limit = 200 } }
                    return New-HttpResponse -StatusCode 200 -Content $body
                }
                '/api/v1/taskSessions' {
                    # VBR 13.1: sessionTypeFilter=BackupJob matches no file share task
                    if ($Query.Contains('sessionTypeFilter')) { return New-HttpResponse -StatusCode 200 -Content '{"data":[],"pagination":{"total":0,"count":0,"skip":0,"limit":200}}' }
                    return New-HttpResponse -StatusCode 200 -Content $script:LabTasks
                }
            }
            throw "Unexpected request: $Method $Path"
        }
        $text = ConvertTo-PromText -Metric (Get-VeeamObjectMetric -Session (New-TestSession))
        Assert-PromText -Actual $text -Expected (Get-ExpectedText -Name 'lab/vbr-13.1/veeam_objects.prom')
    }

    It 'uses only the given session types' {
        $null = Get-VeeamObjectMetric -Session (New-TestSession) -SessionType 'BackupJob'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/v1/taskSessions' }
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly -ParameterFilter { $Query -and $Query['typeFilter'] -eq 'ReplicaJob' }
    }

    It 'sets createdAfterFilter in UTC: tasks now minus <Days> days, sessions one day earlier' -TestCases @(@{ Days = 8 }, @{ Days = 1 }) {
        param($Days)
        $script:Captured = New-Object System.Collections.Generic.List[object]
        $before = [System.DateTimeOffset]::UtcNow
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest {
            $script:Captured.Add([pscustomobject]@{ Path = $Path; After = $Query['createdAfterFilter'] })
            New-HttpResponse -StatusCode 200 -Content '{"data":[],"pagination":{"total":0,"count":0}}'
        }
        $null = Get-VeeamObjectMetric -Session (New-TestSession) -LookbackDays $Days
        $after = [System.DateTimeOffset]::UtcNow

        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        foreach ($c in ($script:Captured | Where-Object { $_.Path -ne '/api/v1/jobs/states' })) {
            $c.After | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
            $value = [System.DateTimeOffset]::ParseExact($c.After, "yyyy-MM-dd'T'HH:mm:ss'Z'", $inv, [System.Globalization.DateTimeStyles]::AssumeUniversal)
            $expectedDays = $Days
            if ($c.Path -eq '/api/v1/sessions') { $expectedDays = $Days + 1 }
            $value | Should -BeGreaterOrEqual $before.AddDays(-$expectedDays).AddSeconds(-1)
            $value | Should -BeLessOrEqual $after.AddDays(-$expectedDays)
        }
    }

    It 'throws if a request fails' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 403 -Content '{"errorCode":"AccessDenied","message":"no"}' } -ParameterFilter { $Path -eq '/api/v1/taskSessions' }
        { Get-VeeamObjectMetric -Session (New-TestSession) } | Should -Throw '*taskSessions*HTTP 403*'
    }
}

Describe 'Format-VeeamResultMessage' {
    It 'replaces line breaks and tabs and collapses spaces' {
        InModuleScope VeeamExporter {
            Format-VeeamResultMessage -Message "  Error:`r`n  disk`tfull  " | Should -BeExactly 'Error: disk full'
        }
    }

    It 'truncates to 200 characters' {
        InModuleScope VeeamExporter {
            $result = Format-VeeamResultMessage -Message ('a' * 250)
            $result.Length | Should -Be 200
        }
    }

    It 'does not split a surrogate pair' {
        InModuleScope VeeamExporter {
            $emoji = [char]::ConvertFromUtf32(0x1F4BE)
            $result = Format-VeeamResultMessage -Message (('a' * 199) + $emoji + 'b')
            $result | Should -BeExactly ('a' * 199)
        }
    }

    It 'turns $null into an empty string' {
        InModuleScope VeeamExporter { Format-VeeamResultMessage -Message $null | Should -BeExactly '' }
    }
}
