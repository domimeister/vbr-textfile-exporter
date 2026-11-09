# Grafana alert rules in alerting/: consistent with docs/metrics.md, well-formed for
# Grafana file provisioning, and their logic unit-tested with promtool.
# Keep this file ASCII-only (Windows PowerShell 5.1 reads it as ANSI).

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'PromtoolHelpers.ps1')
    $script:Promtool = Get-Command -Name 'promtool' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $script:AlertsPath = Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'alerting') -ChildPath 'veeam-alerts.json'
    $script:AlertsBytes = [System.IO.File]::ReadAllBytes($script:AlertsPath)
    $script:Alerts = Get-FileText -Path $script:AlertsPath | ConvertFrom-Json
    $script:Groups = @($script:Alerts.groups)
    $script:Rules = @($script:Groups | ForEach-Object { $_.rules })
    $script:LogicTestPath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'alerting') -ChildPath 'veeam-alerts.test.yml'
    $script:Spec = Get-FileText -Path (Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'docs') -ChildPath 'metrics.md')
    $script:DatasourceUid = '${VEEAM_PROMETHEUS_DATASOURCE_UID}'
    $script:MetricPattern = '\b(?:veeam|windows_textfile|windows_exporter)_[a-z_]+'
    # Threshold types of Grafana's threshold expression and their PromQL operators.
    $script:Operators = @{ gt = '>'; lt = '<'; eq = '==' }

    function Get-SpecAlert {
        # Minimal reader for the single-line fields of the spec block, no YAML module needed.
        param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
        $chunks = [regex]::Split($Text, '(?m)^\s*- alert:\s*')
        foreach ($chunk in @($chunks | Select-Object -Skip 1)) {
            [pscustomobject]@{
                Name      = ($chunk -split "`n")[0].Trim()
                Query     = [regex]::Match($chunk, '(?m)^\s*query:\s*(.+?)\s*$').Groups[1].Value
                Condition = [regex]::Match($chunk, '(?m)^\s*condition:\s*(.+?)\s*$').Groups[1].Value
                For       = [regex]::Match($chunk, '(?m)^\s*for:\s*(\S+)\s*$').Groups[1].Value
                Severity  = [regex]::Match($chunk, '(?m)^\s*severity:\s*(\w+)\s*$').Groups[1].Value
            }
        }
    }

    function Get-RuleStep {
        param([Parameter(Mandatory = $true)]$Rule, [Parameter(Mandatory = $true)][string]$RefId)
        return @($Rule.data | Where-Object { $_.refId -eq $RefId })
    }

    function ConvertTo-SpecAlert {
        # The rule in the notation of the spec: query of A, threshold of B as "A <op> <value>".
        param([Parameter(Mandatory = $true)]$Rule)
        $query = @(Get-RuleStep -Rule $Rule -RefId 'A')[0].model.expr
        $evaluator = @(@(Get-RuleStep -Rule $Rule -RefId 'B')[0].model.conditions)[0].evaluator
        $type = "$($evaluator.type)"
        $operator = if ($script:Operators.ContainsKey($type)) { $script:Operators[$type] } else { "<unknown threshold type '$type'>" }
        $value = ([double]@($evaluator.params)[0]).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        [pscustomobject]@{
            Name      = "$($Rule.title)"
            Query     = "$query"
            Condition = 'A {0} {1}' -f $operator, $value
            For       = "$($Rule.for)"
            Severity  = "$($Rule.labels.severity)"
        }
    }

    function Write-EquivalentRuleFile {
        # promtool cannot read Grafana rules. Query A combined with the threshold of B
        # selects the same series as the Grafana rule, so promtool can test the logic.
        param([Parameter(Mandatory = $true)][string]$Path)
        $lines = @('groups:', '  - name: veeam', '    rules:')
        foreach ($rule in $script:Rules) {
            $alert = ConvertTo-SpecAlert -Rule $rule
            $expr = '({0}) {1}' -f $alert.Query, ($alert.Condition -replace '^A ', '')
            $lines += '      - alert: {0}' -f $alert.Name
            $lines += "        expr: '{0}'" -f ($expr -replace "'", "''")
            $lines += '        for: {0}' -f $alert.For
            $lines += '        labels:'
            $lines += '          severity: {0}' -f $alert.Severity
        }
        [System.IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
    }

    $block = [regex]::Match($script:Spec, '(?s)## Example Alerts.*?```yaml\n(.*?)```').Groups[1].Value
    $script:SpecAlerts = @(Get-SpecAlert -Text $block)
}

