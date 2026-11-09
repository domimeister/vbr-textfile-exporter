# VBR version from the local installation (docs/metrics.md#OP-13).
# Keep this file ASCII-only (Windows PowerShell 5.1 reads it as ANSI).

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
}

Describe 'ConvertFrom-ServiceImagePath' {
    It 'returns <Expected> for <ImagePath>' -TestCases @(
        @{ ImagePath = '"C:\Program Files\Veeam\Backup and Replication\Backup\Veeam.Backup.Service.exe"'; Expected = 'C:\Program Files\Veeam\Backup and Replication\Backup\Veeam.Backup.Service.exe' }
        @{ ImagePath = '"C:\Program Files\Veeam\Backup.Service.exe" -service -port 9392'; Expected = 'C:\Program Files\Veeam\Backup.Service.exe' }
        @{ ImagePath = '  "C:\Veeam\svc.exe"  '; Expected = 'C:\Veeam\svc.exe' }
        @{ ImagePath = '"\??\C:\Veeam\svc.exe" -x'; Expected = 'C:\Veeam\svc.exe' }
        # Unquoted, and no candidate exists on this machine: up to the first ".exe".
        @{ ImagePath = 'C:\Program Files\Veeam\Backup.Service.exe'; Expected = 'C:\Program Files\Veeam\Backup.Service.exe' }
        @{ ImagePath = 'C:\Veeam\Backup.Service.EXE /svc'; Expected = 'C:\Veeam\Backup.Service.EXE' }
        @{ ImagePath = '\??\C:\Veeam\svc.exe -x'; Expected = 'C:\Veeam\svc.exe' }
    ) {
        param($ImagePath, $Expected)
        InModuleScope VeeamExporter -Parameters @{ ImagePath = $ImagePath } {
            param($ImagePath)
            ConvertFrom-ServiceImagePath -ImagePath $ImagePath
        } | Should -BeExactly $Expected
    }

    It 'finds <Case> in an unquoted path, the way Windows starts it' -TestCases @(
        @{ Case = 'the executable with arguments'; Files = @('Program Files\Veeam\svc.exe'); Image = 'Program Files\Veeam\svc.exe -service'; Expected = 'Program Files\Veeam\svc.exe' }
        @{ Case = 'the executable named without .exe'; Files = @('Program Files\Veeam\svc.exe'); Image = 'Program Files\Veeam\svc -x'; Expected = 'Program Files\Veeam\svc.exe' }
        @{ Case = 'the executable behind .exe in a directory name'; Files = @('x.exe dir\svc.exe'); Image = 'x.exe dir\svc.exe -x'; Expected = 'x.exe dir\svc.exe' }
        @{ Case = 'a shorter file first, like Windows'; Files = @('Program.exe', 'Program Files\Veeam\svc.exe'); Image = 'Program Files\Veeam\svc.exe'; Expected = 'Program.exe' }
        @{ Case = 'the executable after the NT prefix'; Files = @('Veeam\svc.exe'); Image = '\??\Veeam\svc.exe -x'; Expected = 'Veeam\svc.exe' }
    ) {
        param($Case, $Files, $Image, $Expected)
        # Real files in TestDrive, paths with the separator of this platform.
        $sep = [string][System.IO.Path]::DirectorySeparatorChar
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        foreach ($f in $Files) {
            $path = $root + $sep + $f.Replace('\', $sep)
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
            [System.IO.File]::WriteAllText($path, 'MZ')
        }
        # Image is relative to the root; the NT prefix goes in front of the root.
        $prefix = ''
        $rest = $Image
        if ($rest.StartsWith('\??\')) { $prefix = '\??\'; $rest = $rest.Substring(4) }
        $commandLine = $prefix + $root + $sep + $rest.Replace('\', $sep)
        InModuleScope VeeamExporter -Parameters @{ CommandLine = $commandLine } {
            param($CommandLine)
            ConvertFrom-ServiceImagePath -ImagePath $CommandLine
        } | Should -BeExactly ($root + $sep + $Expected.Replace('\', $sep))
    }

    It 'does not expand environment variables again (the registry read already did)' {
        $env:VEEAM_TEST_ROOT = 'D:\Apps'
        try {
            InModuleScope VeeamExporter { ConvertFrom-ServiceImagePath -ImagePath '"C:\%VEEAM_TEST_ROOT%\Veeam\svc.exe" -x' } | Should -BeExactly 'C:\%VEEAM_TEST_ROOT%\Veeam\svc.exe'
        }
        finally { Remove-Item -Path Env:\VEEAM_TEST_ROOT }
    }

    It 'rejects an empty path and an unbalanced quote' {
        InModuleScope VeeamExporter {
            { ConvertFrom-ServiceImagePath -ImagePath '' } | Should -Throw '*Empty*'
            { ConvertFrom-ServiceImagePath -ImagePath '"C:\Veeam\svc.exe' } | Should -Throw '*Unbalanced*'
        }
    }
}

Describe 'Get-VeeamFileVersion' {
    It 'reads the file version, not the product or assembly version' {
        # A library with three different versions; FileVersionInfo reads the
        # Win32 version resource on Windows and the attributes elsewhere.
        # Add-Type of PowerShell 7 writes no Win32 version resource, so on
        # Windows only Windows PowerShell 5.1 (csc.exe) can build the library.
        if ($PSVersionTable.PSEdition -eq 'Core' -and $IsWindows) { Set-ItResult -Skipped -Because 'Add-Type of PowerShell 7 writes no Win32 version resource'; return }
        $name = 'VersionProbe' + [guid]::NewGuid().ToString('N')
        $dll = Join-Path -Path $TestDrive -ChildPath ($name + '.dll')
        $source = @(
            '[assembly: System.Reflection.AssemblyVersion("1.2.3.4")]'
            '[assembly: System.Reflection.AssemblyFileVersion("13.1.2.57")]'
            '[assembly: System.Reflection.AssemblyInformationalVersion("9.8.7.6")]'
            ('namespace {0} {{ public static class Probe {{ }} }}' -f $name)
        ) -join "`n"
        Add-Type -TypeDefinition $source -OutputAssembly $dll -OutputType Library
        InModuleScope VeeamExporter -Parameters @{ Path = $dll } {
            param($Path)
            Get-VeeamFileVersion -Path $Path
        } | Should -BeExactly '13.1.2.57'
    }

    It 'throws for a missing file and for a file without a version' {
        $plain = Join-Path -Path $TestDrive -ChildPath 'plain.txt'
        [System.IO.File]::WriteAllText($plain, 'no version resource')
        InModuleScope VeeamExporter -Parameters @{ Plain = $plain; Missing = (Join-Path -Path $TestDrive -ChildPath 'missing.exe') } {
            param($Plain, $Missing)
            { Get-VeeamFileVersion -Path $Missing } | Should -Throw '*not found*'
            { Get-VeeamFileVersion -Path $Plain } | Should -Throw '*No file version*'
        }
    }
}

Describe 'Get-VeeamServiceImagePath' {
    It 'reads the ImagePath of a service from the registry, expanded once (Windows)' {
        if (-not ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows)) { Set-ItResult -Skipped -Because 'registry on Windows only'; return }
        # The task scheduler exists on every Windows; its ImagePath is
        # REG_EXPAND_SZ "%systemroot%\system32\svchost.exe -k netsvcs -p".
        $key = Get-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Schedule'
        $key.GetValueKind('ImagePath') | Should -Be 'ExpandString'
        $key.GetValue('ImagePath', $null, 'DoNotExpandEnvironmentNames') | Should -Match '^%systemroot%\\'
        $imagePath = InModuleScope VeeamExporter { Get-VeeamServiceImagePath -ServiceName 'Schedule' }
        $imagePath | Should -Not -Match '%'
        $exe = InModuleScope VeeamExporter -Parameters @{ ImagePath = $imagePath } { param($ImagePath) ConvertFrom-ServiceImagePath -ImagePath $ImagePath }
        $exe | Should -Be (Join-Path -Path $env:SystemRoot -ChildPath 'system32\svchost.exe')
        InModuleScope VeeamExporter { Get-VeeamLocalServerVersion -ServiceName 'Schedule' } | Should -Match '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    }
}

Describe 'Get-VeeamLocalServerVersion' {
    It 'takes the binary of the service VeeamBackupSvc' {
        Mock -ModuleName VeeamExporter Get-VeeamServiceImagePath { '"C:\Program Files\Veeam\Backup and Replication\Backup\Veeam.Backup.Service.exe"' } -ParameterFilter { $ServiceName -eq 'VeeamBackupSvc' }
        Mock -ModuleName VeeamExporter Get-VeeamFileVersion { '13.1.2.57' } -ParameterFilter { $Path -eq 'C:\Program Files\Veeam\Backup and Replication\Backup\Veeam.Backup.Service.exe' }
        InModuleScope VeeamExporter { Get-VeeamLocalServerVersion } | Should -BeExactly '13.1.2.57'
    }

    It 'throws if the service is missing' {
        Mock -ModuleName VeeamExporter Get-VeeamServiceImagePath { throw 'Cannot find path' }
        { InModuleScope VeeamExporter { Get-VeeamLocalServerVersion } } | Should -Throw '*Cannot find path*'
    }
}

Describe 'Test-VeeamLocalBaseUri' {
    It 'returns <Expected> for <BaseUri>' -TestCases @(
        @{ BaseUri = 'https://localhost:9419'; Expected = $true }
        @{ BaseUri = 'https://LOCALHOST:9419/'; Expected = $true }
        @{ BaseUri = 'https://127.0.0.1:9419'; Expected = $true }
        @{ BaseUri = 'https://[::1]:9419'; Expected = $true }
        @{ BaseUri = 'https://vbr02.example.net:9419'; Expected = $false }
        @{ BaseUri = 'https://10.0.0.5:9419'; Expected = $false }
        @{ BaseUri = 'not a uri'; Expected = $false }
        @{ BaseUri = ''; Expected = $false }
    ) {
        param($BaseUri, $Expected)
        InModuleScope VeeamExporter -Parameters @{ BaseUri = $BaseUri } {
            param($BaseUri)
            Test-VeeamLocalBaseUri -BaseUri $BaseUri
        } | Should -Be $Expected
    }

    It 'returns $true for the name of this machine, in any case' {
        $name = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName
        if ($env:COMPUTERNAME) { $name = $env:COMPUTERNAME }
        InModuleScope VeeamExporter -Parameters @{ Name = $name.ToUpperInvariant() } {
            param($Name)
            Test-VeeamLocalBaseUri -BaseUri ('https://{0}:9419' -f $Name)
        } | Should -BeTrue
    }
}
