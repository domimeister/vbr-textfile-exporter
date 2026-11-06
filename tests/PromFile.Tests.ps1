BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
}

Describe 'Write-PromFile' {
    BeforeEach {
        $script:Dir = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        $script:Target = Join-Path -Path $script:Dir -ChildPath 'veeam_test.prom'
    }

    It 'schreibt UTF-8 ohne BOM' {
        $u = [string][char]0x00FC
        Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content ("a{x=`"B" + $u + "ro`"} 1`n")
        $bytes = [System.IO.File]::ReadAllBytes($script:Target)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        # u-umlaut as UTF-8: C3 BC
        $hex = ($bytes | ForEach-Object { $_.ToString('X2') }) -join ''
        $hex | Should -Match 'C3BC'
    }

    It 'schreibt nur LF und einen Zeilenumbruch am Ende' {
        Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content "a 1`r`nb 2"
        $bytes = [System.IO.File]::ReadAllBytes($script:Target)
        ($bytes -contains 0x0D) | Should -BeFalse
        $bytes[-1] | Should -Be 0x0A
        Get-FileText -Path $script:Target | Should -BeExactly "a 1`nb 2`n"
    }

    It 'haengt keinen zweiten Zeilenumbruch an' {
        Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content "a 1`n"
        Get-FileText -Path $script:Target | Should -BeExactly "a 1`n"
    }

    It 'ersetzt eine bestehende Datei und hinterlaesst keine .tmp-Datei' {
        [System.IO.File]::WriteAllText($script:Target, "old 1`n")
        Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content "new 1`n"
        Get-FileText -Path $script:Target | Should -BeExactly "new 1`n"
        Test-Path -LiteralPath ($script:Target + '.tmp') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Dir).Count | Should -Be 1
    }

    It 'schreibt erst <name>.prom.tmp und verschiebt dann' {
        Mock -ModuleName VeeamExporter Move-Item { throw 'move failed' }
        { Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content "a 1`n" } | Should -Throw '*move failed*'
        Should -Invoke -ModuleName VeeamExporter Move-Item -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -like '*veeam_test.prom.tmp' -and $Destination -like '*veeam_test.prom' -and $Force
        }
        Test-Path -LiteralPath $script:Target | Should -BeFalse
        Test-Path -LiteralPath ($script:Target + '.tmp') | Should -BeFalse
    }

    It 'schreibt nicht durch eine vorhandene .tmp-Datei als Link hindurch' {
        $victim = Join-Path -Path $TestDrive -ChildPath ('opfer-' + [guid]::NewGuid().ToString('N') + '.txt')
        [System.IO.File]::WriteAllText($victim, 'original')
        try { $null = New-Item -ItemType SymbolicLink -Path ($script:Target + '.tmp') -Target $victim -ErrorAction Stop }
        catch { Set-ItResult -Skipped -Because 'symbolische Links nicht erlaubt'; return }
        Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content "a 1`n"
        [System.IO.File]::ReadAllText($victim) | Should -BeExactly 'original'
        Get-FileText -Path $script:Target | Should -BeExactly "a 1`n"
        (Get-Item -LiteralPath $script:Target -Force).Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) | Should -BeFalse
    }

    It 'ersetzt eine liegengebliebene .tmp-Datei' {
        [System.IO.File]::WriteAllText(($script:Target + '.tmp'), 'stale')
        Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content "a 1`n"
        Get-FileText -Path $script:Target | Should -BeExactly "a 1`n"
        Test-Path -LiteralPath ($script:Target + '.tmp') | Should -BeFalse
    }

    It 'verweigert ein Verzeichnis anstelle der Zieldatei oder der .tmp-Datei' {
        $null = New-Item -ItemType Directory -Path $script:Target
        { Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content "a 1`n" } | Should -Throw '*is a directory or junction*'
        @(Get-ChildItem -LiteralPath $script:Target).Count | Should -Be 0
        Remove-Item -LiteralPath $script:Target
        $null = New-Item -ItemType Directory -Path ($script:Target + '.tmp')
        { Write-PromFile -Directory $script:Dir -Name 'veeam_test.prom' -Content "a 1`n" } | Should -Throw '*is a directory or junction*'
        Test-Path -LiteralPath $script:Target | Should -BeFalse
    }

    It 'wirft, wenn das Verzeichnis fehlt' {
        { Write-PromFile -Directory (Join-Path $script:Dir 'fehlt') -Name 'veeam_test.prom' -Content "a 1`n" } | Should -Throw '*does not exist*'
    }

    It 'akzeptiert nur Dateinamen auf .prom' {
        { Write-PromFile -Directory $script:Dir -Name '..\evil.prom' -Content "a 1`n" } | Should -Throw
        { Write-PromFile -Directory $script:Dir -Name 'veeam_test.txt' -Content "a 1`n" } | Should -Throw
    }
}