Describe 'Grafana alert rules veeam-alerts.json' {
    It 'is ASCII with LF line endings and a newline at the end' {
        @($script:AlertsBytes | Where-Object { $_ -gt 0x7F }).Count | Should -Be 0
        [System.Array]::IndexOf($script:AlertsBytes, [byte]0x0D) | Should -Be -1
        $script:AlertsBytes[-1] | Should -Be 0x0A
    }

    It 'is a provisioning file with the group veeam in the folder Veeam, evaluated every minute' {
        $script:Alerts.apiVersion | Should -Be 1
        $script:Groups.Count | Should -Be 1
        $script:Groups[0].orgId | Should -Be 1
        $script:Groups[0].name | Should -BeExactly 'veeam'
        $script:Groups[0].folder | Should -BeExactly 'Veeam'
        $script:Groups[0].interval | Should -BeExactly '1m'
    }

    It 'matches the example alerts in docs/metrics.md (name, query, condition, for, severity)' {
        $script:SpecAlerts.Count | Should -BeGreaterThan 0
        $format = { '{0} | {1} | {2} | for={3} | {4}' -f $_.Name, $_.Query, $_.Condition, $_.For, $_.Severity }
        $file = @($script:Rules | ForEach-Object { ConvertTo-SpecAlert -Rule $_ } | ForEach-Object $format | Sort-Object)
        $spec = @($script:SpecAlerts | ForEach-Object $format | Sort-Object)
        ($file -join "`n") | Should -BeExactly ($spec -join "`n")
    }

    It 'gives every rule a unique uid derived from its title' {
        $bad = foreach ($rule in $script:Rules) {
            $expected = ($rule.title -creplace '(?<!^)([A-Z])', '-$1').ToLowerInvariant()
            if ("$($rule.uid)" -cne $expected -or "$($rule.uid)".Length -gt 40) { '{0}: {1}' -f $rule.title, $rule.uid }
        }
        @($bad) | Should -BeNullOrEmpty
        @($script:Rules | ForEach-Object { $_.uid } | Sort-Object -Unique).Count | Should -Be $script:Rules.Count
    }

    It 'queries Prometheus through the data source variable, as an instant query (A)' {
        $bad = foreach ($rule in $script:Rules) {
            $a = @(Get-RuleStep -Rule $rule -RefId 'A')
            if ($a.Count -ne 1 -or "$($a[0].datasourceUid)" -cne $script:DatasourceUid -or $a[0].model.refId -ne 'A' -or
                $a[0].model.instant -ne $true -or $a[0].model.range -ne $false -or -not "$($a[0].model.expr)") { $rule.title }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'uses a single threshold on A as the condition (B)' {
        $bad = foreach ($rule in $script:Rules) {
            $b = @(Get-RuleStep -Rule $rule -RefId 'B')
            $conditions = @($b | ForEach-Object { $_.model.conditions })
            $ok = $rule.condition -eq 'B' -and @($rule.data).Count -eq 2 -and $b.Count -eq 1 -and
                $b[0].datasourceUid -eq '__expr__' -and $b[0].model.refId -eq 'B' -and $b[0].model.type -eq 'threshold' -and
                $b[0].model.expression -eq 'A' -and $conditions.Count -eq 1 -and
                $script:Operators.ContainsKey("$($conditions[0].evaluator.type)") -and @($conditions[0].evaluator.params).Count -eq 1
            if (-not $ok) { $rule.title }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'treats no data as OK and query errors as errors, and is not paused' {
        @($script:Rules | Where-Object { $_.noDataState -cne 'OK' -or $_.execErrState -cne 'Error' -or $_.isPaused -ne $false } |
                ForEach-Object { $_.title }) | Should -BeNullOrEmpty
    }

    It 'gives every rule the severity critical or warning and a summary annotation' {
        @($script:Rules | Where-Object { @('critical', 'warning') -cnotcontains "$($_.labels.severity)" -or -not "$($_.annotations.summary)" } |
                ForEach-Object { $_.title }) | Should -BeNullOrEmpty
    }

    It 'uses only metrics documented in docs/metrics.md' {
        # String literals are label values (file names like veeam_license.prom), not metrics.
        $names = @(foreach ($rule in $script:Rules) {
                $query = (ConvertTo-SpecAlert -Rule $rule).Query -replace '"(?:[^"\\]|\\.)*"', '""'
                foreach ($m in [regex]::Matches($query, $script:MetricPattern)) { $m.Value }
            }) | Sort-Object -Unique
        @($names).Count | Should -BeGreaterThan 0
        @($names | Where-Object { -not $script:Spec.Contains('`' + $_ + '`') }) | Should -BeNullOrEmpty
    }

    It 'never uses the Prometheus label job for Veeam jobs' {
        @($script:Rules | ForEach-Object { (ConvertTo-SpecAlert -Rule $_).Query } |
                Where-Object { $_ -match '\bjob\s*(=|!=|=~|!~)' -or $_ -match '[(,]\s*job\s*[,)]' }) | Should -BeNullOrEmpty
    }
}

Describe 'Logic of the alert rules (promtool)' {
    BeforeAll {
        $script:RulesDir = Join-Path -Path $TestDrive -ChildPath 'promtool'
        $null = New-Item -ItemType Directory -Path $script:RulesDir
        $script:RulesPath = Join-Path -Path $script:RulesDir -ChildPath 'veeam-alerts.rules.yml'
        Write-EquivalentRuleFile -Path $script:RulesPath
        Copy-Item -LiteralPath $script:LogicTestPath -Destination $script:RulesDir
    }

    It 'pass promtool check rules as equivalent Prometheus rules' {
        if (-not $script:Promtool) { Set-ItResult -Skipped -Because 'promtool not in PATH'; return }
        $result = Invoke-PromtoolCommand -Executable $script:Promtool.Source -Arguments @('check', 'rules', $script:RulesPath)
        $result.ExitCode | Should -Be 0 -Because $result.Output
    }

    It 'pass the promtool unit tests in tests/alerting' {
        if (-not $script:Promtool) { Set-ItResult -Skipped -Because 'promtool not in PATH'; return }
        $testPath = Join-Path -Path $script:RulesDir -ChildPath (Split-Path -Leaf $script:LogicTestPath)
        $result = Invoke-PromtoolCommand -Executable $script:Promtool.Source -Arguments @('test', 'rules', $testPath)
        $result.ExitCode | Should -Be 0 -Because $result.Output
    }
}
