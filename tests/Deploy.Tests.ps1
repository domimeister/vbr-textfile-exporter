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
    $script:Pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
}

AfterAll {
    foreach ($name in $script:CreatedStubs) { Remove-Item -Path "Function:\$name" -ErrorAction SilentlyContinue }
    Remove-Module -Name VeeamExporterDeploy -ErrorAction SilentlyContinue
}

Describe 'windows_exporter: Textfile-Verzeichnis' {
    It 'liest <Case>' -TestCases @(
        @{ Case = 'Argument in Anfuehrungszeichen'; Image = '"C:\Program Files\windows_exporter\windows_exporter.exe" --log.file eventlog --collector.textfile.directories "D:\Monitoring\textfile"'; Config = $null; Dir = 'D:\Monitoring\textfile'; Source = 'argument' }
        @{ Case = 'Argument mit = und Liste'; Image = 'C:\we\windows_exporter.exe --collector.textfile.directories=C:\tf1,C:\tf2'; Config = $null; Dir = 'C:\tf1'; Source = 'argument' }
        @{ Case = 'alte Option directory mit Backslash am Ende'; Image = 'C:\we\windows_exporter.exe --collector.textfile.directory C:\old\'; Config = $null; Dir = 'C:\old'; Source = 'argument' }
        @{ Case = 'Konfigurationsdatei'; Image = '"C:\we\windows_exporter.exe" --config.file "C:\we\config.yml"'; Config = "collectors:`n  enabled: cpu,textfile`ncollector:`n  textfile:`n    directories: `"D:\\tf`"`n"; Dir = 'D:\tf'; Source = 'config' }
        @{ Case = 'MSI-Standard neben der Exe'; Image = '"C:\Program Files\windows_exporter\windows_exporter.exe" --log.file eventlog'; Config = $null; Dir = 'C:\Program Files\windows_exporter\textfile_inputs'; Source = 'default' }
        @{ Case = 'ohne Dienst'; Image = $null; Config = $null; Dir = 'C:\Program Files\windows_exporter\textfile_inputs'; Source = 'default' }
    ) {
        param($Image, $Config, $Dir, $Source)
        $result = InModuleScope VeeamExporterDeploy -Parameters @{ Image = $Image; Config = $Config } {
            param($Image, $Config)
            Get-WindowsExporterTextfileDirectory -ImagePath $Image -ConfigText $Config
        }
        $result.Directory | Should -BeExactly $Dir
        $result.Source | Should -BeExactly $Source
    }

    It 'erkennt, ob der Textfile-Collector aktiv ist (<Enabled>)' -TestCases @(
        @{ Image = 'x.exe --collectors.enabled "cpu,cs,net"'; Enabled = $false }
        @{ Image = 'x.exe --collectors.enabled=[defaults],mssql'; Enabled = $true }
        @{ Image = 'x.exe --collectors.enabled cpu,textfile'; Enabled = $true }
        @{ Image = 'x.exe --log.file eventlog'; Enabled = $true }
    ) {
        param($Image, $Enabled)
        InModuleScope VeeamExporterDeploy -Parameters @{ Image = $Image } {
            param($Image)
            (Get-WindowsExporterTextfileDirectory -ImagePath $Image).TextfileEnabled
        } | Should -Be $Enabled
    }
}

Describe 'Task-Argumente' {
    It 'quotet <In> als <Out>' -TestCases @(
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

    It 'kommt nach dem Quoten unveraendert im Skript an (echter Prozessstart)' {
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
        $received = @($out | ConvertFrom-Json)
        ($received -join '|') | Should -BeExactly ($values -join '|')
    }

    It 'baut den REST-Task' {
        $d = InModuleScope VeeamExporterDeploy -Parameters @{ WinPs = $script:WinPs } {
            param($WinPs)
            Get-VeeamExporterTaskDefinition -Kind Rest -HostPath $WinPs -InstallPath 'C:\Program Files\VeeamExporter' -DataPath 'C:\ProgramData\VeeamExporter' `
                -TextfileDirectory 'C:\Program Files\windows_exporter\textfile_inputs\' -CertificateThumbprint 'ab:cd ef' -Collector 'jobs', 'objects'
        }
        $d.TaskPath | Should -BeExactly '\VeeamExporter\'
        $d.TaskName | Should -BeExactly 'Veeam Exporter REST'
        $d.Execute | Should -BeExactly $script:WinPs
        $d.Argument | Should -BeExactly ('-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "C:\Program Files\VeeamExporter\Invoke-VeeamExporter.ps1"' +
            ' -CredentialPath C:\ProgramData\VeeamExporter\veeam.cred.xml -TextfileDirectory "C:\Program Files\windows_exporter\textfile_inputs"' +
            ' -Collector jobs,objects -ObjectLookbackDays 8 -LogPath C:\ProgramData\VeeamExporter\logs\rest.log -CertificateThumbprint ABCDEF')
        $d.Trigger.Type | Should -BeExactly 'Repeat'
        $d.Trigger.IntervalMinutes | Should -Be 15
        $d.ExecutionTimeLimit.TotalMinutes | Should -Be 10
    }

    It 'baut den Lizenz-Task' {
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

    It 'registriert Tasks als SYSTEM mit Wiederholung bzw. taeglichem Trigger' {
        Mock -ModuleName VeeamExporterDeploy New-ScheduledTaskAction { [pscustomobject]@{ Execute = $Execute; Argument = $Argument } }
        Mock -ModuleName VeeamExporterDeploy New-ScheduledTaskPrincipal { [pscustomobject]@{ UserId = $UserId } }
        Mock -ModuleName VeeamExporterDeploy New-ScheduledTaskSettingsSet { [pscustomobject]@{} }
        Mock -ModuleName VeeamExporterDeploy New-ScheduledTaskTrigger { [pscustomobject]@{} }
        Mock -ModuleName VeeamExporterDeploy New-ScheduledTask { [pscustomobject]@{} }
        Mock -ModuleName VeeamExporterDeploy Register-ScheduledTask { }
        InModuleScope VeeamExporterDeploy {
            foreach ($kind in 'Rest', 'License') {
                $d = Get-VeeamExporterTaskDefinition -Kind $kind -HostPath 'p.exe' -InstallPath 'C:\i' -DataPath 'C:\d' -TextfileDirectory 'C:\t' -CertificateThumbprint 'AA'
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

Describe 'Host fuer den Lizenz-Task' {
    It 'waehlt <Expected> fuer Modus <Mode> und Modulversion <Version>' -TestCases @(
        @{ Mode = 'Auto'; Version = '13.0.1.1'; Expected = 'pwsh' }
        @{ Mode = 'Auto'; Version = '12.3.1.1139'; Expected = 'winps' }
        @{ Mode = 'WindowsPowerShell'; Version = '13.0.0.0'; Expected = 'winps' }
        @{ Mode = 'PowerShell7'; Version = '12.3.0.0'; Expected = 'pwsh' }
    ) {
        param($Mode, $Version, $Expected)
        $result = InModuleScope VeeamExporterDeploy -Parameters @{ Mode = $Mode; Version = $Version; WinPs = $script:WinPs; Pwsh = $script:Pwsh } {
            param($Mode, $Version, $WinPs, $Pwsh)
            Resolve-VeeamLicenseHost -Mode $Mode -ModuleVersion ([version]$Version) -WindowsPowerShellPath $WinPs -PwshPath $Pwsh
        }
        if ($Expected -eq 'pwsh') { $result | Should -BeExactly $script:Pwsh } else { $result | Should -BeExactly $script:WinPs }
    }

    It 'wirft, wenn VBR 13 ohne PowerShell 7 installiert ist' {
        InModuleScope VeeamExporterDeploy {
            { Resolve-VeeamLicenseHost -Mode Auto -ModuleVersion ([version]'13.0') -WindowsPowerShellPath 'w.exe' -PwshPath $null } | Should -Throw '*PowerShell 7*'
        }
    }

    It 'wirft, wenn das Veeam-Modul fehlt' {
        InModuleScope VeeamExporterDeploy {
            { Resolve-VeeamLicenseHost -Mode Auto -ModuleVersion $null -WindowsPowerShellPath 'w.exe' -PwshPath 'p.exe' } | Should -Throw '*-SkipLicenseTask*'
        }
    }
}

Describe 'Dateien kopieren' {
    It 'kopiert Skripte, Modul und Deploy-Dateien, aber keine Tests' {
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

    It 'entfernt beim Update veraltete Moduldateien' {
        $target = New-TestDirectory -Name 'install'
        InModuleScope VeeamExporterDeploy -Parameters @{ Root = $script:RepoRoot; Target = $target } {
            param($Root, $Target)
            $null = Copy-VeeamExporterFile -SourceRoot $Root -InstallPath $Target -Confirm:$false
            [System.IO.File]::WriteAllText((Join-Path (Join-Path $Target 'VeeamExporter') 'Old.ps1'), '# old')
            $null = Copy-VeeamExporterFile -SourceRoot $Root -InstallPath $Target -Confirm:$false
        }
        Test-Path -LiteralPath (Join-Path (Join-Path $target 'VeeamExporter') 'Old.ps1') | Should -BeFalse
    }

    It 'kopiert nichts, wenn Quelle und Ziel die Installation selbst sind' {
        $target = New-TestDirectory -Name 'install'
        $copied = InModuleScope VeeamExporterDeploy -Parameters @{ Root = $script:RepoRoot; Target = $target } {
            param($Root, $Target)
            $null = Copy-VeeamExporterFile -SourceRoot $Root -InstallPath $Target -Confirm:$false
            @(Copy-VeeamExporterFile -SourceRoot $Target -InstallPath $Target -Confirm:$false)
        }
        $copied.Count | Should -Be 0
    }

    It 'aendert mit -WhatIf nichts' {
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
        Mock -ModuleName VeeamExporterDeploy Set-VeeamExporterDataAcl { }
        Mock -ModuleName VeeamExporterDeploy Save-VeeamExporterCredentialAsSystem { [System.IO.File]::WriteAllText((Join-Path $DataPath 'veeam.cred.xml'), '<Objs/>') }
        Mock -ModuleName VeeamExporterDeploy Register-VeeamExporterTask { $script:Registered.Add($Definition) }
        Mock -ModuleName VeeamExporterDeploy Get-ScheduledTask { }
        Mock -ModuleName VeeamExporterDeploy Unregister-ScheduledTask { }
        Mock -ModuleName VeeamExporterDeploy Start-ScheduledTask { }
        Mock -ModuleName VeeamExporterDeploy Wait-VeeamExporterTask { [pscustomobject]@{ LastTaskResult = 0 } }
        $script:Cred = New-TestCredential
    }

    It 'installiert Dateien, Credential und beide Tasks und startet sie einmal' {
        $result = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -InformationAction SilentlyContinue

        Test-Path -LiteralPath (Join-Path $script:Install 'Invoke-VeeamExporter.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path (Join-Path $script:Data 'logs') '.') | Should -BeTrue
        Should -Invoke -ModuleName VeeamExporterDeploy Set-VeeamExporterDataAcl -Times 1 -Exactly
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

    It 'nutzt Windows PowerShell fuer den Lizenz-Task unter VBR 12' {
        $script:ModuleVersion = [version]'12.3.1.1139'
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -InformationAction SilentlyContinue
        $script:Registered[1].Execute | Should -BeExactly $script:WinPs
    }

    It 'behaelt ein vorhandenes Credential und ersetzt es nur mit -UpdateCredential' {
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -InformationAction SilentlyContinue
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Force -NoStart -InformationAction SilentlyContinue
        Should -Invoke -ModuleName VeeamExporterDeploy Save-VeeamExporterCredentialAsSystem -Times 1 -Exactly
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -UpdateCredential -Force -NoStart -InformationAction SilentlyContinue
        Should -Invoke -ModuleName VeeamExporterDeploy Save-VeeamExporterCredentialAsSystem -Times 2 -Exactly
    }

    It 'uebernimmt einen angegebenen Thumbprint ohne TLS-Abfrage' {
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -CertificateThumbprint 'ab cd:ef' -NoStart -InformationAction SilentlyContinue
        Should -Invoke -ModuleName VeeamExporterDeploy Get-TlsCertificateInfo -Times 0 -Exactly
        $script:Registered[0].Argument | Should -Match '-CertificateThumbprint ABCDEF$'
    }

    It 'registriert mit -SkipLicenseTask nur den REST-Task' {
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -NoStart -SkipLicenseTask -InformationAction SilentlyContinue
        ($script:Registered | ForEach-Object TaskName) -join ',' | Should -BeExactly 'Veeam Exporter REST'
        Should -Invoke -ModuleName VeeamExporterDeploy Find-VeeamPowerShellModule -Times 0 -Exactly
    }

    It 'aendert mit -WhatIf nichts' {
        $null = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -WhatIf -InformationAction SilentlyContinue
        Test-Path -LiteralPath $script:Install | Should -BeFalse
        Test-Path -LiteralPath $script:Data | Should -BeFalse
        Should -Invoke -ModuleName VeeamExporterDeploy Save-VeeamExporterCredentialAsSystem -Times 0 -Exactly
        Should -Invoke -ModuleName VeeamExporterDeploy Start-ScheduledTask -Times 0 -Exactly
    }

    It 'bricht ohne Administratorrechte ab' {
        Mock -ModuleName VeeamExporterDeploy Test-VeeamExporterAdministrator { $false }
        { Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Force } | Should -Throw '*Administrator*'
    }

    It 'bricht ab, wenn das Textfile-Verzeichnis fehlt' {
        { Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -TextfileDirectory (Join-Path $TestDrive 'fehlt') -Force -InformationAction SilentlyContinue } | Should -Throw '*does not exist*'
        Test-Path -LiteralPath $script:Install | Should -BeFalse
    }

    It 'warnt, wenn ein Task beim ersten Lauf einen Fehler meldet' {
        Mock -ModuleName VeeamExporterDeploy Wait-VeeamExporterTask { [pscustomobject]@{ LastTaskResult = 1 } }
        $result = Install-VeeamExporter -SourceRoot $script:RepoRoot -InstallPath $script:Install -DataPath $script:Data -Credential $script:Cred -Force -InformationAction SilentlyContinue -WarningVariable warnings -WarningAction SilentlyContinue
        @($warnings).Count | Should -Be 1
        @($result.FirstRun | Where-Object { -not $_.Ok }).Count | Should -Be 2
    }
}

Describe 'Credential fuer SYSTEM' {
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

    It 'startet einen einmaligen SYSTEM-Task und raeumt Task und Uebergabedatei ab' {
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

    It 'raeumt auch bei einem Fehler auf und meldet ihn' {
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

    It 'Worker-Skript verweigert ausserhalb von SYSTEM und loescht die Uebergabedatei' {
        $transfer = Join-Path -Path $script:Data -ChildPath 'transfer-test.bin'
        [System.IO.File]::WriteAllText($transfer, '{}')
        $worker = Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'deploy') -ChildPath 'Save-VeeamExporterSystemCredential.ps1'
        $output = & (Get-Process -Id $PID).Path -NoProfile -File $worker -TransferFile $transfer -Path (Join-Path $script:Data 'veeam.cred.xml') 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join ' ') | Should -Match 'SYSTEM'
        Test-Path -LiteralPath $transfer | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Data 'veeam.cred.xml') | Should -BeFalse
    }

    It 'verschluesselt die Uebergabedatei mit DPAPI LocalMachine (nur Windows)' {
        if (-not ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows)) { Set-ItResult -Skipped -Because 'DPAPI nur unter Windows'; return }
        $path = Join-Path -Path $script:Data -ChildPath 'transfer-roundtrip.bin'
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

    It 'entfernt Tasks, Installation, Daten und nur die eigenen .prom-Dateien' {
        $result = Uninstall-VeeamExporter -InstallPath $script:Install -DataPath $script:Data -TextfileDirectory $script:Textfile -Confirm:$false
        Should -Invoke -ModuleName VeeamExporterDeploy Unregister-ScheduledTask -Times 2 -Exactly
        Test-Path -LiteralPath $script:Install | Should -BeFalse
        Test-Path -LiteralPath $script:Data | Should -BeFalse
        (Get-SortedFileName -Directory $script:Textfile) | Should -BeExactly 'node_custom.prom'
        @($result.RemovedPromFiles).Count | Should -Be 4
    }

    It 'behaelt mit -KeepData Credential und Logs' {
        $null = Uninstall-VeeamExporter -InstallPath $script:Install -DataPath $script:Data -TextfileDirectory $script:Textfile -KeepData -Confirm:$false
        Test-Path -LiteralPath (Join-Path $script:Data 'veeam.cred.xml') | Should -BeTrue
        Test-Path -LiteralPath $script:Install | Should -BeFalse
    }

    It 'loescht kein Verzeichnis, das nicht nach Installation aussieht' {
        $foreign = New-TestDirectory -Name 'foreign'
        [System.IO.File]::WriteAllText((Join-Path $foreign 'wichtig.txt'), 'x')
        { Uninstall-VeeamExporter -InstallPath $foreign -DataPath $script:Data -TextfileDirectory $script:Textfile -Confirm:$false } | Should -Throw '*does not look like*'
        Test-Path -LiteralPath (Join-Path $foreign 'wichtig.txt') | Should -BeTrue
    }

    It 'loescht kein Datenverzeichnis mit fremden Dateien' {
        [System.IO.File]::WriteAllText((Join-Path $script:Data 'fremd.txt'), 'x')
        { Uninstall-VeeamExporter -InstallPath $script:Install -DataPath $script:Data -TextfileDirectory $script:Textfile -Confirm:$false } | Should -Throw '*unexpected files*'
        Test-Path -LiteralPath (Join-Path $script:Data 'fremd.txt') | Should -BeTrue
    }

    It 'aendert mit -WhatIf nichts' {
        $null = Uninstall-VeeamExporter -InstallPath $script:Install -DataPath $script:Data -TextfileDirectory $script:Textfile -WhatIf
        Should -Invoke -ModuleName VeeamExporterDeploy Unregister-ScheduledTask -Times 0 -Exactly
        Test-Path -LiteralPath $script:Install | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Textfile 'veeam_jobs.prom') | Should -BeTrue
    }
}

Describe 'Zertifikat von localhost:9419 auslesen' {
    It 'liest Thumbprint und Subject eines TLS-Dienstes (openssl s_server)' {
        $openssl = Get-Command -Name 'openssl' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $openssl) { Set-ItResult -Skipped -Because 'openssl nicht verfuegbar'; return }
        $dir = New-TestDirectory -Name 'tls'
        $key = Join-Path $dir 'k.pem'
        $crt = Join-Path $dir 'c.pem'
        & $openssl.Source req -x509 -newkey rsa:2048 -nodes -keyout $key -out $crt -days 1 -subj '/CN=vbr-test' 2>$null
        $fingerprint = ((& $openssl.Source x509 -in $crt -noout -fingerprint -sha1) -replace '^.*=', '' -replace ':', '')
        $port = Get-Random -Minimum 20000 -Maximum 40000
        $server = Start-Process -FilePath $openssl.Source -ArgumentList @('s_server', '-accept', $port, '-cert', $crt, '-key', $key, '-quiet') -PassThru -RedirectStandardOutput (Join-Path $dir 'out.txt') -RedirectStandardError (Join-Path $dir 'err.txt')
        try {
            $info = $null
            for ($i = 0; $i -lt 20 -and $null -eq $info; $i++) {
                try { $info = Get-TlsCertificateInfo -HostName 'localhost' -Port $port -TimeoutSeconds 5 }
                catch { Start-Sleep -Milliseconds 250 }
            }
            $info.Thumbprint | Should -BeExactly $fingerprint.ToUpperInvariant()
            $info.Subject | Should -BeExactly 'CN=vbr-test'
        }
        finally {
            Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'meldet einen geschlossenen Port mit Host und Port' {
        { Get-TlsCertificateInfo -HostName '127.0.0.1' -Port 9 -TimeoutSeconds 3 } | Should -Throw '*127.0.0.1:9*'
    }
}
