<#
.SYNOPSIS
Internal: runs as SYSTEM in a one-shot task started by Install-VeeamExporter.ps1.
.DESCRIPTION
Reads the transfer file (password protected with DPAPI LocalMachine), writes
the PSCredential with Export-Clixml (DPAPI of SYSTEM) and deletes the
transfer file in every case. Exit code 0 on success, else 1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TransferFile,
    [Parameter(Mandatory = $true)][string]$Path
)

$ErrorActionPreference = 'Stop'
$exitCode = 1
try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'VeeamExporterDeploy.psm1') -Force
    if (-not (Test-VeeamExporterLocalSystem)) { throw 'This script must run as SYSTEM (it is started by Install-VeeamExporter.ps1).' }
    $credential = Read-VeeamExporterTransferFile -Path $TransferFile
    Export-Clixml -InputObject $credential -LiteralPath $Path -Force
    $exitCode = 0
}
catch {
    Write-Error -Message ('Storing the credential failed: {0}' -f $_.Exception.Message) -ErrorAction Continue
}
finally {
    if (Test-Path -LiteralPath $TransferFile) { Remove-Item -LiteralPath $TransferFile -Force -ErrorAction SilentlyContinue }
}
exit $exitCode
