BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Set-TestTimeZone

    if (-not ('VeeamExporterTest.VBRLicenseStatus' -as [type])) {
        Add-Type -TypeDefinition 'namespace VeeamExporterTest { public enum VBRLicenseStatus { Valid, Expired, Invalid } public enum VBRLicenseType { Rental, Perpetual, Subscription, Evaluation, Free, Empty, NFR } }'
    }
}

Describe 'Get-VeeamLicenseMetric' {
    It 'erzeugt veeam_license.prom fuer <Name> zeilengenau' -TestCases @(
        @{ Name = 'rental' }, @{ Name = 'perpetual-socket' }, @{ Name = 'expired' }
    ) {
        param($Name)
        $license = Get-FixtureText -Name "license/license-$Name.json" | ConvertFrom-Json
        $actual = ConvertTo-PromText -Metric (Get-VeeamLicenseMetric -License $license)
        Assert-PromText -Actual $actual -Expected (Get-ExpectedText -Name "license/veeam_license_$Name.prom")
    }

    It 'liest echte Objekte mit Enums und DateTime (Kind Local)' {
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

    It 'behandelt DateTime.MaxValue als nicht gesetzt' {
        $license = [pscustomobject]@{ Status = 'Valid'; ExpirationDate = [datetime]::MaxValue; SupportExpirationDate = [datetime]::MaxValue }
        $text = ConvertTo-PromText -Metric (Get-VeeamLicenseMetric -License $license)
        $text | Should -Not -Match 'expiration_timestamp_seconds'
    }

    It 'meldet <Status> als ungueltig' -TestCases @(@{ Status = 'Expired' }, @{ Status = 'Invalid' }, @{ Status = '' }) {
        param($Status)
        $text = ConvertTo-PromText -Metric (Get-VeeamLicenseMetric -License ([pscustomobject]@{ Status = $Status }))
        $text | Should -Match "veeam_license_valid 0`n"
    }

    It 'nimmt bei mehreren Lizenzobjekten das erste und warnt' {
        $a = [pscustomobject]@{ Status = 'Valid'; LicensedTo = 'Erste' }
        $b = [pscustomobject]@{ Status = 'Expired'; LicensedTo = 'Zweite' }
        $text = ConvertTo-PromText -Metric (Get-VeeamLicenseMetric -License @($a, $b) -WarningVariable warnings -WarningAction SilentlyContinue)
        @($warnings).Count | Should -Be 1
        $text | Should -Match 'licensed_to="Erste"'
        $text | Should -Not -Match 'Zweite'
    }

    It 'summiert InstanceLicenseSummary, falls es ein Array ist' {
        $license = [pscustomobject]@{ Status = 'Valid'; InstanceLicenseSummary = @(
                [pscustomobject]@{ LicensedInstancesNumber = 10; UsedInstancesNumber = 4 }
                [pscustomobject]@{ LicensedInstancesNumber = 5; UsedInstancesNumber = 1.5 }
            )
        }
        $text = ConvertTo-PromText -Metric (Get-VeeamLicenseMetric -License $license)
        $text | Should -Match "veeam_license_instances_licensed 15`n"
        $text | Should -Match "veeam_license_instances_used 5.5`n"
    }

    It 'wirft ohne Lizenzobjekt' {
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

    It 'schreibt veeam_license.prom und veeam_exporter_license.prom bei Erfolg' {
        Set-LicenseMock
        $result = Invoke-VeeamLicenseExporterRun -TextfileDirectory $script:Dir -WarningAction SilentlyContinue

        $result.Success | Should -BeTrue
        Get-FileText -Path $script:LicenseFile | Should -BeExactly (Get-ExpectedText -Name 'license/veeam_license_rental.prom')
        $lines = (Get-FileText -Path $script:HealthFile) -split "`n"
        $lines.Count | Should -Be 7
        $lines[0] | Should -BeExactly '# HELP veeam_exporter_collector_success 1 letzter Lauf des Collectors ok, 0 Fehler'
        $lines[1] | Should -BeExactly '# TYPE veeam_exporter_collector_success gauge'
        $lines[2] | Should -BeExactly 'veeam_exporter_collector_success{collector="license"} 1'
        $lines[3] | Should -BeExactly '# HELP veeam_exporter_collector_duration_seconds Laufzeit des Collectors in Sekunden'
        $lines[4] | Should -BeExactly '# TYPE veeam_exporter_collector_duration_seconds gauge'
        $lines[5] | Should -Match '^veeam_exporter_collector_duration_seconds\{collector="license"\} [0-9]+(\.[0-9]+)?$'
        $lines[6] | Should -BeExactly ''
    }

    It 'trennt die Verbindung nur, wenn es sie selbst aufgebaut hat (<Connected>)' -TestCases @(@{ Connected = $true; Times = 1 }, @{ Connected = $false; Times = 0 }) {
        param($Connected, $Times)
        Set-LicenseMock -Connected $Connected
        $null = Invoke-VeeamLicenseExporterRun -TextfileDirectory $script:Dir -WarningAction SilentlyContinue
        Should -Invoke -ModuleName VeeamExporter Disconnect-VeeamLocalServer -Times $Times -Exactly
    }

    It 'laesst die alte veeam_license.prom stehen, wenn Get-VBRInstalledLicense fehlschlaegt' {
        [System.IO.File]::WriteAllText($script:LicenseFile, "veeam_license_valid 1`n")
        Set-LicenseMock -LicenseFails

        $result = Invoke-VeeamLicenseExporterRun -TextfileDirectory $script:Dir -WarningVariable warnings -WarningAction SilentlyContinue

        $result.Success | Should -BeFalse
        Get-FileText -Path $script:LicenseFile | Should -BeExactly "veeam_license_valid 1`n"
        Get-FileText -Path $script:HealthFile | Should -Match 'veeam_exporter_collector_success\{collector="license"\} 0'
        @($warnings | Where-Object { "$_" -like '*access denied*' }).Count | Should -Be 1
        Should -Invoke -ModuleName VeeamExporter Disconnect-VeeamLocalServer -Times 1 -Exactly
    }

    It 'schreibt den Health-Status auch, wenn das Veeam-Modul fehlt' {
        Set-LicenseMock -ImportFails
        $result = Invoke-VeeamLicenseExporterRun -TextfileDirectory $script:Dir -WarningAction SilentlyContinue
        $result.Success | Should -BeFalse
        Test-Path -LiteralPath $script:LicenseFile | Should -BeFalse
        Get-FileText -Path $script:HealthFile | Should -Match 'veeam_exporter_collector_success\{collector="license"\} 0'
        Should -Invoke -ModuleName VeeamExporter Connect-VeeamLocalServer -Times 0 -Exactly
    }

    It 'laesst veeam_exporter.prom des REST-Tasks unangetastet' {
        $restHealth = Join-Path -Path $script:Dir -ChildPath 'veeam_exporter.prom'
        [System.IO.File]::WriteAllText($restHealth, "veeam_exporter_collector_success{collector=`"jobs`"} 1`n")
        Set-LicenseMock
        $null = Invoke-VeeamLicenseExporterRun -TextfileDirectory $script:Dir -WarningAction SilentlyContinue
        Get-FileText -Path $restHealth | Should -BeExactly "veeam_exporter_collector_success{collector=`"jobs`"} 1`n"
        Get-SortedFileName -Directory $script:Dir | Should -BeExactly 'veeam_exporter.prom,veeam_exporter_license.prom,veeam_license.prom'
    }
}

Describe 'Wrapper um das Veeam-PowerShell-Modul' {
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

    It 'verbindet nicht neu, wenn schon eine Session besteht' {
        Mock -ModuleName VeeamExporter Get-VBRServerSession { [pscustomobject]@{ Server = 'localhost' } }
        Mock -ModuleName VeeamExporter Connect-VBRServer { }
        InModuleScope VeeamExporter { Connect-VeeamLocalServer } | Should -BeFalse
        Should -Invoke -ModuleName VeeamExporter Connect-VBRServer -Times 0 -Exactly
    }

    It 'verbindet lokal ohne Parameter, wenn keine Session besteht' {
        Mock -ModuleName VeeamExporter Get-VBRServerSession { $null }
        Mock -ModuleName VeeamExporter Connect-VBRServer { 'output that must not leak' }
        InModuleScope VeeamExporter { Connect-VeeamLocalServer } | Should -BeExactly $true
        Should -Invoke -ModuleName VeeamExporter Connect-VBRServer -Times 1 -Exactly
    }

    It 'verbindet, wenn Get-VBRServerSession einen Fehler wirft' {
        Mock -ModuleName VeeamExporter Get-VBRServerSession { throw 'no session' }
        Mock -ModuleName VeeamExporter Connect-VBRServer { }
        InModuleScope VeeamExporter { Connect-VeeamLocalServer } | Should -BeTrue
    }

    It 'gibt die Lizenz als Array zurueck' {
        Mock -ModuleName VeeamExporter Get-VBRInstalledLicense { [pscustomobject]@{ Status = 'Valid' } }
        $result = InModuleScope VeeamExporter { , (Get-VeeamInstalledLicense) }
        $result.Count | Should -Be 1
        $result[0].Status | Should -Be 'Valid'
    }

    It 'importiert das Modul nicht, wenn die Cmdlets schon da sind' {
        Mock -ModuleName VeeamExporter Import-Module { }
        InModuleScope VeeamExporter { Import-VeeamBackupModule }
        Should -Invoke -ModuleName VeeamExporter Import-Module -Times 0 -Exactly
    }

    It 'meldet einen fehlgeschlagenen Import mit Modulname' {
        Remove-Item -Path 'Function:\Get-VBRInstalledLicense'
        try {
            Mock -ModuleName VeeamExporter Import-Module { throw 'The specified module was not loaded' }
            { InModuleScope VeeamExporter { Import-VeeamBackupModule } } | Should -Throw '*Veeam.Backup.PowerShell*not loaded*'
            Should -Invoke -ModuleName VeeamExporter Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Veeam.Backup.PowerShell' -and $Global }
        }
        finally {
            function global:Get-VBRInstalledLicense { }
        }
    }
}
