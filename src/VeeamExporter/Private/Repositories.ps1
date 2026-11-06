function Get-VeeamSobrMap {
    <#
    From GET scaleOutRepositories: SOBR id -> name, and extent repository id
    -> SOBR name (performance, capacity and archive extents). Keys are
    lower-case GUID strings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$ScaleOutRepository
    )
    $byId = New-OrdinalDictionary
    $byExtent = New-OrdinalDictionary
    foreach ($sobr in $ScaleOutRepository) {
        $name = [string](Get-VeeamField -InputObject $sobr -Name 'name')
        if (-not $name) { continue }
        $id = Get-VeeamGuidKey -Value (Get-VeeamField -InputObject $sobr -Name 'id')
        if ($id) { $byId[$id] = $name }

        $extentIds = New-Object -TypeName System.Collections.Generic.List[string]
        $performance = Get-VeeamField -InputObject (Get-VeeamField -InputObject $sobr -Name 'performanceTier') -Name 'performanceExtents'
        foreach ($e in @($performance)) { if ($null -ne $e) { $extentIds.Add((Get-VeeamGuidKey -Value (Get-VeeamField -InputObject $e -Name 'id'))) } }
        $capacity = Get-VeeamField -InputObject (Get-VeeamField -InputObject $sobr -Name 'capacityTier') -Name 'extents'
        foreach ($e in @($capacity)) { if ($null -ne $e) { $extentIds.Add((Get-VeeamGuidKey -Value (Get-VeeamField -InputObject $e -Name 'id'))) } }
        $extentIds.Add((Get-VeeamGuidKey -Value (Get-VeeamField -InputObject (Get-VeeamField -InputObject $sobr -Name 'archiveTier') -Name 'extentId')))

        foreach ($extentId in $extentIds) {
            if ($extentId) { $byExtent[$extentId] = $name }
        }
    }
    return [pscustomobject]@{ ById = $byId; ByExtent = $byExtent }
}

function Get-VeeamRepositorySobrName {
    # SOBR name for one repository state, '' when it is not an extent.
    # 1.3+: scaleOutRepositoryDetails in the state wins (membership as name
    # when the id is unknown); otherwise the extent lists of the SOBRs.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$SobrMap
    )
    $details = Get-VeeamField -InputObject $State -Name 'scaleOutRepositoryDetails'
    if ($null -ne $details) {
        $sobrId = Get-VeeamGuidKey -Value (Get-VeeamField -InputObject $details -Name 'scaleOutRepositoryId')
        if ($sobrId -and $SobrMap.ById.ContainsKey($sobrId)) { return [string]$SobrMap.ById[$sobrId] }
        $membership = [string](Get-VeeamField -InputObject $details -Name 'membership')
        if ($membership) { return $membership }
    }
    $id = Get-VeeamGuidKey -Value (Get-VeeamField -InputObject $State -Name 'id')
    if ($id -and $SobrMap.ByExtent.ContainsKey($id)) { return [string]$SobrMap.ByExtent[$id] }
    return ''
}
