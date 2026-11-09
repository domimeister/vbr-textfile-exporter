function Test-VeeamSuccessStatus {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][int]$StatusCode)
    return ($StatusCode -ge 200 -and $StatusCode -lt 300)
}

function Test-VeeamUnsupportedApiVersion {
    # An unsupported x-api-version is answered with HTTP 400 and an error text
    # mentioning the API version (confirmed with VBR 13.1, docs/metrics.md#OP-7).
    # Everything else (wrong password = 401, 403, 5xx) stops the probe
    # immediately, so a wrong password is never tried once per version.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][object]$Response)
    if ($Response.StatusCode -ne 400) { return $false }
    $text = [string]$Response.Content
    if ($text -match '(?i)invalid_grant|invalid_client|unauthori[sz]ed|password|credential') { return $false }
    return ($text -match '(?i)version')
}

function Invoke-VeeamRestGet {
    # Authenticated GET, returns the parsed JSON body.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][string]$Path,
        [System.Collections.IDictionary]$Query
    )
    if (-not $Session.AccessToken) { throw 'Not connected: no access token.' }
    $headers = [ordered]@{
        'x-api-version' = $Session.ApiVersion
        'Accept'        = 'application/json'
        'Authorization' = 'Bearer ' + $Session.AccessToken
    }
    $response = Invoke-VeeamHttpRequest -Context $Session -Method GET -Path $Path -Query $Query -Headers $headers
    if (-not (Test-VeeamSuccessStatus -StatusCode $response.StatusCode)) {
        throw ('GET {0} failed: HTTP {1} {2}' -f $Path, $response.StatusCode, (Get-VeeamErrorText -Content $response.Content))
    }
    if (-not $response.Content) { return $null }
    return ($response.Content | ConvertFrom-Json)
}

function Get-VeeamPagedItem {
    # Reads all pages via skip/limit and returns the combined data items.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [Parameter(Mandatory = $true)][string]$Path,
        [System.Collections.IDictionary]$Query,
        [ValidateRange(1, 10000)][int]$PageSize = $script:VeeamDefaultPageSize,
        [int]$MaxPages = 10000
    )
    $items = New-Object -TypeName System.Collections.Generic.List[object]
    $skip = 0
    $page = 0
    while ($true) {
        $page++
        if ($page -gt $MaxPages) { throw "Paging for $Path exceeded $MaxPages pages." }

        $q = [ordered]@{}
        if ($Query) { foreach ($key in $Query.Keys) { $q[$key] = $Query[$key] } }
        $q['skip'] = $skip
        $q['limit'] = $PageSize

        $body = Invoke-VeeamRestGet -Session $Session -Path $Path -Query $q
        $data = Get-VeeamField -InputObject $body -Name 'data'
        $pageItems = @()
        if ($null -ne $data) { $pageItems = @($data) }
        foreach ($item in $pageItems) { $items.Add($item) }

        $skip += $pageItems.Count
        $total = Get-VeeamField -InputObject (Get-VeeamField -InputObject $body -Name 'pagination') -Name 'total'

        if ($pageItems.Count -eq 0) { break }
        if ($null -ne $total) {
            if ($skip -ge [int64]$total) { break }
        }
        elseif ($pageItems.Count -lt $PageSize) {
            break
        }
    }
    return $items.ToArray()
}

function Get-VeeamJobState {
    # GET /api/v1/jobs/states (all pages), loaded once per session: the jobs
    # and the objects collector both need it in the same run. A failed load
    # is not kept, so the next collector tries again.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Session)
    $cached = $Session.PSObject.Properties['JobStateCache']
    if ($null -ne $cached -and $null -ne $cached.Value) { return $cached.Value }
    $states = @(Get-VeeamPagedItem -Session $Session -Path '/api/v1/jobs/states')
    $Session | Add-Member -NotePropertyName 'JobStateCache' -NotePropertyValue $states -Force
    return $states
}
