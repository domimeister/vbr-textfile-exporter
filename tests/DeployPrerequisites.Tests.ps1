BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-Module -Name (Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'deploy') -ChildPath 'VeeamExporterDeploy.psm1') -Force

    function New-TestService {
        param([string]$Name, [string]$PathName, [string]$State = 'Running', [int]$ProcessId = 4321)
        return [pscustomobject]@{ Name = $Name; PathName = $PathName; State = $State; ProcessId = $ProcessId }
    }
    $script:Exe = '"C:\Program Files\windows_exporter\windows_exporter.exe"'
}

Describe 'Finding the windows_exporter service' {
    BeforeEach {
        $script:Services = @(New-TestService -Name 'Spooler' -PathName 'C:\Windows\System32\spoolsv.exe' -ProcessId 700)
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterWindowsService { $script:Services }
    }

    It 'finds the service named windows_exporter' {
        $script:Services += New-TestService -Name 'windows_exporter' -PathName 'D:\Tools\we\exporter.exe'
        (InModuleScope VeeamExporterDeploy { Find-WindowsExporterService }).Name | Should -BeExactly 'windows_exporter'
    }

    It 'finds a renamed service by its executable <PathName>' -TestCases @(
        @{ PathName = '"C:\Program Files\windows_exporter\windows_exporter.exe" --config.file="C:\x\config.yaml"' }
        @{ PathName = 'D:\Monitoring\windows_exporter-0.32.1-amd64.exe --web.listen-address=:9200' }
    ) {
        param($PathName)
        $script:Services += New-TestService -Name 'prom_win' -PathName $PathName
        (InModuleScope VeeamExporterDeploy { Find-WindowsExporterService }).Name | Should -BeExactly 'prom_win'
    }

    It 'prefers the service named windows_exporter over another one with that executable' {
        $script:Services += New-TestService -Name 'windows_exporter_old' -PathName ($script:Exe + ' --web.listen-address=:9183')
        $script:Services += New-TestService -Name 'windows_exporter' -PathName $script:Exe
        (InModuleScope VeeamExporterDeploy { Find-WindowsExporterService }).Name | Should -BeExactly 'windows_exporter'
    }

    It 'asks for the name when several renamed services run windows_exporter' {
        $script:Services += New-TestService -Name 'we_a' -PathName $script:Exe
        $script:Services += New-TestService -Name 'we_b' -PathName ($script:Exe + ' --web.listen-address=:9183')
        { InModuleScope VeeamExporterDeploy { Find-WindowsExporterService } } | Should -Throw '*Several services run windows_exporter: we_a, we_b*-WindowsExporterService*'
        (InModuleScope VeeamExporterDeploy { Find-WindowsExporterService -Name 'we_b' }).Name | Should -BeExactly 'we_b'
    }

    It 'takes a service given by name whatever it runs, and refuses a name that does not exist' {
        $script:Services += New-TestService -Name 'metrics' -PathName 'D:\bin\agent.exe'
        (InModuleScope VeeamExporterDeploy { Find-WindowsExporterService -Name 'metrics' }).Name | Should -BeExactly 'metrics'
        { InModuleScope VeeamExporterDeploy { Find-WindowsExporterService -Name 'nope' } } | Should -Throw "*Service 'nope' not found*"
    }

    It 'returns nothing when there is no such service' {
        InModuleScope VeeamExporterDeploy { Find-WindowsExporterService } | Should -BeNullOrEmpty
        $found = InModuleScope VeeamExporterDeploy { Find-WindowsExporterTextfileDirectory }
        $found.ServiceFound | Should -BeFalse
        $found.ServiceRunning | Should -BeFalse
        $found.TextfileCheck | Should -BeExactly 'config'
    }
}

