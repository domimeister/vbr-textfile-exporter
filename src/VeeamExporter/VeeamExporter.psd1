@{
    RootModule           = 'VeeamExporter.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '6f0c7a52-3a4e-4f4b-9a57-6c1e2d9b8f10'
    Author               = 'domimeister'
    Description          = 'Veeam Backup & Replication exporter for the windows_exporter textfile collector (read-only REST).'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'Connect-VeeamServer'
        'Disconnect-VeeamServer'
        'Get-VeeamServerInfo'
        'Get-VeeamJobMetric'
        'Get-VeeamObjectMetric'
        'Get-VeeamRepositoryMetric'
        'Invoke-VeeamExporterRun'
        'Get-VeeamLicenseMetric'
        'Invoke-VeeamLicenseExporterRun'
        'New-PromMetric'
        'Add-PromSample'
        'ConvertTo-PromText'
        'Write-PromFile'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
