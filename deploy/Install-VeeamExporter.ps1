<#
.SYNOPSIS
Installs or updates the Veeam exporter on this VBR server (run as Administrator).
.DESCRIPTION
Copies the exporter to C:\Program Files\VeeamExporter, stores the Veeam
credential for SYSTEM (DPAPI) in C:\ProgramData\VeeamExporter, registers the
scheduled tasks "\VeeamExporter\Veeam Exporter REST" (every 15 minutes) and
"\VeeamExporter\Veeam Exporter License" (daily) and runs both once.
Stops before any change unless the windows_exporter service runs with the
textfile collector and the Veeam account can read the REST API.
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
credential file is missing or -UpdateCredential is set. The installation
tries it once against the REST API and stops if that fails.
.PARAMETER WindowsExporterService
Name of the windows_exporter service if it is not windows_exporter and its
executable is not called windows_exporter*.exe.
.PARAMETER SkipWindowsExporterCheck
Install although the windows_exporter service cannot be found or asked for
its textfile collector (only warnings then).
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
    [ValidateRange(5, 30)][int]$RestIntervalMinutes = 15,
    [string]$LicenseTime = '06:17',
    [string[]]$Collector = @('jobs', 'objects', 'repositories'),
    [ValidateRange(1, 90)][int]$ObjectLookbackDays = 8,
    [switch]$NoStart,
    [switch]$Force,
    [switch]$AllowUnsafeTextfileDirectory,
    [string]$WindowsExporterService,
    [switch]$SkipWindowsExporterCheck
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'VeeamExporterDeploy.psm1') -Force

$params = @{} + $PSBoundParameters
$params.SourceRoot = Split-Path -Parent $PSScriptRoot
# Module functions do not inherit this script's preference variables, so the
# installer's messages are shown by passing the common parameter explicitly.
if (-not $params.ContainsKey('InformationAction')) { $params.InformationAction = 'Continue' }
Install-VeeamExporter @params
