# Executable of a Windows service command line (ImagePath). One parser for
# the exporter (VeeamBackupSvc, docs/metrics.md#OP-13) and the deploy module
# (windows_exporter), which dot-sources this file: keep it self-contained.

function Get-ServiceImagePathCandidate {
    # The files Windows tries for an unquoted command line, in its order
    # (CreateProcess): the text up to each blank, shortest first, with ".exe"
    # added when the file name has no extension.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][string]$CommandLine)
    $candidates = New-Object -TypeName System.Collections.Generic.List[string]
    for ($i = 1; $i -le $CommandLine.Length; $i++) {
        $atEnd = ($i -eq $CommandLine.Length)
        if (-not $atEnd -and -not ([char]::IsWhiteSpace($CommandLine[$i]) -and -not [char]::IsWhiteSpace($CommandLine[$i - 1]))) { continue }
        $candidate = $CommandLine.Substring(0, $i).TrimEnd()
        if ($candidate.Length -eq 0) { continue }
        $leaf = $candidate.Substring($candidate.LastIndexOfAny([char[]]@('\', '/')) + 1)
        if ($leaf.IndexOf('.') -lt 0) { $candidate += '.exe' }
        if (-not $candidates.Contains($candidate)) { $candidates.Add($candidate) }
    }
    return [string[]]$candidates.ToArray()
}

function ConvertFrom-ServiceImagePath {
    # The executable of a service, found the way Windows starts it: a quoted
    # path ends at the closing quote; for an unquoted one the first candidate
    # (Get-ServiceImagePathCandidate) that is an existing file wins. Without
    # such a file (not on this machine) the text up to the first ".exe"
    # counts, else the first candidate. A leading "\??\" (NT path prefix) is
    # removed. Environment variables are not expanded: reading the registry
    # value already does that for REG_EXPAND_SZ, as the service control
    # manager does; a second expansion would change a literal %NAME%.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ImagePath
    )
    $path = $ImagePath.Trim()
    if ($path.StartsWith('"')) {
        $end = $path.IndexOf('"', 1)
        if ($end -lt 0) { throw ('Unbalanced quote in service image path: {0}' -f $ImagePath) }
        $path = $path.Substring(1, $end - 1)
        if ($path.StartsWith('\??\')) { $path = $path.Substring(4) }
        if (-not $path) { throw 'Empty service image path.' }
        return $path
    }
    if ($path.StartsWith('\??\')) { $path = $path.Substring(4) }
    if (-not $path) { throw 'Empty service image path.' }
    $candidates = @(Get-ServiceImagePathCandidate -CommandLine $path)
    foreach ($candidate in $candidates) {
        if ([System.IO.File]::Exists($candidate)) { return $candidate }
    }
    $match = [regex]::Match($path, '^(.*?\.exe)(\s|$)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) { return $match.Groups[1].Value }
    return $candidates[0]
}
