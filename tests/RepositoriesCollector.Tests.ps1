BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    $script:DocSobr = Get-FixtureData -Name 'doc/1.3-rev2/scaleOutRepositories.json'
}

Describe 'Repositories-Collector: Ausgabe' {
    It 'erzeugt veeam_repositories.prom aus dem Doku-Beispiel <Version> zeilengenau' -TestCases @(
        @{ Version = '1.2-rev1' }, @{ Version = '1.3-rev0' }, @{ Version = '1.3-rev1' }, @{ Version = '1.3-rev2' }
    ) {
        param($Version)
        $metrics = Get-VeeamRepositoryMetric -RepositoryState (Get-FixtureData -Name "doc/$Version/repositories-states.json") -ScaleOutRepository $script:DocSobr
        Assert-PromText -Actual (ConvertTo-PromText -Metric $metrics) -Expected (Get-ExpectedText -Name "doc/$Version/veeam_repositories.prom")
    }

    It 'setzt sobr fuer Performance-, Archive- und unbekannte Extents und behandelt Object Storage' {
        $metrics = Get-VeeamRepositoryMetric -RepositoryState (Get-FixtureData -Name 'repositories-sobr-states.json') -ScaleOutRepository $script:DocSobr
        Assert-PromText -Actual (ConvertTo-PromText -Metric $metrics) -Expected (Get-ExpectedText -Name 'veeam_repositories_sobr.prom')
    }

    It 'laesst out_of_date unter 1.2-rev1 weg (Feld fehlt im Modell)' {
        $text = Get-ExpectedText -Name 'doc/1.2-rev1/veeam_repositories.prom'
        $text | Should -Not -Match 'veeam_repository_out_of_date'
        $metrics = Get-VeeamRepositoryMetric -RepositoryState (Get-FixtureData -Name 'doc/1.2-rev1/repositories-states.json') -ScaleOutRepository @()
        ($metrics | Where-Object Name -EQ 'veeam_repository_out_of_date').Samples.Count | Should -Be 0
    }

    It 'liest isOutOfDate als String "false" nicht als wahr (1.3-rev0-Beispiel)' {
        $metrics = Get-VeeamRepositoryMetric -RepositoryState (Get-FixtureData -Name 'doc/1.3-rev0/repositories-states.json') -ScaleOutRepository @()
        $samples = ($metrics | Where-Object Name -EQ 'veeam_repository_out_of_date').Samples
        ($samples | Where-Object { $_.Labels['repository'] -eq 'Backup Repository 1' }).Value | Should -Be 0
        ($samples | Where-Object { $_.Labels['repository'] -eq 'Default Backup Repository' }).Value | Should -Be 1
    }

    It 'rechnet den Fuellgrad aus free/capacity und nicht aus usedSpace' {
        # Doku-Beispiel: 299.4 GB Kapazitaet, 217.8 GB frei, 173.4 GB Backups
        $metrics = Get-VeeamRepositoryMetric -RepositoryState (Get-FixtureData -Name 'doc/1.3-rev2/repositories-states.json') -ScaleOutRepository @()
        $get = { param($n) (($metrics | Where-Object Name -EQ $n).Samples | Where-Object { $_.Labels['repository'] -eq 'Backup Repository 1' }).Value }
        $fill = 1 - (& $get 'veeam_repository_free_bytes') / (& $get 'veeam_repository_capacity_bytes')
        [math]::Round($fill, 3) | Should -Be 0.273
        # usedSpace/capacity waere 0.579 und damit falsch
        [math]::Round((& $get 'veeam_repository_backup_bytes') / (& $get 'veeam_repository_capacity_bytes'), 3) | Should -Be 0.579
    }

    It 'liefert ohne Repositories leeren Text' {
        ConvertTo-PromText -Metric (Get-VeeamRepositoryMetric -RepositoryState @() -ScaleOutRepository @()) | Should -BeExactly ''
    }
}

