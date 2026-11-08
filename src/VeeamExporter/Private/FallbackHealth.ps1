# Health text for a run whose module could not be loaded: the entry scripts
# dot-source this file (and Public/Write-PromFile.ps1) when Import-Module
# fails, so the health file still changes on every run (CLAUDE.md). Keep it
# self-contained. The output must equal ConvertTo-PromText of
# New-VeeamCollectorHealthMetric for failed collectors with duration 0
# (tests/ExporterRun.Tests.ps1), because windows_exporter needs identical HELP
# texts in all files.

function Format-VeeamFailedHealthText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # Requested collectors, comma lists allowed; unknown names are ignored.
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowNull()][string[]]$Collector,
        # Known collector names in output order; used in full if none was requested.
        [Parameter(Mandatory = $true)][string[]]$Known
    )
    $requested = @(foreach ($v in @($Collector)) { if ($null -ne $v) { foreach ($p in ($v -split ',')) { $p.Trim() } } })
    $names = @($Known | Where-Object { $requested -contains $_ })
    if ($names.Count -eq 0) { $names = $Known }
    $lines = New-Object -TypeName System.Collections.Generic.List[string]
    $lines.Add('# HELP veeam_exporter_collector_success 1 last collector run ok, 0 failure')
    $lines.Add('# TYPE veeam_exporter_collector_success gauge')
    foreach ($n in $names) { $lines.Add(('veeam_exporter_collector_success{{collector="{0}"}} 0' -f $n)) }
    $lines.Add('# HELP veeam_exporter_collector_duration_seconds Collector duration in seconds')
    $lines.Add('# TYPE veeam_exporter_collector_duration_seconds gauge')
    foreach ($n in $names) { $lines.Add(('veeam_exporter_collector_duration_seconds{{collector="{0}"}} 0' -f $n)) }
    return (($lines.ToArray() -join "`n") + "`n")
}
