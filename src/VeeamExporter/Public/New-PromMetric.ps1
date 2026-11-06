function New-PromMetric {
    <#
    .SYNOPSIS
    Creates an empty metric family (name, HELP, TYPE) for ConvertTo-PromText.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Help,
        [ValidateSet('gauge', 'counter', 'untyped')][string]$Type = 'gauge'
    )
    if (-not (Test-PromName -Name $Name)) { throw "Invalid metric name: '$Name'" }
    return [pscustomobject]@{
        PSTypeName = 'VeeamExporter.PromMetric'
        Name       = $Name
        Help       = $Help
        Type       = $Type
        Samples    = New-Object -TypeName System.Collections.Generic.List[object]
    }
}
