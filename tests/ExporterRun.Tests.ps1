BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    $script:ScriptVersion = (Import-PowerShellDataFile -Path $script:ModuleManifest).ModuleVersion
    Set-TestTimeZone
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

    It 'writes all collector files and veeam_exporter.prom on success' {
        Set-VeeamApiMock
        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction SilentlyContinue
        Export-GeneratedPromFile -Directory $script:Dir -Name 'ExporterRun/success'

        $result.Success | Should -BeTrue
        $result.ApiVersion | Should -BeExactly '1.3-rev2'
        Get-FileText -Path $script:JobsFile | Should -BeExactly (Get-ExpectedText -Name 'veeam_jobs.prom')
        # job names come from the session names here (jobs/states has other jobs)
        Get-FileText -Path $script:ObjectsFile | Should -BeExactly (Get-ExpectedText -Name 'doc/1.3-rev0/veeam_objects.prom')
        Get-FileText -Path $script:RepositoriesFile | Should -BeExactly (Get-ExpectedText -Name 'veeam_repositories_sobr.prom')

        $lines = (Get-FileText -Path $script:HealthFile) -split "`n"
        $lines.Count | Should -Be 14
        $lines[0] | Should -BeExactly '# HELP veeam_exporter_collector_success 1 last collector run ok, 0 failure'
        $lines[1] | Should -BeExactly '# TYPE veeam_exporter_collector_success gauge'
        $lines[2] | Should -BeExactly 'veeam_exporter_collector_success{collector="jobs"} 1'
        $lines[3] | Should -BeExactly 'veeam_exporter_collector_success{collector="objects"} 1'
        $lines[4] | Should -BeExactly 'veeam_exporter_collector_success{collector="repositories"} 1'
        $lines[5] | Should -BeExactly '# HELP veeam_exporter_collector_duration_seconds Collector duration in seconds'
        $lines[6] | Should -BeExactly '# TYPE veeam_exporter_collector_duration_seconds gauge'
        $lines[7] | Should -Match '^veeam_exporter_collector_duration_seconds\{collector="jobs"\} [0-9]+(\.[0-9]+)?$'
        $lines[8] | Should -Match '^veeam_exporter_collector_duration_seconds\{collector="objects"\} [0-9]+(\.[0-9]+)?$'
        $lines[9] | Should -Match '^veeam_exporter_collector_duration_seconds\{collector="repositories"\} [0-9]+(\.[0-9]+)?$'
        $lines[10] | Should -BeExactly '# HELP veeam_exporter_info Exporter and server version (value always 1)'
        $lines[11] | Should -BeExactly '# TYPE veeam_exporter_info gauge'
        $lines[12] | Should -BeExactly ('veeam_exporter_info{{script_version="{0}",api_version="1.3-rev2",vbr_version="13.0.1.180"}} 1' -f $script:ScriptVersion)
        $lines[13] | Should -BeExactly ''
    }

    It 'reads vbr_version locally and never calls serverInfo (Backup Viewer may not, OP-13)' {
        Set-VeeamApiMock -VbrVersion '13.1.2.57'
        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningVariable warnings -WarningAction SilentlyContinue
        $result.Success | Should -BeTrue
        @($warnings).Count | Should -Be 0
        Get-FileText -Path $script:HealthFile | Should -Match ([regex]::Escape('api_version="1.3-rev2",vbr_version="13.1.2.57"} 1'))
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly -ParameterFilter { $Path -like '*serverInfo*' }
    }

    It 'leaves vbr_version empty without a warning when -BaseUri points to another server' {
        Set-VeeamApiMock -VbrVersion '13.1.2.57'
        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -BaseUri 'https://vbr02.example.net:9419' -WarningVariable warnings -WarningAction SilentlyContinue
        $result.Success | Should -BeTrue
        @($warnings).Count | Should -Be 0
        Get-FileText -Path $script:HealthFile | Should -Match ([regex]::Escape('api_version="1.3-rev2",vbr_version=""} 1'))
        Should -Invoke -ModuleName VeeamExporter Get-VeeamLocalServerVersion -Times 0 -Exactly
    }

    It 'leaves vbr_version empty and warns once if the local version cannot be read; collectors still run' {
        Set-VeeamApiMock -VbrVersionFails
        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningVariable warnings -WarningAction SilentlyContinue
        Export-GeneratedPromFile -Directory $script:Dir -Name 'ExporterRun/vbr-version-unreadable'
        $result.Success | Should -BeTrue
        @($warnings | Where-Object { "$_" -like 'VBR version not readable*' }).Count | Should -Be 1
        @($warnings).Count | Should -Be 1
        Get-FileText -Path $script:HealthFile | Should -Match ([regex]::Escape('api_version="1.3-rev2",vbr_version=""} 1'))
    }

    It 'accepts collectors as a comma-separated list (powershell.exe -File)' {
        Set-VeeamApiMock
        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -Collector 'jobs, objects' -ObjectSessionType 'BackupJob,ReplicaJob' -WarningAction SilentlyContinue
        ($result.Collectors | ForEach-Object Collector) -join ',' | Should -BeExactly 'jobs,objects'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 2 -Exactly -ParameterFilter { $Path -eq '/api/v1/sessions' }
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/v1/taskSessions' }
    }

    It 'aborts on an unknown collector before logging in, after writing veeam_exporter.prom' {
        Set-VeeamApiMock
        { Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -Collector 'jobs,licence' } | Should -Throw "*Unknown collector 'licence'*"
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly
        # Only the known requested collector is reported, as failed.
        $health = Get-FileText -Path $script:HealthFile
        $health | Should -Match 'veeam_exporter_collector_success\{collector="jobs"\} 0'
        $health | Should -Not -Match 'collector="licence"'
        $health | Should -Not -Match 'collector="objects"'
        $health | Should -Match ([regex]::Escape('api_version="",vbr_version="13.0.1.180"} 1'))
    }

    It 'reports all collectors as failed if none of the requested names is known' {
        Set-VeeamApiMock
        { Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -Collector 'repository' } | Should -Throw "*Unknown collector 'repository'*"
        $health = Get-FileText -Path $script:HealthFile
        foreach ($c in 'jobs', 'objects', 'repositories') { $health | Should -Match ('veeam_exporter_collector_success\{collector="' + $c + '"\} 0') }
    }

    It 'writes veeam_exporter.prom also when no session type is given' {
        Set-VeeamApiMock
        { Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -ObjectSessionType ',' } | Should -Throw '*No session type*'
        Get-FileText -Path $script:HealthFile | Should -Match 'veeam_exporter_collector_success\{collector="objects"\} 0'
    }

    It 'writes veeam_exporter.prom also when a warning is turned into an error (-WarningAction Stop)' {
        Set-VeeamApiMock -VbrVersionFails
        { Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction Stop } | Should -Throw
        Test-Path -LiteralPath $script:HealthFile | Should -BeTrue
    }

    It 'reads the credential from -CredentialPath' {
        Set-VeeamApiMock
        $path = Join-Path -Path $script:Dir -ChildPath 'veeam.cred.xml'
        Mock -ModuleName VeeamExporter Import-Clixml { New-TestCredential } -ParameterFilter { $LiteralPath -eq $path }
        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -CredentialPath $path -WarningAction SilentlyContinue
        $result.Success | Should -BeTrue
        Get-FileText -Path $script:JobsFile | Should -BeExactly (Get-ExpectedText -Name 'veeam_jobs.prom')
    }

    It 'treats a credential that cannot be read like a failed logon (<Case>)' -TestCases @(
        @{ Case = 'missing file'; Content = $null }
        @{ Case = 'no PSCredential in the file'; Content = 'just a string' }
    ) {
        param($Case, $Content)
        Set-VeeamApiMock
        $path = Join-Path -Path $script:Dir -ChildPath 'veeam.cred.xml'
        if ($null -ne $Content) { $Content | Export-Clixml -LiteralPath $path }
        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -CredentialPath $path -WarningVariable warnings -WarningAction SilentlyContinue
        $result.Success | Should -BeFalse
        @($warnings | Where-Object { "$_" -like 'Cannot read credential*veeam.cred.xml*' }).Count | Should -Be 1
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly
        $health = Get-FileText -Path $script:HealthFile
        foreach ($c in 'jobs', 'objects', 'repositories') { $health | Should -Match ('veeam_exporter_collector_success\{collector="' + $c + '"\} 0') }
        $health | Should -Match ([regex]::Escape('vbr_version="13.0.1.180"} 1'))
    }

    It 'runs only the jobs collector with -Collector jobs' {
        Set-VeeamApiMock
        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -Collector 'jobs' -WarningAction SilentlyContinue
        Export-GeneratedPromFile -Directory $script:Dir -Name 'ExporterRun/jobs-only'
        $result.Success | Should -BeTrue
        Test-Path -LiteralPath $script:ObjectsFile | Should -BeFalse
        Get-FileText -Path $script:HealthFile | Should -Not -Match 'collector="objects"'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly -ParameterFilter { $Path -eq '/api/v1/taskSessions' }
    }

    It 'passes lookback and session types on to the objects collector' {
        Set-VeeamApiMock
        $null = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -ObjectSessionType 'ReplicaJob' -ObjectLookbackDays 2 -WarningAction SilentlyContinue
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/v1/sessions' -and $Query['typeFilter'] -eq 'ReplicaJob' }
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly -ParameterFilter { $Path -eq '/api/v1/sessions' -and $Query['typeFilter'] -eq 'BackupJob' }
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/v1/taskSessions' }
        $expected = [System.DateTimeOffset]::UtcNow.AddDays(-2).ToString('yyyy-MM-dd')
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/v1/taskSessions' -and $Query['createdAfterFilter'].StartsWith($expected) }
    }

    It 'isolates collectors: if objects fails, jobs keeps running' {
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

    It 'logs out at the end' {
        Set-VeeamApiMock
        $null = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction SilentlyContinue
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/oauth2/logout' }
    }

    It 'keeps the old veeam_jobs.prom if the collector fails' {
        [System.IO.File]::WriteAllText($script:JobsFile, "veeam_job_enabled{job_name=`"alt`"} 1`n")
        Set-VeeamApiMock -JobsStatus 500

        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction SilentlyContinue

        $result.Success | Should -BeFalse
        Get-FileText -Path $script:JobsFile | Should -BeExactly "veeam_job_enabled{job_name=`"alt`"} 1`n"
        Get-FileText -Path $script:HealthFile | Should -Match 'veeam_exporter_collector_success\{collector="jobs"\} 0'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Path -eq '/api/oauth2/logout' }
    }

    It 'keeps the old veeam_repositories.prom and reports 0 when the answer has no data array' {
        [System.IO.File]::WriteAllText($script:RepositoriesFile, "veeam_repository_online{repository=`"alt`"} 1`n")
        Set-VeeamApiMock
        $script:MockRepositoryStates = '{"repositories":[]}'
        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction SilentlyContinue
        $result.Success | Should -BeFalse
        Get-FileText -Path $script:RepositoriesFile | Should -BeExactly "veeam_repository_online{repository=`"alt`"} 1`n"
        Get-FileText -Path $script:HealthFile | Should -Match 'veeam_exporter_collector_success\{collector="repositories"\} 0'
    }

    It 'writes veeam_exporter.prom even if the login fails' {
        Set-VeeamApiMock -TokenStatus 400 -TokenContent $script:InvalidGrantJson

        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction SilentlyContinue
        Export-GeneratedPromFile -Directory $script:Dir -Name 'ExporterRun/login-failed'

        $result.Success | Should -BeFalse
        Test-Path -LiteralPath $script:JobsFile | Should -BeFalse
        $health = Get-FileText -Path $script:HealthFile
        $health | Should -Match 'veeam_exporter_collector_success\{collector="jobs"\} 0'
        $health | Should -Match 'veeam_exporter_collector_success\{collector="objects"\} 0'
        $health | Should -Match 'veeam_exporter_collector_success\{collector="repositories"\} 0'
        # The VBR version is read locally and does not need the login (OP-13).
        $health | Should -Match ([regex]::Escape('api_version="",vbr_version="13.0.1.180"} 1'))
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly -ParameterFilter { $Path -eq '/api/v1/jobs/states' }
    }

    It 'writes neither password nor token into a .prom file' {
        Set-VeeamApiMock
        $null = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction SilentlyContinue
        foreach ($file in Get-ChildItem -LiteralPath $script:Dir) {
            $text = Get-FileText -Path $file.FullName
            $text | Should -Not -Match 'S3cret'
            $text | Should -Not -Match 'access-123'
            $text | Should -Not -Match 'refresh-456'
        }
    }

    It 'leaves no .tmp files behind' {
        Set-VeeamApiMock
        $null = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction SilentlyContinue
        @(Get-ChildItem -LiteralPath $script:Dir -Filter '*.tmp').Count | Should -Be 0
        Get-SortedFileName -Directory $script:Dir | Should -BeExactly 'veeam_exporter.prom,veeam_jobs.prom,veeam_objects.prom,veeam_repositories.prom'
    }
}

Describe 'Health file without the module' {
    It 'Format-VeeamFailedHealthText equals the module output for failed collectors (<Name>)' -TestCases @(
        @{ Name = 'REST'; Requested = @('jobs,objects', 'repositories'); Known = @('jobs', 'objects', 'repositories'); Expected = @('jobs', 'objects', 'repositories') }
        @{ Name = 'subset and unknown names'; Requested = @('Objects, licence'); Known = @('jobs', 'objects', 'repositories'); Expected = @('objects') }
        @{ Name = 'nothing known'; Requested = @('typo'); Known = @('jobs', 'objects', 'repositories'); Expected = @('jobs', 'objects', 'repositories') }
        @{ Name = 'license'; Requested = @('license'); Known = @('license'); Expected = @('license') }
    ) {
        param($Name, $Requested, $Known, $Expected)
        InModuleScope VeeamExporter -Parameters @{ Requested = $Requested; Known = $Known; Expected = $Expected } {
            param($Requested, $Known, $Expected)
            $results = @($Expected | ForEach-Object { [pscustomobject]@{ Collector = $_; Success = $false; DurationSeconds = 0 } })
            $module = ConvertTo-PromText -Metric (New-VeeamCollectorHealthMetric -Result $results)
            Format-VeeamFailedHealthText -Collector $Requested -Known $Known | Should -BeExactly $module
        }
    }
}

Describe 'Entry scripts write the health file in any case' {
    BeforeAll {
        # Child processes with the PowerShell edition of this test run.
        $script:Exe = (Get-Process -Id $PID).Path
        function Invoke-EntryScript {
            param([string]$Script, [string[]]$Arguments)
            # Windows PowerShell 5.1 turns redirected stderr of a child process into a
            # terminating error when $ErrorActionPreference is Stop (GitHub Actions sets it).
            $ErrorActionPreference = 'Continue'
            $output = & $script:Exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @Arguments 2>&1
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
        }
    }

    BeforeEach {
        $script:Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $script:Out = Join-Path -Path $script:Root -ChildPath 'textfile'
        $script:App = Join-Path -Path $script:Root -ChildPath 'app'
        $null = New-Item -ItemType Directory -Path $script:Out
        Copy-Item -LiteralPath $script:SrcRoot -Destination $script:App -Recurse
    }

    It 'REST task: a missing credential file still gives veeam_exporter.prom with all collectors 0' {
        $r = Invoke-EntryScript -Script (Join-Path $script:App 'Invoke-VeeamExporter.ps1') -Arguments @('-CredentialPath', (Join-Path $script:Root 'missing.cred.xml'), '-TextfileDirectory', $script:Out)
        $r.ExitCode | Should -Be 1
        $health = Get-FileText -Path (Join-Path $script:Out 'veeam_exporter.prom')
        foreach ($c in 'jobs', 'objects', 'repositories') { $health | Should -Match ('veeam_exporter_collector_success\{collector="' + $c + '"\} 0') }
        $health | Should -Match 'veeam_exporter_info\{'
    }

    It 'REST task: a module that cannot be loaded still gives veeam_exporter.prom with the requested collectors 0' {
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $script:App 'VeeamExporter') 'VeeamExporter.psd1'), '@{ this is not a manifest')
        $r = Invoke-EntryScript -Script (Join-Path $script:App 'Invoke-VeeamExporter.ps1') -Arguments @('-CredentialPath', 'x', '-TextfileDirectory', $script:Out, '-Collector', 'jobs,repositories')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Veeam exporter aborted'
        Get-FileText -Path (Join-Path $script:Out 'veeam_exporter.prom') | Should -BeExactly ("# HELP veeam_exporter_collector_success 1 last collector run ok, 0 failure`n" +
            "# TYPE veeam_exporter_collector_success gauge`n" +
            "veeam_exporter_collector_success{collector=`"jobs`"} 0`n" +
            "veeam_exporter_collector_success{collector=`"repositories`"} 0`n" +
            "# HELP veeam_exporter_collector_duration_seconds Collector duration in seconds`n" +
            "# TYPE veeam_exporter_collector_duration_seconds gauge`n" +
            "veeam_exporter_collector_duration_seconds{collector=`"jobs`"} 0`n" +
            "veeam_exporter_collector_duration_seconds{collector=`"repositories`"} 0`n")
    }

    It 'license task: a module that cannot be loaded still gives veeam_exporter_license.prom with license 0' {
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $script:App 'VeeamExporter') 'VeeamExporter.psd1'), '@{ this is not a manifest')
        $r = Invoke-EntryScript -Script (Join-Path $script:App 'Invoke-VeeamLicenseExporter.ps1') -Arguments @('-TextfileDirectory', $script:Out)
        $r.ExitCode | Should -Be 1
        $health = Get-FileText -Path (Join-Path $script:Out 'veeam_exporter_license.prom')
        $health | Should -Match 'veeam_exporter_collector_success\{collector="license"\} 0'
        Test-Path -LiteralPath (Join-Path $script:Out 'veeam_exporter.prom') | Should -BeFalse
    }
}
