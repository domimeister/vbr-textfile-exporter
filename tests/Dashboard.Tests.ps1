# Static checks of the Grafana dashboard in dashboards/.
# Keep this file ASCII-only (Windows PowerShell 5.1 reads it as ANSI).

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    $script:DashboardPath = Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'dashboards') -ChildPath 'veeam-vbr.json'
    $script:DashboardBytes = [System.IO.File]::ReadAllBytes($script:DashboardPath)
    $script:Dashboard = Get-FileText -Path $script:DashboardPath | ConvertFrom-Json
    $script:Spec = Get-FileText -Path (Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'docs') -ChildPath 'metrics.md')

    # Panels of a collapsed row sit in row.panels.
    $script:Panels = @(foreach ($p in $script:Dashboard.panels) {
            $p
            if ($p.PSObject.Properties['panels']) { $p.panels }
        })
    $script:Targets = @(foreach ($p in $script:Panels) {
            if ($p.PSObject.Properties['targets']) { $p.targets }
        })
    $script:Exprs = @($script:Targets | ForEach-Object { [string]$_.expr })
    $script:MetricPattern = '\b(?:veeam|windows_textfile)_[a-z_]+'
}

Describe 'Grafana dashboard veeam-vbr.json' {
    It 'is ASCII with LF line endings and a newline at the end' {
        @($script:DashboardBytes | Where-Object { $_ -gt 0x7F }).Count | Should -Be 0
        [System.Array]::IndexOf($script:DashboardBytes, [byte]0x0D) | Should -Be -1
        $script:DashboardBytes[-1] | Should -Be 0x0A
    }

    It 'has a fixed uid and the variables datasource and instance' {
        $script:Dashboard.uid | Should -Be 'veeam-vbr'
        $names = @($script:Dashboard.templating.list | ForEach-Object { $_.name })
        $names | Should -Contain 'datasource'
        $names | Should -Contain 'instance'
    }

    It 'takes the data source from the variable in every panel, query and query variable' {
        $items = @($script:Panels | Where-Object { $_.type -ne 'row' }) + $script:Targets +
            @($script:Dashboard.templating.list | Where-Object { $_.type -eq 'query' })
        $bad = foreach ($item in $items) {
            if ("$($item.datasource.uid)" -ne '${datasource}') { '{0}{1}{2}' -f $item.title, $item.refId, $item.name }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'filters every metric selector by the instance variable' {
        $bad = foreach ($e in $script:Exprs) {
            foreach ($m in [regex]::Matches($e, "($script:MetricPattern)(\{[^}]*\})?")) {
                if (-not $m.Groups[2].Value.Contains('instance=~"$instance"')) { $m.Value }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'uses only metrics documented in docs/metrics.md' {
        $names = @(foreach ($e in $script:Exprs) {
                foreach ($m in [regex]::Matches($e, $script:MetricPattern)) { $m.Value }
            }) | Sort-Object -Unique
        @($names).Count | Should -BeGreaterThan 0
        @($names | Where-Object { -not $script:Spec.Contains('`' + $_ + '`') }) | Should -BeNullOrEmpty
    }

    It 'never uses the Prometheus label job for Veeam jobs' {
        @($script:Exprs | Where-Object { $_ -match '\bjob\s*(=|!=|=~|!~)' -or $_ -match '[(,]\s*job\s*[,)]' }) | Should -BeNullOrEmpty
    }
}
