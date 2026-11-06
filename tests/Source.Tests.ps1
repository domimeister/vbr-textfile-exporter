BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    $script:SourceFiles = @(Get-ChildItem -LiteralPath $script:SrcRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1')
    $script:TestFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.ps1')
}

Describe 'Quellcode-Regeln' {
    It 'Quell- und Testdateien sind reines ASCII (Windows PowerShell 5.1 liest ohne BOM als ANSI)' {
        $bad = foreach ($f in ($script:SourceFiles + $script:TestFiles)) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            if (@($bytes | Where-Object { $_ -gt 0x7F }).Count -gt 0) { $f.Name }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'enthaelt keine PowerShell-7-only-Syntax' {
        $forbiddenTokens = @('AndAnd', 'OrOr', 'QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'QuestionMark')
        $bad = foreach ($f in $script:SourceFiles) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
            foreach ($t in $tokens) {
                if ($forbiddenTokens -contains $t.Kind.ToString()) { '{0}:{1} {2}' -f $f.Name, $t.Extent.StartLineNumber, $t.Text }
                if ($t.Kind.ToString() -eq 'Parameter' -and $t.Text -match '^-(SkipCertificateCheck|Parallel)') { '{0}:{1} {2}' -f $f.Name, $t.Extent.StartLineNumber, $t.Text }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'hat keine Parserfehler' {
        $bad = foreach ($f in $script:SourceFiles) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
            if ($errors) { '{0}: {1}' -f $f.Name, ($errors -join '; ') }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'nutzt weder Out-File noch Set-Content/Add-Content' {
        $bad = foreach ($f in $script:SourceFiles) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($c in $commands) {
                if (@('Out-File', 'Set-Content', 'Add-Content') -contains $c.GetCommandName()) { '{0}:{1}' -f $f.Name, $c.Extent.StartLineNumber }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'schaltet die Zertifikatspruefung nie pauschal ab' {
        $bad = foreach ($f in $script:SourceFiles) {
            $text = [System.IO.File]::ReadAllText($f.FullName)
            if ($text -match 'ValidationCallback\s*=\s*\{\s*\$true\s*\}' -or $text -match '=>\s*true\b' -or $text -match 'TrustAllCerts') { $f.Name }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'setzt -UseBasicParsing bei Invoke-WebRequest' {
        $text = ($script:SourceFiles | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $text | Should -Match 'UseBasicParsing\s*=\s*\$true'
        $text | Should -Not -Match 'Invoke-RestMethod'
    }

    It 'ruft nur lesende Veeam-Cmdlets auf' {
        $allowed = @('Get-VBRServerSession', 'Connect-VBRServer', 'Disconnect-VBRServer', 'Get-VBRInstalledLicense')
        $bad = foreach ($f in $script:SourceFiles) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($c in $commands) {
                $name = $c.GetCommandName()
                if ($name -match '-VBR' -and $allowed -notcontains $name) { '{0}:{1} {2}' -f $f.Name, $c.Extent.StartLineNumber, $name }
            }
            # also catches calls by string, e.g. & 'Install-VBRLicense'
            $text = [System.IO.File]::ReadAllText($f.FullName)
            foreach ($m in [regex]::Matches($text, '\b[A-Za-z]+-VBR[A-Za-z]+')) {
                if ($allowed -notcontains $m.Value) { '{0}: {1}' -f $f.Name, $m.Value }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'exportiert die Funktionen aus dem Manifest' {
        $manifest = Import-PowerShellDataFile -Path $script:ModuleManifest
        $exported = @((Get-Command -Module VeeamExporter).Name | Sort-Object)
        ($exported -join ',') | Should -BeExactly ((@($manifest.FunctionsToExport) | Sort-Object) -join ',')
    }
}
