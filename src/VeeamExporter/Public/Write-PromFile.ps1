function Write-PromFile {
    <#
    .SYNOPSIS
    Writes a .prom file atomically: UTF-8 without BOM, LF, newline at the end.
    .DESCRIPTION
    Writes <Name>.tmp first and then replaces the target with Move-Item -Force,
    so the windows_exporter never reads a half-written file.
    Runs as SYSTEM: an existing .tmp (possibly a link planted by another
    account) is deleted, never written through, and the new .tmp is created
    exclusively (CreateNew). A directory or junction in place of the target is
    refused, so Move-Item cannot put the file somewhere else.
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
        Move-Item -LiteralPath $tmp -Destination $target -Force
    }
    catch {
        if ($created) {
            try { [System.IO.File]::Delete($tmp) } catch { Write-Verbose "Cannot remove $tmp." }
        }
        throw
    }
}
