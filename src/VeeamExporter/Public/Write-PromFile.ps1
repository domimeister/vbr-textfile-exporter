function Write-PromFile {
    <#
    .SYNOPSIS
    Writes a .prom file atomically: UTF-8 without BOM, LF, newline at the end.
    .DESCRIPTION
    Writes <Name>.tmp first and then replaces the target with Move-Item -Force,
    so the windows_exporter never reads a half-written file.
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

    $utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    try {
        [System.IO.File]::WriteAllText($tmp, $text, $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $target -Force
    }
    catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}
