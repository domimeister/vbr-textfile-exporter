# VBR version from the local installation (docs/metrics.md#OP-13).
# Keep this file ASCII-only (Windows PowerShell 5.1 reads it as ANSI).

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
}

Describe 'ConvertFrom-ServiceImagePath' {
    It 'returns <Expected> for <ImagePath>' -TestCases @(
        @{ ImagePath = '"C:\Program Files\Veeam\Backup and Replication\Backup\Veeam.Backup.Service.exe"'; Expected = 'C:\Program Files\Veeam\Backup and Replication\Backup\Veeam.Backup.Service.exe' }
        @{ ImagePath = '"C:\Program Files\Veeam\Backup.Service.exe" -service -port 9392'; Expected = 'C:\Program Files\Veeam\Backup.Service.exe' }
        @{ ImagePath = 'C:\Program Files\Veeam\Backup.Service.exe'; Expected = 'C:\Program Files\Veeam\Backup.Service.exe' }
        @{ ImagePath = 'C:\Veeam\Backup.Service.EXE /svc'; Expected = 'C:\Veeam\Backup.Service.EXE' }
        @{ ImagePath = '  "C:\Veeam\svc.exe"  '; Expected = 'C:\Veeam\svc.exe' }
    ) {
        param($ImagePath, $Expected)
        InModuleScope VeeamExporter -Parameters @{ ImagePath = $ImagePath } {
            param($ImagePath)
            ConvertFrom-ServiceImagePath -ImagePath $ImagePath
        } | Should -BeExactly $Expected
    }

    It 'expands environment variables' {
        $env:VEEAM_TEST_ROOT = 'D:\Apps'
        try {
            InModuleScope VeeamExporter { ConvertFrom-ServiceImagePath -ImagePath '%VEEAM_TEST_ROOT%\Veeam\svc.exe -x' } | Should -BeExactly 'D:\Apps\Veeam\svc.exe'
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
    It 'reads the numeric file version of a binary' {
        # Any binary with a version resource; PowerShell's own engine assembly exists on every platform.
        $path = [System.Management.Automation.PSObject].Assembly.Location
        $expected = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($path)
        InModuleScope VeeamExporter -Parameters @{ Path = $path } {
            param($Path)
            Get-VeeamFileVersion -Path $Path
        } | Should -BeExactly ('{0}.{1}.{2}.{3}' -f $expected.FileMajorPart, $expected.FileMinorPart, $expected.FileBuildPart, $expected.FilePrivatePart)
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