Describe 'Asking the running windows_exporter' {
    BeforeEach {
        $script:Asked = New-Object System.Collections.Generic.List[string]
        $script:Answers = @{}
        Mock -ModuleName VeeamExporterDeploy Test-WindowsExporterTextfileCollector { $script:Asked.Add($MetricsUri); $script:Answers[$MetricsUri] }
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterListenEndpoint { }
    }

    It 'asks the port the process listens on, also when the command line does not name it' {
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterWindowsService { New-TestService -Name 'prom_win' -PathName ($script:Exe + ' --collector.textfile.directories="D:\Prom Files"') }
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterListenEndpoint { [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 9200 }; [pscustomobject]@{ LocalAddress = '::'; LocalPort = 9200 } } -ParameterFilter { $ProcessId -eq 4321 }
        $script:Answers['http://localhost:9200/metrics'] = $true
        $found = InModuleScope VeeamExporterDeploy { Find-WindowsExporterTextfileDirectory }
        $found.MetricsUri | Should -BeExactly 'http://localhost:9200/metrics'
        $found.TextfileCheck | Should -BeExactly 'metrics'
        $found.TextfileEnabled | Should -BeTrue
        $found.Directory | Should -BeExactly 'D:\Prom Files'
        $found.ServiceName | Should -BeExactly 'prom_win'
        ($script:Asked -join ',') | Should -BeExactly 'http://localhost:9200/metrics'
    }

    It 'uses the bound address of the process (<Address>)' -TestCases @(
        @{ Address = '10.0.0.5'; Uri = 'http://10.0.0.5:9182/metrics' }
        @{ Address = '::1'; Uri = 'http://[::1]:9182/metrics' }
    ) {
        param($Address, $Uri)
        $script:Address = $Address
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterWindowsService { New-TestService -Name 'windows_exporter' -PathName $script:Exe }
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterListenEndpoint { [pscustomobject]@{ LocalAddress = $script:Address; LocalPort = 9182 } }
        $script:Answers[$Uri] = $false
        $found = InModuleScope VeeamExporterDeploy { Find-WindowsExporterTextfileDirectory }
        $found.MetricsUri | Should -BeExactly $Uri
        $found.TextfileEnabled | Should -BeFalse
    }

    It 'falls back to the address from the command line and lists what it tried' {
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterWindowsService { New-TestService -Name 'windows_exporter' -PathName ($script:Exe + ' --web.listen-address=:9100') }
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterListenEndpoint { [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 9555 } }
        $found = InModuleScope VeeamExporterDeploy { Find-WindowsExporterTextfileDirectory }
        ($script:Asked -join ',') | Should -BeExactly 'http://localhost:9555/metrics,http://localhost:9100/metrics'
        $found.TextfileCheck | Should -BeExactly 'config'
        ($found.MetricsTried -join ',') | Should -BeExactly 'http://localhost:9555/metrics,http://localhost:9100/metrics'
    }

    It 'does not ask a stopped service for its ports' {
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterWindowsService { New-TestService -Name 'windows_exporter' -PathName $script:Exe -State 'Stopped' -ProcessId 0 }
        $found = InModuleScope VeeamExporterDeploy { Find-WindowsExporterTextfileDirectory }
        $found.ServiceFound | Should -BeTrue
        $found.ServiceRunning | Should -BeFalse
        Should -Invoke -ModuleName VeeamExporterDeploy Get-VeeamExporterListenEndpoint -Times 0 -Exactly
    }

    It 'passes the service name on' {
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterWindowsService { New-TestService -Name 'a' -PathName $script:Exe; New-TestService -Name 'b' -PathName ($script:Exe + ' --collector.textfile.directories=D:\b') }
        (InModuleScope VeeamExporterDeploy { Find-WindowsExporterTextfileDirectory -ServiceName 'b' }).Directory | Should -BeExactly 'D:\b'
    }
}

