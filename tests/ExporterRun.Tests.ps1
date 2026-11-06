BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    $script:ScriptVersion = (Import-PowerShellDataFile -Path $script:ModuleManifest).ModuleVersion
    Set-TestTimeZone

    function Set-VeeamApiMock {
        param(
            [int]$TokenStatus = 200,
            [string]$TokenContent = $script:TokenJson,
            [int]$JobsStatus = 200,
            [int]$TaskSessionsStatus = 200,
            [int]$ServerInfoStatus = 200
        )
        $script:MockTokenStatus = $TokenStatus
        $script:MockTokenContent = $TokenContent
        $script:MockJobsStatus = $JobsStatus
        $script:MockTaskSessionsStatus = $TaskSessionsStatus
        $script:MockServerInfoStatus = $ServerInfoStatus
        $script:MockRepositoryStates = Get-FixtureText -Name 'repositories-sobr-states.json'
        $script:MockSobrs = Get-FixtureText -Name 'doc/1.3-rev2/scaleOutRepositories.json'
        $script:MockJobsContent = Get-FixtureText -Name 'jobs-states.json'
        $script:MockSessionsContent = Get-FixtureText -Name 'objects-doc-sessions.json'
        $script:MockTasksContent = (Get-FixtureText -Name 'doc/1.3-rev0/taskSessions.json') -replace '"total": 52', '"total": 6'
        $script:MockEmpty = '{"data":[],"pagination":{"total":0,"count":0,"skip":0,"limit":200}}'
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest {
            switch ($Path) {
                '/api/oauth2/token' { return New-HttpResponse -StatusCode $script:MockTokenStatus -Content $script:MockTokenContent }
                '/api/oauth2/logout' { return New-HttpResponse -StatusCode 200 }
                '/api/v1/serverInfo' {
                    if ($script:MockServerInfoStatus -ne 200) { return New-HttpResponse -StatusCode $script:MockServerInfoStatus -Content '{"errorCode":"AccessDenied","message":"Access is denied."}' }
                    return New-HttpResponse -StatusCode 200 -Content '{"vbrId":"b3b2c6e0","name":"vbr01","buildVersion":"13.0.1.180","patches":[]}'
                }
                '/api/v1/backupInfrastructure/repositories/states' { return New-HttpResponse -StatusCode 200 -Content $script:MockRepositoryStates }
                '/api/v1/backupInfrastructure/scaleOutRepositories' { return New-HttpResponse -StatusCode 200 -Content $script:MockSobrs }
                '/api/v1/jobs/states' {
                    if ($script:MockJobsStatus -ne 200) { return New-HttpResponse -StatusCode $script:MockJobsStatus -Content '{"errorCode":"InternalError","message":"boom"}' }
                    return New-HttpResponse -StatusCode 200 -Content $script:MockJobsContent
                }
                '/api/v1/sessions' {
                    if ($Query['typeFilter'] -ne 'BackupJob') { return New-HttpResponse -StatusCode 200 -Content $script:MockEmpty }
                    return New-HttpResponse -StatusCode 200 -Content $script:MockSessionsContent
                }
                '/api/v1/taskSessions' {
                    if ($script:MockTaskSessionsStatus -ne 200) { return New-HttpResponse -StatusCode $script:MockTaskSessionsStatus -Content '{"errorCode":"InternalError","message":"boom"}' }
                    if ($Query['sessionTypeFilter'] -ne 'BackupJob') { return New-HttpResponse -StatusCode 200 -Content $script:MockEmpty }
                    return New-HttpResponse -StatusCode 200 -Content $script:MockTasksContent
                }
            }
            throw "Unexpected request: $Method $Path"
        }
    }
}

