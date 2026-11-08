<#
.SYNOPSIS
Installs or updates the Veeam exporter on this VBR server (run as Administrator).
.DESCRIPTION
Copies the exporter to C:\Program Files\VeeamExporter, stores the Veeam
credential for SYSTEM (DPAPI) in C:\ProgramData\VeeamExporter, registers the
scheduled tasks "\VeeamExporter\Veeam Exporter REST" (every 15 minutes) and
"\VeeamExporter\Veeam Exporter License" (daily) and runs both once.
Re-running it updates files and tasks and keeps the credential.
See deploy\README.md.
.PARAMETER CertificateThumbprint
SHA-1 thumbprint of the VBR REST certificate. Without it, the certificate of
localhost:9419 is read and shown for confirmation.
.PARAMETER AllowUnsafeTextfileDirectory
Only warn (instead of aborting) when other accounts may write to the
textfile directory of the windows_exporter.
.PARAMETER Credential
Veeam account for the REST API (role Backup Viewer). Asked for when the
credential file is missing or -UpdateCredential is set.
.EXAMPLE
.\Install-VeeamExporter.ps1
.EXAMPLE
.\Install-VeeamExporter.ps1 -UpdateCredential
.EXAMPLE
.\Install-VeeamExporter.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$InstallPath,
    [string]$DataPath,
    [string]$TextfileDirectory,
    [string]$CertificateThumbprint,
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$UpdateCredential,
    [string]$VeeamModule,
    [switch]$SkipLicenseTask,
    [ValidateRange(5, 60)][int]$RestIntervalMinutes = 15,
    [string]$LicenseTime = '06:17',
    [string[]]$Collector = @('jobs', 'objects', 'repositories'),
    [ValidateRange(1, 90)][int]$ObjectLookbackDays = 8,
    [switch]$NoStart,
    [switch]$Force,
    [switch]$AllowUnsafeTextfileDirectory
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'VeeamExporterDeploy.psm1') -Force

$params = @{} + $PSBoundParameters
$params.SourceRoot = Split-Path -Parent $PSScriptRoot
Install-VeeamExporter @params
