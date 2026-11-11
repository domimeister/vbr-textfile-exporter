BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-Module -Name (Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'deploy') -ChildPath 'VeeamExporterDeploy.psm1') -Force

    function Copy-TestExporter {
        param([string]$Target)
        InModuleScope VeeamExporterDeploy -Parameters @{ Root = $script:RepoRoot; Target = $Target } {
            param($Root, $Target)
            $null = Copy-VeeamExporterFile -SourceRoot $Root -InstallPath $Target -Confirm:$false -WarningAction SilentlyContinue
        }
    }
    function Get-HiddenFolder {
        param([string]$Target)
        return @(Get-ChildItem -LiteralPath $Target -Directory -Force | Where-Object { $_.Name -like '.*' })
    }
}

Describe 'Updating an installation' {
    BeforeEach {
        # An installed older version: every file differs from the source.
        $script:Target = Join-Path -Path $TestDrive -ChildPath ('install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Copy-TestExporter -Target $script:Target
        $script:Module = Join-Path -Path $script:Target -ChildPath 'VeeamExporter'
        $script:Marker = Join-Path -Path $script:Module -ChildPath 'Marker.ps1'
        $script:Entry = Join-Path -Path $script:Target -ChildPath 'Invoke-VeeamExporter.ps1'
        $script:LicenseEntry = Join-Path -Path $script:Target -ChildPath 'Invoke-VeeamLicenseExporter.ps1'
        $script:Deploy = Join-Path -Path (Join-Path -Path $script:Target -ChildPath 'deploy') -ChildPath 'VeeamExporterDeploy.psm1'
        [System.IO.File]::WriteAllText($script:Marker, '# old module')
        foreach ($file in @($script:Entry, $script:LicenseEntry, $script:Deploy)) { [System.IO.File]::WriteAllText($file, '# old') }
    }

    It 'replaces every file' {
        Copy-TestExporter -Target $script:Target
        Test-Path -LiteralPath $script:Marker | Should -BeFalse
        foreach ($file in @($script:Entry, $script:LicenseEntry, $script:Deploy)) { Get-FileText -Path $file | Should -Not -BeExactly '# old' -Because $file }
        (Get-HiddenFolder -Target $script:Target).Count | Should -Be 0
    }

    It 'replaces files that are read-only' {
        foreach ($file in @($script:Entry, $script:Deploy)) { (Get-Item -LiteralPath $file).IsReadOnly = $true }
        Copy-TestExporter -Target $script:Target
        foreach ($file in @($script:Entry, $script:Deploy)) { Get-FileText -Path $file | Should -Not -BeExactly '# old' -Because $file }
        (Get-HiddenFolder -Target $script:Target).Count | Should -Be 0
    }

    It 'puts everything back when <Step> cannot be put in place' -TestCases @(
        @{ Step = 'the module'; Pattern = '*VeeamExporter' }
        @{ Step = 'the second script'; Pattern = '*Invoke-VeeamLicenseExporter.ps1' }
        @{ Step = 'the last deploy file'; Pattern = '*Save-VeeamExporterSystemCredential.ps1' }
    ) {
        param($Step, $Pattern)
        $script:Pattern = $Pattern
        Mock -ModuleName VeeamExporterDeploy Move-VeeamExporterItem { throw 'The process cannot access the file.' } -ParameterFilter { $Path -like '*.staging-*' -and $Destination -like $script:Pattern }
        { Copy-TestExporter -Target $script:Target } | Should -Throw '*cannot access the file*'
        Get-FileText -Path $script:Marker | Should -BeExactly '# old module'
        foreach ($file in @($script:Entry, $script:LicenseEntry, $script:Deploy)) { Get-FileText -Path $file | Should -BeExactly '# old' -Because $file }
        (Get-HiddenFolder -Target $script:Target).Count | Should -Be 0
    }

    It 'leaves nothing behind when a first installation fails half way' {
        $fresh = Join-Path -Path $TestDrive -ChildPath ('fresh-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Mock -ModuleName VeeamExporterDeploy Move-VeeamExporterItem { throw 'The process cannot access the file.' } -ParameterFilter { $Destination -like '*Invoke-VeeamLicenseExporter.ps1' }
        { Copy-TestExporter -Target $fresh } | Should -Throw '*cannot access the file*'
        @(Get-ChildItem -LiteralPath $fresh -Recurse -File -Force).Count | Should -Be 0
        (Get-HiddenFolder -Target $fresh).Count | Should -Be 0
    }

    It 'keeps what it could not put back, and the next installation puts it back first' {
        # The second script cannot be put in place, and then the first one cannot go back.
        $script:Blocked = $true
        Mock -ModuleName VeeamExporterDeploy Move-VeeamExporterItem { throw 'The process cannot access the file.' } -ParameterFilter {
            $script:Blocked -and (($Path -like '*.staging-*' -and $Destination -like '*Invoke-VeeamLicenseExporter.ps1') -or ($Path -like '*.old-*' -and $Destination -like '*Invoke-VeeamExporter.ps1'))
        }
        { InModuleScope VeeamExporterDeploy -Parameters @{ Root = $script:RepoRoot; Target = $script:Target } {
                param($Root, $Target)
                $null = Copy-VeeamExporterFile -SourceRoot $Root -InstallPath $Target -Confirm:$false -WarningAction SilentlyContinue -WarningVariable w
            } } | Should -Throw '*cannot access the file*'
        Test-Path -LiteralPath $script:Entry | Should -BeFalse
        Get-FileText -Path $script:Marker | Should -BeExactly '# old module'
        $left = @(Get-HiddenFolder -Target $script:Target)
        $left.Count | Should -Be 1
        Get-FileText -Path (Join-Path -Path $left[0].FullName -ChildPath 'Invoke-VeeamExporter.ps1') | Should -BeExactly '# old'

        # Next installation: the copy fails, the old script is back anyway.
        $script:Blocked = $false
        Mock -ModuleName VeeamExporterDeploy Copy-Item { throw 'There is not enough space on the disk.' } -ParameterFilter { $Recurse }
        { Copy-TestExporter -Target $script:Target } | Should -Throw '*not enough space*'
        Get-FileText -Path $script:Entry | Should -BeExactly '# old'
        (Get-HiddenFolder -Target $script:Target).Count | Should -Be 0
    }

    It 'puts the module back that an update moved aside before it was killed' {
        $old = Join-Path -Path $script:Target -ChildPath '.old-0123'
        $null = New-Item -ItemType Directory -Path $old
        [System.IO.Directory]::Move($script:Module, (Join-Path -Path $old -ChildPath 'VeeamExporter'))
        Mock -ModuleName VeeamExporterDeploy Copy-Item { throw 'There is not enough space on the disk.' } -ParameterFilter { $Recurse }
        { Copy-TestExporter -Target $script:Target } | Should -Throw '*not enough space*'
        Get-FileText -Path $script:Marker | Should -BeExactly '# old module'
        (Get-HiddenFolder -Target $script:Target).Count | Should -Be 0
    }
}
