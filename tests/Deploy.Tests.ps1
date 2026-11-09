BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    $script:DeployModule = Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'deploy') -ChildPath 'VeeamExporterDeploy.psm1'
    Import-Module -Name $script:DeployModule -Force

    # Stubs for Windows-only cmdlets (ScheduledTasks, Set-Acl) so they can be
    # mocked on Linux. On Windows the real cmdlets are mocked instead.
    $script:CreatedStubs = New-Object System.Collections.Generic.List[string]
    $stubs = @{
        'New-ScheduledTaskAction'      = 'param($Execute, $Argument)'
        'New-ScheduledTaskPrincipal'   = 'param($UserId, $LogonType, $RunLevel)'
        'New-ScheduledTaskSettingsSet' = 'param($ExecutionTimeLimit, $MultipleInstances, [switch]$StartWhenAvailable, [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries)'
        'New-ScheduledTaskTrigger'     = 'param([switch]$Once, [switch]$Daily, $At, $RepetitionInterval)'
        'New-ScheduledTask'            = 'param($Action, $Principal, $Settings, $Trigger, $Description)'
        'Register-ScheduledTask'       = 'param($TaskPath, $TaskName, $InputObject, [switch]$Force)'
        'Unregister-ScheduledTask'     = '[CmdletBinding(SupportsShouldProcess = $true)] param($TaskPath, $TaskName)'
        'Get-ScheduledTask'            = '[CmdletBinding()] param($TaskPath, $TaskName)'
        'Start-ScheduledTask'          = 'param($TaskPath, $TaskName)'
        'Stop-ScheduledTask'           = 'param($TaskPath, $TaskName)'
        'Get-ScheduledTaskInfo'        = 'param($TaskPath, $TaskName)'
        'Set-Acl'                      = 'param($LiteralPath, $AclObject)'
    }
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
            $null = New-Item -Path "Function:\global:$name" -Value ([scriptblock]::Create($stubs[$name]))
            $script:CreatedStubs.Add($name)
        }
    }

    function New-TestDirectory {
        param([string]$Name)
        $path = Join-Path -Path $TestDrive -ChildPath ($Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $path
        return $path
    }

    $script:WinPs = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

    $script:SidSystem = 'S-1-5-18'
    $script:SidAdmins = 'S-1-5-32-544'
    $script:SidUsers = 'S-1-5-32-545'
    $script:SidAuthUsers = 'S-1-5-11'
    $script:SidAttacker = 'S-1-5-21-1-2-3-1001'
    # Security as returned by Get-VeeamExporterItemSecurity (default: safe).
    function New-TestSecurity {
        param([string]$Owner = 'S-1-5-32-544', [object[]]$Rules = @())
        $all = @(
            [pscustomobject]@{ Sid = 'S-1-5-18'; Rights = [int64]2032127; Allow = $true }
            [pscustomobject]@{ Sid = 'S-1-5-32-544'; Rights = [int64]2032127; Allow = $true }
        ) + @($Rules)
        return [pscustomobject]@{ Owner = $Owner; Rules = $all }
    }
    function New-TestRule {
        param([string]$Sid, [int64]$Rights, [bool]$Allow = $true)
        return [pscustomobject]@{ Sid = $Sid; Rights = $Rights; Allow = $Allow }
    }
    # FileSystemRights as access mask
    $script:RightsReadExecute = [int64]1179817
    $script:RightsModify = [int64]1245631
    $script:RightsCreateFolders = [int64]4
    $script:RightsGenericWrite = [int64]0x40000000
    $script:Pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
}

AfterAll {
    foreach ($name in $script:CreatedStubs) { Remove-Item -Path "Function:\$name" -ErrorAction SilentlyContinue }
    Remove-Module -Name VeeamExporterDeploy -ErrorAction SilentlyContinue
}

