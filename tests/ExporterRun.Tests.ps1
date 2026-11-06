BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    $script:ScriptVersion = (Import-PowerShellDataFile -Path $script:ModuleManifest).ModuleVersion

    function Set-VeeamApiMock {
        param(
            [int]$TokenStatus = 200,
            [string]$TokenContent = $script:TokenJson,
            [int]$JobsStatus = 200
        )
        $script:MockTokenStatus = $TokenStatus
        $script:MockTokenContent = $TokenContent
        $script:MockJobsStatus = $JobsStatus
        $script:MockJobsContent = Get-FixtureText -Name 'jobs-states.json'
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest {
            switch ($Path) {
                '/api/oauth2/token' { return New-HttpResponse -StatusCode $script:MockTokenStatus -Content $script:MockTokenContent }
                '/api/oauth2/logout' { return New-HttpResponse -StatusCode 200 }
                '/api/v1/serverInfo' { return New-HttpResponse -StatusCode 200 -Content '{"vbrId":"b3b2c6e0","name":"vbr01","buildVersion":"13.0.1.180","patches":[]}' }
                '/api/v1/jobs/states' {
                    if ($script:MockJobsStatus -ne 200) { return New-HttpResponse -StatusCode $script:MockJobsStatus -Content '{"errorCode":"InternalError","message":"boom"}' }
                    return New-HttpResponse -StatusCode 200 -Content $script:MockJobsContent
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
        $script:HealthFile = Join-Path -Path $script:Dir -ChildPath 'veeam_exporter.prom'
    }

    It 'schreibt veeam_jobs.prom und veeam_exporter.prom bei Erfolg' {
        Set-VeeamApiMock
        $result = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction SilentlyContinue

        $result.Success | Should -BeTrue
        $result.ApiVersion | Should -BeExactly '1.3-rev2'
        Get-FileText -Path $script:JobsFile | Should -BeExactly (Get-ExpectedText -Name 'veeam_jobs.prom')

        $lines = (Get-FileText -Path $script:HealthFile) -split "`n"
        $lines.Count | Should -Be 10
        $lines[0] | Should -BeExactly '# HELP veeam_exporter_collector_success 1 letzter Lauf des Collectors ok, 0 Fehler'
        $lines[1] | Should -BeExactly '# TYPE veeam_exporter_collector_success gauge'
        $lines[2] | Should -BeExactly 'veeam_exporter_collector_success{collector="jobs"} 1'
        $lines[3] | Should -BeExactly '# HELP veeam_exporter_collector_duration_seconds Laufzeit des Collectors in Sekunden'
        $lines[4] | Should -BeExactly '# TYPE veeam_exporter_collector_duration_seconds gauge'
        $lines[5] | Should -Match '^veeam_exporter_collector_duration_seconds\{collector="jobs"\} [0-9]+(\.[0-9]+)?$'
        $lines[6] | Should -BeExactly '# HELP veeam_exporter_info Exporter- und Server-Version (Wert immer 1)'
        $lines[7] | Should -BeExactly '# TYPE veeam_exporter_info gauge'
        $lines[8] | Should -BeExactly ('veeam_exporter_info{{script_version="{0}",api_version="1.3-rev2",vbr_version="13.0.1.180"}} 1' -f $script:ScriptVersion)
        $lines[9] | Should -BeExactly ''
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
        @(Get-ChildItem -LiteralPath $script:Dir | ForEach-Object Name | Sort-Object) -join ',' | Should -BeExactly 'veeam_exporter.prom,veeam_jobs.prom'
    }
}