Describe 'Does the windows_exporter export the data' {
    It 'is <Expected> when /metrics <Case>' -TestCases @(
        @{ Case = 'has veeam_exporter_info'; Content = "windows_cs_hostname 1`nveeam_exporter_info{script_version=`"0.2.1`"} 1`n"; Expected = $true }
        @{ Case = 'has no Veeam data'; Content = "windows_cs_hostname 1`n# veeam_exporter_info{} 1`n"; Expected = $false }
    ) {
        param($Case, $Content, $Expected)
        $script:Content = $Content
        Mock -ModuleName VeeamExporterDeploy Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = $script:Content } }
        InModuleScope VeeamExporterDeploy { Test-WindowsExporterExport -MetricsUri 'http://localhost:9182/metrics' } | Should -Be $Expected
    }

    It 'returns nothing if /metrics is not reachable' {
        Mock -ModuleName VeeamExporterDeploy Invoke-WebRequest { throw 'Unable to connect to the remote server' }
        InModuleScope VeeamExporterDeploy { Test-WindowsExporterExport -MetricsUri 'http://localhost:9182/metrics' } | Should -BeNullOrEmpty
    }
}

Describe 'Trying the Veeam account' {
    BeforeEach {
        $script:Calls = New-Object System.Collections.Generic.List[string]
        $script:Cred = New-TestCredential
        Mock -ModuleName VeeamExporterDeploy Connect-VeeamServer { $script:Calls.Add('logon ' + $Credential.UserName + ' ' + $CertificateThumbprint); New-TestSession }
        Mock -ModuleName VeeamExporterDeploy Disconnect-VeeamServer { $script:Calls.Add('logoff') }
        Mock -ModuleName VeeamExporter Invoke-VeeamRestGet { $script:Calls.Add('GET ' + $Path) }
        function Test-Login {
            InModuleScope VeeamExporterDeploy -Parameters @{ Cred = $script:Cred; Manifest = $script:ModuleManifest } {
                param($Cred, $Manifest)
                Test-VeeamExporterLogin -Credential $Cred -CertificateThumbprint ('AB' * 20) -ModuleManifest $Manifest
            }
        }
    }

    It 'logs on, reads one job state and logs off' {
        { Test-Login } | Should -Not -Throw
        ($script:Calls -join ' | ') | Should -BeExactly ('logon veeam-viewer ' + ('AB' * 20) + ' | GET /api/v1/jobs/states | logoff')
    }

    It 'names the account and the reason when the logon fails, and says that nothing was changed' {
        Mock -ModuleName VeeamExporterDeploy Connect-VeeamServer { throw 'POST /api/oauth2/token: HTTP 401 AccessDenied' }
        { Test-Login } | Should -Throw '*account veeam-viewer cannot read the REST API*HTTP 401 AccessDenied*Backup Viewer*Nothing was changed*'
        Should -Invoke -ModuleName VeeamExporterDeploy Disconnect-VeeamServer -Times 0 -Exactly
    }

    It 'logs off also when the account may not read (no role)' {
        Mock -ModuleName VeeamExporter Invoke-VeeamRestGet { throw 'GET /api/v1/jobs/states: HTTP 403' }
        { Test-Login } | Should -Throw '*HTTP 403*'
        Should -Invoke -ModuleName VeeamExporterDeploy Disconnect-VeeamServer -Times 1 -Exactly
    }

    It 'only uses read calls of the exporter module' {
        $body = InModuleScope VeeamExporterDeploy { (Get-Command -Name Test-VeeamExporterLogin).ScriptBlock.ToString() }
        $body | Should -Not -Match 'Invoke-WebRequest|Invoke-RestMethod|-Method'
    }
}

Describe 'Entry scripts need -TextfileDirectory' {
    It '<Script> has no default for it' -TestCases @(
        @{ Script = 'Invoke-VeeamExporter.ps1' }
        @{ Script = 'Invoke-VeeamLicenseExporter.ps1' }
    ) {
        param($Script)
        $parameter = (Get-Command -Name (Join-Path -Path $script:SrcRoot -ChildPath $Script)).Parameters['TextfileDirectory']
        @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count | Should -Be 1
        (Get-Content -LiteralPath (Join-Path -Path $script:SrcRoot -ChildPath $Script) -Raw) | Should -Not -Match '\$TextfileDirectory\s*='
    }
}
