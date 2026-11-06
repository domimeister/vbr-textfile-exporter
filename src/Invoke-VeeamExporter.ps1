<#
.SYNOPSIS
Veeam exporter for the windows_exporter textfile collector (REST collectors).
.DESCRIPTION
Runs as a scheduled task on the VBR server, reads the local REST API
(read-only) and writes veeam_<collector>.prom plus veeam_exporter.prom into
the textfile directory. Exit code 0 when every collector succeeded, else 1.
.PARAMETER CredentialPath
Clixml file with the PSCredential of the Veeam user, created by the task
account itself (DPAPI): Get-Credential | Export-Clixml -Path <file>
.PARAMETER ObjectLookbackDays
How far back the objects collector reads task sessions (default 8 days).
.PARAMETER ObjectSessionType
Session types for the objects collector (default BackupJob, ReplicaJob).
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
    [ValidateSet('jobs', 'objects', 'repositories')][string[]]$Collector = @('jobs', 'objects', 'repositories'),
    [ValidateRange(1, 90)][int]$ObjectLookbackDays = 8,
    [string[]]$ObjectSessionType = @('BackupJob', 'ReplicaJob'),
    [int]$TimeoutSec = 60
)

$ErrorActionPreference = 'Stop'

try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'VeeamExporter\VeeamExporter.psd1') -Force
    $credential = Import-Clixml -LiteralPath $CredentialPath
    if (-not ($credential -is [System.Management.Automation.PSCredential])) {
        throw "$CredentialPath does not contain a PSCredential."
    }

    $result = Invoke-VeeamExporterRun -TextfileDirectory $TextfileDirectory -Credential $credential `
        -BaseUri $BaseUri -CertificateThumbprint $CertificateThumbprint -ApiVersion $ApiVersion `
        -Collector $Collector -ObjectLookbackDays $ObjectLookbackDays -ObjectSessionType $ObjectSessionType `
        -TimeoutSec $TimeoutSec
}
catch {
    Write-Error -Message ('Veeam exporter aborted: {0}' -f $_.Exception.Message) -ErrorAction Continue
    exit 1
}

if ($result.Success) { exit 0 }
exit 1
