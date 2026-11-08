function ConvertTo-VeeamQueryString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][System.Collections.IDictionary]$Query
    )
    if ($null -eq $Query -or $Query.Count -eq 0) { return '' }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $parts = foreach ($key in $Query.Keys) {
        $value = $Query[$key]
        if ($null -eq $value) { continue }
        '{0}={1}' -f [uri]::EscapeDataString([string]$key), [uri]::EscapeDataString([System.Convert]::ToString($value, $inv))
    }
    return ($parts -join '&')
}

function New-VeeamHttpContext {
    # Connection settings plus, under PowerShell 7, the HttpClient with the
    # pinning handler. Holds no credentials.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BaseUri,
        [AllowNull()][AllowEmptyString()][string]$CertificateThumbprint,
        [int]$TimeoutSec = 60
    )
    # The password is sent to this URI: TLS only.
    $parsed = $null
    if (-not [uri]::TryCreate($BaseUri, [System.UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -ne 'https') {
        throw "BaseUri must be an absolute https:// URI, got '$BaseUri'."
    }
    Initialize-VeeamTransportSecurity -CertificateThumbprint $CertificateThumbprint

    $client = $null
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $handler = New-Object -TypeName System.Net.Http.HttpClientHandler
        $handler.SslProtocols = [System.Security.Authentication.SslProtocols]::Tls12 -bor [System.Security.Authentication.SslProtocols]::Tls13
        # Never follow redirects: a 3xx answer counts as an error.
        $handler.AllowAutoRedirect = $false
        if ($CertificateThumbprint) {
            Initialize-VeeamCertificatePinType
            $handler.ServerCertificateCustomValidationCallback = [VeeamExporter.CertificatePinHandler]::Create($CertificateThumbprint)
        }
        $client = New-Object -TypeName System.Net.Http.HttpClient -ArgumentList $handler, $true
        $client.Timeout = [timespan]::FromSeconds($TimeoutSec)
    }

    return [pscustomobject]@{
        PSTypeName   = 'VeeamExporter.HttpContext'
        BaseUri      = $BaseUri.TrimEnd('/')
        TimeoutSec   = $TimeoutSec
        HttpClient   = $client
        ApiVersion   = $null
        AccessToken  = $null
        RefreshToken = $null
    }
}

function Assert-VeeamReadOnlyRequest {
    # Hard rule: GET only, plus POST to the OAuth2 token and logout endpoints.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path
    )
    if ($Method -ceq 'GET') { return }
    if ($Method -ceq 'POST' -and $script:VeeamAllowedPostPaths -contains $Path) { return }
    throw "Blocked request: $Method $Path. The exporter is read-only."
}

function Invoke-VeeamHttpRequest {
    # Single transport function (mocked in tests). Returns StatusCode and
    # Content for every HTTP answer; throws only on transport errors
    # (connection, TLS, timeout). Never puts the form body into messages.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [System.Collections.IDictionary]$Query,
        [System.Collections.IDictionary]$Headers,
        [System.Collections.IDictionary]$FormBody
    )
    Assert-VeeamReadOnlyRequest -Method $Method -Path $Path

    $uri = $Context.BaseUri + $Path
    $queryString = ConvertTo-VeeamQueryString -Query $Query
    if ($queryString) { $uri = $uri + '?' + $queryString }
    $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

    if ($null -ne $Context.HttpClient) {
        $request = New-Object -TypeName System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::new($Method)), $uri
        try {
            if ($Headers) {
                foreach ($key in $Headers.Keys) {
                    [void]$request.Headers.TryAddWithoutValidation([string]$key, [string]$Headers[$key])
                }
            }
            if ($FormBody) {
                $pairs = New-Object -TypeName 'System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]'
                foreach ($key in $FormBody.Keys) {
                    $pairs.Add((New-Object -TypeName 'System.Collections.Generic.KeyValuePair[string,string]' -ArgumentList ([string]$key), ([string]$FormBody[$key])))
                }
                $request.Content = New-Object -TypeName System.Net.Http.FormUrlEncodedContent -ArgumentList (, $pairs)
            }
            $response = $Context.HttpClient.SendAsync($request).GetAwaiter().GetResult()
            try {
                $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                return [pscustomobject]@{
                    StatusCode = [int]$response.StatusCode
                    Content    = $utf8.GetString($bytes)
                }
            }
            finally {
                $response.Dispose()
            }
        }
        finally {
            $request.Dispose()
        }
    }

    # Windows PowerShell 5.1
    $params = @{
        Uri                = $uri
        Method             = $Method
        UseBasicParsing    = $true
        TimeoutSec         = $Context.TimeoutSec
        # Never follow redirects: a 3xx answer counts as an error.
        MaximumRedirection = 0
        ErrorAction        = 'Stop'
    }
    if ($Headers) {
        $h = @{}
        foreach ($key in $Headers.Keys) { $h[[string]$key] = [string]$Headers[$key] }
        $params.Headers = $h
    }
    if ($FormBody) {
        $params.Body = ConvertTo-VeeamQueryString -Query $FormBody
        $params.ContentType = 'application/x-www-form-urlencoded'
    }
    try {
        $r = Invoke-WebRequest @params
        # JSON is UTF-8 (RFC 8259); decode the raw bytes so umlauts survive.
        return [pscustomobject]@{
            StatusCode = [int]$r.StatusCode
            Content    = $utf8.GetString($r.RawContentStream.ToArray())
        }
    }
    catch [System.Net.WebException] {
        $webResponse = $_.Exception.Response
        if ($null -eq $webResponse) { throw }
        $errorDetails = $null
        if ($_.ErrorDetails) { $errorDetails = $_.ErrorDetails.Message }
        return [pscustomobject]@{
            StatusCode = [int]$webResponse.StatusCode
            Content    = (Read-VeeamErrorResponseBody -Stream $webResponse.GetResponseStream() -ErrorDetailsMessage $errorDetails)
        }
    }
}

function Read-VeeamErrorResponseBody {
    # Body of an HTTP error response under Windows PowerShell 5.1. Invoke-WebRequest
    # has already read the response stream (into ErrorDetails), so the stream is at
    # its end and reading it again returns an empty string (lab test, VBR 13.1).
    # Rewind it and decode as UTF-8; fall back to ErrorDetails if that gives nothing.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][System.IO.Stream]$Stream,
        [AllowNull()][AllowEmptyString()][string]$ErrorDetailsMessage
    )
    $content = ''
    if ($null -ne $Stream) {
        if ($Stream.CanSeek) { $Stream.Position = 0 }
        $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
        $reader = New-Object -TypeName System.IO.StreamReader -ArgumentList $Stream, $utf8
        try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    if (-not $content -and $ErrorDetailsMessage) { $content = $ErrorDetailsMessage }
    return $content
}

function Get-VeeamErrorText {
    # Short error description from a Veeam or OAuth2 error body (max 200 chars).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$Content
    )
    if (-not $Content) { return '' }
    $text = $null
    try {
        $json = $Content | ConvertFrom-Json
        $parts = @()
        foreach ($name in @('errorCode', 'message', 'error', 'error_description')) {
            $v = Get-VeeamField -InputObject $json -Name $name
            if ($v) { $parts += [string]$v }
        }
        if ($parts.Count -gt 0) { $text = $parts -join ': ' }
    }
    catch {
        $text = $null
    }
    if (-not $text) { $text = $Content }
    $text = ($text -replace '\s+', ' ').Trim()
    if ($text.Length -gt 200) { $text = $text.Substring(0, 200) }
    return $text
}
