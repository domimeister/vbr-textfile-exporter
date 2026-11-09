BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    # Not -Include: Windows PowerShell 5.1 ignores it together with -LiteralPath.
    $codeExtensions = @('.ps1', '.psm1', '.psd1')
    $script:SourceFiles = @(Get-ChildItem -LiteralPath $script:SrcRoot -Recurse -File | Where-Object { $codeExtensions -contains $_.Extension })
    $script:DeployFiles = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'deploy') -Recurse -File | Where-Object { $codeExtensions -contains $_.Extension })
    $script:AllCodeFiles = $script:SourceFiles + $script:DeployFiles
    $script:TestFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.ps1')
}

Describe 'Source code rules' {
    It 'source and test files are pure ASCII (Windows PowerShell 5.1 reads files without BOM as ANSI)' {
        $bad = foreach ($f in ($script:AllCodeFiles + $script:TestFiles)) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            if (@($bytes | Where-Object { $_ -gt 0x7F }).Count -gt 0) { $f.Name }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'contains no PowerShell-7-only syntax' {
        $forbiddenTokens = @('AndAnd', 'OrOr', 'QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'QuestionMark')
        $bad = foreach ($f in $script:AllCodeFiles) {
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

    It 'has no parser errors' {
        $bad = foreach ($f in $script:AllCodeFiles) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
            if ($errors) { '{0}: {1}' -f $f.Name, ($errors -join '; ') }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'uses neither Out-File nor Set-Content/Add-Content' {
        $bad = foreach ($f in $script:AllCodeFiles) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($c in $commands) {
                if (@('Out-File', 'Set-Content', 'Add-Content') -contains $c.GetCommandName()) { '{0}:{1}' -f $f.Name, $c.Extent.StartLineNumber }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'never disables certificate validation wholesale' {
        $bad = foreach ($f in $script:SourceFiles) {
            $text = [System.IO.File]::ReadAllText($f.FullName)
            if ($text -match 'ValidationCallback\s*=\s*\{\s*\$true\s*\}' -or $text -match '=>\s*true\b' -or $text -match 'TrustAllCerts') { $f.Name }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'sets -UseBasicParsing on Invoke-WebRequest' {
        $text = ($script:SourceFiles | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $text | Should -Match 'UseBasicParsing\s*=\s*\$true'
        $text | Should -Not -Match 'Invoke-RestMethod'
    }

    It 'follows no HTTP redirects (5.1 and 7)' {
        $text = [System.IO.File]::ReadAllText((Join-Path -Path $script:SrcRoot -ChildPath 'VeeamExporter/Private/Http.ps1'))
        $text | Should -Match 'MaximumRedirection\s*=\s*0'
        $text | Should -Match '\.AllowAutoRedirect\s*=\s*\$false'
    }

    It 'allows only TLS 1.2 under 5.1 (no -bor onto the old setting)' {
        $text = [System.IO.File]::ReadAllText((Join-Path -Path $script:SrcRoot -ChildPath 'VeeamExporter/Private/Tls.ps1'))
        $text | Should -Match 'SecurityProtocol\s*=\s*\[System\.Net\.SecurityProtocolType\]::Tls12\s'
        $text | Should -Not -Match 'SecurityProtocol\s*=\s*\[System\.Net\.ServicePointManager\]::SecurityProtocol'
    }

    It 'uses -LiteralPath with Import-/Export-Clixml' {
        $files = @(Get-ChildItem -LiteralPath $script:SrcRoot -Recurse -Filter '*.ps1') + @(Get-ChildItem -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'deploy') -Filter '*.ps*1')
        $bad = foreach ($f in $files) {
            $lines = [System.IO.File]::ReadAllLines($f.FullName)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '(Import|Export)-Clixml\b' -and $lines[$i] -match '\s-Path\b') { '{0}:{1}' -f $f.Name, ($i + 1) }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'calls only reading Veeam cmdlets' {
        $allowed = @('Get-VBRServerSession', 'Connect-VBRServer', 'Disconnect-VBRServer', 'Get-VBRInstalledLicense')
        $bad = foreach ($f in $script:AllCodeFiles) {
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

    It 'entry script accepts comma-separated lists from powershell.exe -File' {
        # Windows PowerShell 5.1 turns redirected stderr of a child process into a
        # terminating error when $ErrorActionPreference is Stop (GitHub Actions sets it).
        $ErrorActionPreference = 'Continue'
        $script = Join-Path -Path $script:SrcRoot -ChildPath 'Invoke-VeeamExporter.ps1'
        $missing = Join-Path -Path $TestDrive -ChildPath 'missing.cred.xml'
        # Never the default directory: on a machine with windows_exporter the
        # run would replace the real veeam_exporter.prom.
        $out = Join-Path -Path $TestDrive -ChildPath 'textfile-lists'
        $null = New-Item -ItemType Directory -Path $out
        $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $script -CredentialPath $missing -TextfileDirectory $out -Collector 'jobs,objects' -ObjectSessionType 'BackupJob,ReplicaJob' 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join ' ') | Should -Not -Match 'Cannot validate argument'
        ($output -join ' ') | Should -Match 'missing.cred.xml'
        Get-FileText -Path (Join-Path -Path $out -ChildPath 'veeam_exporter.prom') | Should -Match 'veeam_exporter_collector_success\{collector="objects"\} 0'
    }

    It 'refers every # ASSUMPTION: to an open point of docs/metrics.md' {
        $docs = [System.IO.File]::ReadAllText((Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'docs') -ChildPath 'metrics.md'))
        $open = @([regex]::Matches($docs, '(?m)^- \[ \] \*\*(OP-[0-9]+)\*\*') | ForEach-Object { $_.Groups[1].Value })
        $open.Count | Should -BeGreaterThan 0
        $markers = 0
        $bad = foreach ($f in $script:AllCodeFiles) {
            $lines = [System.IO.File]::ReadAllLines($f.FullName)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -cnotmatch '#\s*ASSUMPTION:') { continue }
                $markers++
                $link = [regex]::Match($lines[$i], 'docs/metrics\.md#(OP-[0-9]+)\b')
                if (-not $link.Success) { '{0}:{1} links no open point' -f $f.Name, ($i + 1) }
                elseif ($open -notcontains $link.Groups[1].Value) { '{0}:{1} {2} is not an open point' -f $f.Name, ($i + 1), $link.Groups[1].Value }
            }
        }
        @($bad) | Should -BeNullOrEmpty
        $markers | Should -BeGreaterThan 0
    }

    It 'marks the OP-3 assumption for MinValue/MaxValue where timestamps are converted' {
        $text = [System.IO.File]::ReadAllText((Join-Path -Path $script:SrcRoot -ChildPath 'VeeamExporter/Private/Convert.ps1'))
        $text | Should -Match '# ASSUMPTION: MinValue/MaxValue mean "not set".*docs/metrics\.md#OP-3'
    }

    It 'exports the functions from the manifest' {
        $manifest = Import-PowerShellDataFile -Path $script:ModuleManifest
        $exported = @((Get-Command -Module VeeamExporter).Name | Sort-Object)
        ($exported -join ',') | Should -BeExactly ((@($manifest.FunctionsToExport) | Sort-Object) -join ',')
    }
}
