# Other .prom files with Veeam metrics in the textfile directory. One check
# for the exporter (every REST run) and the deploy module (installation),
# which dot-sources this file: keep it self-contained.

function Get-VeeamOwnPromFileName {
    # The files the two tasks write. The deploy module has the same list for
    # the uninstallation, which must work without this file; a test compares
    # the two.
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]@('veeam_jobs.prom', 'veeam_objects.prom', 'veeam_repositories.prom', 'veeam_license.prom', 'veeam_exporter.prom', 'veeam_exporter_license.prom')
}

function Get-VeeamForeignPromFile {
    # Other .prom files in the textfile directory that hold Veeam metrics: a
    # copy such as "veeam_jobs - Kopie.prom", a second exporter. Of two files
    # with the same series windows_exporter 0.32.1 keeps the one that sorts
    # first, so such a file can hide this exporter's current data
    # (docs/metrics.md).
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][string]$Directory)
    $own = @(Get-VeeamOwnPromFileName)
    $found = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Filter '*.prom' -File -Force -ErrorAction SilentlyContinue)) {
        if ($file.Extension -ne '.prom' -or $own -contains $file.Name) { continue }
        # The file belongs to someone else: open it so that its owner can
        # still write, delete and rename it, and look at the first 1000
        # lines only. A copy of an exporter file shows Veeam metrics in line 1.
        try {
            $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $stream = New-Object -TypeName System.IO.FileStream -ArgumentList $file.FullName, ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::Read), $share
            try {
                $reader = New-Object -TypeName System.IO.StreamReader -ArgumentList $stream
                for ($n = 0; $n -lt 1000; $n++) {
                    $line = $reader.ReadLine()
                    if ($null -eq $line) { break }
                    if ($line -match '^(# (HELP|TYPE) )?veeam_') { $found.Add($file.Name); break }
                }
            }
            finally { $stream.Dispose() }
        }
        catch { Write-Verbose ('{0} not readable: {1}' -f $file.FullName, $_.Exception.Message) }
    }
    return [string[]]$found.ToArray()
}
