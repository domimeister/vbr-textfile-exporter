BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Set-TestTimeZone
}

Describe 'All .prom files of both tasks together (windows_exporter rules)' {
    BeforeAll {
        $script:Dir = Join-Path -Path $TestDrive -ChildPath 'textfile'
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        Set-VeeamApiMock
        $null = Invoke-VeeamExporterRun -TextfileDirectory $script:Dir -Credential (New-TestCredential) -WarningAction SilentlyContinue
        Set-LicenseMock
        $null = Invoke-VeeamLicenseExporterRun -TextfileDirectory $script:Dir -WarningAction SilentlyContinue
        $script:Parsed = @(Get-ChildItem -LiteralPath $script:Dir -Filter '*.prom' | ForEach-Object { Read-PromFile -Path $_.FullName })
        $script:AllSamples = @($script:Parsed | ForEach-Object { $_.Samples })
    }

    It 'generates all six files' {
        Get-SortedFileName -Directory $script:Dir -Filter '*.prom' |
            Should -BeExactly 'veeam_exporter.prom,veeam_exporter_license.prom,veeam_jobs.prom,veeam_license.prom,veeam_objects.prom,veeam_repositories.prom'
    }

    It 'contains no identical series in two files (otherwise the windows_exporter discards everything)' {
        $duplicates = @($script:AllSamples | Group-Object -Property Series -CaseSensitive | Where-Object Count -GT 1 | ForEach-Object Name)
        $duplicates | Should -BeNullOrEmpty
    }

    It 'has the same HELP text and TYPE per metric in all files' {
        $names = @($script:Parsed | ForEach-Object { $_.Help.Keys }) | Sort-Object -Unique
        foreach ($name in $names) {
            $helps = @($script:Parsed | Where-Object { $_.Help.ContainsKey($name) } | ForEach-Object { $_.Help[$name] } | Sort-Object -Unique)
            $types = @($script:Parsed | Where-Object { $_.Type.ContainsKey($name) } | ForEach-Object { $_.Type[$name] } | Sort-Object -Unique)
            $helps.Count | Should -Be 1 -Because $name
            $types.Count | Should -Be 1 -Because $name
        }
    }

    It 'has the same label names per metric in all files' {
        foreach ($group in ($script:AllSamples | Group-Object -Property Name)) {
            @($group.Group | ForEach-Object LabelNames | Sort-Object -Unique).Count | Should -Be 1 -Because $group.Name
        }
    }

    It 'uses collector values jobs, objects, repositories, license' {
        $collectors = @($script:AllSamples | Where-Object Name -EQ 'veeam_exporter_collector_success' | ForEach-Object { $_.Series -replace '^.*collector="([^"]+)".*$', '$1' } | Sort-Object)
        ($collectors -join ',') | Should -BeExactly 'jobs,license,objects,repositories'
    }
}
