BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
}

Describe 'ConvertTo-UnixTimestamp' {
    It 'converts <In> to <Out>' -TestCases @(
        @{ In = '2024-01-17T22:00:12.36+01:00'; Out = 1705525212 }
        @{ In = '2024-01-18T06:30:00Z'; Out = 1705559400 }
        @{ In = '2024-01-18T06:30:00.9999999Z'; Out = 1705559400 }
        @{ In = '1970-01-01T00:00:00Z'; Out = 0 }
    ) {
        param($In, $Out)
        InModuleScope VeeamExporter -Parameters @{ In = $In } {
            param($In)
            ConvertTo-UnixTimestamp -Value $In
        } | Should -Be $Out
    }

    It 'accepts DateTime (PowerShell 7 ConvertFrom-Json) and DateTimeOffset' {
        InModuleScope VeeamExporter {
            $utc = [datetime]::SpecifyKind([datetime]'2024-01-18 06:30:00', [System.DateTimeKind]::Utc)
            ConvertTo-UnixTimestamp -Value $utc | Should -Be 1705559400
            ConvertTo-UnixTimestamp -Value $utc.ToLocalTime() | Should -Be 1705559400
            ConvertTo-UnixTimestamp -Value ([System.DateTimeOffset]::new(2024, 1, 18, 7, 30, 0, [timespan]::FromHours(1))) | Should -Be 1705559400
        }
    }

    It 'reads timestamps without offset in the time zone of the server (OP-9)' {
        Set-TestTimeZone
        InModuleScope VeeamExporter {
            ConvertTo-UnixTimestamp -Value '2024-01-18T07:30:00' | Should -Be 1705559400
            ConvertTo-UnixTimestamp -Value '2024-11-13T22:00:49.893878' | Should -Be 1731531649
            $unspecified = [datetime]::SpecifyKind([datetime]'2024-01-18 07:30:00', [System.DateTimeKind]::Unspecified)
            ConvertTo-UnixTimestamp -Value $unspecified | Should -Be 1705559400
        }
    }

    It 'ignores the time zone if the timestamp has an offset' {
        Set-TestTimeZone
        InModuleScope VeeamExporter {
            ConvertTo-UnixTimestamp -Value '2024-01-18T06:30:00Z' | Should -Be 1705559400
            ConvertTo-UnixTimestamp -Value '2024-01-18T09:30:00+03:00' | Should -Be 1705559400
            ConvertTo-UnixTimestamp -Value '2024-01-18T09:30:00+0300' | Should -Be 1705559400
        }
    }

    It 'treats 0001-01-01 as not set' {
        Set-TestTimeZone
        InModuleScope VeeamExporter {
            ConvertTo-UnixTimestamp -Value '0001-01-01T00:00:00' | Should -BeNullOrEmpty
            ConvertTo-UnixTimestamp -Value '0001-01-01T00:00:00+01:00' | Should -BeNullOrEmpty
            ConvertTo-UnixTimestamp -Value ([datetime]::MinValue) | Should -BeNullOrEmpty
        }
    }

    It 'formats filter values in UTC with Z' {
        InModuleScope VeeamExporter {
            $value = New-Object System.DateTimeOffset -ArgumentList 2024, 1, 18, 7, 30, 5, ([timespan]::FromHours(1))
            ConvertTo-VeeamFilterTimestamp -Value $value | Should -BeExactly '2024-01-18T06:30:05Z'
        }
    }

    It 'returns $null for $null and empty strings' {
        InModuleScope VeeamExporter {
            ConvertTo-UnixTimestamp -Value $null | Should -BeNullOrEmpty
            ConvertTo-UnixTimestamp -Value '' | Should -BeNullOrEmpty
        }
    }

    It 'throws on an invalid timestamp' {
        InModuleScope VeeamExporter {
            { ConvertTo-UnixTimestamp -Value 'gestern' } | Should -Throw '*Invalid timestamp*'
        }
    }
}

Describe 'ConvertTo-VeeamResultCode' {
    It 'maps <In> to <Out>' -TestCases @(
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
