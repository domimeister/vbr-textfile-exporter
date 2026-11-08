BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Set-TestTimeZone

    if (-not ('VeeamExporterTest.VBRLicenseStatus' -as [type])) {
        Add-Type -TypeDefinition 'namespace VeeamExporterTest { public enum VBRLicenseStatus { Valid, Expired, Invalid } public enum VBRLicenseType { Rental, Perpetual, Subscription, Evaluation, Free, Empty, NFR } }'
    }
}

Describe 'Get-VeeamLicenseMetric' {
    It 'generates veeam_license.prom line by line for <Name>' -TestCases @(
        @{ Name = 'rental' }, @{ Name = 'perpetual-socket' }, @{ Name = 'expired' }
    ) {
        param($Name)
        $license = Get-FixtureText -Name "license/license-$Name.json" | ConvertFrom-Json
        $actual = ConvertTo-PromText -Metric (Get-VeeamLicenseMetric -License $license)
        Assert-PromText -Actual $actual -Expected (Get-ExpectedText -Name "license/veeam_license_$Name.prom")
    }

    It 'reads real objects with enums and DateTime (Kind Local)' {
        $expiration = New-Object datetime -ArgumentList 2027, 3, 31, 12, 0, 0, ([System.DateTimeKind]::Local)
        $license = [pscustomobject]@{
            Status                 = [VeeamExporterTest.VBRLicenseStatus]::Valid
            Type                   = [VeeamExporterTest.VBRLicenseType]::Subscription
            Edition                = 'EnterprisePlus'
            LicensedTo             = 'Test AG'
            ExpirationDate         = $expiration
            SupportExpirationDate  = [datetime]::MinValue
            InstanceLicenseSummary = [pscustomobject]@{ LicensedInstancesNumber = 100; UsedInstancesNumber = 99 }
        }
        $text = ConvertTo-PromText -Metric (Get-VeeamLicenseMetric -License $license)
        $expected = ([System.DateTimeOffset]$expiration).ToUnixTimeSeconds()
        $text | Should -Match ([regex]::Escape('veeam_license_info{edition="EnterprisePlus",license_type="Subscription",status="Valid",licensed_to="Test AG"} 1'))
        $text | Should -Match "veeam_license_valid 1`n"
        $text | Should -Match "veeam_license_expiration_timestamp_seconds $expected`n"
        $text | Should -Not -Match 'veeam_license_support_expiration_timestamp_seconds'
        $text | Should -Match "veeam_license_instances_used 99`n"
    }

    It 'treats DateTime.MaxValue as not set' {
        $license = [pscustomobject]@{ Status = 'Valid'; ExpirationDate = [datetime]::MaxValue; SupportExpirationDate = [datetime]::MaxValue }
        $text = ConvertTo-PromText -Metric (Get-VeeamLicenseMetric -License $license)
        $text | Should -Not -Match 'expiration_timestamp_seconds'
    }

    It 'reports <Status> as invalid' -TestCases @(@{ Status = 'Expired' }, @{ Status = 'Invalid' }, @{ Status = '' }) {
        param($Status)
        $text = ConvertTo-PromText -Metric (Get-VeeamLicenseMetric -License ([pscustomobject]@{ Status = $Status }))
        $text | Should -Match "veeam_license_valid 0`n"
    }

    It 'takes the first of several license objects and warns' {
        $a = [pscustomobject]@{ Status = 'Valid'; LicensedTo = 'Erste' }
        $b = [pscustomobject]@{ Status = 'Expired'; LicensedTo = 'Zweite' }
        $text = ConvertTo-PromText -Metric (Get-VeeamLicenseMetric -License @($a, $b) -WarningVariable warnings -WarningAction SilentlyContinue)
        @($warnings).Count | Should -Be 1
        $text | Should -Match 'licensed_to="Erste"'
        $text | Should -Not -Match 'Zweite'
    }

    It 'sums InstanceLicenseSummary if it is an array' {
        $license = [pscustomobject]@{ Status = 'Valid'; InstanceLicenseSummary = @(
                [pscustomobject]@{ LicensedInstancesNumber = 10; UsedInstancesNumber = 4 }
                [pscustomobject]@{ LicensedInstancesNumber = 5; UsedInstancesNumber = 1.5 }
            )
        }
        $text = ConvertTo-PromText -Metric (Get-VeeamLicenseMetric -License $license)
        $text | Should -Match "veeam_license_instances_licensed 15`n"
        $text | Should -Match "veeam_license_instances_used 5.5`n"
    }

    It 'throws without a license object' {
        { Get-VeeamLicenseMetric -License @() } | Should -Throw '*no license*'
        { Get-VeeamLicenseMetric -License $null } | Should -Throw '*no license*'
    }
}

