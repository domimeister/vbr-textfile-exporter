function Get-VeeamForeignPromFile {
    # Other .prom files in the textfile directory that hold Veeam metrics: a
    # copy such as "veeam_jobs - Kopie.prom", a second exporter. Of two files
    # with the same series windows_exporter 0.32.1 keeps the one that sorts
    # first, so such a file can hide this exporter's current data
    # (docs/metrics.md). The installer has the same check.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][string]$Directory)
    $own = @('veeam_jobs.prom', 'veeam_objects.prom', 'veeam_repositories.prom', 'veeam_license.prom', 'veeam_exporter.prom', 'veeam_exporter_license.prom')
    $found = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Filter '*.prom' -File -Force -ErrorAction SilentlyContinue)) {
        if ($file.Extension -ne '.prom' -or $own -contains $file.Name) { continue }
        try {
            foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
                if ($line -match '^(# (HELP|TYPE) )?veeam_') { $found.Add($file.Name); break }
            }
        }
        catch { Write-Verbose ('{0} not readable: {1}' -f $file.FullName, $_.Exception.Message) }
    }
    return [string[]]$found.ToArray()
}
