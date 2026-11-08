<#
.SYNOPSIS
Removes the Veeam exporter from this VBR server (run as Administrator).
.DESCRIPTION
Unregisters all tasks under \VeeamExporter\, deletes the exporter's .prom
files from the textfile directory (otherwise the stale-alerts keep firing on
old data), the installation and, unless -KeepData, the credential and logs.
.EXAMPLE
.\Uninstall-VeeamExporter.ps1
.EXAMPLE
.\Uninstall-VeeamExporter.ps1 -KeepData -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$InstallPath,
    [string]$DataPath,
    [string]$TextfileDirectory,
    [switch]$KeepData
)

$ErrorActionPreference = 'Stop'
# Load the deploy module into memory first: the script may run from the
# installation folder that is about to be deleted.
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'VeeamExporterDeploy.psm1') -Force
$params = @{} + $PSBoundParameters
# Module functions do not inherit this script's preference variables, so the
# messages are shown by passing the common parameter explicitly.
if (-not $params.ContainsKey('InformationAction')) { $params.InformationAction = 'Continue' }
Uninstall-VeeamExporter @params
