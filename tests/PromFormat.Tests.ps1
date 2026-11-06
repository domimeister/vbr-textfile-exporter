BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
}

Describe 'Label escaping' {
    It 'escaped <Name>' -TestCases @(
        @{ Name = 'Backslash'; In = 'a\b'; Out = 'a\\b' }
        @{ Name = 'quote'; In = 'a"b'; Out = 'a\"b' }
        @{ Name = 'LF'; In = "a`nb"; Out = 'a\nb' }
        @{ Name = 'CRLF'; In = "a`r`nb"; Out = 'a\nb' }
        @{ Name = 'UNC path'; In = '\\fs01\share "x"'; Out = '\\\\fs01\\share \"x\"' }
        @{ Name = 'empty'; In = ''; Out = '' }
    ) {
        param($In, $Out)
        InModuleScope VeeamExporter -Parameters @{ In = $In } {
            param($In)
            ConvertTo-PromLabelValue -Value $In
        } | Should -BeExactly $Out
    }

    It 'turns $null into an empty string' {
        InModuleScope VeeamExporter { ConvertTo-PromLabelValue -Value $null } | Should -BeExactly ''
    }
}

Describe 'Format-PromValue' {
    It 'formats <In> as <Out>' -TestCases @(
        @{ In = 0; Out = '0' }
        @{ In = -1; Out = '-1' }
        @{ In = [int64]1705525212; Out = '1705525212' }
        @{ In = 1.5; Out = '1.5' }
        @{ In = $true; Out = '1' }
        @{ In = $false; Out = '0' }
        @{ In = [double]::NaN; Out = 'NaN' }
        @{ In = [double]::PositiveInfinity; Out = '+Inf' }
        @{ In = [double]::NegativeInfinity; Out = '-Inf' }
    ) {
        param($In, $Out)
        InModuleScope VeeamExporter -Parameters @{ In = $In } {
            param($In)
            Format-PromValue -Value $In
        } | Should -BeExactly $Out
    }

    It 'uses a dot as decimal separator regardless of the culture' {
        $result = InModuleScope VeeamExporter {
            $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = New-Object System.Globalization.CultureInfo 'de-CH'
                Format-PromValue -Value 1234.25
            }
            finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $old
            }
        }
        $result | Should -BeExactly '1234.25'
    }
}

Describe 'ConvertTo-PromText' {
    It 'writes HELP and TYPE exactly once per metric, without timestamps' {
        $a = New-PromMetric -Name 'test_a' -Help 'Help A'
        Add-PromSample -Metric $a -Labels ([ordered]@{ job_name = 'J1' }) -Value 1
        Add-PromSample -Metric $a -Labels ([ordered]@{ job_name = 'J2' }) -Value 2
        $b = New-PromMetric -Name 'test_b' -Help 'Help B'
        Add-PromSample -Metric $b -Value 3

        $text = ConvertTo-PromText -Metric @($a, $b)

        $text | Should -BeExactly ("# HELP test_a Help A`n# TYPE test_a gauge`n" +
            "test_a{job_name=`"J1`"} 1`ntest_a{job_name=`"J2`"} 2`n" +
            "# HELP test_b Help B`n# TYPE test_b gauge`ntest_b 3`n")
    }

    It 'omits metrics without samples entirely' {
        $empty = New-PromMetric -Name 'test_empty' -Help 'empty'
        $one = New-PromMetric -Name 'test_one' -Help 'one'
        Add-PromSample -Metric $one -Value 1
        $text = ConvertTo-PromText -Metric @($empty, $one)
        $text | Should -Not -Match 'test_empty'
    }

    It 'ignores samples with value $null' {
        $m = New-PromMetric -Name 'test_null' -Help 'x'
        Add-PromSample -Metric $m -Labels ([ordered]@{ job_name = 'J1' }) -Value $null
        $m.Samples.Count | Should -Be 0
    }

    It 'escapes HELP text' {
        $m = New-PromMetric -Name 'test_help' -Help "a\b`nc"
        Add-PromSample -Metric $m -Value 1
        (ConvertTo-PromText -Metric @($m)) | Should -Match ([regex]::Escape('# HELP test_help a\\b\nc'))
    }

    It 'throws on a duplicate series' {
        $m = New-PromMetric -Name 'test_dup' -Help 'x'
        Add-PromSample -Metric $m -Labels ([ordered]@{ job_name = 'J1' }) -Value 1
        Add-PromSample -Metric $m -Labels ([ordered]@{ job_name = 'J1' }) -Value 2
        { ConvertTo-PromText -Metric @($m) } | Should -Throw '*Duplicate series*'
    }

    It 'throws on a duplicate metric name' {
        $m1 = New-PromMetric -Name 'test_same' -Help 'x'
        $m2 = New-PromMetric -Name 'test_same' -Help 'y'
        { ConvertTo-PromText -Metric @($m1, $m2) } | Should -Throw '*defined twice*'
    }

    It 'rejects the reserved label <Label>' -TestCases @(@{ Label = 'job' }, @{ Label = 'instance' }) {
        param($Label)
        $m = New-PromMetric -Name 'test_reserved' -Help 'x'
        { Add-PromSample -Metric $m -Labels @{ $Label = 'x' } -Value 1 } | Should -Throw '*reserved*'
    }

    It 'rejects invalid metric and label names' {
        { New-PromMetric -Name 'veeam-job' -Help 'x' } | Should -Throw '*Invalid metric name*'
        $m = New-PromMetric -Name 'test_label' -Help 'x'
        { Add-PromSample -Metric $m -Labels @{ 'job-name' = 'x' } -Value 1 } | Should -Throw '*Invalid label name*'
    }

    It 'returns an empty string for an empty list' {
        ConvertTo-PromText -Metric @() | Should -BeExactly ''
    }
}
