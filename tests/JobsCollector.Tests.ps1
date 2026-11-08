BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')

    function Get-JobsPromText {
        param([string]$Fixture)
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 200 -Content $script:FixtureContent }
        $script:FixtureContent = Get-FixtureText -Name $Fixture
        return ConvertTo-PromText -Metric (Get-VeeamJobMetric -Session (New-TestSession))
    }
}

Describe 'Jobs collector' {
    It 'generates veeam_jobs.prom line by line from jobs/states' {
        $actual = Get-JobsPromText -Fixture 'jobs-states.json'
        $expected = Get-ExpectedText -Name 'veeam_jobs.prom'

        $actualLines = $actual -split "`n"
        $expectedLines = $expected -split "`n"
        for ($i = 0; $i -lt [math]::Max($actualLines.Count, $expectedLines.Count); $i++) {
            $actualLines[$i] | Should -BeExactly $expectedLines[$i] -Because "Zeile $($i + 1)"
        }
        $actual | Should -BeExactly $expected
    }

    It 'generates veeam_jobs.prom line by line from the doc example <Version>' -TestCases @(
        @{ Version = '1.3-rev0' }, @{ Version = '1.3-rev1' }, @{ Version = '1.3-rev2' }
    ) {
        param($Version)
        $actual = Get-JobsPromText -Fixture "doc/$Version/jobs-states.json"
        Assert-PromText -Actual $actual -Expected (Get-ExpectedText -Name "doc/$Version/veeam_jobs.prom")
    }

    It 'escapes label values and keeps umlauts (UTF-8)' {
        $actual = Get-JobsPromText -Fixture 'jobs-states-escaping.json'
        $actual | Should -BeExactly (Get-ExpectedText -Name 'veeam_jobs_escaping.prom')
    }

    It 'reads GET /api/v1/jobs/states' {
        $null = Get-JobsPromText -Fixture 'jobs-states.json'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Path -eq '/api/v1/jobs/states'
        }
    }

    It 'uses job_name and never job or instance as label' {
        $actual = Get-JobsPromText -Fixture 'jobs-states.json'
        $actual | Should -Not -Match '[{,]job='
        $actual | Should -Not -Match '[{,]instance='
    }

    It 'omits next_run for chained jobs and last_run for jobs that never ran' {
        $actual = Get-JobsPromText -Fixture 'jobs-states.json'
        $actual | Should -Not -Match 'veeam_job_next_run_timestamp_seconds\{job_name="Backup Copy Job 1"\}'
        $actual | Should -Not -Match 'veeam_job_last_run_timestamp_seconds\{job_name="Replica Job 1"\}'
    }

    It 'returns empty text for a server without jobs' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest {
            New-HttpResponse -StatusCode 200 -Content '{"data":[],"pagination":{"total":0,"count":0,"skip":0,"limit":200}}'
        }
        ConvertTo-PromText -Metric (Get-VeeamJobMetric -Session (New-TestSession)) | Should -BeExactly ''
    }

    It 'contains each HELP and TYPE line exactly once and no timestamps' {
        $lines = (Get-JobsPromText -Fixture 'jobs-states.json').TrimEnd("`n") -split "`n"
        $help = @($lines | Where-Object { $_ -like '# HELP *' } | ForEach-Object { ($_ -split ' ')[2] })
        $type = @($lines | Where-Object { $_ -like '# TYPE *' } | ForEach-Object { ($_ -split ' ')[2] })
        $help.Count | Should -Be 7
        @($help | Select-Object -Unique).Count | Should -Be 7
        ($type -join ',') | Should -BeExactly ($help -join ',')
        foreach ($line in ($lines | Where-Object { $_ -notlike '#*' })) {
            $line | Should -Match '^[a-z_]+(\{.*\})? -?[0-9]+$'
        }
    }
}