Describe 'windows_exporter: textfile directory' {
    It 'reads <Case>' -TestCases @(
        @{ Case = 'quoted argument'; Image = '"C:\Program Files\windows_exporter\windows_exporter.exe" --log.file eventlog --collector.textfile.directories "D:\Monitoring\textfile"'; Config = $null; Dir = 'D:\Monitoring\textfile'; Source = 'argument' }
        @{ Case = 'argument with = and list'; Image = 'C:\we\windows_exporter.exe --collector.textfile.directories=C:\tf1,C:\tf2'; Config = $null; Dir = 'C:\tf1'; Source = 'argument' }
        @{ Case = 'old option directory with trailing backslash'; Image = 'C:\we\windows_exporter.exe --collector.textfile.directory C:\old\'; Config = $null; Dir = 'C:\old'; Source = 'argument' }
        @{ Case = 'config file'; Image = '"C:\we\windows_exporter.exe" --config.file "C:\we\config.yml"'; Config = "collectors:`n  enabled: cpu,textfile`ncollector:`n  textfile:`n    directories: `"D:\\tf`"`n"; Dir = 'D:\tf'; Source = 'config' }
        @{ Case = 'config file, plain value with spaces'; Image = 'x.exe --config.file c.yaml'; Config = "collector:`n  textfile:`n    directories: C:\Program Files\windows_exporter\textfile_inputs`n"; Dir = 'C:\Program Files\windows_exporter\textfile_inputs'; Source = 'config' }
        @{ Case = 'config file, plain value with comment and CRLF'; Image = 'x.exe --config.file c.yaml'; Config = "collector:`r`n  textfile:`r`n    directories: C:\Program Files\we\tf   # textfile inputs`r`nlog:`r`n  level: info`r`n"; Dir = 'C:\Program Files\we\tf'; Source = 'config' }
        @{ Case = 'config file, plain list with spaces'; Image = 'x.exe --config.file c.yaml'; Config = "collector:`n  textfile:`n    directories: D:\My Data\tf1, D:\tf2`n"; Dir = 'D:\My Data\tf1'; Source = 'config' }
        @{ Case = 'config file, single quotes'; Image = 'x.exe --config.file c.yaml'; Config = "collector:`n  textfile:`n    directories: 'C:\Program Files\we\tf'`n"; Dir = 'C:\Program Files\we\tf'; Source = 'config' }
        @{ Case = 'MSI default next to the exe'; Image = '"C:\Program Files\windows_exporter\windows_exporter.exe" --log.file eventlog'; Config = $null; Dir = 'C:\Program Files\windows_exporter\textfile_inputs'; Source = 'default' }
        @{ Case = 'MSI default next to an unquoted exe with blanks'; Image = 'C:\Program Files\windows_exporter\windows_exporter.exe --log.file eventlog'; Config = $null; Dir = 'C:\Program Files\windows_exporter\textfile_inputs'; Source = 'default' }
        @{ Case = 'without service'; Image = $null; Config = $null; Dir = 'C:\Program Files\windows_exporter\textfile_inputs'; Source = 'default' }
    ) {
        param($Image, $Config, $Dir, $Source)
        $result = InModuleScope VeeamExporterDeploy -Parameters @{ Image = $Image; Config = $Config } {
            param($Image, $Config)
            Get-WindowsExporterTextfileDirectory -ImagePath $Image -ConfigText $Config
        }
        $result.Directory | Should -BeExactly $Dir
        $result.Source | Should -BeExactly $Source
    }

    It 'reads from the collector list whether textfile is enabled: <Case>' -TestCases @(
        @{ Case = 'explicit list without textfile'; Image = 'x.exe --collectors.enabled "cpu,cs,net"'; Config = $null; Enabled = $false }
        @{ Case = 'explicit list with textfile'; Image = 'x.exe --collectors.enabled cpu,textfile'; Config = $null; Enabled = $true }
        @{ Case = '[defaults] plus textfile'; Image = 'x.exe --collectors.enabled=[defaults],textfile'; Config = $null; Enabled = $true }
        @{ Case = 'config, single quotes (YAML needs them for [defaults])'; Image = 'x.exe --config.file c.yaml'; Config = "collectors:`n  enabled: '[defaults],textfile'`n"; Enabled = $true }
        @{ Case = 'config, double quotes without textfile'; Image = 'x.exe --config.file c.yaml'; Config = "collectors:`n  enabled: `"cpu,net`"`n"; Enabled = $false }
        @{ Case = 'config, unquoted list'; Image = 'x.exe --config.file c.yaml'; Config = "collectors:`n  enabled: cpu,textfile # comment`n"; Enabled = $true }
    ) {
        param($Case, $Image, $Config, $Enabled)
        InModuleScope VeeamExporterDeploy -Parameters @{ Image = $Image; Config = $Config } {
            param($Image, $Config)
            (Get-WindowsExporterTextfileDirectory -ImagePath $Image -ConfigText $Config).TextfileEnabled
        } | Should -Be $Enabled
    }

    It 'leaves it open when it depends on the default set: <Case>' -TestCases @(
        @{ Case = 'no collector list'; Image = 'x.exe --log.file eventlog'; Config = $null }
        @{ Case = '[defaults] without textfile'; Image = 'x.exe --collectors.enabled=[defaults],mssql'; Config = $null }
        @{ Case = 'empty config file'; Image = 'x.exe --config.file c.yaml'; Config = '' }
    ) {
        param($Case, $Image, $Config)
        $result = InModuleScope VeeamExporterDeploy -Parameters @{ Image = $Image; Config = $Config } {
            param($Image, $Config)
            Get-WindowsExporterTextfileDirectory -ImagePath $Image -ConfigText $Config
        }
        $result.TextfileEnabled | Should -BeNullOrEmpty
    }

    It 'derives the metrics URI from <Case>' -TestCases @(
        @{ Case = 'the default'; Image = 'x.exe --log.file eventlog'; Config = $null; Uri = 'http://localhost:9182/metrics' }
        @{ Case = 'a listen-address argument'; Image = 'x.exe --web.listen-address=:9999'; Config = $null; Uri = 'http://localhost:9999/metrics' }
        @{ Case = 'a wildcard host'; Image = 'x.exe --web.listen-address "0.0.0.0:9182"'; Config = $null; Uri = 'http://localhost:9182/metrics' }
        @{ Case = 'a specific host'; Image = 'x.exe --web.listen-address=10.0.0.5:9182'; Config = $null; Uri = 'http://10.0.0.5:9182/metrics' }
        @{ Case = 'the config file'; Image = 'x.exe --config.file c.yaml'; Config = "web:`n  listen-address: `":9100`"`n"; Uri = 'http://localhost:9100/metrics' }
    ) {
        param($Case, $Image, $Config, $Uri)
        InModuleScope VeeamExporterDeploy -Parameters @{ Image = $Image; Config = $Config } {
            param($Image, $Config)
            (Get-WindowsExporterTextfileDirectory -ImagePath $Image -ConfigText $Config).MetricsUri
        } | Should -BeExactly $Uri
    }
}

Describe 'Image path parser shared with the exporter' {
    BeforeAll {
        # Child process with the PowerShell edition of this test run.
        function Invoke-DeployModuleProbe {
            param([string]$ModulePath)
            $command = "`$ErrorActionPreference = 'Stop'; Import-Module -Name '$ModulePath'; & (Get-Module -Name VeeamExporterDeploy) { (Get-Command -Name ConvertFrom-ServiceImagePath).ScriptBlock.File }"
            $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
            # Windows PowerShell 5.1 turns redirected stderr of a child process into a
            # terminating error when $ErrorActionPreference is Stop (GitHub Actions sets it).
            $ErrorActionPreference = 'Continue'
            $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (@($output | ForEach-Object { "$_" }) -join "`n").Trim() }
        }
    }

    It 'is the file of the exporter module (repository layout)' {
        $file = InModuleScope VeeamExporterDeploy { (Get-Command -Name ConvertFrom-ServiceImagePath).ScriptBlock.File }
        $expected = Join-Path -Path (Join-Path -Path (Join-Path -Path $script:SrcRoot -ChildPath 'VeeamExporter') -ChildPath 'Private') -ChildPath 'ServiceImagePath.ps1'
        [System.IO.Path]::GetFullPath($file) | Should -Be ([System.IO.Path]::GetFullPath($expected))
        (Get-Command -Module VeeamExporter -Name ConvertFrom-ServiceImagePath -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        InModuleScope VeeamExporter { (Get-Command -Name ConvertFrom-ServiceImagePath).ScriptBlock.File } | Should -Be $file
    }

    It 'loads from an installation made by Copy-VeeamExporterFile' {
        $target = New-TestDirectory -Name 'install'
        $null = InModuleScope VeeamExporterDeploy -Parameters @{ Root = $script:RepoRoot; Target = $target } {
            param($Root, $Target)
            Copy-VeeamExporterFile -SourceRoot $Root -InstallPath $Target -Confirm:$false
        }
        $r = Invoke-DeployModuleProbe -ModulePath (Join-Path -Path (Join-Path -Path $target -ChildPath 'deploy') -ChildPath 'VeeamExporterDeploy.psm1')
        $r.ExitCode | Should -Be 0
        $expected = Join-Path -Path (Join-Path -Path (Join-Path -Path $target -ChildPath 'VeeamExporter') -ChildPath 'Private') -ChildPath 'ServiceImagePath.ps1'
        [System.IO.Path]::GetFullPath($r.Output) | Should -Be ([System.IO.Path]::GetFullPath($expected))
    }

    It 'refuses to load without the parser file' {
        $alone = Join-Path -Path (New-TestDirectory -Name 'alone') -ChildPath 'deploy'
        $null = New-Item -ItemType Directory -Path $alone
        Copy-Item -LiteralPath $script:DeployModule -Destination $alone
        $r = Invoke-DeployModuleProbe -ModulePath (Join-Path -Path $alone -ChildPath 'VeeamExporterDeploy.psm1')
        ($r.Output -replace '\s', '') | Should -Match 'ServiceImagePath\.ps1oftheexportermodulenotfound'
    }
}

Describe 'windows_exporter: service lookup' {
    BeforeEach {
        $script:Key = 'HKLM:\SYSTEM\CurrentControlSet\Services\windows_exporter'
        Mock -ModuleName VeeamExporterDeploy Test-Path { $true } -ParameterFilter { $LiteralPath -eq $script:Key }
        Mock -ModuleName VeeamExporterDeploy Get-ItemProperty { [pscustomobject]@{ ImagePath = '"C:\Program Files\windows_exporter\windows_exporter.exe" --collectors.enabled "[defaults],textfile"' } }
    }

    It 'prefers the answer of the running service over the command line' {
        Mock -ModuleName VeeamExporterDeploy Test-WindowsExporterTextfileCollector { $false }
        $result = InModuleScope VeeamExporterDeploy { Find-WindowsExporterTextfileDirectory }
        $result.TextfileEnabled | Should -BeFalse
        $result.TextfileCheck | Should -BeExactly 'metrics'
        $result.ServiceFound | Should -BeTrue
    }

    It 'falls back to the command line if /metrics is not reachable' {
        Mock -ModuleName VeeamExporterDeploy Test-WindowsExporterTextfileCollector { $null }
        $result = InModuleScope VeeamExporterDeploy { Find-WindowsExporterTextfileDirectory }
        $result.TextfileEnabled | Should -BeTrue
        $result.TextfileCheck | Should -BeExactly 'config'
    }
}

Describe 'windows_exporter: asking the running service' {
    It 'is <Expected> when /metrics <Case>' -TestCases @(
        @{ Case = 'has the textfile collector'; Content = "# HELP x`nwindows_exporter_collector_success{collector=`"cpu`"} 1`nwindows_exporter_collector_success{collector=`"textfile`"} 1`n"; Expected = $true }
        @{ Case = 'lists it as failed'; Content = "windows_exporter_collector_success{collector=`"textfile`"} 0`n"; Expected = $true }
        @{ Case = 'lacks it (windows_exporter 0.32 defaults)'; Content = "windows_exporter_collector_success{collector=`"cpu`"} 1`nwindows_exporter_collector_success{collector=`"system`"} 1`n"; Expected = $false }
    ) {
        param($Case, $Content, $Expected)
        Mock -ModuleName VeeamExporterDeploy Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = $Content } }
        InModuleScope VeeamExporterDeploy { Test-WindowsExporterTextfileCollector -MetricsUri 'http://localhost:9182/metrics' } | Should -Be $Expected
        Should -Invoke -ModuleName VeeamExporterDeploy Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq 'http://localhost:9182/metrics' -and $UseBasicParsing }
    }

    It 'returns nothing if /metrics is not reachable' {
        Mock -ModuleName VeeamExporterDeploy Invoke-WebRequest { throw 'Unable to connect to the remote server' }
        InModuleScope VeeamExporterDeploy { Test-WindowsExporterTextfileCollector -MetricsUri 'http://localhost:9182/metrics' } | Should -BeNullOrEmpty
    }
}

Describe 'Task arguments' {
    It 'quotes <In> as <Out>' -TestCases @(
        @{ In = 'abc'; Out = 'abc' }
        @{ In = 'C:\Program Files\x.ps1'; Out = '"C:\Program Files\x.ps1"' }
        @{ In = 'C:\Program Files\dir\'; Out = '"C:\Program Files\dir\\"' }
        @{ In = 'a"b'; Out = '"a\"b"' }
        @{ In = 'a\"b'; Out = '"a\\\"b"' }
        @{ In = ''; Out = '""' }
        @{ In = 'C:\dir\file'; Out = 'C:\dir\file' }
    ) {
        param($In, $Out)
        InModuleScope VeeamExporterDeploy -Parameters @{ In = $In } {
            param($In)
            ConvertTo-TaskArgument -Value $In
        } | Should -BeExactly $Out
    }

    It 'arrives unchanged in the script after quoting (real process start)' {
        $script:ArgScript = Join-Path -Path $TestDrive -ChildPath 'args.ps1'
        [System.IO.File]::WriteAllText($script:ArgScript, '$args | ConvertTo-Json -Compress')
        $values = @('C:\Program Files\dir\', 'a"b', 'with space', 'jobs,objects', 'x\\y')
        $line = InModuleScope VeeamExporterDeploy -Parameters @{ Values = $values; Script = $script:ArgScript } {
            param($Values, $Script)
            Join-TaskArgument -Argument (@('-NoProfile', '-File', $Script) + $Values)
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.Arguments = $line
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        # Windows PowerShell 5.1: ConvertFrom-Json emits a JSON array as one object.
        $received = @(($out | ConvertFrom-Json) | ForEach-Object { $_ })
        ($received -join '|') | Should -BeExactly ($values -join '|')
    }

    It 'builds the REST task' {
        $d = InModuleScope VeeamExporterDeploy -Parameters @{ WinPs = $script:WinPs } {
            param($WinPs)
            Get-VeeamExporterTaskDefinition -Kind Rest -HostPath $WinPs -InstallPath 'C:\Program Files\VeeamExporter' -DataPath 'C:\ProgramData\VeeamExporter' `
                -TextfileDirectory 'C:\Program Files\windows_exporter\textfile_inputs\' -CertificateThumbprint 'ab:cd ef 01 23 45 67 89 ab cd ef 01 23 45 67 89 ab cd ef 01' -Collector 'jobs', 'objects'
        }
        $d.TaskPath | Should -BeExactly '\VeeamExporter\'
        $d.TaskName | Should -BeExactly 'Veeam Exporter REST'
        $d.Execute | Should -BeExactly $script:WinPs
        $d.Argument | Should -BeExactly ('-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "C:\Program Files\VeeamExporter\Invoke-VeeamExporter.ps1"' +
            ' -CredentialPath C:\ProgramData\VeeamExporter\veeam.cred.xml -TextfileDirectory "C:\Program Files\windows_exporter\textfile_inputs"' +
            ' -Collector jobs,objects -ObjectLookbackDays 8 -LogPath C:\ProgramData\VeeamExporter\logs\rest.log -CertificateThumbprint ABCDEF0123456789ABCDEF0123456789ABCDEF01')
        $d.Trigger.Type | Should -BeExactly 'Repeat'
        $d.Trigger.IntervalMinutes | Should -Be 15
        $d.ExecutionTimeLimit.TotalMinutes | Should -Be 10
    }

    It 'puts the collectors into the REST task in lower case, each one once' {
        $d = InModuleScope VeeamExporterDeploy {
            Get-VeeamExporterTaskDefinition -Kind Rest -HostPath 'p.exe' -InstallPath 'C:\i' -DataPath 'C:\d' -TextfileDirectory 'C:\t' -Collector 'Jobs, objects', 'JOBS', ' repositories '
        }
        $d.Argument | Should -BeLikeExactly '* -Collector jobs,objects,repositories *'
    }

    It 'refuses <Case> for the REST task' -TestCases @(
        @{ Case = 'an unknown collector'; Collector = @('jobs', 'repository'); Message = "*Unknown collector 'repository'. Valid: jobs, objects, repositories*" }
        @{ Case = 'an empty list'; Collector = @(' , '); Message = '*No collector selected*' }
    ) {
        param($Case, $Collector, $Message)
        InModuleScope VeeamExporterDeploy -Parameters @{ Collector = $Collector; Message = $Message } {
            param($Collector, $Message)
            { Get-VeeamExporterTaskDefinition -Kind Rest -HostPath 'p.exe' -InstallPath 'C:\i' -DataPath 'C:\d' -TextfileDirectory 'C:\t' -Collector $Collector } | Should -Throw $Message
        }
    }

    It 'builds the license task' {
        $d = InModuleScope VeeamExporterDeploy -Parameters @{ Pwsh = $script:Pwsh } {
            param($Pwsh)
            Get-VeeamExporterTaskDefinition -Kind License -HostPath $Pwsh -InstallPath 'C:\Program Files\VeeamExporter' -DataPath 'C:\ProgramData\VeeamExporter' `
                -TextfileDirectory 'D:\tf' -VeeamModule 'C:\Program Files\Veeam\Backup and Replication\Console\Veeam.Backup.PowerShell\Veeam.Backup.PowerShell.psd1' -LicenseTime '05:43'
        }
        $d.TaskName | Should -BeExactly 'Veeam Exporter License'
        $d.Execute | Should -BeExactly $script:Pwsh
        $d.Argument | Should -BeExactly ('-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "C:\Program Files\VeeamExporter\Invoke-VeeamLicenseExporter.ps1"' +
            ' -TextfileDirectory D:\tf -ModuleName "C:\Program Files\Veeam\Backup and Replication\Console\Veeam.Backup.PowerShell\Veeam.Backup.PowerShell.psd1"' +
            ' -LogPath C:\ProgramData\VeeamExporter\logs\license.log')
        $d.Trigger.Type | Should -BeExactly 'Daily'
        $d.Trigger.At | Should -BeExactly '05:43'
    }

    It 'registers tasks as SYSTEM with repetition or a daily trigger' {
        # On Windows these mocks replace the real ScheduledTasks cmdlets. Their
        # parameters stay CimInstance-typed, and Pester also binds the dynamic
        # parameters of the original, so the mocks hand out real task objects
        # there (in memory, never registered; module-qualified calls bypass the
        # mocks). The untyped Linux stubs take plain objects.
        $script:RealTaskCmdlets = -not ($script:CreatedStubs -contains 'New-ScheduledTask')
        Mock -ModuleName VeeamExporterDeploy New-ScheduledTaskAction {
            if ($script:RealTaskCmdlets) { ScheduledTasks\New-ScheduledTaskAction -Execute 'cmd.exe' } else { [pscustomobject]@{} }
        }
        Mock -ModuleName VeeamExporterDeploy New-ScheduledTaskPrincipal {
            if ($script:RealTaskCmdlets) { ScheduledTasks\New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount } else { [pscustomobject]@{} }
        }
        Mock -ModuleName VeeamExporterDeploy New-ScheduledTaskSettingsSet {
            if ($script:RealTaskCmdlets) { ScheduledTasks\New-ScheduledTaskSettingsSet } else { [pscustomobject]@{} }
        }
        Mock -ModuleName VeeamExporterDeploy New-ScheduledTaskTrigger {
            if ($script:RealTaskCmdlets) { ScheduledTasks\New-ScheduledTaskTrigger -Once -At ([datetime]::Today) } else { [pscustomobject]@{} }
        }
        Mock -ModuleName VeeamExporterDeploy New-ScheduledTask {
            if ($script:RealTaskCmdlets) { ScheduledTasks\New-ScheduledTask -Action (ScheduledTasks\New-ScheduledTaskAction -Execute 'cmd.exe') } else { [pscustomobject]@{} }
        }
        Mock -ModuleName VeeamExporterDeploy Register-ScheduledTask { }
        InModuleScope VeeamExporterDeploy {
            foreach ($kind in 'Rest', 'License') {
                $d = Get-VeeamExporterTaskDefinition -Kind $kind -HostPath 'p.exe' -InstallPath 'C:\i' -DataPath 'C:\d' -TextfileDirectory 'C:\t' -CertificateThumbprint ('AA' * 20)
                Register-VeeamExporterTask -Definition $d -Confirm:$false
            }
        }
        Should -Invoke -ModuleName VeeamExporterDeploy New-ScheduledTaskPrincipal -Times 2 -Exactly -ParameterFilter { $UserId -eq 'SYSTEM' -and $LogonType -eq 'ServiceAccount' -and $RunLevel -eq 'Highest' }
        Should -Invoke -ModuleName VeeamExporterDeploy New-ScheduledTaskTrigger -Times 1 -Exactly -ParameterFilter { $Once -and $RepetitionInterval -eq [timespan]::FromMinutes(15) }
        Should -Invoke -ModuleName VeeamExporterDeploy New-ScheduledTaskTrigger -Times 1 -Exactly -ParameterFilter { $Daily -and $At.Hour -eq 6 -and $At.Minute -eq 17 }
        Should -Invoke -ModuleName VeeamExporterDeploy New-ScheduledTaskSettingsSet -Times 2 -Exactly -ParameterFilter { $MultipleInstances -eq 'IgnoreNew' }
        Should -Invoke -ModuleName VeeamExporterDeploy Register-ScheduledTask -Times 2 -Exactly -ParameterFilter { $TaskPath -eq '\VeeamExporter\' -and $Force }
    }
}

Describe 'Host for the license task' {
    It 'always chooses PowerShell 7 (module version <Version>)' -TestCases @(
        @{ Version = '13.0.1.1' }
        @{ Version = '13.1.2.57' }
        @{ Version = $null }
    ) {
        param($Version)
        $result = InModuleScope VeeamExporterDeploy -Parameters @{ Version = $Version; Pwsh = $script:Pwsh } {
            param($Version, $Pwsh)
            $v = $null
            if ($Version) { $v = [version]$Version }
            Resolve-VeeamLicenseHost -ModuleVersion $v -PwshPath $Pwsh
        }
        $result | Should -BeExactly $script:Pwsh
    }

    It 'rejects a Veeam module older than 13 (VBR 12 is not supported)' {
        InModuleScope VeeamExporterDeploy {
            { Resolve-VeeamLicenseHost -ModuleVersion ([version]'12.3.1.1139') -PwshPath 'p.exe' } | Should -Throw '*requires Veeam Backup & Replication 13 or later*'
        }
    }

    It 'throws if PowerShell 7 is missing' {
        InModuleScope VeeamExporterDeploy {
            { Resolve-VeeamLicenseHost -ModuleVersion ([version]'13.0') -PwshPath $null } | Should -Throw '*PowerShell 7*'
        }
    }
}

Describe 'Veeam PowerShell module' {
    It 'reads the version from the manifest, because Windows PowerShell 5.1 lists the VBR 13 module as 0.0' {
        $dir = New-TestDirectory -Name 'veeam-module'
        $psd1 = Join-Path -Path $dir -ChildPath 'Veeam.Backup.PowerShell.psd1'
        [System.IO.File]::WriteAllText($psd1, "@{ ModuleVersion = '13.1.2.57'; PowerShellVersion = '7.6' }")
        Mock -ModuleName VeeamExporterDeploy Get-Module { [pscustomobject]@{ Name = 'Veeam.Backup.PowerShell'; Version = [version]'0.0'; Path = $psd1 } } -ParameterFilter { $ListAvailable }
        $result = InModuleScope VeeamExporterDeploy -Parameters @{ Dir = $dir } {
            param($Dir)
            $saved = $env:ProgramFiles
            try { $env:ProgramFiles = $Dir; Find-VeeamPowerShellModule } finally { $env:ProgramFiles = $saved }
        }
        $result.Module | Should -BeExactly $psd1
        $result.Version | Should -Be ([version]'13.1.2.57')
    }

    It 'returns nothing if no manifest is readable' {
        $dir = New-TestDirectory -Name 'no-veeam-module'
        Mock -ModuleName VeeamExporterDeploy Get-Module { } -ParameterFilter { $ListAvailable }
        $result = InModuleScope VeeamExporterDeploy -Parameters @{ Dir = $dir } {
            param($Dir)
            $saved = $env:ProgramFiles
            try { $env:ProgramFiles = $Dir; Find-VeeamPowerShellModule } finally { $env:ProgramFiles = $saved }
        }
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Copying files' {
    It 'copies scripts, module and deploy files, but no tests' {
        $target = New-TestDirectory -Name 'install'
        $copied = InModuleScope VeeamExporterDeploy -Parameters @{ Root = $script:RepoRoot; Target = $target } {
            param($Root, $Target)
            Copy-VeeamExporterFile -SourceRoot $Root -InstallPath $Target -Confirm:$false
        }
        $copied | Should -Contain 'Invoke-VeeamExporter.ps1'
        $copied | Should -Contain 'Invoke-VeeamLicenseExporter.ps1'
        $copied | Should -Contain 'VeeamExporter\VeeamExporter.psd1'
        $copied | Should -Contain 'deploy\Save-VeeamExporterSystemCredential.ps1'
        $copied | Should -Contain 'deploy\VeeamExporterDeploy.psm1'
        @($copied | Where-Object { $_ -like '*Tests*' -or $_ -like '*fixtures*' }).Count | Should -Be 0
        $moduleFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:SrcRoot 'VeeamExporter') -Recurse -File).Count
        @($copied | Where-Object { $_ -like 'VeeamExporter\*' }).Count | Should -Be $moduleFiles
    }

    It 'removes outdated module files on update' {
        $target = New-TestDirectory -Name 'install'
        InModuleScope VeeamExporterDeploy -Parameters @{ Root = $script:RepoRoot; Target = $target } {
            param($Root, $Target)
            $null = Copy-VeeamExporterFile -SourceRoot $Root -InstallPath $Target -Confirm:$false
            [System.IO.File]::WriteAllText((Join-Path (Join-Path $Target 'VeeamExporter') 'Old.ps1'), '# old')
            $null = Copy-VeeamExporterFile -SourceRoot $Root -InstallPath $Target -Confirm:$false
        }
        Test-Path -LiteralPath (Join-Path (Join-Path $target 'VeeamExporter') 'Old.ps1') | Should -BeFalse
    }

    It 'keeps the old installation when the copy fails, and leaves nothing behind' {
        $target = New-TestDirectory -Name 'install'
        InModuleScope VeeamExporterDeploy -Parameters @{ Root = $script:RepoRoot; Target = $target } {
            param($Root, $Target)
            $null = Copy-VeeamExporterFile -SourceRoot $Root -InstallPath $Target -Confirm:$false
        }
        $marker = Join-Path (Join-Path $target 'VeeamExporter') 'Marker.ps1'
        [System.IO.File]::WriteAllText($marker, '# installed before')
        Mock -ModuleName VeeamExporterDeploy Copy-Item { throw 'There is not enough space on the disk.' } -ParameterFilter { $Recurse }
        { InModuleScope VeeamExporterDeploy -Parameters @{ Root = $script:RepoRoot; Target = $target } {
                param($Root, $Target)
                $null = Copy-VeeamExporterFile -SourceRoot $Root -InstallPath $Target -Confirm:$false
            } } | Should -Throw '*not enough space*'
        Test-Path -LiteralPath $marker | Should -BeTrue
        Test-Path -LiteralPath (Join-Path (Join-Path $target 'VeeamExporter') 'VeeamExporter.psd1') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $target -Directory -Force | Where-Object { $_.Name -like '.*' }).Count | Should -Be 0
    }

    It 'swaps in the new module and removes staging folders, also those of an update that was killed' {
        $target = New-TestDirectory -Name 'install'
        $null = New-Item -ItemType Directory -Path (Join-Path $target '.staging-0123')
        $null = New-Item -ItemType Directory -Path (Join-Path $target '.old-0123')
        InModuleScope VeeamExporterDeploy -Parameters @{ Root = $script:RepoRoot; Target = $target } {
            param($Root, $Target)
            $null = Copy-VeeamExporterFile -SourceRoot $Root -InstallPath $Target -Confirm:$false
            [System.IO.File]::WriteAllText((Join-Path (Join-Path $Target 'VeeamExporter') 'Marker.ps1'), '# old')
            $null = Copy-VeeamExporterFile -SourceRoot $Root -InstallPath $Target -Confirm:$false
        }
        Test-Path -LiteralPath (Join-Path (Join-Path $target 'VeeamExporter') 'Marker.ps1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $target 'Invoke-VeeamExporter.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path (Join-Path $target 'deploy') 'VeeamExporterDeploy.psm1') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $target -Directory -Force | Where-Object { $_.Name -like '.*' }).Count | Should -Be 0
    }

    It 'copies nothing if source and target are the installation itself' {
        $target = New-TestDirectory -Name 'install'
        $copied = InModuleScope VeeamExporterDeploy -Parameters @{ Root = $script:RepoRoot; Target = $target } {
            param($Root, $Target)
            $null = Copy-VeeamExporterFile -SourceRoot $Root -InstallPath $Target -Confirm:$false
            @(Copy-VeeamExporterFile -SourceRoot $Target -InstallPath $Target -Confirm:$false)
        }
        $copied.Count | Should -Be 0
    }

    It 'changes nothing with -WhatIf' {
        $target = Join-Path -Path $TestDrive -ChildPath 'whatif-install'
        InModuleScope VeeamExporterDeploy -Parameters @{ Root = $script:RepoRoot; Target = $target } {
            param($Root, $Target)
            $null = Copy-VeeamExporterFile -SourceRoot $Root -InstallPath $Target -WhatIf
        }
        Test-Path -LiteralPath $target | Should -BeFalse
    }
}

Describe 'Install-VeeamExporter' {
    BeforeEach {
        $script:Textfile = New-TestDirectory -Name 'textfile'
        $script:Install = Join-Path -Path $TestDrive -ChildPath ('install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Data = Join-Path -Path $TestDrive -ChildPath ('data-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Registered = New-Object System.Collections.Generic.List[object]
        $script:ModuleVersion = [version]'13.0.1.1'
        Mock -ModuleName VeeamExporterDeploy Test-VeeamExporterAdministrator { $true }
        Mock -ModuleName VeeamExporterDeploy Find-WindowsExporterTextfileDirectory { [pscustomobject]@{ Directory = $script:Textfile; Source = 'argument'; TextfileEnabled = $true; ServiceFound = $true } }
        Mock -ModuleName VeeamExporterDeploy Get-TlsCertificateInfo { [pscustomobject]@{ Thumbprint = 'C0FFEE00C0FFEE00C0FFEE00C0FFEE00C0FFEE00'; Subject = 'CN=vbr01'; NotAfter = (Get-Date).AddYears(5) } }
        Mock -ModuleName VeeamExporterDeploy Find-PowerShellHost { [pscustomobject]@{ WindowsPowerShell = $script:WinPs; Pwsh = $script:Pwsh } }
        Mock -ModuleName VeeamExporterDeploy Find-VeeamPowerShellModule { [pscustomobject]@{ Module = 'C:\Veeam\Veeam.Backup.PowerShell.psd1'; Version = $script:ModuleVersion } }
        Mock -ModuleName VeeamExporterDeploy Set-VeeamExporterDirectoryAcl { }
        Mock -ModuleName VeeamExporterDeploy New-VeeamExporterSecureDirectoryItem { $null = New-Item -ItemType Directory -Path $Path }
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity }
        Mock -ModuleName VeeamExporterDeploy Save-VeeamExporterCredentialAsSystem { [System.IO.File]::WriteAllText((Join-Path $DataPath 'veeam.cred.xml'), '<Objs/>') }
        Mock -ModuleName VeeamExporterDeploy Register-VeeamExporterTask { $script:Registered.Add($Definition) }
        Mock -ModuleName VeeamExporterDeploy Get-ScheduledTask { }
        Mock -ModuleName VeeamExporterDeploy Unregister-ScheduledTask { }
        Mock -ModuleName VeeamExporterDeploy Start-ScheduledTask { }
        Mock -ModuleName VeeamExporterDeploy Wait-VeeamExporterTask { [pscustomobject]@{ LastTaskResult = 0 } }
        $script:Cred = New-TestCredential
    }

    It 'warns about the textfile collector when it is <Case>' -TestCases @(
        @{ Case = 'off'; Enabled = $false; Pattern = '*runs without the textfile collector*' }
        @{ Case = 'unknown'; Enabled = $null; Pattern = '*Could not verify*textfile*' }
    ) {
        param($Case, $Enabled, $Pattern)
        $script:TfEnabled = $Enabled
        Mock -ModuleName VeeamExporterDeploy Find-WindowsExporterTextfileDirectory { [pscustomobject]@{ Directory = $script:Textfile; Source = 'default'; TextfileEnabled = $script:TfEnabled; ServiceFound = $true; MetricsUri = 'http://localhost:9182/metrics'; TextfileCheck = 'config' } }
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -InformationAction SilentlyContinue -WarningVariable warnings -WarningAction SilentlyContinue
        (@($warnings | ForEach-Object { [string]$_ }) -join "`n") | Should -BeLike $Pattern
    }

    It 'does not warn about the textfile collector when it runs' {
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -InformationAction SilentlyContinue -WarningVariable warnings -WarningAction SilentlyContinue
        (@($warnings | ForEach-Object { [string]$_ }) -join "`n") | Should -Not -BeLike '*textfile collector*'
    }

    It 'warns about a copy of an exporter file in the textfile directory' {
        [System.IO.File]::WriteAllText((Join-Path $script:Textfile 'veeam_jobs - Kopie.prom'), "veeam_job_enabled{job_name=`"a`"} 1`n")
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -InformationAction SilentlyContinue -WarningVariable warnings -WarningAction SilentlyContinue
        (@($warnings | ForEach-Object { [string]$_ }) -join "`n") | Should -BeLike '*hold Veeam metrics: veeam_jobs - Kopie.prom*can hide*'
    }

    It 'installs files, credential and both tasks and starts them once' {
        $result = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -InformationAction SilentlyContinue

        Test-Path -LiteralPath (Join-Path $script:Install 'Invoke-VeeamExporter.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path (Join-Path $script:Data 'logs') '.') | Should -BeTrue
        Should -Invoke -ModuleName VeeamExporterDeploy Set-VeeamExporterDirectoryAcl -Times 1 -Exactly -ParameterFilter { $Kind -eq 'Install' -and $Path -eq $script:Install }
        Should -Invoke -ModuleName VeeamExporterDeploy Set-VeeamExporterDirectoryAcl -Times 1 -Exactly -ParameterFilter { $Kind -eq 'Data' -and $Path -eq $script:Data }
        Should -Invoke -ModuleName VeeamExporterDeploy Save-VeeamExporterCredentialAsSystem -Times 1 -Exactly -ParameterFilter {
            $Credential.UserName -eq 'veeam-viewer' -and $HostPath -eq $script:WinPs -and $WorkerScript -like '*Save-VeeamExporterSystemCredential.ps1'
        }
        ($script:Registered | ForEach-Object TaskName) -join ',' | Should -BeExactly 'Veeam Exporter REST,Veeam Exporter License'
        $script:Registered[0].Execute | Should -BeExactly $script:WinPs
        $script:Registered[0].Argument | Should -Match '-CertificateThumbprint C0FFEE00C0FFEE00C0FFEE00C0FFEE00C0FFEE00$'
        $script:Registered[1].Execute | Should -BeExactly $script:Pwsh
        Should -Invoke -ModuleName VeeamExporterDeploy Start-ScheduledTask -Times 2 -Exactly
        @($result.FirstRun | Where-Object Ok).Count | Should -Be 2
    }

    It 'removes the files of dropped parts on a re-install (<Case>)' -TestCases @(
        @{ Case = '-SkipLicenseTask'; Extra = @{ SkipLicenseTask = $true }; Left = 'other_app.prom,veeam_exporter.prom,veeam_jobs.prom,veeam_objects.prom,veeam_repositories.prom' }
        @{ Case = '-Collector jobs'; Extra = @{ Collector = @('jobs') }; Left = 'other_app.prom,veeam_exporter.prom,veeam_exporter_license.prom,veeam_jobs.prom,veeam_license.prom' }
        @{ Case = 'all parts'; Extra = @{}; Left = 'other_app.prom,veeam_exporter.prom,veeam_exporter_license.prom,veeam_jobs.prom,veeam_license.prom,veeam_objects.prom,veeam_repositories.prom' }
    ) {
        param($Extra, $Left)
        foreach ($n in 'veeam_jobs.prom', 'veeam_objects.prom', 'veeam_repositories.prom', 'veeam_license.prom', 'veeam_exporter.prom', 'veeam_exporter_license.prom', 'other_app.prom') {
            [System.IO.File]::WriteAllText((Join-Path $script:Textfile $n), "x 1`n")
        }
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -InformationAction SilentlyContinue @Extra
        Get-SortedFileName -Directory $script:Textfile | Should -BeExactly $Left
    }

    It 'refuses an unknown collector before it changes anything' {
        [System.IO.File]::WriteAllText((Join-Path $script:Textfile 'veeam_repositories.prom'), "x 1`n")
        { Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -InformationAction SilentlyContinue -Collector 'jobs,objects,repository' } |
            Should -Throw "*Unknown collector 'repository'*"
        Test-Path -LiteralPath $script:Install | Should -BeFalse
        Test-Path -LiteralPath $script:Data | Should -BeFalse
        Should -Invoke -ModuleName VeeamExporterDeploy Register-VeeamExporterTask -Times 0 -Exactly
        Get-SortedFileName -Directory $script:Textfile | Should -BeExactly 'veeam_repositories.prom'
    }

    It 'keeps the files of collectors given in another case on a re-install' {
        foreach ($n in 'veeam_jobs.prom', 'veeam_objects.prom', 'veeam_repositories.prom') { [System.IO.File]::WriteAllText((Join-Path $script:Textfile $n), "x 1`n") }
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -InformationAction SilentlyContinue -Collector 'Jobs,OBJECTS'
        Get-SortedFileName -Directory $script:Textfile | Should -BeExactly 'veeam_jobs.prom,veeam_objects.prom'
        $script:Registered[0].Argument | Should -BeLikeExactly '* -Collector jobs,objects *'
    }

    It 'removes the exporter files in the textfile directory the tasks used before' {
        $old = New-TestDirectory -Name 'old-textfile'
        foreach ($n in 'veeam_jobs.prom', 'veeam_exporter.prom', 'other_app.prom') { [System.IO.File]::WriteAllText((Join-Path $old $n), "x 1`n") }
        $previous = InModuleScope VeeamExporterDeploy -Parameters @{ Old = $old } {
            param($Old)
            Get-VeeamExporterTaskDefinition -Kind Rest -HostPath 'p.exe' -InstallPath 'C:\i' -DataPath 'C:\d' -TextfileDirectory $Old -CertificateThumbprint ('AA' * 20)
        }
        $script:PreviousTask = [pscustomobject]@{ TaskPath = '\VeeamExporter\'; TaskName = 'Veeam Exporter REST'; State = 'Ready'; Actions = @([pscustomobject]@{ Arguments = $previous.Argument }) }
        Mock -ModuleName VeeamExporterDeploy Get-ScheduledTask { $script:PreviousTask }
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -InformationAction SilentlyContinue
        Get-SortedFileName -Directory $old | Should -BeExactly 'other_app.prom'
    }

    It 'refuses to install on VBR 12' {
        $script:ModuleVersion = [version]'12.3.1.1139'
        { Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -InformationAction SilentlyContinue } |
            Should -Throw '*requires Veeam Backup & Replication 13 or later*'
        $script:Registered.Count | Should -Be 0
    }

    It 'throws if the Veeam module is missing and the license task is not skipped' {
        Mock -ModuleName VeeamExporterDeploy Find-VeeamPowerShellModule { }
        { Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -InformationAction SilentlyContinue } |
            Should -Throw '*-SkipLicenseTask*'
    }

    It 'keeps an existing credential and replaces it only with -UpdateCredential' {
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -InformationAction SilentlyContinue
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Force -NoStart -InformationAction SilentlyContinue
        Should -Invoke -ModuleName VeeamExporterDeploy Save-VeeamExporterCredentialAsSystem -Times 1 -Exactly
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -UpdateCredential -Force -NoStart -InformationAction SilentlyContinue
        Should -Invoke -ModuleName VeeamExporterDeploy Save-VeeamExporterCredentialAsSystem -Times 2 -Exactly
    }

    It 'takes a given thumbprint without a TLS query' {
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -CertificateThumbprint 'ab cd:ef 01 23 45 67 89 ab cd ef 01 23 45 67 89 ab cd ef 01' -NoStart -InformationAction SilentlyContinue
        Should -Invoke -ModuleName VeeamExporterDeploy Get-TlsCertificateInfo -Times 0 -Exactly
        $script:Registered[0].Argument | Should -Match '-CertificateThumbprint ABCDEF0123456789ABCDEF0123456789ABCDEF01$'
    }

    It 'refuses an invalid thumbprint before it changes anything' {
        { Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -CertificateThumbprint 'SHA256: 3F:2A' -NoStart -InformationAction SilentlyContinue } | Should -Throw "*contains 'S'*"
        Test-Path -LiteralPath $script:Install | Should -BeFalse
        $script:Registered.Count | Should -Be 0
    }

    It 'makes relative paths absolute before they go into the tasks' {
        $module = Join-Path -Path $TestDrive -ChildPath 'Veeam.Backup.PowerShell.psd1'
        [System.IO.File]::WriteAllText($module, "@{ ModuleVersion = '13.0.1.1' }")
        Push-Location -LiteralPath $TestDrive
        try {
            $result = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath (Split-Path -Leaf $script:Install) -DataPath (Split-Path -Leaf $script:Data) `
                -TextfileDirectory (Split-Path -Leaf $script:Textfile) -VeeamModule (Join-Path '.' 'Veeam.Backup.PowerShell.psd1') `
                -Credential $script:Cred -Force -NoStart -InformationAction SilentlyContinue
        }
        finally { Pop-Location }
        $result.InstallPath | Should -BeExactly $script:Install
        $result.DataPath | Should -BeExactly $script:Data
        $result.TextfileDirectory | Should -BeExactly $script:Textfile
        # Join-TaskArgument quotes only arguments with blanks; TestDrive has none.
        $script:Registered[0].Argument | Should -BeLike ('* -File {0}*' -f $script:Install)
        $script:Registered[0].Argument | Should -BeLike ('* -TextfileDirectory {0} *' -f $script:Textfile)
        $script:Registered[1].Argument | Should -BeLike ('* -ModuleName {0}*' -f $module)
    }

    It 'registers only the REST task with -SkipLicenseTask' {
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -SkipLicenseTask -InformationAction SilentlyContinue
        ($script:Registered | ForEach-Object TaskName) -join ',' | Should -BeExactly 'Veeam Exporter REST'
        Should -Invoke -ModuleName VeeamExporterDeploy Find-VeeamPowerShellModule -Times 0 -Exactly
    }

    It 'checks pwsh.exe and the Veeam module that the license task runs as SYSTEM' {
        Mock -ModuleName VeeamExporterDeploy Assert-VeeamExporterTrustedFile { }
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -InformationAction SilentlyContinue
        Should -Invoke -ModuleName VeeamExporterDeploy Assert-VeeamExporterTrustedFile -Times 1 -Exactly -ParameterFilter { $Path -eq $script:Pwsh }
        Should -Invoke -ModuleName VeeamExporterDeploy Assert-VeeamExporterTrustedFile -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\Veeam\Veeam.Backup.PowerShell.psd1' }
    }

    It 'refuses a pwsh.exe that other accounts can change, before it changes anything' {
        Mock -ModuleName VeeamExporterDeploy Assert-VeeamExporterTrustedFile { throw 'PowerShell 7 (pwsh.exe) can be changed by other accounts' } -ParameterFilter { $Path -eq $script:Pwsh }
        { Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -InformationAction SilentlyContinue } | Should -Throw '*can be changed by other accounts*'
        Test-Path -LiteralPath $script:Install | Should -BeFalse
        Should -Invoke -ModuleName VeeamExporterDeploy Register-VeeamExporterTask -Times 0 -Exactly
    }

    It 'warns when the Veeam module is given by name' {
        Mock -ModuleName VeeamExporterDeploy Assert-VeeamExporterTrustedFile { }
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -VeeamModule 'Veeam.Backup.PowerShell' -InformationAction SilentlyContinue -WarningVariable warnings -WarningAction SilentlyContinue
        (@($warnings | ForEach-Object { [string]$_ }) -join "`n") | Should -BeLike "*loads the Veeam module 'Veeam.Backup.PowerShell' by name*"
        Should -Invoke -ModuleName VeeamExporterDeploy Assert-VeeamExporterTrustedFile -Times 0 -Exactly -ParameterFilter { $Purpose -like '*Veeam*' }
    }

    It 'accepts a REST interval of at most 30 minutes (VeeamExporterStale fires after 1 hour)' {
        { Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -RestIntervalMinutes 31 -InformationAction SilentlyContinue } | Should -Throw '*RestIntervalMinutes*'
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -RestIntervalMinutes 30 -InformationAction SilentlyContinue
        $script:Registered[0].Trigger.IntervalMinutes | Should -Be 30
        $range = @((Get-Command -Name (Join-Path (Join-Path $script:RepoRoot 'deploy') 'Install-VeeamExporter.ps1')).Parameters['RestIntervalMinutes'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })[0]
        $range.MaxRange | Should -Be 30
    }

    It 'changes nothing with -WhatIf' {
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -WhatIf -InformationAction SilentlyContinue
        Test-Path -LiteralPath $script:Install | Should -BeFalse
        Test-Path -LiteralPath $script:Data | Should -BeFalse
        Should -Invoke -ModuleName VeeamExporterDeploy Save-VeeamExporterCredentialAsSystem -Times 0 -Exactly
        Should -Invoke -ModuleName VeeamExporterDeploy Start-ScheduledTask -Times 0 -Exactly
    }

    It 'aborts without administrator rights' {
        Mock -ModuleName VeeamExporterDeploy Test-VeeamExporterAdministrator { $false }
        { Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Force } | Should -Throw '*Administrator*'
    }

    It 'aborts if the textfile directory is missing' {
        { Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -TextfileDirectory (Join-Path $TestDrive 'missing') -Force -InformationAction SilentlyContinue } | Should -Throw '*does not exist*'
        Test-Path -LiteralPath $script:Install | Should -BeFalse
    }

    It 'waits for a running task before the first run, as long as the task may run' {
        $script:RunningPolls = 2
        $script:PollsLeftAtStart = New-Object System.Collections.Generic.List[int]
        Mock -ModuleName VeeamExporterDeploy Get-ScheduledTask {
            if ($script:RunningPolls -gt 0) { $script:RunningPolls--; return [pscustomobject]@{ State = 'Running' } }
            [pscustomobject]@{ State = 'Ready' }
        }
        Mock -ModuleName VeeamExporterDeploy Start-Sleep { }
        Mock -ModuleName VeeamExporterDeploy Start-ScheduledTask { $script:PollsLeftAtStart.Add($script:RunningPolls) }
        $result = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -InformationAction SilentlyContinue
        # The first start only happens after the running instance has finished.
        ($script:PollsLeftAtStart -join ',') | Should -BeExactly '0,0'
        Should -Invoke -ModuleName VeeamExporterDeploy Wait-VeeamExporterTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'Veeam Exporter REST' -and $TimeoutSeconds -eq 660 }
        Should -Invoke -ModuleName VeeamExporterDeploy Wait-VeeamExporterTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'Veeam Exporter License' -and $TimeoutSeconds -eq 1860 }
        @($result.FirstRun | Where-Object Ok).Count | Should -Be 2
    }

    It 'waits for running tasks before it replaces the files' {
        $script:Order = New-Object System.Collections.Generic.List[string]
        $script:Tasks = @(
            [pscustomobject]@{ TaskPath = '\VeeamExporter\'; TaskName = 'Veeam Exporter REST'; State = 'Running' }
            [pscustomobject]@{ TaskPath = '\VeeamExporter\'; TaskName = 'Veeam Exporter License'; State = 'Ready' }
        )
        Mock -ModuleName VeeamExporterDeploy Get-ScheduledTask { $script:Tasks }
        Mock -ModuleName VeeamExporterDeploy Wait-VeeamExporterTaskIdle { $script:Order.Add('wait ' + $TaskName + ' ' + $TimeoutSeconds) }
        Mock -ModuleName VeeamExporterDeploy Copy-VeeamExporterFile { $script:Order.Add('copy') }
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -InformationAction SilentlyContinue
        ($script:Order -join ' | ') | Should -BeExactly 'wait Veeam Exporter REST 660 | wait Veeam Exporter License 1860 | copy'
    }

    It 'goes on with the next task and returns the summary if a first run is not finished in time' {
        Mock -ModuleName VeeamExporterDeploy Wait-VeeamExporterTask { throw 'Task \VeeamExporter\Veeam Exporter REST did not finish within 660 s.' } -ParameterFilter { $TaskName -eq 'Veeam Exporter REST' }
        $result = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -InformationAction SilentlyContinue -WarningVariable warnings -WarningAction SilentlyContinue
        Should -Invoke -ModuleName VeeamExporterDeploy Start-ScheduledTask -Times 2 -Exactly
        $rest = @($result.FirstRun | Where-Object Task -EQ 'Veeam Exporter REST')[0]
        $rest.Ok | Should -BeFalse
        $rest.LastTaskResult | Should -BeNullOrEmpty
        @($result.FirstRun | Where-Object { $_.Task -eq 'Veeam Exporter License' -and $_.Ok }).Count | Should -Be 1
        @($warnings | Where-Object { "$_" -like "First run of Veeam Exporter REST not checked*did not finish within 660 s*Get-ScheduledTaskInfo*" }).Count | Should -Be 1
    }

    It 'warns if a task reports an error on its first run' {
        Mock -ModuleName VeeamExporterDeploy Wait-VeeamExporterTask { [pscustomobject]@{ LastTaskResult = 1 } }
        $result = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -InformationAction SilentlyContinue -WarningVariable warnings -WarningAction SilentlyContinue
        @($warnings).Count | Should -Be 1
        @($result.FirstRun | Where-Object { -not $_.Ok }).Count | Should -Be 2
    }
}

Describe 'Wrapper scripts show the information messages' {
    BeforeAll {
        # Child processes with the PowerShell edition of this test run, against a
        # stub of the deploy module next to copies of the wrapper scripts.
        $script:Exe = (Get-Process -Id $PID).Path
        $script:StubDir = Join-Path -Path $TestDrive -ChildPath 'wrapper-stub'
        $null = New-Item -ItemType Directory -Path $script:StubDir
        foreach ($name in 'Install-VeeamExporter.ps1', 'Uninstall-VeeamExporter.ps1') {
            Copy-Item -LiteralPath (Join-Path (Join-Path $script:RepoRoot 'deploy') $name) -Destination $script:StubDir
        }
        $stub = @'
function Install-VeeamExporter {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$SourceRoot, [switch]$Force)
    Write-Information 'install-information-marker'
}
function Uninstall-VeeamExporter {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([switch]$KeepData)
    Write-Information 'uninstall-information-marker'
}
'@
        [System.IO.File]::WriteAllText((Join-Path $script:StubDir 'VeeamExporterDeploy.psm1'), $stub)
        function Invoke-Wrapper {
            # Called like in a console (.\Install-VeeamExporter.ps1, a child scope of
            # the global scope). With -File the script runs in the global scope, where
            # the module would see its preference variable anyway.
            param([string]$Name, [string[]]$Arguments)
            # Windows PowerShell 5.1 turns redirected stderr of a child process into a
            # terminating error when $ErrorActionPreference is Stop (GitHub Actions sets it).
            $ErrorActionPreference = 'Continue'
            $command = "& '{0}' {1}" -f (Join-Path $script:StubDir $Name), ($Arguments -join ' ')
            $output = & $script:Exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command 2>&1
            return ($output | Out-String)
        }
    }

    It '<Name> prints the messages by default' -TestCases @(
        @{ Name = 'Install-VeeamExporter.ps1'; Marker = 'install-information-marker'; Arguments = @('-Force') }
        @{ Name = 'Uninstall-VeeamExporter.ps1'; Marker = 'uninstall-information-marker'; Arguments = @('-KeepData') }
    ) {
        param($Name, $Marker, $Arguments)
        Invoke-Wrapper -Name $Name -Arguments $Arguments | Should -Match $Marker
    }

    It '<Name> keeps -InformationAction SilentlyContinue from the caller' -TestCases @(
        @{ Name = 'Install-VeeamExporter.ps1'; Marker = 'install-information-marker'; Arguments = @('-Force') }
        @{ Name = 'Uninstall-VeeamExporter.ps1'; Marker = 'uninstall-information-marker'; Arguments = @('-KeepData') }
    ) {
        param($Name, $Marker, $Arguments)
        Invoke-Wrapper -Name $Name -Arguments ($Arguments + @('-InformationAction', 'SilentlyContinue')) | Should -Not -Match $Marker
    }
}

Describe 'Credential for SYSTEM' {
    BeforeEach {
        $script:Data = New-TestDirectory -Name 'data'
        $script:Defs = New-Object System.Collections.Generic.List[object]
        Mock -ModuleName VeeamExporterDeploy Write-VeeamExporterTransferFile { [System.IO.File]::WriteAllText($Path, '{}') }
        Mock -ModuleName VeeamExporterDeploy Register-VeeamExporterTask { $script:Defs.Add($Definition) }
        Mock -ModuleName VeeamExporterDeploy Start-ScheduledTask { }
        Mock -ModuleName VeeamExporterDeploy Unregister-ScheduledTask { }
        Mock -ModuleName VeeamExporterDeploy Wait-VeeamExporterTask {
            [System.IO.File]::WriteAllText((Join-Path $script:Data 'veeam.cred.xml'), '<Objs/>')
            [pscustomobject]@{ LastTaskResult = 0 }
        }
    }

    It 'starts a one-time SYSTEM task and cleans up task and handover file' {
        InModuleScope VeeamExporterDeploy -Parameters @{ Data = $script:Data; Cred = (New-TestCredential) } {
            param($Data, $Cred)
            Save-VeeamExporterCredentialAsSystem -Credential $Cred -DataPath $Data -WorkerScript 'C:\Program Files\VeeamExporter\deploy\Save-VeeamExporterSystemCredential.ps1' -HostPath 'p.exe' -Confirm:$false
        }
        $script:Defs.Count | Should -Be 1
        $script:Defs[0].TaskName | Should -Match '^Credential Setup [0-9a-f]{32}$'
        $script:Defs[0].Trigger | Should -BeNullOrEmpty
        $script:Defs[0].Argument | Should -Match ([regex]::Escape('-File "C:\Program Files\VeeamExporter\deploy\Save-VeeamExporterSystemCredential.ps1" -TransferFile'))
        $script:Defs[0].Argument | Should -Not -Match 'S3cret'
        Should -Invoke -ModuleName VeeamExporterDeploy Unregister-ScheduledTask -Times 1 -Exactly
        @(Get-ChildItem -LiteralPath $script:Data -Filter 'transfer-*').Count | Should -Be 0
    }

    It 'cleans up on failure too and reports it' {
        Mock -ModuleName VeeamExporterDeploy Wait-VeeamExporterTask { [pscustomobject]@{ LastTaskResult = 1 } }
        {
            InModuleScope VeeamExporterDeploy -Parameters @{ Data = $script:Data; Cred = (New-TestCredential) } {
                param($Data, $Cred)
                Save-VeeamExporterCredentialAsSystem -Credential $Cred -DataPath $Data -WorkerScript 'w.ps1' -HostPath 'p.exe' -Confirm:$false
            }
        } | Should -Throw '*result 1*'
        Should -Invoke -ModuleName VeeamExporterDeploy Unregister-ScheduledTask -Times 1 -Exactly
        @(Get-ChildItem -LiteralPath $script:Data -Filter 'transfer-*').Count | Should -Be 0
    }

    It 'worker script refuses outside of SYSTEM and deletes the handover file' {
        # Windows PowerShell 5.1 turns redirected stderr of a child process into a
        # terminating error when $ErrorActionPreference is Stop (GitHub Actions sets it).
        $ErrorActionPreference = 'Continue'
        $transfer = Join-Path -Path $script:Data -ChildPath 'transfer-test.bin'
        [System.IO.File]::WriteAllText($transfer, '{}')
        $worker = Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'deploy') -ChildPath 'Save-VeeamExporterSystemCredential.ps1'
        $output = & (Get-Process -Id $PID).Path -NoProfile -File $worker -TransferFile $transfer -Path (Join-Path $script:Data 'veeam.cred.xml') 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join ' ') | Should -Match 'SYSTEM'
        Test-Path -LiteralPath $transfer | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Data 'veeam.cred.xml') | Should -BeFalse
    }
}

# Separate block: 'Credential for SYSTEM' mocks Write-VeeamExporterTransferFile.
Describe 'Permissions: files the license task runs' {
    BeforeEach {
        $script:Dir = New-TestDirectory -Name 'pwsh'
        $script:File = Join-Path -Path $script:Dir -ChildPath 'pwsh.exe'
        [System.IO.File]::WriteAllText($script:File, 'MZ')
    }

    It 'accepts a file and folder that only trusted accounts can change' {
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity -Rules @(New-TestRule -Sid $script:SidUsers -Rights $script:RightsReadExecute) }
        { InModuleScope VeeamExporterDeploy -Parameters @{ Path = $script:File } { param($Path) Assert-VeeamExporterTrustedFile -Path $Path -Purpose 'PowerShell 7 (pwsh.exe)' } } | Should -Not -Throw
        Should -Invoke -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity -Times 2 -Exactly
    }

    It 'refuses <Case>' -TestCases @(
        @{ Case = 'a folder where Users may create files'; Target = 'dir'; Sid = 'S-1-5-32-545'; Rights = [int64]2 }
        @{ Case = 'a file that Authenticated Users may modify'; Target = 'file'; Sid = 'S-1-5-11'; Rights = [int64]1245631 }
    ) {
        param($Case, $Target, $Sid, $Rights)
        $script:Weak = $script:Dir
        if ($Target -eq 'file') { $script:Weak = $script:File }
        $script:WeakRule = New-TestRule -Sid $Sid -Rights $Rights
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity }
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity -Rules @($script:WeakRule) } -ParameterFilter { $Path -eq $script:Weak }
        { InModuleScope VeeamExporterDeploy -Parameters @{ Path = $script:File } { param($Path) Assert-VeeamExporterTrustedFile -Path $Path -Purpose 'PowerShell 7 (pwsh.exe)' } } |
            Should -Throw ('*can be changed by other accounts*' + $Sid + '*has access*')
    }

    It 'refuses a file owned by another account' {
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity }
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity -Owner $script:SidAttacker } -ParameterFilter { $Path -eq $script:File }
        { InModuleScope VeeamExporterDeploy -Parameters @{ Path = $script:File } { param($Path) Assert-VeeamExporterTrustedFile -Path $Path -Purpose 'The Veeam PowerShell module' } } |
            Should -Throw '*The Veeam PowerShell module*owner is*'
    }

    It 'leaves a path that does not exist to the task' {
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { throw 'must not be read' }
        { InModuleScope VeeamExporterDeploy { Assert-VeeamExporterTrustedFile -Path 'C:\nowhere\pwsh.exe' -Purpose 'PowerShell 7 (pwsh.exe)' } } | Should -Not -Throw
    }
}

