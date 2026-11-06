function Connect-VeeamServer {
    <#
    .SYNOPSIS
    Logs on to the VBR REST API (OAuth2 password grant) and selects the API version.
    .DESCRIPTION
    Tries the supported x-api-version values from highest to lowest on the
    token request and keeps the first one the server accepts. With -ApiVersion
    only that version is used. The returned session holds the tokens; do not
    log or output it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Credential,
        [string]$BaseUri = 'https://localhost:9419',
        [AllowNull()][AllowEmptyString()][string]$CertificateThumbprint,
        [AllowNull()][AllowEmptyString()][string]$ApiVersion,
        [int]$TimeoutSec = 60
    )
    $session = New-VeeamHttpContext -BaseUri $BaseUri -CertificateThumbprint $CertificateThumbprint -TimeoutSec $TimeoutSec

    $candidates = $script:VeeamApiVersions
    if ($ApiVersion) { $candidates = @($ApiVersion) }

    $rejected = @()
    foreach ($version in $candidates) {
        $headers = [ordered]@{
            'x-api-version' = $version
            'Accept'        = 'application/json'
        }
        $form = [ordered]@{
            'grant_type' = 'password'
            'username'   = $Credential.UserName
            'password'   = $Credential.GetNetworkCredential().Password
        }
        $response = Invoke-VeeamHttpRequest -Context $session -Method POST -Path '/api/oauth2/token' -Headers $headers -FormBody $form
        $form = $null

        if (Test-VeeamSuccessStatus -StatusCode $response.StatusCode) {
            $token = $response.Content | ConvertFrom-Json
            $accessToken = Get-VeeamField -InputObject $token -Name 'access_token'
            if (-not $accessToken) { throw 'Token response contains no access_token.' }
            $session.ApiVersion = $version
            $session.AccessToken = $accessToken
            $session.RefreshToken = Get-VeeamField -InputObject $token -Name 'refresh_token'
            Write-Verbose "Connected to $($session.BaseUri) with x-api-version $version."
            return $session
        }

        if ((-not $ApiVersion) -and (Test-VeeamUnsupportedApiVersion -Response $response)) {
            Write-Verbose "x-api-version $version not supported, trying next."
            $rejected += $version
            continue
        }

        throw ('Logon failed (HTTP {0}, x-api-version {1}): {2}' -f $response.StatusCode, $version, (Get-VeeamErrorText -Content $response.Content))
    }
    throw ('Server supports none of the API versions: {0}' -f ($rejected -join ', '))
}
