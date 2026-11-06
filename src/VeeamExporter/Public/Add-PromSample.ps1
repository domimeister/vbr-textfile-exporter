function Add-PromSample {
    <#
    .SYNOPSIS
    Adds a sample to a metric. Label order follows the (ordered) dictionary.
    A $null value adds nothing, so optional API fields simply produce no series.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Metric,
        [System.Collections.IDictionary]$Labels,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value
    )
    if ($null -eq $Value) { return }
    $copy = [ordered]@{}
    if ($Labels) {
        foreach ($key in $Labels.Keys) {
            $name = [string]$key
            if (-not (Test-PromName -Name $name -Label)) { throw "Invalid label name '$name' on $($Metric.Name)." }
            if ($name -ceq 'job' -or $name -ceq 'instance') { throw "Label '$name' is reserved for Prometheus (use job_name)." }
            $copy[$name] = $Labels[$key]
        }
    }
    $Metric.Samples.Add([pscustomobject]@{ Labels = $copy; Value = $Value })
}
