BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-Module -Name (Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'deploy') -ChildPath 'VeeamExporterDeploy.psm1') -Force

    # The exporter and the installer load the same file.
    function Get-ForeignFile {
        param([string]$Module, [string]$Directory)
        $found = InModuleScope $Module -Parameters @{ Dir = $Directory } { param($Dir) Get-VeeamForeignPromFile -Directory $Dir }
        return (@($found) | Sort-Object) -join ','
    }
}

Describe 'One check for other .prom files' {
    It 'is the same file in the exporter and in the deploy module' {
        $expected = Join-Path -Path (Join-Path -Path (Join-Path -Path $script:SrcRoot -ChildPath 'VeeamExporter') -ChildPath 'Private') -ChildPath 'ForeignPromFile.ps1'
        foreach ($module in @('VeeamExporter', 'VeeamExporterDeploy')) {
            $file = InModuleScope $module { (Get-Command -Name Get-VeeamForeignPromFile).ScriptBlock.File }
            [System.IO.Path]::GetFullPath($file) | Should -Be ([System.IO.Path]::GetFullPath($expected)) -Because $module
        }
        InModuleScope VeeamExporterDeploy { Get-Command -Name Get-VeeamExporterForeignPromFile -ErrorAction SilentlyContinue } | Should -BeNullOrEmpty
    }

    It 'knows the same exporter files as the deploy module' {
        $deploy = @(InModuleScope VeeamExporterDeploy { $script:PromFiles }) | Sort-Object
        $shared = @(InModuleScope VeeamExporter { Get-VeeamOwnPromFileName }) | Sort-Object
        ($shared -join ',') | Should -BeExactly ($deploy -join ',')
    }

    It 'does not report the exporter files or their .tmp files' {
        $dir = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir
        foreach ($name in @(InModuleScope VeeamExporterDeploy { $script:PromFiles })) {
            [System.IO.File]::WriteAllText((Join-Path -Path $dir -ChildPath $name), "veeam_license_valid 1`n")
            [System.IO.File]::WriteAllText((Join-Path -Path $dir -ChildPath ($name + '.tmp')), "veeam_license_valid 1`n")
        }
        Get-ForeignFile -Module 'VeeamExporterDeploy' -Directory $dir | Should -BeNullOrEmpty
    }
}

Describe 'Reading other .prom files (<Module>)' -ForEach @(
    @{ Module = 'VeeamExporter' }
    @{ Module = 'VeeamExporterDeploy' }
) {
    BeforeEach {
        $script:Dir = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:Dir
    }

    It 'reads a file that its owner keeps open for writing' {
        $path = Join-Path -Path $script:Dir -ChildPath 'other_exporter.prom'
        [System.IO.File]::WriteAllText($path, "veeam_license_valid 1`n")
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $owner = New-Object -TypeName System.IO.FileStream -ArgumentList $path, ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::ReadWrite), $share
        try { Get-ForeignFile -Module $Module -Directory $script:Dir | Should -BeExactly 'other_exporter.prom' }
        finally { $owner.Dispose() }
    }

    It 'looks at the first 1000 lines of a file only' {
        $other = "node_custom 1`n"
        [System.IO.File]::WriteAllText((Join-Path -Path $script:Dir -ChildPath 'line1000.prom'), (($other * 999) + "veeam_license_valid 1`n"))
        [System.IO.File]::WriteAllText((Join-Path -Path $script:Dir -ChildPath 'line1001.prom'), (($other * 1000) + "veeam_license_valid 1`n"))
        Get-ForeignFile -Module $Module -Directory $script:Dir | Should -BeExactly 'line1000.prom'
    }

    It 'leaves the files closed afterwards' {
        $path = Join-Path -Path $script:Dir -ChildPath 'copy.prom'
        [System.IO.File]::WriteAllText($path, "veeam_license_valid 1`n")
        Get-ForeignFile -Module $Module -Directory $script:Dir | Should -BeExactly 'copy.prom'
        $exclusive = New-Object -TypeName System.IO.FileStream -ArgumentList $path, ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::ReadWrite), ([System.IO.FileShare]::None)
        $exclusive.Dispose()
    }
}