Describe 'Invoke-VeeamLicenseExporterRun' {
    BeforeEach {
        $script:Dir = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        $script:LicenseFile = Join-Path -Path $script:Dir -ChildPath 'veeam_license.prom'
        $script:HealthFile = Join-Path -Path $script:Dir -ChildPath 'veeam_exporter_license.prom'
    }

    It 'writes veeam_license.prom and veeam_exporter_license.prom on success' {
        Set-LicenseMock
        $result = Invoke-VeeamLicenseExporterRun -TextfileDirectory $script:Dir -WarningAction SilentlyContinue
        Export-GeneratedPromFile -Directory $script:Dir -Name 'LicenseRun/success'

        $result.Success | Should -BeTrue
        Get-FileText -Path $script:LicenseFile | Should -BeExactly (Get-ExpectedText -Name 'license/veeam_license_rental.prom')
        $lines = (Get-FileText -Path $script:HealthFile) -split "`n"
        $lines.Count | Should -Be 7
        $lines[0] | Should -BeExactly '# HELP veeam_exporter_collector_success 1 last collector run ok, 0 failure'
        $lines[1] | Should -BeExactly '# TYPE veeam_exporter_collector_success gauge'
        $lines[2] | Should -BeExactly 'veeam_exporter_collector_success{collector="license"} 1'
        $lines[3] | Should -BeExactly '# HELP veeam_exporter_collector_duration_seconds Collector duration in seconds'
        $lines[4] | Should -BeExactly '# TYPE veeam_exporter_collector_duration_seconds gauge'
        $lines[5] | Should -Match '^veeam_exporter_collector_duration_seconds\{collector="license"\} [0-9]+(\.[0-9]+)?$'
        $lines[6] | Should -BeExactly ''
    }

    It 'disconnects only if it opened the connection itself (<Connected>)' -TestCases @(@{ Connected = $true; Times = 1 }, @{ Connected = $false; Times = 0 }) {
        param($Connected, $Times)
        Set-LicenseMock -Connected $Connected
        $null = Invoke-VeeamLicenseExporterRun -TextfileDirectory $script:Dir -WarningAction SilentlyContinue
        Should -Invoke -ModuleName VeeamExporter Disconnect-VeeamLocalServer -Times $Times -Exactly
    }

    It 'keeps the old veeam_license.prom if Get-VBRInstalledLicense fails' {
        [System.IO.File]::WriteAllText($script:LicenseFile, "veeam_license_valid 1`n")
        Set-LicenseMock -LicenseFails

        $result = Invoke-VeeamLicenseExporterRun -TextfileDirectory $script:Dir -WarningVariable warnings -WarningAction SilentlyContinue

        $result.Success | Should -BeFalse
        Get-FileText -Path $script:LicenseFile | Should -BeExactly "veeam_license_valid 1`n"
        Get-FileText -Path $script:HealthFile | Should -Match 'veeam_exporter_collector_success\{collector="license"\} 0'
        @($warnings | Where-Object { "$_" -like '*access denied*' }).Count | Should -Be 1
        Should -Invoke -ModuleName VeeamExporter Disconnect-VeeamLocalServer -Times 1 -Exactly
    }

    It 'writes the health status even if the Veeam module is missing' {
        Set-LicenseMock -ImportFails
        $result = Invoke-VeeamLicenseExporterRun -TextfileDirectory $script:Dir -WarningAction SilentlyContinue
        Export-GeneratedPromFile -Directory $script:Dir -Name 'LicenseRun/module-missing'
        $result.Success | Should -BeFalse
        Test-Path -LiteralPath $script:LicenseFile | Should -BeFalse
        Get-FileText -Path $script:HealthFile | Should -Match 'veeam_exporter_collector_success\{collector="license"\} 0'
        Should -Invoke -ModuleName VeeamExporter Connect-VeeamLocalServer -Times 0 -Exactly
    }

    It 'leaves veeam_exporter.prom of the REST task untouched' {
        $restHealth = Join-Path -Path $script:Dir -ChildPath 'veeam_exporter.prom'
        [System.IO.File]::WriteAllText($restHealth, "veeam_exporter_collector_success{collector=`"jobs`"} 1`n")
        Set-LicenseMock
        $null = Invoke-VeeamLicenseExporterRun -TextfileDirectory $script:Dir -WarningAction SilentlyContinue
        Get-FileText -Path $restHealth | Should -BeExactly "veeam_exporter_collector_success{collector=`"jobs`"} 1`n"
        Get-SortedFileName -Directory $script:Dir | Should -BeExactly 'veeam_exporter.prom,veeam_exporter_license.prom,veeam_license.prom'
    }
}

Describe 'Wrapper around the Veeam PowerShell module' {
    BeforeAll {
        # Stubs: the real cmdlets only exist on a VBR server.
        function global:Get-VBRServerSession { }
        function global:Connect-VBRServer { }
        function global:Disconnect-VBRServer { }
        function global:Get-VBRInstalledLicense { }
    }
    AfterAll {
        foreach ($name in 'Get-VBRServerSession', 'Connect-VBRServer', 'Disconnect-VBRServer', 'Get-VBRInstalledLicense') {
            Remove-Item -Path "Function:\$name" -ErrorAction SilentlyContinue
        }
    }

    It 'does not reconnect if a session already exists' {
        Mock -ModuleName VeeamExporter Get-VBRServerSession { [pscustomobject]@{ Server = 'localhost' } }
        Mock -ModuleName VeeamExporter Connect-VBRServer { }
        InModuleScope VeeamExporter { Connect-VeeamLocalServer } | Should -BeFalse
        Should -Invoke -ModuleName VeeamExporter Connect-VBRServer -Times 0 -Exactly
    }

    It 'connects locally without parameters if no session exists' {
        Mock -ModuleName VeeamExporter Get-VBRServerSession { $null }
        Mock -ModuleName VeeamExporter Connect-VBRServer { 'output that must not leak' }
        InModuleScope VeeamExporter { Connect-VeeamLocalServer } | Should -BeExactly $true
        Should -Invoke -ModuleName VeeamExporter Connect-VBRServer -Times 1 -Exactly
    }

    It 'connects if Get-VBRServerSession throws an error' {
        Mock -ModuleName VeeamExporter Get-VBRServerSession { throw 'no session' }
        Mock -ModuleName VeeamExporter Connect-VBRServer { }
        InModuleScope VeeamExporter { Connect-VeeamLocalServer } | Should -BeTrue
    }

    It 'returns the license as an array' {
        Mock -ModuleName VeeamExporter Get-VBRInstalledLicense { [pscustomobject]@{ Status = 'Valid' } }
        # InModuleScope unrolls its output, and under Windows PowerShell 5.1 a
        # single pscustomobject has no .Count, hence @() around the call.
        $result = @(InModuleScope VeeamExporter { Get-VeeamInstalledLicense })
        $result.Count | Should -Be 1
        $result[0].Status | Should -Be 'Valid'
    }

    It 'does not import the module if the cmdlets are already present' {
        Mock -ModuleName VeeamExporter Import-Module { }
        InModuleScope VeeamExporter { Import-VeeamBackupModule }
        Should -Invoke -ModuleName VeeamExporter Import-Module -Times 0 -Exactly
    }

    It 'reports a failed import with the module name' {
        # Mock the command lookup instead of removing the stub: on a machine with
        # VBR installed, PowerShell would find the real cmdlet via module
        # auto-loading and never call Import-Module (#23).
        Mock -ModuleName VeeamExporter Get-Command { } -ParameterFilter { $Name -eq 'Get-VBRInstalledLicense' }
        Mock -ModuleName VeeamExporter Import-Module { throw 'The specified module was not loaded' }
        { InModuleScope VeeamExporter { Import-VeeamBackupModule } } | Should -Throw '*Veeam.Backup.PowerShell*not loaded*'
        Should -Invoke -ModuleName VeeamExporter Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Veeam.Backup.PowerShell' -and $Global }
    }
}