Describe 'Credential handover file' {
    It 'encrypts the handover file with DPAPI LocalMachine (Windows only)' {
        if (-not ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows)) { Set-ItResult -Skipped -Because 'DPAPI on Windows only'; return }
        $path = Join-Path -Path (New-TestDirectory -Name 'handover') -ChildPath 'transfer-roundtrip.bin'
        InModuleScope VeeamExporterDeploy -Parameters @{ Path = $path; Cred = (New-TestCredential) } {
            param($Path, $Cred)
            Write-VeeamExporterTransferFile -Path $Path -Credential $Cred
        }
        [System.IO.File]::ReadAllText($path) | Should -Not -Match 'S3cret'
        $back = Read-VeeamExporterTransferFile -Path $path
        $back.UserName | Should -BeExactly 'veeam-viewer'
        $back.GetNetworkCredential().Password | Should -BeExactly 'S3cret!pw'
    }
}

Describe 'Format-CertificateThumbprint' {
    It 'normalizes <Case>' -TestCases @(
        @{ Case = 'upper case without separators'; In = 'C0FFEE00C0FFEE00C0FFEE00C0FFEE00C0FFEE00' }
        @{ Case = 'lower case with blanks'; In = 'c0 ff ee 00 c0 ff ee 00 c0 ff ee 00 c0 ff ee 00 c0 ff ee 00' }
        @{ Case = 'colons and hyphens'; In = 'C0:FF:EE:00:C0:FF:EE:00:C0:FF-EE-00-C0-FF-EE-00-C0-FF-EE-00' }
        @{ Case = 'copied from the certificate dialog (U+200E in front)'; In = ([string][char]0x200E + 'c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00') }
    ) {
        param($In)
        InModuleScope VeeamExporterDeploy -Parameters @{ In = $In } {
            param($In)
            Format-CertificateThumbprint -Thumbprint $In
        } | Should -BeExactly 'C0FFEE00C0FFEE00C0FFEE00C0FFEE00C0FFEE00'
    }

    It 'refuses <Case>' -TestCases @(
        @{ Case = 'a label from certutil'; In = 'Cert Hash(sha1): c0 ff ee 00 c0 ff ee 00 c0 ff ee 00 c0 ff ee 00 c0 ff ee 00'; Message = "*contains 'r'*" }
        @{ Case = 'a SHA-256 fingerprint'; In = ('3F2A' * 16); Message = '*64 hex digits*' }
        @{ Case = 'a SHA-256 label'; In = 'SHA256: 3F:2A'; Message = "*contains 'S'*" }
        @{ Case = 'a value without hex digits'; In = ' : - '; Message = '*0 hex digits*' }
        @{ Case = 'an empty value'; In = ''; Message = '*0 hex digits*' }
        @{ Case = 'one digit too few'; In = 'C0FFEE00C0FFEE00C0FFEE00C0FFEE00C0FFEE0'; Message = '*39 hex digits*' }
    ) {
        param($In, $Message)
        InModuleScope VeeamExporterDeploy -Parameters @{ In = $In; Message = $Message } {
            param($In, $Message)
            { Format-CertificateThumbprint -Thumbprint $In } | Should -Throw $Message
        }
    }

    It 'gives the same result as the check of the exporter for <Case>' -TestCases @(
        @{ Case = 'upper case'; In = 'C0FFEE00C0FFEE00C0FFEE00C0FFEE00C0FFEE00' }
        @{ Case = 'blanks, colons, hyphens, lower case'; In = 'c0 ff:ee-00 c0ff ee00c0ffee00c0ffee00c0ffee00' }
        @{ Case = 'U+200E in front'; In = ([string][char]0x200E + 'c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00') }
        @{ Case = 'a tab and a line break'; In = "C0FFEE00C0FFEE00C0FF`tEE00C0FFEE00C0FFEE00`r`n" }
        @{ Case = 'a label'; In = 'SHA1: C0FFEE00C0FFEE00C0FFEE00C0FFEE00C0FFEE00' }
        @{ Case = 'SHA-256'; In = ('3F2A' * 16) }
        @{ Case = '39 digits'; In = 'C0FFEE00C0FFEE00C0FFEE00C0FFEE00C0FFEE0' }
        @{ Case = 'an empty value'; In = '' }
        @{ Case = 'non-ASCII digits'; In = ([string][char]0x0661 + 'C0FFEE00C0FFEE00C0FFEE00C0FFEE00C0FFEE0') }
    ) {
        param($Case, $In)
        # Installer and exporter each have their own copy (separate modules); they must not drift.
        $deploy = InModuleScope VeeamExporterDeploy -Parameters @{ In = $In } {
            param($In)
            try { 'ok:' + (Format-CertificateThumbprint -Thumbprint $In) } catch { 'error:' + $_.Exception.Message }
        }
        $exporter = InModuleScope VeeamExporter -Parameters @{ In = $In } {
            param($In)
            try { 'ok:' + (ConvertTo-VeeamCertificateThumbprint -Thumbprint $In) } catch { 'error:' + $_.Exception.Message }
        }
        $exporter | Should -BeExactly $deploy
    }
}

