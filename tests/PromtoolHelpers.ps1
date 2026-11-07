# Shared by tests/Promtool.Tests.ps1, tests/Rules.Tests.ps1 and tests/Invoke-PromtoolCheck.ps1.
# Keep this file ASCII-only (Windows PowerShell 5.1 reads it as ANSI).

function Invoke-PromtoolProcess {
    # Runs "promtool check metrics" and feeds the raw UTF-8 bytes via stdin.
    # A pipeline into a native exe would re-encode under Windows PowerShell 5.1.
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

    # .NET Framework (Windows PowerShell 5.1) creates the stdin writer with
    # Console.InputEncoding and writes its preamble into the pipe at once.
    # With code page 65001 that is a UTF-8 BOM, and promtool rejects line 1
    # ("invalid metric name"). .NET (PowerShell 7) never writes a preamble.
    $savedEncoding = $null
    if ($PSVersionTable.PSEdition -ne 'Core') {
        try {
            $savedEncoding = [System.Console]::InputEncoding
            [System.Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false
        }
        catch {
            # No console: the encoding then comes from code page 0, without preamble.
            $savedEncoding = $null
        }
    }
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
    }
    finally {
        if ($null -ne $savedEncoding) { [System.Console]::InputEncoding = $savedEncoding }
    }

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

function Invoke-PromtoolCommand {
    # Runs promtool with arguments and without stdin, e.g. "check rules <file>".
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.Arguments = (@($Arguments | ForEach-Object { '"{0}"' -f $_ })) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = ($stdout + $stderr).Trim() }
    }
    finally {
        $process.Dispose()
    }
}
