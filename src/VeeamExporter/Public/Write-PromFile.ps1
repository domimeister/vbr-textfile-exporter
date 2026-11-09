# The entry scripts dot-source this file on its own when the module cannot be
# loaded (FallbackHealth.ps1), so everything Write-PromFile needs is in here.

# windows_exporter opens a .prom file without FILE_SHARE_DELETE while it reads
# it; the replacement is refused for that moment (lab, 0.32.1: up to 17 % of the
# writes under continuous scraping). A few attempts get past it.
$script:PromFileReplaceAttempts = 5
$script:PromFileReplaceDelayMs = 200

function Move-VeeamPromFile {
    # One attempt to put the written .tmp in place of the target with a single
    # rename (MoveFileEx with MOVEFILE_REPLACE_EXISTING): the target is never
    # deleted first, so a failed attempt changes nothing. PowerShell 7:
    # File.Move with overwrite. Windows PowerShell 5.1 has no such overload;
    # FileSystem.MoveFile of Microsoft.VisualBasic calls MoveFileEx with the
    # same flag (flags 11, checked in the lab) and needs no compiled code.
    # File.Replace (ReplaceFile) is no option: it holds the target while it
    # copies metadata, and windows_exporter fails to read it then (lab: 1412
    # of 1461 scrapes during continuous writes).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if ($null -ne [System.IO.File].GetMethod('Move', [type[]]@([string], [string], [bool]))) {
        [System.IO.File]::Move($Source, $Destination, $true)
        return
    }
    if (-not ('Microsoft.VisualBasic.FileIO.FileSystem' -as [type])) { Add-Type -AssemblyName Microsoft.VisualBasic }
    [Microsoft.VisualBasic.FileIO.FileSystem]::MoveFile($Source, $Destination, $true)
}

function Write-PromFile {
    <#
    .SYNOPSIS
    Writes a .prom file atomically: UTF-8 without BOM, LF, newline at the end.
    .DESCRIPTION
    Writes <Name>.tmp first and then puts it in place of the target in one
    step (Move-VeeamPromFile), so the windows_exporter never reads a
    half-written file and never finds the target missing. The step is retried
    while windows_exporter holds the target open.
    Runs as SYSTEM: an existing .tmp (possibly a link planted by another
    account) is deleted, never written through, and the new .tmp is created
    exclusively (CreateNew). A directory or junction in place of the target is
    refused, so the file cannot be put somewhere else.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_.-]+\.prom$')][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    $dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Directory)
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        throw "Textfile directory does not exist: $dir"
    }
    $target = Join-Path -Path $dir -ChildPath $Name
    $tmp = $target + '.tmp'

    $text = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`n" }

    if ([System.IO.Directory]::Exists($target)) { throw "Refusing to write ${target}: it is a directory or junction." }
    if ([System.IO.Directory]::Exists($tmp)) { throw "Refusing to write ${tmp}: it is a directory or junction." }

    $utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    $bytes = $utf8NoBom.GetBytes($text)
    $created = $false
    try {
        # Deletes a stale file or a symbolic link itself, not its target.
        [System.IO.File]::Delete($tmp)
        $stream = New-Object -TypeName System.IO.FileStream -ArgumentList $tmp, ([System.IO.FileMode]::CreateNew), ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::None)
        $created = $true
        try { $stream.Write($bytes, 0, $bytes.Length) }
        finally { $stream.Dispose() }
        # A read-only target cannot be replaced (Move-Item -Force used to clear it as well).
        if ([System.IO.File]::Exists($target)) {
            $attributes = [System.IO.File]::GetAttributes($target)
            if (($attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                [System.IO.File]::SetAttributes($target, ($attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
            }
        }
        $attempt = 0
        while ($true) {
            $attempt++
            try {
                Move-VeeamPromFile -Source $tmp -Destination $target
                break
            }
            catch {
                if ($attempt -ge $script:PromFileReplaceAttempts) { throw }
                Write-Verbose ('Replacing {0} failed (attempt {1}): {2}' -f $target, $attempt, $_.Exception.Message)
                Start-Sleep -Milliseconds $script:PromFileReplaceDelayMs
            }
        }
    }
    catch {
        if ($created) {
            try { [System.IO.File]::Delete($tmp) } catch { Write-Verbose "Cannot remove $tmp." }
        }
        throw
    }
}
