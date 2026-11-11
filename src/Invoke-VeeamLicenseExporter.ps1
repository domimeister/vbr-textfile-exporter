<#
.SYNOPSIS
Veeam license exporter for the windows_exporter textfile collector (own task, daily).
.DESCRIPTION
Reads the installed license with Get-VBRInstalledLicense (Veeam PowerShell
module) and writes veeam_license.prom plus veeam_exporter_license.prom into
the textfile directory. Run as SYSTEM or as a local account with the Backup
Administrator role; no stored password. Run with pwsh.exe (PowerShell 7) on a
VBR 13 server with the Veeam console; the Veeam module requires PowerShell 7.
Exit code 0 on success, else 1.
.PARAMETER LogPath
Optional: transcript of the last run (overwritten each run).
.EXAMPLE
pwsh.exe -NoProfile -File .\Invoke-VeeamLicenseExporter.ps1 -TextfileDirectory 'C:\Program Files\windows_exporter\textfile_inputs'
#>
[CmdletBinding()]
param(
    # No default: a run by hand without it would write into the directory
    # the windows_exporter serves.
    [Parameter(Mandatory = $true)][string]$TextfileDirectory,
    [string]$ModuleName = 'Veeam.Backup.PowerShell',
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$exitCode = 1
$transcript = $false
if ($LogPath) {
    try {
        $logDir = Split-Path -Parent $LogPath
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { $null = New-Item -ItemType Directory -Path $logDir }
        $null = Start-Transcript -LiteralPath $LogPath -Force
        $transcript = $true
    }
    catch { Write-Warning ('Cannot start transcript {0}: {1}' -f $LogPath, $_.Exception.Message) }
}

$moduleRoot = Join-Path -Path $PSScriptRoot -ChildPath 'VeeamExporter'
$moduleLoaded = $false
try {
    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'VeeamExporter.psd1') -Force
    $moduleLoaded = $true
    $result = Invoke-VeeamLicenseExporterRun -TextfileDirectory $TextfileDirectory -ModuleName $ModuleName
    if ($result.Success) { $exitCode = 0 }
}
catch {
    Write-Error -Message ('Veeam license exporter aborted: {0}' -f $_.Exception.Message) -ErrorAction Continue
}

if (-not $moduleLoaded) {
    # Without the module: still replace the health file, collector license 0.
    try {
        . (Join-Path -Path (Join-Path -Path $moduleRoot -ChildPath 'Private') -ChildPath 'FallbackHealth.ps1')
        . (Join-Path -Path (Join-Path -Path $moduleRoot -ChildPath 'Public') -ChildPath 'Write-PromFile.ps1')
        Write-PromFile -Directory $TextfileDirectory -Name 'veeam_exporter_license.prom' `
            -Content (Format-VeeamFailedHealthText -Collector @('license') -Known @('license'))
    }
    catch { Write-Warning ('Writing veeam_exporter_license.prom without the module failed: {0}' -f $_.Exception.Message) }
}

if ($transcript) { try { $null = Stop-Transcript } catch { Write-Verbose 'Stop-Transcript failed.' } }
exit $exitCode
