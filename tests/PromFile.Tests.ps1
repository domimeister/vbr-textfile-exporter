BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
}

Describe 'Write-PromFile' {
    BeforeEach {
        $script:Dir = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        $script:Target = Join-Path -Path $script:Dir -ChildPath 'veeam_test.prom'
    }

    It 'writes UTF-8 without BOM' {
        $u = [string][char]0x00FC
        Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content ("a{x=`"B" + $u + "ro`"} 1`n")
        $bytes = [System.IO.File]::ReadAllBytes($script:Target)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        # u-umlaut as UTF-8: C3 BC
        $hex = ($bytes | ForEach-Object { $_.ToString('X2') }) -join ''
        $hex | Should -Match 'C3BC'
    }

    It 'writes only LF and one newline at the end' {
        Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content "a 1`r`nb 2"
        $bytes = [System.IO.File]::ReadAllBytes($script:Target)
        ($bytes -contains 0x0D) | Should -BeFalse
        $bytes[-1] | Should -Be 0x0A
        Get-FileText -Path $script:Target | Should -BeExactly "a 1`nb 2`n"
    }

    It 'does not append a second newline' {
        Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content "a 1`n"
        Get-FileText -Path $script:Target | Should -BeExactly "a 1`n"
    }

    It 'replaces an existing file and leaves no .tmp file behind' {
        [System.IO.File]::WriteAllText($script:Target, "old 1`n")
        Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content "new 1`n"
        Get-FileText -Path $script:Target | Should -BeExactly "new 1`n"
        Test-Path -LiteralPath ($script:Target + '.tmp') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Dir).Count | Should -Be 1
    }

    It 'writes <name>.prom.tmp first and then moves it' {
        Mock -ModuleName VeeamExporter Move-Item { throw 'move failed' }
        { Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content "a 1`n" } | Should -Throw '*move failed*'
        Should -Invoke -ModuleName VeeamExporter Move-Item -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -like '*veeam_test.prom.tmp' -and $Destination -like '*veeam_test.prom' -and $Force
        }
        Test-Path -LiteralPath $script:Target | Should -BeFalse
        Test-Path -LiteralPath ($script:Target + '.tmp') | Should -BeFalse
    }

    It 'does not write through an existing .tmp file that is a link' {
        $victim = Join-Path -Path $TestDrive -ChildPath ('opfer-' + [guid]::NewGuid().ToString('N') + '.txt')
        [System.IO.File]::WriteAllText($victim, 'original')
        try { $null = New-Item -ItemType SymbolicLink -Path ($script:Target + '.tmp') -Target $victim -ErrorAction Stop }
        catch { Set-ItResult -Skipped -Because 'symbolic links not permitted'; return }
        Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content "a 1`n"
        [System.IO.File]::ReadAllText($victim) | Should -BeExactly 'original'
        Get-FileText -Path $script:Target | Should -BeExactly "a 1`n"
        (Get-Item -LiteralPath $script:Target -Force).Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) | Should -BeFalse
    }

    It 'replaces a leftover .tmp file' {
        [System.IO.File]::WriteAllText(($script:Target + '.tmp'), 'stale')
        Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content "a 1`n"
        Get-FileText -Path $script:Target | Should -BeExactly "a 1`n"
        Test-Path -LiteralPath ($script:Target + '.tmp') | Should -BeFalse
    }

    It 'refuses a directory in place of the target file or the .tmp file' {
        $null = New-Item -ItemType Directory -Path $script:Target
        { Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content "a 1`n" } | Should -Throw '*is a directory or junction*'
        @(Get-ChildItem -LiteralPath $script:Target).Count | Should -Be 0
        Remove-Item -LiteralPath $script:Target
        $null = New-Item -ItemType Directory -Path ($script:Target + '.tmp')
        { Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content "a 1`n" } | Should -Throw '*is a directory or junction*'
        Test-Path -LiteralPath $script:Target | Should -BeFalse
    }

    It 'throws if the directory is missing' {
        { Write-PromFile -Directory (Join-Path $script:Dir 'missing') -Name 'veeam_test.prom' -Content "a 1`n" } | Should -Throw '*does not exist*'
    }

    It 'accepts only file names ending in .prom' {
        { Write-PromFile -Directory $script:Dir -Name '..\evil.prom' -Content "a 1`n" } | Should -Throw
        { Write-PromFile -Directory $script:Dir -Name 'veeam_test.txt' -Content "a 1`n" } | Should -Throw
    }
}
