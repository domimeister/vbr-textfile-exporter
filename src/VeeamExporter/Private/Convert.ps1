function Get-VeeamField {
    # Returns a property of a JSON object or $null when it does not exist.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $InputObject) { return $null }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function ConvertTo-UnixTimestamp {
    # Converts an API timestamp (ISO 8601 string, DateTime or DateTimeOffset)
    # to whole Unix seconds. Returns $null for empty input.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][object]$Value
    )
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.DateTimeOffset]) {
        return [int64]$Value.ToUnixTimeSeconds()
    }
    if ($Value -is [datetime]) {
        # PowerShell 7 ConvertFrom-Json turns ISO strings into DateTime.
        # ANNAHME: Unspecified kind is UTC, see docs/metrics.md#OP-9
        $dt = $Value
        if ($dt.Kind -eq [System.DateTimeKind]::Unspecified) {
            $dt = [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Utc)
        }
        return [int64]([System.DateTimeOffset]$dt.ToUniversalTime()).ToUnixTimeSeconds()
    }
    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) { return $null }
    # ANNAHME: strings without offset are UTC, see docs/metrics.md#OP-9
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
    $parsed = [System.DateTimeOffset]::MinValue
    if (-not [System.DateTimeOffset]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        throw "Invalid timestamp: '$text'"
    }
    return [int64]$parsed.ToUnixTimeSeconds()
}

function ConvertTo-VeeamResultCode {
    # Success 0, Warning 1, Failed 2, None -1.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][object]$Result
    )
    if ($null -eq $Result) { return -1 }
    switch -Regex (([string]$Result).Trim()) {
        '^(?i)success$' { return 0 }
        '^(?i)warning$' { return 1 }
        '^(?i)failed$' { return 2 }
        '^(?i)none$' { return -1 }
    }
    # ANNAHME: unknown result values count as None, see docs/metrics.md#OP-8
    return -1
}