Describe 'Invoke-VeeamExporterRun' {
    BeforeEach {
        $script:Dir = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        $script:JobsFile = Join-Path -Path $script:Dir -ChildPath 'veeam_jobs.prom'
        $script:ObjectsFile = Join-Path -Path $script:Dir -ChildPath 'veeam_objects.prom'
        $script:RepositoriesFile = Join-Path -Path $script:Dir -ChildPath 'veeam_repositories.prom'
        $script:HealthFile = Join-Path -Path $script:Dir -ChildPath 'veeam_exporter.prom'
    }

    It 'schreibt alle Collector-Dateien und veeam_exporter.prom bei Erfolg' {
        Set-VeeamApiMock
        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction SilentlyContinue

        $result.Success | Should -BeTrue
        $result.ApiVersion | Should -BeExactly '1.3-rev2'
        Get-FileText -Path $script:JobsFile | Should -BeExactly (Get-ExpectedText -Name 'veeam_jobs.prom')
        # job names come from the session names here (jobs/states has other jobs)
        Get-FileText -Path $script:ObjectsFile | Should -BeExactly (Get-ExpectedText -Name 'doc/1.3-rev0/veeam_objects.prom')
        Get-FileText -Path $script:RepositoriesFile | Should -BeExactly (Get-ExpectedText -Name 'veeam_repositories_sobr.prom')

        $lines = (Get-FileText -Path $script:HealthFile) -split "`n"
        $lines.Count | Should -Be 14
        $lines[0] | Should -BeExactly '# HELP veeam_exporter_collector_success 1 letzter Lauf des Collectors ok, 0 Fehler'
        $lines[1] | Should -BeExactly '# TYPE veeam_exporter_collector_success gauge'
        $lines[2] | Should -BeExactly 'veeam_exporter_collector_success{collector="jobs"} 1'
        $lines[3] | Should -BeExactly 'veeam_exporter_collector_success{collector="objects"} 1'
        $lines[4] | Should -BeExactly 'veeam_exporter_collector_success{collector="repositories"} 1'
        $lines[5] | Should -BeExactly '# HELP veeam_exporter_collector_duration_seconds Laufzeit des Collectors in Sekunden'
        $lines[6] | Should -BeExactly '# TYPE veeam_exporter_collector_duration_seconds gauge'
        $lines[7] | Should -Match '^veeam_exporter_collector_duration_seconds\{collector="jobs"\} [0-9]+(\.[0-9]+)?$'
        $lines[8] | Should -Match '^veeam_exporter_collector_duration_seconds\{collector="objects"\} [0-9]+(\.[0-9]+)?$'
        $lines[9] | Should -Match '^veeam_exporter_collector_duration_seconds\{collector="repositories"\} [0-9]+(\.[0-9]+)?$'
        $lines[10] | Should -BeExactly '# HELP veeam_exporter_info Exporter- und Server-Version (Wert immer 1)'
        $lines[11] | Should -BeExactly '# TYPE veeam_exporter_info gauge'
        $lines[12] | Should -BeExactly ('veeam_exporter_info{{script_version="{0}",api_version="1.3-rev2",vbr_version="13.0.1.180"}} 1' -f $script:ScriptVersion)
        $lines[13] | Should -BeExactly ''
    }

    It 'laesst vbr_version bei HTTP 403 auf serverInfo leer, ohne Warnung (Viewer-Rolle)' {
        Set-VeeamApiMock -ServerInfoStatus 403
        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningVariable warnings -WarningAction SilentlyContinue
        $result.Success | Should -BeTrue
        @($warnings).Count | Should -Be 0
        Get-FileText -Path $script:HealthFile | Should -Match ([regex]::Escape('api_version="1.3-rev2",vbr_version=""} 1'))
    }

    It 'warnt bei anderen Fehlern auf serverInfo' {
        Set-VeeamApiMock -ServerInfoStatus 500
        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningVariable warnings -WarningAction SilentlyContinue
        $result.Success | Should -BeTrue
        @($warnings | Where-Object { "$_" -like '*serverInfo*' }).Count | Should -Be 1
    }

    It 'laesst mit -Collector jobs nur den Jobs-Collector laufen' {
        Set-VeeamApiMock
        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -Collector 'jobs' -WarningAction SilentlyContinue
        $result.Success | Should -BeTrue
        Test-Path -LiteralPath $script:ObjectsFile | Should -BeFalse
        Get-FileText -Path $script:HealthFile | Should -Not -Match 'collector="objects"'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly -ParameterFilter { $Path -eq '/api/v1/taskSessions' }
    }

    It 'gibt Lookback und Session-Typen an den Objects-Collector weiter' {
        Set-VeeamApiMock
        $null = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -ObjectSessionType 'ReplicaJob' -ObjectLookbackDays 2 -WarningAction SilentlyContinue
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/v1/taskSessions' -and $Query['sessionTypeFilter'] -eq 'ReplicaJob' }
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly -ParameterFilter { $Path -eq '/api/v1/taskSessions' -and $Query['sessionTypeFilter'] -eq 'BackupJob' }
        $expected = [System.DateTimeOffset]::UtcNow.AddDays(-2).ToString('yyyy-MM-dd')
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/v1/taskSessions' -and $Query['createdAfterFilter'].StartsWith($expected) }
    }

    It 'isoliert Collectors: faellt objects aus, laeuft jobs weiter' {
        [System.IO.File]::WriteAllText($script:ObjectsFile, "veeam_object_last_result{job_name=`"alt`",object=`"vm`"} 0`n")
        Set-VeeamApiMock -TaskSessionsStatus 500

        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction SilentlyContinue

        $result.Success | Should -BeFalse
        Get-FileText -Path $script:JobsFile | Should -BeExactly (Get-ExpectedText -Name 'veeam_jobs.prom')
        Get-FileText -Path $script:ObjectsFile | Should -BeExactly "veeam_object_last_result{job_name=`"alt`",object=`"vm`"} 0`n"
        $health = Get-FileText -Path $script:HealthFile
        $health | Should -Match 'veeam_exporter_collector_success\{collector="jobs"\} 1'
        $health | Should -Match 'veeam_exporter_collector_success\{collector="objects"\} 0'
    }

    It 'meldet sich am Ende ab' {
        Set-VeeamApiMock
        $null = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction SilentlyContinue
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/oauth2/logout' }
    }

    It 'laesst die alte veeam_jobs.prom stehen, wenn der Collector fehlschlaegt' {
        [System.IO.File]::WriteAllText($script:JobsFile, "veeam_job_enabled{job_name=`"alt`"} 1`n")
        Set-VeeamApiMock -JobsStatus 500

        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction SilentlyContinue

        $result.Success | Should -BeFalse
        Get-FileText -Path $script:JobsFile | Should -BeExactly "veeam_job_enabled{job_name=`"alt`"} 1`n"
        Get-FileText -Path $script:HealthFile | Should -Match 'veeam_exporter_collector_success\{collector="jobs"\} 0'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/oauth2/logout' }
    }

    It 'schreibt veeam_exporter.prom auch, wenn die Anmeldung fehlschlaegt' {
        Set-VeeamApiMock -TokenStatus 400 -TokenContent $script:InvalidGrantJson

        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction SilentlyContinue

        $result.Success | Should -BeFalse
        Test-Path -LiteralPath $script:JobsFile | Should -BeFalse
        $health = Get-FileText -Path $script:HealthFile
        $health | Should -Match 'veeam_exporter_collector_success\{collector="jobs"\} 0'
        $health | Should -Match 'veeam_exporter_collector_success\{collector="objects"\} 0'
        $health | Should -Match 'veeam_exporter_collector_success\{collector="repositories"\} 0'
        $health | Should -Match ([regex]::Escape('api_version="",vbr_version=""} 1'))
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly -ParameterFilter { $Path -eq '/api/v1/jobs/states' }
    }

    It 'schreibt weder Passwort noch Token in eine .prom-Datei' {
        Set-VeeamApiMock
        $null = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction SilentlyContinue
        foreach ($file in Get-ChildItem -LiteralPath $script:Dir) {
            $text = Get-FileText -Path $file.FullName
            $text | Should -Not -Match 'S3cret'
            $text | Should -Not -Match 'access-123'
            $text | Should -Not -Match 'refresh-456'
        }
    }

    It 'hinterlaesst keine .tmp-Dateien' {
        Set-VeeamApiMock
        $null = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction SilentlyContinue
        @(Get-ChildItem -LiteralPath $script:Dir -Filter '*.tmp').Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $script:Dir | ForEach-Object Name | Sort-Object) -join ',' | Should -BeExactly 'veeam_exporter.prom,veeam_jobs.prom,veeam_objects.prom,veeam_repositories.prom'
    }
}
