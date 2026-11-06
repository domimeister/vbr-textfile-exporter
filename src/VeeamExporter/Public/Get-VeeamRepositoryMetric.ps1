function Get-VeeamRepositoryMetric {
    <#
    .SYNOPSIS
    Repositories collector: repositories/states plus scaleOutRepositories -> metrics for veeam_repositories.prom.
    .DESCRIPTION
    Follows docs/metrics.md, section "Repositories". Pass -RepositoryState
    and -ScaleOutRepository to build the metrics from already loaded data
    (tests).
    #>
    [CmdletBinding(DefaultParameterSetName = 'Session')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Session')][object]$Session,
        [Parameter(Mandatory = $true, ParameterSetName = 'Data')][AllowEmptyCollection()][object[]]$RepositoryState,
        [Parameter(Mandatory = $true, ParameterSetName = 'Data')][AllowEmptyCollection()][object[]]$ScaleOutRepository
    )
    if ($PSCmdlet.ParameterSetName -eq 'Session') {
        $RepositoryState = @(Get-VeeamPagedItem -Session $Session -Path '/api/v1/backupInfrastructure/repositories/states')
        $ScaleOutRepository = @(Get-VeeamPagedItem -Session $Session -Path '/api/v1/backupInfrastructure/scaleOutRepositories')
    }
    $sobrMap = Get-VeeamSobrMap -ScaleOutRepository @($ScaleOutRepository)

    $capacity = New-PromMetric -Name 'veeam_repository_capacity_bytes' -Help 'Kapazitaet des Repositories in Bytes (GB aus der API mal 1024^3)'
    $free = New-PromMetric -Name 'veeam_repository_free_bytes' -Help 'Freier Platz im Repository in Bytes'
    $backup = New-PromMetric -Name 'veeam_repository_backup_bytes' -Help 'Von Backup-Dateien belegter Platz in Bytes (nicht fuer den Fuellgrad verwenden)'
    $online = New-PromMetric -Name 'veeam_repository_online' -Help '1 Repository online, 0 offline'
    $outOfDate = New-PromMetric -Name 'veeam_repository_out_of_date' -Help '1 wenn Komponenten des Repositories veraltet sind'

    foreach ($state in $RepositoryState) {
        $name = [string](Get-VeeamField -InputObject $state -Name 'name')
        $labels = [ordered]@{
            repository      = $name
            repository_type = [string](Get-VeeamField -InputObject $state -Name 'type')
            host            = [string](Get-VeeamField -InputObject $state -Name 'hostName')
            sobr            = (Get-VeeamRepositorySobrName -State $state -SobrMap $sobrMap)
        }
        Add-PromSample -Metric $capacity -Labels $labels -Value (ConvertTo-VeeamByteCount -GB (Get-VeeamField -InputObject $state -Name 'capacityGB'))
        Add-PromSample -Metric $free -Labels $labels -Value (ConvertTo-VeeamByteCount -GB (Get-VeeamField -InputObject $state -Name 'freeGB'))
        Add-PromSample -Metric $backup -Labels $labels -Value (ConvertTo-VeeamByteCount -GB (Get-VeeamField -InputObject $state -Name 'usedSpaceGB'))

        $isOnline = ConvertTo-VeeamBool -Value (Get-VeeamField -InputObject $state -Name 'isOnline')
        if ($null -ne $isOnline) { Add-PromSample -Metric $online -Labels ([ordered]@{ repository = $name }) -Value ([int]$isOnline) }
        # isOutOfDate exists from 1.3 on; under 1.2-rev1 the series is missing.
        $isOutOfDate = ConvertTo-VeeamBool -Value (Get-VeeamField -InputObject $state -Name 'isOutOfDate')
        if ($null -ne $isOutOfDate) { Add-PromSample -Metric $outOfDate -Labels ([ordered]@{ repository = $name }) -Value ([int]$isOutOfDate) }
    }

    return @($capacity, $free, $backup, $online, $outOfDate)
}
