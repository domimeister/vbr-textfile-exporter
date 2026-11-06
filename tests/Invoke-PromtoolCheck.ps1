<#
.SYNOPSIS
    Runs "promtool check metrics" on .prom files.

.DESCRIPTION
    Checks every *.prom file in or below the given paths with
    "promtool check metrics" (parser and lint). Fails if promtool rejects a
    file or prints a finding, and if a path contains no .prom file at all,
    so an empty output directory cannot pass silently.

    CI runs it on the files the Pester tests generated (they copy them to
    $env:VEEAM_TEST_PROM_OUTPUT, see Export-GeneratedPromFile in
    TestHelpers.ps1) and on tests/fixtures/expected.

    Not a Pester test file (no .Tests.ps1 suffix): Invoke-Pester skips it.

.EXAMPLE
    $env:VEEAM_TEST_PROM_OUTPUT = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'veeam-prom'
    Invoke-Pester -Path tests
    ./tests/Invoke-PromtoolCheck.ps1 -Path $env:VEEAM_TEST_PROM_OUTPUT, 'tests/fixtures/expected'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Path,
    [string]$Promtool = 'promtool'
)

$ErrorActionPreference = 'Stop'

$command = Get-Command -Name $Promtool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $command) { throw "promtool not found ('$Promtool'). Put it in PATH or pass -Promtool." }

function Invoke-Promtool {
    # Feeds the raw UTF-8 bytes via stdin. A pipeline into a native exe
    # would re-encode the text under Windows PowerShell 5.1.
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.Arguments = 'check metrics'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        $process.StandardInput.BaseStream.Write($Bytes, 0, $Bytes.Length)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = ($stdout + $stderr).Trim() }
    }
    finally {
        $process.Dispose()
    }
}

$checked = 0
$failed = New-Object System.Collections.Generic.List[string]
foreach ($root in $Path) {
    if (-not (Test-Path -LiteralPath $root)) { throw "Path not found: $root" }
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.prom' | Sort-Object -Property FullName)
    if ($files.Count -eq 0) { throw "No .prom files in $root" }
    foreach ($file in $files) {
        $result = Invoke-Promtool -Executable $command.Source -Bytes ([System.IO.File]::ReadAllBytes($file.FullName))
        $checked++
        if ($result.ExitCode -eq 0 -and -not $result.Output) {
            Write-Output ('ok    {0}' -f $file.FullName)
        }
        else {
            Write-Output ('FAIL  {0} (exit code {1})' -f $file.FullName, $result.ExitCode)
            Write-Output ($result.Output -replace '(?m)^', '      ')
            $failed.Add($file.FullName)
        }
    }
}

Write-Output ('promtool check metrics: {0} file(s) checked, {1} failed' -f $checked, $failed.Count)
if ($failed.Count -gt 0) { throw "promtool rejected $($failed.Count) file(s)" }
