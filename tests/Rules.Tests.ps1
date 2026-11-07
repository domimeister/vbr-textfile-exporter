# Alerting rules in rules/: consistent with docs/metrics.md, valid and unit-tested with promtool.
# Keep this file ASCII-only (Windows PowerShell 5.1 reads it as ANSI).

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'PromtoolHelpers.ps1')
    $script:Promtool = Get-Command -Name 'promtool' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $script:RulesPath = Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'rules') -ChildPath 'veeam.rules.yml'
    $script:RulesTestPath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'rules') -ChildPath 'veeam.rules.test.yml'

    function Get-AlertRule {
        # Minimal reader for single-line expr/for/severity/summary, no YAML module needed.
        param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
        $chunks = [regex]::Split($Text, '(?m)^\s*- alert:\s*')
        foreach ($chunk in @($chunks | Select-Object -Skip 1)) {
            [pscustomobject]@{
                Name     = ($chunk -split "`n")[0].Trim()
                Expr     = [regex]::Match($chunk, '(?m)^\s*expr:\s*(.+?)\s*$').Groups[1].Value
                For      = [regex]::Match($chunk, '(?m)^\s*for:\s*(\S+)\s*$').Groups[1].Value
                Severity = [regex]::Match($chunk, 'severity:\s*(\w+)').Groups[1].Value
                Summary  = [regex]::Match($chunk, '(?m)^\s*summary:\s*(.+?)\s*$').Groups[1].Value
            }
        }
    }

    $spec = Get-FileText -Path (Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'docs') -ChildPath 'metrics.md')
    $block = [regex]::Match($spec, '(?s)## Example Alerts.*?```yaml\n(.*?)```').Groups[1].Value
    $script:SpecRules = @(Get-AlertRule -Text $block)
    $script:FileRules = @(Get-AlertRule -Text (Get-FileText -Path $script:RulesPath))
}

Describe 'Alerting rules' {
    It 'match the example alerts in docs/metrics.md (name, expr, for, severity)' {
        $script:SpecRules.Count | Should -BeGreaterThan 0
        $format = { '{0} | {1} | for={2} | {3}' -f $_.Name, $_.Expr, $_.For, $_.Severity }
        $file = @($script:FileRules | ForEach-Object $format | Sort-Object)
        $spec = @($script:SpecRules | ForEach-Object $format | Sort-Object)
        ($file -join "`n") | Should -BeExactly ($spec -join "`n")
    }

    It 'give every rule a summary annotation' {
        @($script:FileRules | Where-Object { -not $_.Summary } | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty
    }

    It 'pass promtool check rules' {
        if (-not $script:Promtool) { Set-ItResult -Skipped -Because 'promtool not in PATH'; return }
        $result = Invoke-PromtoolCommand -Executable $script:Promtool.Source -Arguments @('check', 'rules', $script:RulesPath)
        $result.ExitCode | Should -Be 0 -Because $result.Output
    }

    It 'pass the promtool unit tests in tests/rules' {
        if (-not $script:Promtool) { Set-ItResult -Skipped -Because 'promtool not in PATH'; return }
        $result = Invoke-PromtoolCommand -Executable $script:Promtool.Source -Arguments @('test', 'rules', $script:RulesTestPath)
        $result.ExitCode | Should -Be 0 -Because $result.Output
    }
}
