BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
}

Describe 'Label-Escaping' {
    It 'escaped <Name>' -TestCases @(
        @{ Name = 'Backslash'; In = 'a\b'; Out = 'a\\b' }
        @{ Name = 'Anfuehrungszeichen'; In = 'a"b'; Out = 'a\"b' }
        @{ Name = 'LF'; In = "a`nb"; Out = 'a\nb' }
        @{ Name = 'CRLF'; In = "a`r`nb"; Out = 'a\nb' }
        @{ Name = 'UNC-Pfad'; In = '\\fs01\share "x"'; Out = '\\\\fs01\\share \"x\"' }
        @{ Name = 'leer'; In = ''; Out = '' }
    ) {
        param($In, $Out)
        InModuleScope VeeamExporter -Parameters @{ In = $In } {
            param($In)
            ConvertTo-PromLabelValue -Value $In
        } | Should -BeExactly $Out
    }

    It 'macht aus $null einen leeren String' {
        InModuleScope VeeamExporter { ConvertTo-PromLabelValue -Value $null } | Should -BeExactly ''
    }
}

Describe 'Format-PromValue' {
    It 'formatiert <In> als <Out>' -TestCases @(
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

    It 'nutzt unabhaengig von der Kultur einen Punkt als Dezimaltrenner' {
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
    It 'schreibt HELP und TYPE genau einmal pro Metrik, ohne Timestamps' {
        $a = New-PromMetric -Name 'test_a' -Help 'Hilfe A'
        Add-PromSample -Metric $a -Labels ([ordered]@{ job_name = 'J1' }) -Value 1
        Add-PromSample -Metric $a -Labels ([ordered]@{ job_name = 'J2' }) -Value 2
        $b = New-PromMetric -Name 'test_b' -Help 'Hilfe B'
        Add-PromSample -Metric $b -Value 3

        $text = ConvertTo-PromText -Metric @($a, $b)

        $text | Should -BeExactly ("# HELP test_a Hilfe A`n# TYPE test_a gauge`n" +
            "test_a{job_name=`"J1`"} 1`ntest_a{job_name=`"J2`"} 2`n" +
            "# HELP test_b Hilfe B`n# TYPE test_b gauge`ntest_b 3`n")
    }

    It 'laesst Metriken ohne Samples komplett weg' {
        $empty = New-PromMetric -Name 'test_empty' -Help 'leer'
        $one = New-PromMetric -Name 'test_one' -Help 'eins'
        Add-PromSample -Metric $one -Value 1
        $text = ConvertTo-PromText -Metric @($empty, $one)
        $text | Should -Not -Match 'test_empty'
    }

    It 'ignoriert Samples mit Wert $null' {
        $m = New-PromMetric -Name 'test_null' -Help 'x'
        Add-PromSample -Metric $m -Labels ([ordered]@{ job_name = 'J1' }) -Value $null
        $m.Samples.Count | Should -Be 0
    }

    It 'escaped HELP-Text' {
        $m = New-PromMetric -Name 'test_help' -Help "a\b`nc"
        Add-PromSample -Metric $m -Value 1
        (ConvertTo-PromText -Metric @($m)) | Should -Match ([regex]::Escape('# HELP test_help a\\b\nc'))
    }

    It 'wirft bei doppelter Serie' {
        $m = New-PromMetric -Name 'test_dup' -Help 'x'
        Add-PromSample -Metric $m -Labels ([ordered]@{ job_name = 'J1' }) -Value 1
        Add-PromSample -Metric $m -Labels ([ordered]@{ job_name = 'J1' }) -Value 2
        { ConvertTo-PromText -Metric @($m) } | Should -Throw '*Duplicate series*'
    }

    It 'wirft bei doppeltem Metriknamen' {
        $m1 = New-PromMetric -Name 'test_same' -Help 'x'
        $m2 = New-PromMetric -Name 'test_same' -Help 'y'
        { ConvertTo-PromText -Metric @($m1, $m2) } | Should -Throw '*defined twice*'
    }

    It 'lehnt die reservierten Labels <Label> ab' -TestCases @(@{ Label = 'job' }, @{ Label = 'instance' }) {
        param($Label)
        $m = New-PromMetric -Name 'test_reserved' -Help 'x'
        { Add-PromSample -Metric $m -Labels @{ $Label = 'x' } -Value 1 } | Should -Throw '*reserved*'
    }

    It 'lehnt ungueltige Metrik- und Labelnamen ab' {
        { New-PromMetric -Name 'veeam-job' -Help 'x' } | Should -Throw '*Invalid metric name*'
        $m = New-PromMetric -Name 'test_label' -Help 'x'
        { Add-PromSample -Metric $m -Labels @{ 'job-name' = 'x' } -Value 1 } | Should -Throw '*Invalid label name*'
    }

    It 'liefert fuer eine leere Liste einen leeren String' {
        ConvertTo-PromText -Metric @() | Should -BeExactly ''
    }
}