Describe 'Repositories-Collector: REST-Abfragen' {
    BeforeEach {
        $script:States = Get-FixtureText -Name 'repositories-sobr-states.json'
        $script:Sobrs = Get-FixtureText -Name 'doc/1.3-rev2/scaleOutRepositories.json'
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest {
            switch ($Path) {
                '/api/v1/backupInfrastructure/repositories/states' { return New-HttpResponse -StatusCode 200 -Content $script:States }
                '/api/v1/backupInfrastructure/scaleOutRepositories' { return New-HttpResponse -StatusCode 200 -Content $script:Sobrs }
            }
            throw "Unexpected request: $Method $Path"
        }
    }

    It 'liest repositories/states und scaleOutRepositories per GET mit Paging' {
        $text = ConvertTo-PromText -Metric (Get-VeeamRepositoryMetric -Session (New-TestSession))
        Assert-PromText -Actual $text -Expected (Get-ExpectedText -Name 'veeam_repositories_sobr.prom')
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Path -eq '/api/v1/backupInfrastructure/repositories/states' -and $Query['skip'] -eq 0 -and $Query['limit'] -eq 200
        }
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Path -eq '/api/v1/backupInfrastructure/scaleOutRepositories' -and $Query['skip'] -eq 0
        }
    }

    It 'wirft, wenn scaleOutRepositories fehlschlaegt' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 403 -Content '{"errorCode":"AccessDenied","message":"no"}' } -ParameterFilter { $Path -eq '/api/v1/backupInfrastructure/scaleOutRepositories' }
        { Get-VeeamRepositoryMetric -Session (New-TestSession) } | Should -Throw '*scaleOutRepositories*HTTP 403*'
    }
}

Describe 'ConvertTo-VeeamBool' {
    It 'wandelt <Label> in <Out>' -TestCases @(
        @{ Label = '$true'; In = $true; Out = $true }
        @{ Label = '$false'; In = $false; Out = $false }
        @{ Label = '"true"'; In = 'true'; Out = $true }
        @{ Label = '"false"'; In = 'false'; Out = $false }
        @{ Label = '"TRUE"'; In = 'TRUE'; Out = $true }
        @{ Label = '" False "'; In = ' False '; Out = $false }
        @{ Label = '1'; In = 1; Out = $true }
        @{ Label = '0'; In = 0; Out = $false }
    ) {
        param($In, $Out)
        InModuleScope VeeamExporter -Parameters @{ In = $In } {
            param($In)
            ConvertTo-VeeamBool -Value $In
        } | Should -BeExactly $Out
    }

    It 'liefert $null fuer $null und unlesbare Werte' {
        InModuleScope VeeamExporter {
            ConvertTo-VeeamBool -Value $null | Should -BeNullOrEmpty
            ConvertTo-VeeamBool -Value 'unknown' | Should -BeNullOrEmpty
            ConvertTo-VeeamBool -Value '' | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-VeeamByteCount' {
    It 'rechnet <In> GB in <Out> Bytes (1024^3, ganze Bytes)' -TestCases @(
        @{ In = 299.4; Out = 321478302106 }
        @{ In = 0.1; Out = 107374182 }
        @{ In = 1; Out = 1073741824 }
        @{ In = 0; Out = 0 }
        @{ In = '299.4'; Out = 321478302106 }
        @{ In = [decimal]'299.4'; Out = 321478302106 }
    ) {
        param($In, $Out)
        InModuleScope VeeamExporter -Parameters @{ In = $In } {
            param($In)
            ConvertTo-VeeamByteCount -GB $In
        } | Should -Be $Out
    }

    It 'liest Strings kulturunabhaengig' {
        $result = InModuleScope VeeamExporter {
            $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = New-Object System.Globalization.CultureInfo 'de-DE'
                ConvertTo-VeeamByteCount -GB '1.5'
            }
            finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
        }
        $result | Should -Be 1610612736
    }

    It 'liefert $null fuer fehlende Werte' {
        InModuleScope VeeamExporter {
            ConvertTo-VeeamByteCount -GB $null | Should -BeNullOrEmpty
            ConvertTo-VeeamByteCount -GB '' | Should -BeNullOrEmpty
        }
    }
}
