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

function ConvertTo-VeeamDateTimeOffset {
    # Converts an API timestamp (ISO 8601 string, DateTime or DateTimeOffset)
    # to a DateTimeOffset. Returns $null for empty input.
    # PowerShell 7 ConvertFrom-Json already turns ISO strings into DateTime:
    # Utc for "Z", Local for an explicit offset, Unspecified without offset.
    [CmdletBinding()]
    [OutputType([System.DateTimeOffset])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][object]$Value
    )
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.DateTimeOffset]) {
        if ($Value.Year -le 1 -or $Value.Year -ge 9999) { return $null }
        return $Value
    }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Value -is [datetime]) {
        $dt = $Value
    }
    else {
        $text = ([string]$Value).Trim()
        if ($text.Length -eq 0) { return $null }
        # DateTime.MinValue/MaxValue as "not set" (e.g. endTime of a running
        # task, expiration of a perpetual license, docs/metrics.md#OP-3).
        if ($text.StartsWith('0001-01-01') -or $text.StartsWith('9999-12-31')) { return $null }
        if ($text -match '(?i)(z|[+-][0-9]{2}:?[0-9]{2})$') {
            $parsedOffset = [System.DateTimeOffset]::MinValue
            if (-not [System.DateTimeOffset]::TryParse($text, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$parsedOffset)) {
                throw "Invalid timestamp: '$text'"
            }
            return $parsedOffset
        }
        $dt = [datetime]::MinValue
        if (-not [datetime]::TryParse($text, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
            throw "Invalid timestamp: '$text'"
        }
    }

    if ($dt.Year -le 1 -or $dt.Year -ge 9999) { return $null }
    if ($dt.Kind -ne [System.DateTimeKind]::Unspecified) {
        return (New-Object -TypeName System.DateTimeOffset -ArgumentList $dt.ToUniversalTime())
    }
    # ANNAHME: no offset means local time of the VBR server, see docs/metrics.md#OP-9
    $offset = $script:VeeamTimeZone.GetUtcOffset($dt)
    return (New-Object -TypeName System.DateTimeOffset -ArgumentList $dt, $offset)
}

function ConvertTo-UnixTimestamp {
    # API timestamp -> whole Unix seconds. Returns $null for empty input.
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][object]$Value
    )
    $dto = ConvertTo-VeeamDateTimeOffset -Value $Value
    if ($null -eq $dto) { return $null }
    return [int64]$dto.ToUnixTimeSeconds()
}

function ConvertTo-VeeamFilterTimestamp {
    # DateTimeOffset -> value for createdAfterFilter etc. (UTC, explicit "Z").
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][System.DateTimeOffset]$Value
    )
    return $Value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
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

function Format-VeeamResultMessage {
    # Free-text result message for a label: line breaks and tabs -> space,
    # whitespace runs collapsed, trimmed, cut to MaxLength characters.
    # Escaping happens later in ConvertTo-PromText.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][object]$Message,
        [int]$MaxLength = 200
    )
    if ($null -eq $Message) { return '' }
    $text = ([string]$Message) -replace '\s+', ' '
    $text = $text.Trim()
    if ($text.Length -gt $MaxLength) {
        $cut = $MaxLength
        # Never split a surrogate pair.
        if ([char]::IsHighSurrogate($text[$cut - 1])) { $cut-- }
        $text = $text.Substring(0, $cut).TrimEnd()
    }
    return $text
}

function ConvertTo-VeeamBool {
    # Boolean field that may also arrive as a string ("true"/"false"), as in
    # the 1.3-rev0 doc example. [bool]'false' would be $true in PowerShell.
    # Returns $true, $false or $null (missing / not readable).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][object]$Value
    )
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        switch -Regex ($Value.Trim()) {
            '^(?i)(true|1)$' { return $true }
            '^(?i)(false|0)$' { return $false }
        }
        return $null
    }
    try { return ([System.Convert]::ToDouble($Value, [System.Globalization.CultureInfo]::InvariantCulture) -ne 0) }
    catch { return $null }
}

function ConvertTo-VeeamByteCount {
    # GB value from the API -> whole bytes.
    # ANNAHME: GB means GiB (1024^3), see docs/metrics.md#OP-5
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][object]$GB
    )
    if ($null -eq $GB) { return $null }
    if ($GB -is [string] -and $GB.Trim().Length -eq 0) { return $null }
    $value = [System.Convert]::ToDouble($GB, [System.Globalization.CultureInfo]::InvariantCulture)
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { return $null }
    return [int64][math]::Round($value * 1073741824.0, [System.MidpointRounding]::AwayFromZero)
}

function ConvertTo-VeeamCount {
    # Whole numbers as int64 ("1000", not "1000.0"), fractions stay double.
    [CmdletBinding()]
    [OutputType([long], [double])]
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    $d = [double]$Value
    if ([math]::Floor($d) -eq $d) { return [int64]$d }
    return $d
}
