function ConvertTo-PromText {
    <#
    .SYNOPSIS
    Renders metrics in the Prometheus text format (LF, trailing newline).
    .DESCRIPTION
    HELP and TYPE appear exactly once per metric. Metrics without samples are
    omitted. Duplicate metric names or duplicate series throw, because the
    windows_exporter would reject the whole file. No timestamps are written.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Metric
    )
    # Ordinal (case-sensitive) sets: PowerShell hashtables ignore case, but
    # Prometheus names and label values do not.
    $names = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::Ordinal)
    $sb = New-Object -TypeName System.Text.StringBuilder
    foreach ($m in $Metric) {
        if (-not $names.Add($m.Name)) { throw "Metric $($m.Name) defined twice." }
        if ($m.Samples.Count -eq 0) { continue }

        [void]$sb.Append('# HELP ').Append($m.Name).Append(' ').Append((ConvertTo-PromHelpText -Text $m.Help)).Append("`n")
        [void]$sb.Append('# TYPE ').Append($m.Name).Append(' ').Append($m.Type).Append("`n")
        $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::Ordinal)
        foreach ($s in $m.Samples) {
            $labelText = ''
            if ($s.Labels.Count -gt 0) {
                $pairs = foreach ($key in $s.Labels.Keys) {
                    '{0}="{1}"' -f $key, (ConvertTo-PromLabelValue -Value $s.Labels[$key])
                }
                $labelText = '{' + ($pairs -join ',') + '}'
            }
            $series = $m.Name + $labelText
            if (-not $seen.Add($series)) { throw "Duplicate series: $series" }
            [void]$sb.Append($series).Append(' ').Append((Format-PromValue -Value $s.Value)).Append("`n")
        }
    }
    return $sb.ToString()
}