Describe 'Uninstall-VeeamExporter' {
    BeforeEach {
        $script:Textfile = New-TestDirectory -Name 'textfile'
        $script:Install = New-TestDirectory -Name 'install'
        $script:Data = New-TestDirectory -Name 'data'
        InModuleScope VeeamExporterDeploy -Parameters @{ Root = $script:RepoRoot; Target = $script:Install } {
            param($Root, $Target)
            $null = Copy-VeeamExporterFile -SourceRoot $Root -InstallPath $Target -Confirm:$false
        }
        [System.IO.File]::WriteAllText((Join-Path $script:Data 'veeam.cred.xml'), '<Objs/>')
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Data 'logs')
        foreach ($n in 'veeam_jobs.prom', 'veeam_objects.prom', 'veeam_exporter.prom', 'veeam_license.prom.tmp', 'node_custom.prom') {
            [System.IO.File]::WriteAllText((Join-Path $script:Textfile $n), "x 1`n")
        }
        Mock -ModuleName VeeamExporterDeploy Test-VeeamExporterAdministrator { $true }
        Mock -ModuleName VeeamExporterDeploy Get-ScheduledTask {
            @([pscustomobject]@{ TaskPath = '\VeeamExporter\'; TaskName = 'Veeam Exporter REST' }, [pscustomobject]@{ TaskPath = '\VeeamExporter\'; TaskName = 'Veeam Exporter License' })
        }
        Mock -ModuleName VeeamExporterDeploy Unregister-ScheduledTask { }
    }

    It 'removes tasks, installation, data and only its own .prom files' {
        $result = Uninstall-VeeamExporter -InstallPath $script:Install -DataPath $script:Data -TextfileDirectory $script:Textfile -Confirm:$false
        Should -Invoke -ModuleName VeeamExporterDeploy Unregister-ScheduledTask -Times 2 -Exactly
        Test-Path -LiteralPath $script:Install | Should -BeFalse
        Test-Path -LiteralPath $script:Data | Should -BeFalse
        (Get-SortedFileName -Directory $script:Textfile) | Should -BeExactly 'node_custom.prom'
        @($result.RemovedPromFiles).Count | Should -Be 4
    }

    It 'keeps credential and logs with -KeepData' {
        $null = Uninstall-VeeamExporter -InstallPath $script:Install -DataPath $script:Data -TextfileDirectory $script:Textfile -KeepData -Confirm:$false
        Test-Path -LiteralPath (Join-Path $script:Data 'veeam.cred.xml') | Should -BeTrue
        Test-Path -LiteralPath $script:Install | Should -BeFalse
    }

    It 'deletes no directory that does not look like an installation' {
        $foreign = New-TestDirectory -Name 'foreign'
        [System.IO.File]::WriteAllText((Join-Path $foreign 'important.txt'), 'x')
        { Uninstall-VeeamExporter -InstallPath $foreign -DataPath $script:Data -TextfileDirectory $script:Textfile -Confirm:$false } | Should -Throw '*does not look like*'
        Test-Path -LiteralPath (Join-Path $foreign 'important.txt') | Should -BeTrue
    }

    It 'deletes no data directory with foreign files' {
        [System.IO.File]::WriteAllText((Join-Path $script:Data 'foreign.txt'), 'x')
        { Uninstall-VeeamExporter -InstallPath $script:Install -DataPath $script:Data -TextfileDirectory $script:Textfile -Confirm:$false } | Should -Throw '*unexpected files*'
        Test-Path -LiteralPath (Join-Path $script:Data 'foreign.txt') | Should -BeTrue
    }

    It 'changes nothing with -WhatIf' {
        $null = Uninstall-VeeamExporter -InstallPath $script:Install -DataPath $script:Data -TextfileDirectory $script:Textfile -WhatIf
        Should -Invoke -ModuleName VeeamExporterDeploy Unregister-ScheduledTask -Times 0 -Exactly
        Test-Path -LiteralPath $script:Install | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Textfile 'veeam_jobs.prom') | Should -BeTrue
    }

    It 'takes the textfile directory from the installed tasks, not from the service' {
        $decoy = New-TestDirectory -Name 'service-textfile'
        [System.IO.File]::WriteAllText((Join-Path $decoy 'veeam_jobs.prom'), "x 1`n")
        $script:Decoy = $decoy
        Mock -ModuleName VeeamExporterDeploy Find-WindowsExporterTextfileDirectory { [pscustomobject]@{ Directory = $script:Decoy } }
        $definition = InModuleScope VeeamExporterDeploy -Parameters @{ Dir = $script:Textfile } {
            param($Dir)
            Get-VeeamExporterTaskDefinition -Kind Rest -HostPath 'p.exe' -InstallPath 'C:\i' -DataPath 'C:\d' -TextfileDirectory $Dir -CertificateThumbprint ('AA' * 20)
        }
        $script:Task = [pscustomobject]@{ TaskPath = '\VeeamExporter\'; TaskName = 'Veeam Exporter REST'; State = 'Ready'; Actions = @([pscustomobject]@{ Arguments = $definition.Argument }) }
        Mock -ModuleName VeeamExporterDeploy Get-ScheduledTask { $script:Task }
        $null = Uninstall-VeeamExporter -InstallPath $script:Install -DataPath $script:Data -Confirm:$false
        Get-SortedFileName -Directory $script:Textfile | Should -BeExactly 'node_custom.prom'
        Get-SortedFileName -Directory $decoy | Should -BeExactly 'veeam_jobs.prom'
        Should -Invoke -ModuleName VeeamExporterDeploy Find-WindowsExporterTextfileDirectory -Times 0 -Exactly
    }

    It 'stops a running task before it unregisters it' {
        $script:Order = New-Object System.Collections.Generic.List[string]
        $script:Stopped = $false
        Mock -ModuleName VeeamExporterDeploy Get-ScheduledTask {
            if ($TaskName) { return [pscustomobject]@{ TaskPath = $TaskPath; TaskName = $TaskName; State = $(if ($script:Stopped) { 'Ready' } else { 'Running' }) } }
            @([pscustomobject]@{ TaskPath = '\VeeamExporter\'; TaskName = 'Veeam Exporter REST'; State = 'Running' }, [pscustomobject]@{ TaskPath = '\VeeamExporter\'; TaskName = 'Veeam Exporter License'; State = 'Ready' })
        }
        Mock -ModuleName VeeamExporterDeploy Stop-ScheduledTask { $script:Order.Add('stop ' + $TaskName); $script:Stopped = $true }
        Mock -ModuleName VeeamExporterDeploy Unregister-ScheduledTask { $script:Order.Add('unregister ' + $TaskName) }
        Mock -ModuleName VeeamExporterDeploy Start-Sleep { }
        $null = Uninstall-VeeamExporter -InstallPath $script:Install -DataPath $script:Data -TextfileDirectory $script:Textfile -Confirm:$false
        ($script:Order -join ',') | Should -BeExactly 'stop Veeam Exporter REST,unregister Veeam Exporter REST,unregister Veeam Exporter License'
    }
}

Describe 'Other files with Veeam metrics in the textfile directory' {
    It 'finds copies and other files with Veeam metrics, not its own files or other metrics' {
        $dir = New-TestDirectory -Name 'textfile'
        $files = [ordered]@{
            'veeam_jobs.prom'                 = "veeam_job_enabled{job_name=`"a`"} 1`n"
            'veeam_repositories - Kopie.prom' = "# HELP veeam_repository_online x`n# TYPE veeam_repository_online gauge`nveeam_repository_online{repository=`"R`"} 1`n"
            'old_exporter.prom'               = "veeam_license_valid 1`n"
            'node_custom.prom'                = "# veeam_ in a comment is no metric`nnode_custom 1`n"
            'veeam_jobs.prom.tmp'             = "veeam_job_enabled{job_name=`"a`"} 1`n"
        }
        foreach ($n in $files.Keys) { [System.IO.File]::WriteAllText((Join-Path $dir $n), $files[$n]) }
        $found = @(InModuleScope VeeamExporterDeploy -Parameters @{ Dir = $dir } { param($Dir) Get-VeeamExporterForeignPromFile -Directory $Dir }) | Sort-Object
        ($found -join ',') | Should -BeExactly 'old_exporter.prom,veeam_repositories - Kopie.prom'
    }
}

Describe 'Task arguments: reading them back' {
    It 'Split-TaskArgument inverts Join-TaskArgument' {
        $values = @('-File', 'C:\Program Files\VeeamExporter\Invoke-VeeamExporter.ps1', 'C:\plain', 'C:\with space\', 'C:\trailing\', 'a"b', 'back\\"slash', 'jobs,objects', '-CertificateThumbprint')
        InModuleScope VeeamExporterDeploy -Parameters @{ Values = $values } {
            param($Values)
            $line = Join-TaskArgument -Argument $Values
            (Split-TaskArgument -CommandLine $line) -join '|'
        } | Should -BeExactly ($values -join '|')
    }

    It 'reads the textfile directories of the tasks' {
        $dirs = InModuleScope VeeamExporterDeploy {
            $rest = Get-VeeamExporterTaskDefinition -Kind Rest -HostPath 'p.exe' -InstallPath 'C:\i' -DataPath 'C:\d' -TextfileDirectory 'C:\Program Files\windows_exporter\textfile_inputs' -CertificateThumbprint ('AA' * 20)
            $license = Get-VeeamExporterTaskDefinition -Kind License -HostPath 'p.exe' -InstallPath 'C:\i' -DataPath 'C:\d' -TextfileDirectory 'D:\tf'
            $tasks = @($rest, $license, $null, [pscustomobject]@{ TaskName = 'no actions' }) | ForEach-Object {
                if ($_ -and $_.PSObject.Properties['Argument']) { [pscustomobject]@{ Actions = @([pscustomobject]@{ Arguments = $_.Argument }) } } else { $_ }
            }
            Get-VeeamExporterTaskTextfileDirectory -Task $tasks
        }
        ($dirs -join '|') | Should -BeExactly 'C:\Program Files\windows_exporter\textfile_inputs|D:\tf'
    }
}

Describe 'Permissions: rules' {
    It 'accepts owner Administrators without foreign permissions' {
        InModuleScope VeeamExporterDeploy -Parameters @{ Sec = (New-TestSecurity) } {
            param($Sec)
            @(Get-VeeamExporterAccessProblem -Security $Sec -TrustedSid @('S-1-5-18', 'S-1-5-32-544') -Path 'X' -RightsMask $script:AnyRightsMask)
        } | Should -BeNullOrEmpty
    }

    It 'reports a foreign owner' {
        $problems = @(InModuleScope VeeamExporterDeploy -Parameters @{ Sec = (New-TestSecurity -Owner $script:SidAttacker) } {
                param($Sec)
                Get-VeeamExporterAccessProblem -Security $Sec -TrustedSid @('S-1-5-18', 'S-1-5-32-544') -Path 'X'
            })
        @($problems).Count | Should -Be 1
        $problems[0] | Should -BeLike "X: owner is *$($script:SidAttacker)*"
    }

    It 'evaluates <Case>' -TestCases @(
        @{ Case = 'Users read on write check'; Rights = 1179817; Mask = 'Write'; Problem = $false }
        @{ Case = 'Users read on data directory'; Rights = 1179817; Mask = 'Any'; Problem = $true }
        @{ Case = 'Users modify'; Rights = 1245631; Mask = 'Write'; Problem = $true }
        @{ Case = 'Users create folders (ProgramData)'; Rights = 4; Mask = 'Write'; Problem = $true }
        @{ Case = 'GENERIC_WRITE (inheritable ACE)'; Rights = 0x40000000; Mask = 'Write'; Problem = $true }
        @{ Case = 'check owner only'; Rights = 1245631; Mask = 'None'; Problem = $false }
    ) {
        param($Rights, $Mask, $Problem)
        $problems = InModuleScope VeeamExporterDeploy -Parameters @{ Sec = (New-TestSecurity -Rules @(New-TestRule -Sid $script:SidUsers -Rights $Rights)); Mask = $Mask } {
            param($Sec, $Mask)
            $m = @{ Write = $script:WriteRightsMask; Any = $script:AnyRightsMask; None = [int64]0 }[$Mask]
            @(Get-VeeamExporterAccessProblem -Security $Sec -TrustedSid @('S-1-5-18', 'S-1-5-32-544') -Path 'X' -RightsMask $m)
        }
        (@($problems).Count -gt 0) | Should -Be $Problem
    }

    It 'ignores CREATOR OWNER and deny rules' {
        $rules = @(
            (New-TestRule -Sid 'S-1-3-0' -Rights 2032127)
            (New-TestRule -Sid $script:SidUsers -Rights 2032127 -Allow $false)
        )
        InModuleScope VeeamExporterDeploy -Parameters @{ Sec = (New-TestSecurity -Rules $rules) } {
            param($Sec)
            @(Get-VeeamExporterAccessProblem -Security $Sec -TrustedSid @('S-1-5-18', 'S-1-5-32-544') -Path 'X' -RightsMask $script:AnyRightsMask)
        } | Should -BeNullOrEmpty
    }

    It 'target ACL: owner Administrators, no inheritance, <Kind>' -TestCases @(
        @{ Kind = 'Install'; Expected = 'S-1-5-18=FullControl,S-1-5-32-544=FullControl,S-1-5-32-545=ReadAndExecute' }
        @{ Kind = 'Data'; Expected = 'S-1-5-18=FullControl,S-1-5-32-544=FullControl' }
    ) {
        param($Kind, $Expected)
        $spec = InModuleScope VeeamExporterDeploy -Parameters @{ Kind = $Kind } { param($Kind) Get-VeeamExporterDirectoryAclSpec -Kind $Kind }
        $spec.Owner | Should -BeExactly 'S-1-5-32-544'
        $spec.Protected | Should -BeTrue
        (($spec.Rules | ForEach-Object { '{0}={1}' -f $_.Sid, $_.Rights }) -join ',') | Should -BeExactly $Expected
    }
}

# Separate block: 'Permissions: directories' mocks New-VeeamExporterSecureDirectoryItem.
Describe 'Permissions: creating a directory' {
    It 'Windows: new directory has from the start only SYSTEM and Administrators, without inheritance' {
        if (-not ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows)) { Set-ItResult -Skipped -Because 'ACLs on Windows only'; return }
        $path = Join-Path -Path $TestDrive -ChildPath ('acl-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        InModuleScope VeeamExporterDeploy -Parameters @{ Path = $path } { param($Path) New-VeeamExporterSecureDirectoryItem -Path $Path -Kind Data -Confirm:$false }
        $acl = Get-Acl -LiteralPath $path
        $acl.AreAccessRulesProtected | Should -BeTrue
        $sids = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
        ($sids -join ',') | Should -BeExactly 'S-1-5-18,S-1-5-32-544'
        @($acl.GetAccessRules($false, $true, [System.Security.Principal.SecurityIdentifier])).Count | Should -Be 0
    }
}

Describe 'Permissions: directories' {
    BeforeAll {
        function New-TestLink {
            param([string]$Path, [string]$Target)
            try { $null = New-Item -ItemType SymbolicLink -Path $Path -Target $Target -ErrorAction Stop; return $true }
            catch { return $false }
        }
    }
    BeforeEach {
        Mock -ModuleName VeeamExporterDeploy Set-VeeamExporterDirectoryAcl { }
        Mock -ModuleName VeeamExporterDeploy New-VeeamExporterSecureDirectoryItem { $null = New-Item -ItemType Directory -Path $Path }
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity }
    }

    It 'creates a new directory and sets the ACL' {
        $path = Join-Path -Path $TestDrive -ChildPath ('new-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        InModuleScope VeeamExporterDeploy -Parameters @{ Path = $path } { param($Path) Initialize-VeeamExporterSecureDirectory -Path $Path -Kind Data -Confirm:$false }
        Test-Path -LiteralPath $path | Should -BeTrue
        Should -Invoke -ModuleName VeeamExporterDeploy Set-VeeamExporterDirectoryAcl -Times 1 -Exactly -ParameterFilter { $Kind -eq 'Data' }
    }

    It 'creates a new <Kind> directory directly with the protected ACL (no New-Item)' -TestCases @(@{ Kind = 'Data' }, @{ Kind = 'Install' }) {
        param($Kind)
        $path = Join-Path -Path $TestDrive -ChildPath ('atomar-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Mock -ModuleName VeeamExporterDeploy New-Item { throw 'New-Item must not create the directory' } -ParameterFilter { $Path -eq $script:AtomicPath }
        $script:AtomicPath = $path
        $script:AtomicKind = $Kind
        InModuleScope VeeamExporterDeploy -Parameters @{ Path = $path; Kind = $Kind } { param($Path, $Kind) Initialize-VeeamExporterSecureDirectory -Path $Path -Kind $Kind -Confirm:$false }
        Should -Invoke -ModuleName VeeamExporterDeploy New-VeeamExporterSecureDirectoryItem -Times 1 -Exactly -ParameterFilter { $Path -eq $script:AtomicPath -and $Kind -eq $script:AtomicKind }
        Should -Invoke -ModuleName VeeamExporterDeploy Set-VeeamExporterDirectoryAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $script:AtomicPath }
    }

    It 'does not recreate an existing directory' {
        $path = New-TestDirectory -Name 'existing'
        InModuleScope VeeamExporterDeploy -Parameters @{ Path = $path } { param($Path) Initialize-VeeamExporterSecureDirectory -Path $Path -Kind Data -Confirm:$false }
        Should -Invoke -ModuleName VeeamExporterDeploy New-VeeamExporterSecureDirectoryItem -Times 0 -Exactly
        Should -Invoke -ModuleName VeeamExporterDeploy Set-VeeamExporterDirectoryAcl -Times 1 -Exactly
    }

    It 'rejects a directory that another account created between check and creation' {
        $path = Join-Path -Path $TestDrive -ChildPath ('race-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        # CreateDirectory does nothing when the directory exists; here the attacker won the race.
        Mock -ModuleName VeeamExporterDeploy New-VeeamExporterSecureDirectoryItem { $null = New-Item -ItemType Directory -Path $Path }
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity -Owner $script:SidAttacker }
        { InModuleScope VeeamExporterDeploy -Parameters @{ Path = $path } { param($Path) Initialize-VeeamExporterSecureDirectory -Path $Path -Kind Data -Confirm:$false } } |
            Should -Throw '*not created by an administrator*'
        Should -Invoke -ModuleName VeeamExporterDeploy Set-VeeamExporterDirectoryAcl -Times 0 -Exactly
    }

    It 'Windows: target ACL with owner Administrators only on request' {
        if (-not ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows)) { Set-ItResult -Skipped -Because 'ACLs on Windows only'; return }
        InModuleScope VeeamExporterDeploy {
            $withOwner = New-VeeamExporterDirectorySecurity -Kind Install -IncludeOwner
            $withOwner.GetOwner([System.Security.Principal.SecurityIdentifier]).Value | Should -BeExactly 'S-1-5-32-544'
            $withoutOwner = New-VeeamExporterDirectorySecurity -Kind Install
            $withoutOwner.GetOwner([System.Security.Principal.SecurityIdentifier]) | Should -BeNullOrEmpty
            @($withoutOwner.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value }) -join ',' |
                Should -BeExactly 'S-1-5-18,S-1-5-32-544,S-1-5-32-545'
        }
    }

    It 'does not take over a directory created by another account' {
        $path = New-TestDirectory -Name 'other'
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity -Owner $script:SidAttacker }
        { InModuleScope VeeamExporterDeploy -Parameters @{ Path = $path } { param($Path) Initialize-VeeamExporterSecureDirectory -Path $Path -Kind Data -Confirm:$false } } |
            Should -Throw '*not created by an administrator*'
        Should -Invoke -ModuleName VeeamExporterDeploy Set-VeeamExporterDirectoryAcl -Times 0 -Exactly
    }

    It 'does not take over a directory containing a file of another account' {
        $path = New-TestDirectory -Name 'file'
        $file = Join-Path -Path $path -ChildPath 'veeam.cred.xml'
        [System.IO.File]::WriteAllText($file, '<Objs/>')
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity -Owner $script:SidAttacker } -ParameterFilter { $Path -like '*veeam.cred.xml' }
        { InModuleScope VeeamExporterDeploy -Parameters @{ Path = $path } { param($Path) Initialize-VeeamExporterSecureDirectory -Path $Path -Kind Data -Confirm:$false } } |
            Should -Throw '*veeam.cred.xml: owner is*'
        Should -Invoke -ModuleName VeeamExporterDeploy Set-VeeamExporterDirectoryAcl -Times 0 -Exactly
    }

    It 'does not take over a directory with a junction or symbolic link' {
        $path = New-TestDirectory -Name 'link'
        $outside = New-TestDirectory -Name 'target'
        if (-not (New-TestLink -Path (Join-Path $path 'logs') -Target $outside)) { Set-ItResult -Skipped -Because 'symbolic links not permitted'; return }
        { InModuleScope VeeamExporterDeploy -Parameters @{ Path = $path } { param($Path) Initialize-VeeamExporterSecureDirectory -Path $Path -Kind Data -Confirm:$false } } |
            Should -Throw '*logs: junction or symbolic link*'
        Should -Invoke -ModuleName VeeamExporterDeploy Set-VeeamExporterDirectoryAcl -Times 0 -Exactly
    }

    It 'does not follow links while walking the tree' {
        $path = New-TestDirectory -Name 'tree'
        $outside = New-TestDirectory -Name 'outside'
        [System.IO.File]::WriteAllText((Join-Path $outside 'secret.txt'), 'x')
        if (-not (New-TestLink -Path (Join-Path $path 'l') -Target $outside)) { Set-ItResult -Skipped -Because 'symbolic links not permitted'; return }
        $items = InModuleScope VeeamExporterDeploy -Parameters @{ Path = $path } { param($Path) Get-VeeamExporterTreeItem -Path $Path }
        @($items | Where-Object { $_.Name -eq 'secret.txt' }).Count | Should -Be 0
    }

    It 'data directory: reports read access for Users after setting the ACL' {
        $path = New-TestDirectory -Name 'readable'
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity -Rules @(New-TestRule -Sid $script:SidUsers -Rights $script:RightsReadExecute) }
        { InModuleScope VeeamExporterDeploy -Parameters @{ Path = $path } { param($Path) Initialize-VeeamExporterDataDirectory -Path $Path -Confirm:$false } } |
            Should -Throw '*is not protected*'
    }

    It 'installation: read access for Users is allowed, write access is not' {
        $path = New-TestDirectory -Name 'install'
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity -Rules @(New-TestRule -Sid $script:SidUsers -Rights $script:RightsReadExecute) }
        { InModuleScope VeeamExporterDeploy -Parameters @{ Path = $path } { param($Path) Assert-VeeamExporterDirectorySecure -Path $Path -Kind Install } } | Should -Not -Throw
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity -Rules @(New-TestRule -Sid $script:SidAuthUsers -Rights $script:RightsModify) }
        { InModuleScope VeeamExporterDeploy -Parameters @{ Path = $path } { param($Path) Assert-VeeamExporterDirectorySecure -Path $Path -Kind Install } } | Should -Throw '*S-1-5-11*has access*'
    }

    It 'textfile directory: reports write permissions and links on its own files' {
        $dir = New-TestDirectory -Name 'textfile'
        [System.IO.File]::WriteAllText((Join-Path $dir 'node_custom.prom'), "x 1`n")
        InModuleScope VeeamExporterDeploy -Parameters @{ Dir = $dir } { param($Dir) @(Get-VeeamExporterTextfileProblem -Directory $Dir) } | Should -BeNullOrEmpty

        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity -Rules @(New-TestRule -Sid $script:SidUsers -Rights $script:RightsCreateFolders) }
        $problems = @(InModuleScope VeeamExporterDeploy -Parameters @{ Dir = $dir } { param($Dir) Get-VeeamExporterTextfileProblem -Directory $Dir })
        @($problems).Count | Should -Be 1
        $problems[0] | Should -BeLike '*S-1-5-32-545*has access'

        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity }
        if (-not (New-TestLink -Path (Join-Path $dir 'veeam_jobs.prom.tmp') -Target (Join-Path $dir 'node_custom.prom'))) { Set-ItResult -Skipped -Because 'symbolic links not permitted'; return }
        $problems = InModuleScope VeeamExporterDeploy -Parameters @{ Dir = $dir } { param($Dir) @(Get-VeeamExporterTextfileProblem -Directory $Dir) }
        $problems | Should -BeLike '*veeam_jobs.prom.tmp: junction or symbolic link'
    }

    It 'textfile directory: asks for the trusted accounts once, not per file' {
        $dir = New-TestDirectory -Name 'textfile'
        foreach ($n in 'veeam_jobs.prom', 'veeam_objects.prom', 'veeam_exporter.prom', 'veeam_jobs.prom.tmp') { [System.IO.File]::WriteAllText((Join-Path $dir $n), "x 1`n") }
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterTrustedSid { @('S-1-5-18', 'S-1-5-32-544') }
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity }
        InModuleScope VeeamExporterDeploy -Parameters @{ Dir = $dir } { param($Dir) @(Get-VeeamExporterTextfileProblem -Directory $Dir) } | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity -Times 5 -Exactly
        Should -Invoke -ModuleName VeeamExporterDeploy Get-VeeamExporterTrustedSid -Times 1 -Exactly
    }
}

