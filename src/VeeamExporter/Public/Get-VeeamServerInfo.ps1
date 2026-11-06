function Get-VeeamServerInfo {
    <#
    .SYNOPSIS
    GET /api/v1/serverInfo (VBR build version for veeam_exporter_info).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Session
    )
    return (Invoke-VeeamRestGet -Session $Session -Path '/api/v1/serverInfo')
}
