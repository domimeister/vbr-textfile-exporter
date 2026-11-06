BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
}

Describe 'ConvertTo-UnixTimestamp' {
    It 'wandelt <In> in <Out>' -TestCases @(
        @{ In = '2024-01-17T22:00:12.36+01:00'; Out = 1705525212 }
        @{ In = '2024-01-18T06:30:00Z'; Out = 1705559400 }
        @{ In = '2024-01-18T06:30:00.9999999Z'; Out = 1705559400 }
        @{ In = '2024-01-18T06:30:00'; Out = 1705559400 }
        @{ In = '1970-01-01T00:00:00Z'; Out = 0 }
    ) {
        param($In, $Out)
        InModuleScope VeeamExporter -Parameters @{ In = $In } {
            param($In)
            ConvertTo-UnixTimestamp -Value $In
        } | Should -Be $Out
    }

    It 'akzeptiert DateTime (PowerShell 7 ConvertFrom-Json) und DateTimeOffset' {
        InModuleScope VeeamExporter {
            $utc = [datetime]::SpecifyKind([datetime]'2024-01-18 06:30:00', [System.DateTimeKind]::Utc)
            ConvertTo-UnixTimestamp -Value $utc | Should -Be 1705559400
            ConvertTo-UnixTimestamp -Value $utc.ToLocalTime() | Should -Be 1705559400
            ConvertTo-UnixTimestamp -Value ([System.DateTimeOffset]::new(2024, 1, 18, 7, 30, 0, [timespan]::FromHours(1))) | Should -Be 1705559400
        }
    }

    It 'liefert $null fuer $null und leere Strings' {
        InModuleScope VeeamExporter {
            ConvertTo-UnixTimestamp -Value $null | Should -BeNullOrEmpty
            ConvertTo-UnixTimestamp -Value '' | Should -BeNullOrEmpty
        }
    }

    It 'wirft bei ungueltigem Zeitstempel' {
        InModuleScope VeeamExporter {
            { ConvertTo-UnixTimestamp -Value 'gestern' } | Should -Throw '*Invalid timestamp*'
        }
    }
}

Describe 'ConvertTo-VeeamResultCode' {
    It 'bildet <In> auf <Out> ab' -TestCases @(
        @{ In = 'Success'; Out = 0 }
        @{ In = 'Warning'; Out = 1 }
        @{ In = 'Failed'; Out = 2 }
        @{ In = 'None'; Out = -1 }
        @{ In = 'success'; Out = 0 }
        @{ In = 'FAILED'; Out = 2 }
        @{ In = 'SomethingNew'; Out = -1 }
        @{ In = ''; Out = -1 }
        @{ In = $null; Out = -1 }
    ) {
        param($In, $Out)
        InModuleScope VeeamExporter -Parameters @{ In = $In } {
            param($In)
            ConvertTo-VeeamResultCode -Result $In
        } | Should -Be $Out
    }
}
