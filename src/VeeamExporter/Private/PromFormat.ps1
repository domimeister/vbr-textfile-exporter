function Test-PromName {
    # Metric and label names: [a-zA-Z_:][a-zA-Z0-9_:]* (labels without ':').
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name,
        [switch]$Label
    )
    if ($Label) {
        return ($Name -cmatch '^[a-zA-Z_][a-zA-Z0-9_]*$') -and -not $Name.StartsWith('__')
    }
    return $Name -cmatch '^[a-zA-Z_:][a-zA-Z0-9_:]*$'
}

function ConvertTo-PromLabelValue {
    # Escapes a label value: \ -> \\, " -> \", line break -> \n.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][object]$Value
    )
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    $text = $text.Replace('\', '\\')
    $text = $text.Replace('"', '\"')
    $text = $text.Replace("`r`n", '\n')
    $text = $text.Replace("`r", '\n')
    $text = $text.Replace("`n", '\n')
    return $text
}

function ConvertTo-PromHelpText {
    # Escapes HELP text: \ -> \\, line break -> \n.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $result = $Text.Replace('\', '\\')
    $result = $result.Replace("`r`n", '\n')
    $result = $result.Replace("`r", '\n')
    $result = $result.Replace("`n", '\n')
    return $result
}

function Format-PromValue {
    # Formats a sample value culture-invariant (never "1,5").
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value
    )
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($null -eq $Value) {
        throw 'Sample value must not be null.'
    }
    if ($Value -is [bool]) {
        if ($Value) { return '1' }
        return '0'
    }
    $integerTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    foreach ($t in $integerTypes) {
        if ($Value -is $t) {
            return ([System.Convert]::ToString($Value, $inv))
        }
    }
    $d = [System.Convert]::ToDouble($Value, $inv)
    if ([double]::IsNaN($d)) { return 'NaN' }
    if ([double]::IsPositiveInfinity($d)) { return '+Inf' }
    if ([double]::IsNegativeInfinity($d)) { return '-Inf' }
    return $d.ToString('R', $inv)
}