Describe 'Permissions: install and uninstall' {
    BeforeEach {
        $script:Textfile = New-TestDirectory -Name 'textfile'
        $script:Install = Join-Path -Path $TestDrive -ChildPath ('install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Data = Join-Path -Path $TestDrive -ChildPath ('data-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Mock -ModuleName VeeamExporterDeploy Test-VeeamExporterAdministrator { $true }
        Mock -ModuleName VeeamExporterDeploy Find-PowerShellHost { [pscustomobject]@{ WindowsPowerShell = $script:WinPs; Pwsh = $script:Pwsh } }
        Mock -ModuleName VeeamExporterDeploy Set-VeeamExporterDirectoryAcl { }
        Mock -ModuleName VeeamExporterDeploy New-VeeamExporterSecureDirectoryItem { $null = New-Item -ItemType Directory -Path $Path }
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity }
        Mock -ModuleName VeeamExporterDeploy Save-VeeamExporterCredentialAsSystem { }
        Mock -ModuleName VeeamExporterDeploy Register-VeeamExporterTask { }
        Mock -ModuleName VeeamExporterDeploy Get-ScheduledTask { }
        Mock -ModuleName VeeamExporterDeploy Unregister-ScheduledTask { }
        $script:InstallArgs = @{
            SourceRoot = $script:RepoRoot; InstallPath = $script:Install; DataPath = $script:Data; TextfileDirectory = $script:Textfile
            Credential = (New-TestCredential); CertificateThumbprint = 'C0FFEE00C0FFEE00C0FFEE00C0FFEE00C0FFEE00'; SkipLicenseTask = $true; NoStart = $true; InformationAction = 'SilentlyContinue'
        }
    }

    It 'aborts if another account created the data directory beforehand, before it creates or copies anything' {
        $null = New-Item -ItemType Directory -Path $script:Data
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity -Owner $script:SidAttacker } -ParameterFilter { $Path -like "$($script:Data)*" }
        { Install-VeeamExporter @script:InstallArgs } | Should -Throw '*not created by an administrator*'
        Test-Path -LiteralPath $script:Install | Should -BeFalse
        Should -Invoke -ModuleName VeeamExporterDeploy New-VeeamExporterSecureDirectoryItem -Times 0 -Exactly
        Should -Invoke -ModuleName VeeamExporterDeploy Set-VeeamExporterDirectoryAcl -Times 0 -Exactly
        Should -Invoke -ModuleName VeeamExporterDeploy Save-VeeamExporterCredentialAsSystem -Times 0 -Exactly
        Should -Invoke -ModuleName VeeamExporterDeploy Register-VeeamExporterTask -Times 0 -Exactly
    }

    It 'refuses an untrusted data directory also with -WhatIf' {
        $null = New-Item -ItemType Directory -Path $script:Data
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity -Owner $script:SidAttacker } -ParameterFilter { $Path -like "$($script:Data)*" }
        { Install-VeeamExporter @script:InstallArgs -WhatIf } | Should -Throw '*not created by an administrator*'
    }

    It 'still refuses a data directory created between the first check and its takeover' {
        # Trusted at the pre-flight check, then replaced by another account's directory.
        Mock -ModuleName VeeamExporterDeploy Copy-VeeamExporterFile { $null = New-Item -ItemType Directory -Path $script:Data; @() }
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity -Owner $script:SidAttacker } -ParameterFilter { $Path -like "$($script:Data)*" }
        { Install-VeeamExporter @script:InstallArgs } | Should -Throw '*Refusing to use*not created by an administrator*'
        Should -Invoke -ModuleName VeeamExporterDeploy Save-VeeamExporterCredentialAsSystem -Times 0 -Exactly
        Should -Invoke -ModuleName VeeamExporterDeploy Register-VeeamExporterTask -Times 0 -Exactly
    }

    It 'aborts if another account created the installation directory beforehand' {
        $null = New-Item -ItemType Directory -Path $script:Install
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity -Owner $script:SidAttacker } -ParameterFilter { $Path -like "$($script:Install)*" }
        { Install-VeeamExporter @script:InstallArgs } | Should -Throw '*not created by an administrator*'
        Test-Path -LiteralPath (Join-Path $script:Install 'Invoke-VeeamExporter.ps1') | Should -BeFalse
        Should -Invoke -ModuleName VeeamExporterDeploy Register-VeeamExporterTask -Times 0 -Exactly
    }

    It 'aborts if other accounts may write to the textfile directory' {
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity -Rules @(New-TestRule -Sid $script:SidUsers -Rights $script:RightsModify) } -ParameterFilter { $Path -eq $script:Textfile }
        { Install-VeeamExporter @script:InstallArgs } | Should -Throw '*writable by other accounts*AllowUnsafeTextfileDirectory*'
        Test-Path -LiteralPath $script:Install | Should -BeFalse
    }

    It 'only warns with -AllowUnsafeTextfileDirectory' {
        Mock -ModuleName VeeamExporterDeploy Get-VeeamExporterItemSecurity { New-TestSecurity -Rules @(New-TestRule -Sid $script:SidUsers -Rights $script:RightsModify) } -ParameterFilter { $Path -eq $script:Textfile }
        $null = Install-VeeamExporter @script:InstallArgs -AllowUnsafeTextfileDirectory -WarningVariable warnings -WarningAction SilentlyContinue
        @($warnings | Where-Object { "$_" -like '*writable by other accounts*' }).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $script:Install 'Invoke-VeeamExporter.ps1') | Should -BeTrue
    }

    It 'uninstall does not delete through a link in the data directory' {
        $null = Install-VeeamExporter @script:InstallArgs
        $outside = New-TestDirectory -Name 'victim'
        $victim = Join-Path -Path $outside -ChildPath 'important.txt'
        [System.IO.File]::WriteAllText($victim, 'x')
        $logs = Join-Path -Path $script:Data -ChildPath 'logs'
        Remove-Item -LiteralPath $logs -Recurse -Force
        try { $null = New-Item -ItemType SymbolicLink -Path $logs -Target $outside -ErrorAction Stop }
        catch { Set-ItResult -Skipped -Because 'symbolic links not permitted'; return }
        { Uninstall-VeeamExporter -InstallPath $script:Install -DataPath $script:Data -TextfileDirectory $script:Textfile -Confirm:$false } | Should -Throw '*junctions or symbolic links*'
        Test-Path -LiteralPath $victim | Should -BeTrue
        Test-Path -LiteralPath $script:Data | Should -BeTrue
    }
}

