<#
.SYNOPSIS
Veeam exporter for the windows_exporter textfile collector (REST collectors).
.DESCRIPTION
Runs as a scheduled task on the VBR server, reads the local REST API
(read-only) and writes veeam_<collector>.prom plus veeam_exporter.prom into
the textfile directory. Exit code 0 when every collector succeeded, else 1.
.PARAMETER CredentialPath
Clixml file with the PSCredential of the Veeam user, created by the task
account itself (DPAPI): Get-Credential | Export-Clixml -LiteralPath <file>
.PARAMETER Collector
Collectors to run, also as comma list ("jobs,objects") for powershell.exe -File.
.PARAMETER LogPath
Optional: transcript of the last run (overwritten each run). Contains no secrets.
.PARAMETER ObjectLookbackDays
How far back the objects collector reads task sessions (default 8 days, 1 to 90).
.PARAMETER ObjectSessionType
Session types for the objects collector (default BackupJob, ReplicaJob).
.PARAMETER TimeoutSec
Timeout per HTTP request in seconds (default 60, 1 to 600).
.PARAMETER CertificateThumbprint
SHA-1 thumbprint of the local VBR REST certificate. Only this certificate is
accepted. Without it the default certificate validation applies.
.EXAMPLE
.\Invoke-VeeamExporter.ps1 -CredentialPath C:\ProgramData\VeeamExporter\veeam.cred.xml -CertificateThumbprint 'AB12...'
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredentialPath', Justification = 'Path to a DPAPI-protected Clixml file, not a password.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CredentialPath,
    [string]$TextfileDirectory = 'C:\Program Files\windows_exporter\textfile_inputs',
    [string]$BaseUri = 'https://localhost:9419',
    [string]$CertificateThumbprint,
    [string]$ApiVersion,
    [string[]]$Collector = @('jobs', 'objects', 'repositories'),
    # The ranges of ObjectLookbackDays and TimeoutSec are checked by the run,
    # so a bad task argument still writes veeam_exporter.prom.
    [int]$ObjectLookbackDays = 8,
    [string[]]$ObjectSessionType = @('BackupJob', 'ReplicaJob'),
    [int]$TimeoutSec = 60,
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
    # The run reads the credential itself, so a credential that cannot be read
    # still ends with veeam_exporter.prom (all collectors 0).
    $result = Invoke-VeeamExporterRun -TextfileDirectory $TextfileDirectory -CredentialPath $CredentialPath `
        -BaseUri $BaseUri -CertificateThumbprint $CertificateThumbprint -ApiVersion $ApiVersion `
        -Collector $Collector -ObjectLookbackDays $ObjectLookbackDays -ObjectSessionType $ObjectSessionType `
        -TimeoutSec $TimeoutSec
    if ($result.Success) { $exitCode = 0 }
}
catch {
    Write-Error -Message ('Veeam exporter aborted: {0}' -f $_.Exception.Message) -ErrorAction Continue
}

if (-not $moduleLoaded) {
    # Without the module: still replace the health file, every collector 0.
    try {
        . (Join-Path -Path (Join-Path -Path $moduleRoot -ChildPath 'Private') -ChildPath 'FallbackHealth.ps1')
        . (Join-Path -Path (Join-Path -Path $moduleRoot -ChildPath 'Public') -ChildPath 'Write-PromFile.ps1')
        Write-PromFile -Directory $TextfileDirectory -Name 'veeam_exporter.prom' `
            -Content (Format-VeeamFailedHealthText -Collector $Collector -Known @('jobs', 'objects', 'repositories'))
    }
    catch { Write-Warning ('Writing veeam_exporter.prom without the module failed: {0}' -f $_.Exception.Message) }
}

if ($transcript) { try { $null = Stop-Transcript } catch { Write-Verbose 'Stop-Transcript failed.' } }
exit $exitCode
