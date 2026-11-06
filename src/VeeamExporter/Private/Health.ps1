function New-VeeamCollectorHealthMetric {
    <#
    veeam_exporter_collector_success and _duration_seconds for a list of
    collector results (Collector, Success, DurationSeconds). Both tasks use
    this function, so HELP and label names are identical in
    veeam_exporter.prom and veeam_exporter_license.prom (the windows_exporter
    needs that when a metric appears in more than one file).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates in-memory objects only.')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Result
    )
    $success = New-PromMetric -Name 'veeam_exporter_collector_success' -Help '1 last collector run ok, 0 failure'
    $duration = New-PromMetric -Name 'veeam_exporter_collector_duration_seconds' -Help 'Collector duration in seconds'
    foreach ($r in $Result) {
        Add-PromSample -Metric $success -Labels ([ordered]@{ collector = $r.Collector }) -Value ([int][bool]$r.Success)
        Add-PromSample -Metric $duration -Labels ([ordered]@{ collector = $r.Collector }) -Value ([double]$r.DurationSeconds)
    }
    return @($success, $duration)
}
