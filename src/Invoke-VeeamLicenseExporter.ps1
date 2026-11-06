<#
.SYNOPSIS
Veeam license exporter for the windows_exporter textfile collector (own task, daily).
.DESCRIPTION
Reads the installed license with Get-VBRInstalledLicense (Veeam PowerShell
module) and writes veeam_license.prom plus veeam_exporter_license.prom into
the textfile directory. Run as SYSTEM or as a local account with the Backup
Administrator role; no stored password. VBR 13: run with pwsh.exe
(PowerShell 7) on a server with the Veeam console. VBR 12: powershell.exe.
Exit code 0 on success, else 1.
.EXAMPLE
pwsh.exe -NoProfile -File .\Invoke-VeeamLicenseExporter.ps1 -TextfileDirectory 'C:\Program Files\windows_exporter\textfile_inputs'
#>
[CmdletBinding()]
param(
    [string]$TextfileDirectory = 'C:\Program Files\windows_exporter\textfile_inputs',
    [string]$ModuleName = 'Veeam.Backup.PowerShell'
)

$ErrorActionPreference = 'Stop'

try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'VeeamExporter\VeeamExporter.psd1') -Force
    $result = Invoke-VeeamLicenseExporterRun -TextfileDirectory $TextfileDirectory -ModuleName $ModuleName
}
catch {
    Write-Error -Message ('Veeam license exporter aborted: {0}' -f $_.Exception.Message) -ErrorAction Continue
    exit 1
}

if ($result.Success) { exit 0 }
exit 1
