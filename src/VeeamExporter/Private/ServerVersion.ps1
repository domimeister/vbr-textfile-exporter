# VBR version for veeam_exporter_info, read from the local installation
# (docs/metrics.md#OP-13). REST has it only for Backup Administrator
# (/api/v1/serverInfo), but the exporter runs on the VBR server: the file
# version of the backup service binary is the same build number.

function ConvertFrom-ServiceImagePath {
    # Executable of a service ImagePath: quoted or not, with or without
    # arguments, environment variables expanded.
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
    }
    else {
        $match = [regex]::Match($path, '^(.*?\.exe)(\s|$)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) { $path = $match.Groups[1].Value }
    }
    if (-not $path) { throw 'Empty service image path.' }
    return [System.Environment]::ExpandEnvironmentVariables($path)
}

function Get-VeeamServiceImagePath {
    # ImagePath of a service from the registry (Windows only, mocked in tests).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName
    )
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\{0}' -f $ServiceName
    return [string](Get-ItemProperty -LiteralPath $key -Name 'ImagePath' -ErrorAction Stop).ImagePath
}

function Get-VeeamFileVersion {
    # Numeric file version (major.minor.build.private) from the version resource.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('File not found: {0}' -f $Path) }
    $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    $parts = @($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
    if (@($parts | Where-Object { $_ -ne 0 }).Count -eq 0) { throw ('No file version in {0}' -f $Path) }
    return ($parts -join '.')
}

function Test-VeeamLocalBaseUri {
    # $true if the REST address is this machine: localhost, a loopback
    # address or the machine's own name (short or with its domain). Only then
    # does the local file version belong to the server the data come from.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$BaseUri
    )
    $uri = $null
    if (-not [System.Uri]::TryCreate($BaseUri, [System.UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.IsLoopback) { return $true }
    $hostName = $uri.DnsSafeHost.TrimEnd('.')
    $names = New-Object -TypeName System.Collections.Generic.List[string]
    if ($env:COMPUTERNAME) { $names.Add($env:COMPUTERNAME) }
    try {
        $ip = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        if ($ip.HostName) {
            $names.Add($ip.HostName)
            if ($ip.DomainName) { $names.Add(('{0}.{1}' -f $ip.HostName, $ip.DomainName)) }
        }
    }
    catch { Write-Verbose ('Host name not available: {0}' -f $_.Exception.Message) }
    foreach ($n in $names) {
        if ([string]::Equals($hostName, $n, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-VeeamLocalServerVersion {
    # Build number of the local VBR server, e.g. 13.1.2.57. Read on every run,
    # so an update shows up with the next run.
    # ASSUMPTION: the service binary carries the build number of the installed release or patch, see docs/metrics.md#OP-15
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$ServiceName = 'VeeamBackupSvc'
    )
    $imagePath = Get-VeeamServiceImagePath -ServiceName $ServiceName
    $executable = ConvertFrom-ServiceImagePath -ImagePath $imagePath
    return (Get-VeeamFileVersion -Path $executable)
}