Describe 'Reading the certificate from localhost:9419' {
    It 'reads thumbprint and subject of a TLS service (openssl s_server)' {
        # Windows PowerShell 5.1 turns redirected stderr of a child process into a
        # terminating error when $ErrorActionPreference is Stop (GitHub Actions sets it).
        $ErrorActionPreference = 'Continue'
        $openssl = Get-Command -Name 'openssl' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $openssl) { Set-ItResult -Skipped -Because 'openssl not available'; return }
        $dir = New-TestDirectory -Name 'tls'
        $key = Join-Path $dir 'k.pem'
        $crt = Join-Path $dir 'c.pem'
        & $openssl.Source req -x509 -newkey rsa:2048 -nodes -keyout $key -out $crt -days 1 -subj '/CN=vbr-test' 2>$null
        $fingerprint = ((& $openssl.Source x509 -in $crt -noout -fingerprint -sha1) -replace '^.*=', '' -replace ':', '')
        $port = Get-Random -Minimum 20000 -Maximum 40000
        # IPv4 explicitly: on Windows, s_server may listen on IPv6 only, and the
        # TcpClient of .NET Framework (Windows PowerShell 5.1) connects via IPv4.
        # -www: s_server answers by itself and does not read stdin; without it,
        # an EOF on stdin makes it drop the connection during the handshake.
        $serverErr = Join-Path $dir 'err.txt'
        $server = Start-Process -FilePath $openssl.Source -ArgumentList @('s_server', '-accept', "127.0.0.1:$port", '-cert', $crt, '-key', $key, '-www', '-quiet') -PassThru -RedirectStandardOutput (Join-Path $dir 'out.txt') -RedirectStandardError $serverErr
        try {
            $info = $null
            $lastError = $null
            for ($i = 0; $i -lt 20 -and $null -eq $info; $i++) {
                try { $info = Get-TlsCertificateInfo -HostName 'localhost' -Port $port -TimeoutSeconds 5 }
                catch { $lastError = $_; Start-Sleep -Milliseconds 250 }
            }
            if ($null -eq $info) {
                $serverLog = if (Test-Path -LiteralPath $serverErr) { [System.IO.File]::ReadAllText($serverErr) } else { '' }
                $info | Should -Not -BeNullOrEmpty -Because "Get-TlsCertificateInfo failed: $lastError; s_server stderr: $serverLog"
            }
            $info.Thumbprint | Should -BeExactly $fingerprint.ToUpperInvariant()
            $info.Subject | Should -BeExactly 'CN=vbr-test'
        }
        finally {
            Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports a closed port with host and port' {
        { Get-TlsCertificateInfo -HostName '127.0.0.1' -Port 9 -TimeoutSeconds 3 } | Should -Throw '*127.0.0.1:9*'
    }
}

Describe 'Wait-VeeamExporterTaskIdle' {
    BeforeEach {
        Mock -ModuleName VeeamExporterDeploy Start-Sleep { }
    }

    It 'returns at once when the task does not run' {
        Mock -ModuleName VeeamExporterDeploy Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } }
        InModuleScope VeeamExporterDeploy { Wait-VeeamExporterTaskIdle -TaskPath '\VeeamExporter\' -TaskName 'Veeam Exporter REST' }
        Should -Invoke -ModuleName VeeamExporterDeploy Start-Sleep -Times 0 -Exactly
    }

    It 'throws when the task is still running at the deadline' {
        Mock -ModuleName VeeamExporterDeploy Get-ScheduledTask { [pscustomobject]@{ State = 'Running' } }
        { InModuleScope VeeamExporterDeploy { Wait-VeeamExporterTaskIdle -TaskPath '\VeeamExporter\' -TaskName 'Veeam Exporter REST' -TimeoutSeconds 0 -InformationAction SilentlyContinue } } | Should -Throw '*still running after 0 s*'
    }
}
