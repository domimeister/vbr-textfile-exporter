function Disconnect-VeeamServer {
    <#
    .SYNOPSIS
    Revokes the tokens via POST /api/oauth2/logout and releases the HttpClient.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Session
    )
    try {
        if ($Session.AccessToken) {
            $headers = [ordered]@{
                'x-api-version' = $Session.ApiVersion
                'Accept'        = 'application/json'
                'Authorization' = 'Bearer ' + $Session.AccessToken
            }
            $response = Invoke-VeeamHttpRequest -Context $Session -Method POST -Path '/api/oauth2/logout' -Headers $headers
            if (-not (Test-VeeamSuccessStatus -StatusCode $response.StatusCode)) {
                Write-Warning ('Logout failed: HTTP {0} {1}' -f $response.StatusCode, (Get-VeeamErrorText -Content $response.Content))
            }
        }
    }
    finally {
        $Session.AccessToken = $null
        $Session.RefreshToken = $null
        if ($null -ne $Session.HttpClient) {
            $Session.HttpClient.Dispose()
            $Session.HttpClient = $null
        }
    }
}
