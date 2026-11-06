# Thin wrappers around the Veeam PowerShell module (mocked in tests).
# Read-only: only Get-VBRServerSession, Connect-VBRServer, Disconnect-VBRServer
# and Get-VBRInstalledLicense are allowed; tests/Source.Tests.ps1 checks that.

function Import-VeeamBackupModule {
    [CmdletBinding()]
    param(
        [string]$Name = 'Veeam.Backup.PowerShell'
    )
    if (Get-Command -Name 'Get-VBRInstalledLicense' -ErrorAction SilentlyContinue) { return }
    try {
        Import-Module -Name $Name -DisableNameChecking -Global -ErrorAction Stop
    }
    catch {
        $hint = ''
        if ($PSVersionTable.PSEdition -ne 'Core') { $hint = ' Note: Veeam PowerShell 13 requires PowerShell 7 (pwsh.exe).' }
        throw ('Cannot import module {0}: {1}{2}' -f $Name, $_.Exception.Message, $hint)
    }
}

function Connect-VeeamLocalServer {
    # Connects to the local backup server as the current account unless a
    # session exists. Returns $true when this call opened the session.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $existing = $null
    try { $existing = Get-VBRServerSession -ErrorAction Stop }
    catch { $existing = $null }
    if ($null -ne $existing) { return $false }
    $null = Connect-VBRServer -ErrorAction Stop
    return $true
}

function Disconnect-VeeamLocalServer {
    [CmdletBinding()]
    param()
    $null = Disconnect-VBRServer -ErrorAction Stop
}

function Get-VeeamInstalledLicense {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @(Get-VBRInstalledLicense -ErrorAction Stop)
}
