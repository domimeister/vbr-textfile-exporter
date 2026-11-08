# Deploy helpers for the Veeam exporter (manual install per VBR server).
# Windows PowerShell 5.1 and PowerShell 7. ASCII only (5.1 reads BOM-less
# files as ANSI). Touches nothing in VBR: no REST call, no Veeam cmdlet.

$ErrorActionPreference = 'Stop'

$script:TaskPath = '\VeeamExporter\'
$script:RestTaskName = 'Veeam Exporter REST'
$script:LicenseTaskName = 'Veeam Exporter License'
$script:CredentialFileName = 'veeam.cred.xml'
$script:PromFiles = @(
    'veeam_jobs.prom', 'veeam_objects.prom', 'veeam_repositories.prom', 'veeam_license.prom',
    'veeam_exporter.prom', 'veeam_exporter_license.prom'
)
$script:SidSystem = 'S-1-5-18'
$script:SidAdministrators = 'S-1-5-32-544'
$script:SidUsers = 'S-1-5-32-545'
$script:SidTrustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
# CREATOR OWNER, OWNER RIGHTS: stand for the owner, which is checked on its own.
$script:SidOwnerPlaceholders = @('S-1-3-0', 'S-1-3-4')
# Rights that let an account change a directory or file: write/append data
# (also: create files and subfolders), delete child, delete, change
# permissions, take ownership, GENERIC_ALL, GENERIC_WRITE.
$script:WriteRightsMask = [int64](0x2 -bor 0x4 -bor 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000)
# Any access at all (data directory: credential and transfer file).
$script:AnyRightsMask = [int64]4294967295

# ---------------------------------------------------------------- accounts --

function Test-VeeamExporterLocalSystem {
    <#
    .SYNOPSIS
    $true when the current process runs as NT AUTHORITY\SYSTEM.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try { return ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq $script:SidSystem) }
    catch { return $false }
}

function Test-VeeamExporterAdministrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList ([System.Security.Principal.WindowsIdentity]::GetCurrent())
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

# --------------------------------------------------------- windows_exporter --

function Get-WindowsExporterTextfileDirectory {
    <#
    Textfile directory from the windows_exporter service command line
    (--collector.textfile.directories, older: --collector.textfile.directory)
    or its config file (collector.textfile.directories). First directory of a
    comma list. Falls back to <exe dir>\textfile_inputs (MSI default).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$ImagePath,
        [AllowNull()][AllowEmptyString()][string]$ConfigText
    )
    $directory = $null
    $source = 'default'
    $argPattern = '--collector\.textfile\.director(?:y|ies)(?:=|\s+)(?:"([^"]*)"|(\S+))'
    if ($ImagePath -and $ImagePath -match $argPattern) {
        $directory = $Matches[1]
        if (-not $directory) { $directory = $Matches[2] }
        $source = 'argument'
    }
    elseif ($ConfigText -and $ConfigText -match '(?m)^\s*director(?:y|ies)\s*:\s*(?:"((?:[^"\\]|\\.)*)"|''([^'']*)''|(\S+))') {
        if ($Matches[1]) { $directory = $Matches[1] -replace '\\\\', '\' }
        elseif ($Matches[2]) { $directory = $Matches[2] }
        else { $directory = $Matches[3] }
        $source = 'config'
    }
    if ($directory) { $directory = ($directory -split ',')[0].Trim() }

    if (-not $directory) {
        $exe = $null
        if ($ImagePath -and $ImagePath -match '^\s*"([^"]+)"') { $exe = $Matches[1] }
        elseif ($ImagePath -and $ImagePath -match '^\s*(\S+)') { $exe = $Matches[1] }
        if ($exe -and $exe.LastIndexOf('\') -gt 0) { $directory = $exe.Substring(0, $exe.LastIndexOf('\')) + '\textfile_inputs' }
        else { $directory = 'C:\Program Files\windows_exporter\textfile_inputs' }
    }

    # Textfile collector enabled? Default set includes it.
    $enabled = $true
    $list = $null
    if ($ImagePath -and $ImagePath -match '--collectors\.enabled(?:=|\s+)(?:"([^"]*)"|(\S+))') {
        $list = $Matches[1]
        if (-not $list) { $list = $Matches[2] }
    }
    elseif ($ConfigText -and $ConfigText -match '(?m)^\s*enabled\s*:\s*"?([^"\r\n]+)"?') {
        $list = $Matches[1]
    }
    if ($list) {
        $names = @($list -split ',' | ForEach-Object { $_.Trim() })
        $enabled = ($names -contains 'textfile') -or ($names -contains '[defaults]')
    }

    return [pscustomobject]@{
        Directory       = $directory.TrimEnd('\')
        Source          = $source
        TextfileEnabled = $enabled
    }
}

function Find-WindowsExporterTextfileDirectory {
    # Reads the windows_exporter service from the registry (Windows only).
    [CmdletBinding()]
    param()
    $imagePath = $null
    $configText = $null
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\windows_exporter'
    if (Test-Path -LiteralPath $key) {
        $imagePath = [string](Get-ItemProperty -LiteralPath $key -Name 'ImagePath' -ErrorAction SilentlyContinue).ImagePath
    }
    if ($imagePath -and $imagePath -match '--config\.file(?:=|\s+)(?:"([^"]*)"|(\S+))') {
        $configFile = $Matches[1]
        if (-not $configFile) { $configFile = $Matches[2] }
        if (Test-Path -LiteralPath $configFile) { $configText = [System.IO.File]::ReadAllText($configFile) }
    }
    $result = Get-WindowsExporterTextfileDirectory -ImagePath $imagePath -ConfigText $configText
    $result | Add-Member -NotePropertyName ServiceFound -NotePropertyValue ([bool]$imagePath)
    return $result
}

# --------------------------------------------------------------- certificate --

$script:CertificateCaptureSource = @'
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

namespace VeeamExporterDeploy
{
    public class CertificateCapture
    {
        public X509Certificate2 Certificate;

        // Setup only: reads the certificate the local REST service presents so
        // the admin can confirm and pin it. Nothing is sent over this
        // connection; the exporter itself accepts only the pinned thumbprint.
        private bool Capture(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors)
        {
            if (certificate != null) { Certificate = new X509Certificate2(certificate); }
            return certificate != null;
        }

        public RemoteCertificateValidationCallback Callback
        {
            get { return new RemoteCertificateValidationCallback(Capture); }
        }
    }
}
'@

function Get-TlsCertificateInfo {
    <#
    .SYNOPSIS
    Thumbprint, subject and expiry of the certificate a TLS service presents
    (default: the VBR REST API on localhost:9419). Used once during setup.
    #>
    [CmdletBinding()]
    param(
        [string]$HostName = 'localhost',
        [int]$Port = 9419,
        [int]$TimeoutSeconds = 10
    )
    if (-not ('VeeamExporterDeploy.CertificateCapture' -as [type])) {
        Add-Type -TypeDefinition $script:CertificateCaptureSource -Language CSharp
    }
    $client = New-Object -TypeName System.Net.Sockets.TcpClient
    try {
        $connect = $client.ConnectAsync($HostName, $Port)
        try {
            if (-not $connect.Wait([timespan]::FromSeconds($TimeoutSeconds))) { throw 'timeout' }
        }
        catch {
            throw ('Cannot connect to {0}:{1}: {2}' -f $HostName, $Port, $_.Exception.GetBaseException().Message)
        }
        $capture = New-Object -TypeName VeeamExporterDeploy.CertificateCapture
        $ssl = New-Object -TypeName System.Net.Security.SslStream -ArgumentList $client.GetStream(), $false, $capture.Callback
        try {
            $ssl.ReadTimeout = $TimeoutSeconds * 1000
            $ssl.WriteTimeout = $TimeoutSeconds * 1000
            $protocols = [System.Security.Authentication.SslProtocols]::Tls12
            if ([enum]::GetNames([System.Security.Authentication.SslProtocols]) -contains 'Tls13') {
                $protocols = $protocols -bor [System.Security.Authentication.SslProtocols]::Tls13
            }
            $ssl.AuthenticateAsClient($HostName, $null, $protocols, $false)
        }
        finally {
            $ssl.Dispose()
        }
        if ($null -eq $capture.Certificate) { throw ('{0}:{1} presented no certificate.' -f $HostName, $Port) }
        return [pscustomobject]@{
            Thumbprint = $capture.Certificate.Thumbprint
            Subject    = $capture.Certificate.Subject
            NotAfter   = $capture.Certificate.NotAfter
        }
    }
    finally {
        $client.Dispose()
    }
}

function Format-CertificateThumbprint {
    # Hex digits only, upper case.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Thumbprint)
    return (($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant())
}

# ---------------------------------------------------- PowerShell / Veeam module --

function Get-VeeamModuleManifestVersion {
    # ModuleVersion from a module manifest (.psd1), $null if it cannot be read.
    [CmdletBinding()]
    [OutputType([version])]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $data = Import-PowerShellDataFile -Path $Path
        if ($data.ModuleVersion) { return [version]$data.ModuleVersion }
    }
    catch {
        Write-Verbose ('Cannot read {0}: {1}' -f $Path, $_.Exception.Message)
    }
    return $null
}

function Find-VeeamPowerShellModule {
    <#
    Veeam.Backup.PowerShell module: path and version. Searches PSModulePath
    and the console folder (VBR 13 console path, confirmed in the lab with 13.1).
    The version always comes from the manifest: Windows PowerShell 5.1 lists the
    VBR 13 module (PowerShellVersion 7.6) with version 0.0.
    #>
    [CmdletBinding()]
    param()
    $paths = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($module in @(Get-Module -ListAvailable -Name 'Veeam.Backup.PowerShell' -ErrorAction SilentlyContinue)) {
        if ($module.Path -like '*.psd1') { $paths.Add($module.Path) }
    }
    if ($env:ProgramFiles) {
        $candidate = Join-Path -Path $env:ProgramFiles -ChildPath 'Veeam\Backup and Replication\Console\Veeam.Backup.PowerShell\Veeam.Backup.PowerShell.psd1'
        if (Test-Path -LiteralPath $candidate) { $paths.Add($candidate) }
    }
    $best = $null
    foreach ($path in @($paths | Select-Object -Unique)) {
        $version = Get-VeeamModuleManifestVersion -Path $path
        if ($null -eq $version) { continue }
        if ($null -eq $best -or $version -gt $best.Version) { $best = [pscustomobject]@{ Module = $path; Version = $version } }
    }
    return $best
}

function Find-PowerShellHost {
    # Paths of powershell.exe (5.1) and pwsh.exe (7), $null when missing.
    [CmdletBinding()]
    param()
    $windowsPowerShell = $null
    if ($env:SystemRoot) {
        $candidate = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $candidate) { $windowsPowerShell = $candidate }
    }
    $pwsh = $null
    if ($env:ProgramFiles) {
        $candidate = Join-Path -Path $env:ProgramFiles -ChildPath 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $candidate) { $pwsh = $candidate }
    }
    if (-not $pwsh) {
        $cmd = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $pwsh = $cmd.Source }
    }
    return [pscustomobject]@{ WindowsPowerShell = $windowsPowerShell; Pwsh = $pwsh }
}

function Resolve-VeeamLicenseHost {
    <#
    PowerShell host for the license task: always PowerShell 7 (pwsh.exe), because the
    Veeam PowerShell module of VBR 13 requires it. A module older than 13 means VBR 12,
    which is not supported. $null as version (module given by name) is accepted.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][version]$ModuleVersion,
        [AllowNull()][AllowEmptyString()][string]$PwshPath
    )
    if ($null -ne $ModuleVersion -and $ModuleVersion.Major -lt 13) {
        throw ('Veeam PowerShell module {0} found. The exporter requires Veeam Backup & Replication 13 or later.' -f $ModuleVersion)
    }
    if (-not $PwshPath) { throw 'The license task needs PowerShell 7 (pwsh.exe), but pwsh.exe was not found. Install PowerShell 7 or pass -SkipLicenseTask.' }
    return $PwshPath
}

# ------------------------------------------------------------ task arguments --

function Join-WindowsPath {
    # Windows path for task arguments (Join-Path would use '/' on Linux test hosts).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$ChildPath)
    return ($Path.TrimEnd('\', '/') + '\' + $ChildPath)
}

function ConvertTo-TaskArgument {
    # Quotes one argument for a Windows command line (CommandLineToArgvW rules:
    # backslashes before a quote and at the end are doubled, quotes escaped).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object -TypeName System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($c in $Value.ToCharArray()) {
        if ($c -eq '\') { $backslashes++; continue }
        if ($c -eq '"') {
            [void]$sb.Append([char]'\', (2 * $backslashes + 1)).Append('"')
        }
        else {
            if ($backslashes -gt 0) { [void]$sb.Append([char]'\', $backslashes) }
            [void]$sb.Append($c)
        }
        $backslashes = 0
    }
    if ($backslashes -gt 0) { [void]$sb.Append([char]'\', (2 * $backslashes)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Join-TaskArgument {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Argument)
    return ((@($Argument) | ForEach-Object { ConvertTo-TaskArgument -Value $_ }) -join ' ')
}

function Get-VeeamExporterTaskDefinition {
    <#
    Definition of one scheduled task (pure data, no system change):
    Rest    every RestIntervalMinutes, Invoke-VeeamExporter.ps1
    License daily at LicenseTime, Invoke-VeeamLicenseExporter.ps1
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Rest', 'License')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$HostPath,
        [Parameter(Mandatory = $true)][string]$InstallPath,
        [Parameter(Mandatory = $true)][string]$DataPath,
        [Parameter(Mandatory = $true)][string]$TextfileDirectory,
        [string]$CertificateThumbprint,
        [string[]]$Collector = @('jobs', 'objects', 'repositories'),
        [int]$ObjectLookbackDays = 8,
        [int]$RestIntervalMinutes = 15,
        [string]$VeeamModule = 'Veeam.Backup.PowerShell',
        [string]$LicenseTime = '06:17'
    )
    $common = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned', '-File')
    $logDir = Join-WindowsPath -Path $DataPath -ChildPath 'logs'
    if ($Kind -eq 'Rest') {
        $arguments = $common + @(
            (Join-WindowsPath -Path $InstallPath -ChildPath 'Invoke-VeeamExporter.ps1'),
            '-CredentialPath', (Join-WindowsPath -Path $DataPath -ChildPath $script:CredentialFileName),
            '-TextfileDirectory', $TextfileDirectory.TrimEnd('\'),
            '-Collector', ((@($Collector) | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ','),
            '-ObjectLookbackDays', [string]$ObjectLookbackDays,
            '-LogPath', (Join-WindowsPath -Path $logDir -ChildPath 'rest.log')
        )
        if ($CertificateThumbprint) { $arguments += @('-CertificateThumbprint', (Format-CertificateThumbprint -Thumbprint $CertificateThumbprint)) }
        return [pscustomobject]@{
            TaskPath           = $script:TaskPath
            TaskName           = $script:RestTaskName
            Description        = 'Veeam REST collectors (jobs, objects, repositories) for the windows_exporter textfile collector. Read-only.'
            Execute            = $HostPath
            Argument           = (Join-TaskArgument -Argument $arguments)
            Trigger            = [pscustomobject]@{ Type = 'Repeat'; IntervalMinutes = $RestIntervalMinutes }
            ExecutionTimeLimit = [timespan]::FromMinutes(10)
        }
    }
    $arguments = $common + @(
        (Join-WindowsPath -Path $InstallPath -ChildPath 'Invoke-VeeamLicenseExporter.ps1'),
        '-TextfileDirectory', $TextfileDirectory.TrimEnd('\'),
        '-ModuleName', $VeeamModule,
        '-LogPath', (Join-WindowsPath -Path $logDir -ChildPath 'license.log')
    )
    return [pscustomobject]@{
        TaskPath           = $script:TaskPath
        TaskName           = $script:LicenseTaskName
        Description        = 'Veeam license (Get-VBRInstalledLicense) for the windows_exporter textfile collector. Read-only.'
        Execute            = $HostPath
        Argument           = (Join-TaskArgument -Argument $arguments)
        Trigger            = [pscustomobject]@{ Type = 'Daily'; At = $LicenseTime }
        ExecutionTimeLimit = [timespan]::FromMinutes(30)
    }
}

# ---------------------------------------------------------- scheduled tasks --

function Register-VeeamExporterTask {
    # Registers (or replaces) a task that runs as SYSTEM.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][object]$Definition)
    $action = New-ScheduledTaskAction -Execute $Definition.Execute -Argument $Definition.Argument
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit $Definition.ExecutionTimeLimit -MultipleInstances IgnoreNew `
        -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $taskParams = @{ Action = $action; Principal = $principal; Settings = $settings; Description = $Definition.Description }
    if ($null -ne $Definition.Trigger) {
        if ($Definition.Trigger.Type -eq 'Repeat') {
            # Start two minutes after midnight, then every n minutes, indefinitely.
            $taskParams.Trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date.AddMinutes(2)) -RepetitionInterval ([timespan]::FromMinutes($Definition.Trigger.IntervalMinutes))
        }
        else {
            $taskParams.Trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($Definition.Trigger.At, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture))
        }
    }
    $task = New-ScheduledTask @taskParams
    if ($PSCmdlet.ShouldProcess(($Definition.TaskPath + $Definition.TaskName), 'Register scheduled task (SYSTEM)')) {
        $null = Register-ScheduledTask -TaskPath $Definition.TaskPath -TaskName $Definition.TaskName -InputObject $task -Force
    }
}

function Wait-VeeamExporterTask {
    # Waits until a started task has finished; returns Get-ScheduledTaskInfo.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskPath,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][datetime]$StartedAt,
        [int]$TimeoutSeconds = 300
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $state = [string](Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName).State
        $info = Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $TaskName
        if ($state -ne 'Running' -and $info.LastRunTime -ge $StartedAt.AddSeconds(-2)) { return $info }
        if ((Get-Date) -gt $deadline) { throw ('Task {0}{1} did not finish within {2} s.' -f $TaskPath, $TaskName, $TimeoutSeconds) }
        Start-Sleep -Seconds 2
    }
}

# --------------------------------------------------------------------- files --

function Copy-VeeamExporterFile {
    <#
    Copies the exporter to InstallPath. SourceRoot is either the repository
    (src\, deploy\) or an existing installation (re-run from InstallPath\deploy).
    Returns the copied paths relative to InstallPath.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$InstallPath
    )
    $repoSrc = Join-Path -Path $SourceRoot -ChildPath 'src'
    if (Test-Path -LiteralPath (Join-Path -Path $repoSrc -ChildPath 'Invoke-VeeamExporter.ps1')) {
        $appRoot = $repoSrc
    }
    elseif (Test-Path -LiteralPath (Join-Path -Path $SourceRoot -ChildPath 'Invoke-VeeamExporter.ps1')) {
        $appRoot = $SourceRoot
    }
    else {
        throw "No exporter found under $SourceRoot (expected src\Invoke-VeeamExporter.ps1)."
    }
    $deploySource = Join-Path -Path $SourceRoot -ChildPath 'deploy'
    $fullSource = [System.IO.Path]::GetFullPath($appRoot).TrimEnd('\', '/')
    $fullTarget = [System.IO.Path]::GetFullPath($InstallPath).TrimEnd('\', '/')
    if ($fullSource -eq $fullTarget) {
        Write-Verbose 'Source is the installation itself, nothing to copy.'
        return [string[]]@()
    }
    if (-not $PSCmdlet.ShouldProcess($InstallPath, 'Copy exporter files')) { return [string[]]@() }

    $copied = New-Object -TypeName System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $InstallPath)) { $null = New-Item -ItemType Directory -Path $InstallPath }
    # Never delete or write through a junction or symbolic link.
    $links = @(Get-VeeamExporterReparsePoint -Path $InstallPath)
    if ($links.Count -gt 0) { throw ("Refusing to copy into {0}: it contains junctions or symbolic links: {1}" -f $InstallPath, ($links -join ', ')) }
    foreach ($name in @('Invoke-VeeamExporter.ps1', 'Invoke-VeeamLicenseExporter.ps1')) {
        Copy-Item -LiteralPath (Join-Path -Path $appRoot -ChildPath $name) -Destination (Join-Path -Path $InstallPath -ChildPath $name) -Force
        $copied.Add($name)
    }
    # Replace the module folder completely, so removed files do not linger.
    $moduleTarget = Join-Path -Path $InstallPath -ChildPath 'VeeamExporter'
    if (Test-Path -LiteralPath $moduleTarget) { Remove-Item -LiteralPath $moduleTarget -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path -Path $appRoot -ChildPath 'VeeamExporter') -Destination $moduleTarget -Recurse -Force
    $moduleRoot = (Resolve-Path -LiteralPath $moduleTarget).ProviderPath
    foreach ($f in Get-ChildItem -LiteralPath $moduleTarget -Recurse -File) {
        $copied.Add('VeeamExporter' + $f.FullName.Substring($moduleRoot.Length).Replace('/', '\'))
    }
    $deployTarget = Join-Path -Path $InstallPath -ChildPath 'deploy'
    if (-not (Test-Path -LiteralPath $deployTarget)) { $null = New-Item -ItemType Directory -Path $deployTarget }
    foreach ($name in @('VeeamExporterDeploy.psm1', 'Install-VeeamExporter.ps1', 'Uninstall-VeeamExporter.ps1', 'Save-VeeamExporterSystemCredential.ps1')) {
        $source = Join-Path -Path $deploySource -ChildPath $name
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path -Path $deployTarget -ChildPath $name) -Force
            $copied.Add('deploy\' + $name)
        }
    }
    # Downloaded archives carry Zone.Identifier; RemoteSigned would block them.
    $onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Test-Path -LiteralPath 'Variable:IsWindows') -and $IsWindows)
    if ($onWindows -and (Get-Command -Name 'Unblock-File' -ErrorAction SilentlyContinue)) {
        Get-ChildItem -LiteralPath $InstallPath -Recurse -File | Unblock-File
    }
    return [string[]]$copied.ToArray()
}

# --------------------------------------------------------------- permissions --
# The tasks run as SYSTEM. Every file they execute, read or write must be out
# of reach of ordinary accounts, otherwise a local user gains SYSTEM rights
# (replaced script, junction/symbolic link) or reads the Veeam password
# (transfer file). C:\ProgramData lets every user create folders, so an
# existing directory is only trusted when its owner is trusted.

function Get-VeeamExporterTrustedSid {
    # SYSTEM, Administrators, TrustedInstaller, the installing account and the
    # direct members of the local Administrators group (an earlier
    # installation by another administrator is owned by that account).
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $sids = @($script:SidSystem, $script:SidAdministrators, $script:SidTrustedInstaller)
    try { $sids += [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    catch { Write-Verbose 'Current user SID not available.' }
    if (Get-Command -Name 'Get-LocalGroupMember' -ErrorAction SilentlyContinue) {
        try { $sids += @(Get-LocalGroupMember -SID $script:SidAdministrators -ErrorAction Stop | ForEach-Object { $_.SID.Value }) }
        catch { Write-Verbose ('Members of Administrators not available: {0}' -f $_.Exception.Message) }
    }
    return [string[]]@($sids | Where-Object { $_ } | Select-Object -Unique)
}

function Format-VeeamExporterSid {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Sid)
    try {
        $name = (New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList $Sid).Translate([System.Security.Principal.NTAccount]).Value
        return ('{0} ({1})' -f $name, $Sid)
    }
    catch { return $Sid }
}

function Test-VeeamExporterReparsePoint {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item)
    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-VeeamExporterTreeItem {
    # The item and everything below it. Never follows junctions or symbolic
    # links (they are returned, but not entered).
    [CmdletBinding()]
    [OutputType([System.IO.FileSystemInfo[]])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $root = Get-Item -LiteralPath $Path -Force
    $items = New-Object -TypeName System.Collections.Generic.List[System.IO.FileSystemInfo]
    $items.Add($root)
    $pending = New-Object -TypeName System.Collections.Generic.Stack[System.IO.FileSystemInfo]
    if ($root.PSIsContainer -and -not (Test-VeeamExporterReparsePoint -Item $root)) { $pending.Push($root) }
    while ($pending.Count -gt 0) {
        $dir = $pending.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $dir.FullName -Force)) {
            $items.Add($child)
            if ($child.PSIsContainer -and -not (Test-VeeamExporterReparsePoint -Item $child)) { $pending.Push($child) }
        }
    }
    return $items.ToArray()
}

function Get-VeeamExporterReparsePoint {
    # Full paths of all junctions and symbolic links in a directory tree.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][string]$Path)
    return [string[]]@(Get-VeeamExporterTreeItem -Path $Path | Where-Object { Test-VeeamExporterReparsePoint -Item $_ } | ForEach-Object { $_.FullName })
}

function Get-VeeamExporterItemSecurity {
    # Owner and access rules of a file or directory, as SIDs (Windows only,
    # mocked in tests). Rights are the raw access mask (generic bits included).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $sidType = [System.Security.Principal.SecurityIdentifier]
    $acl = Get-Acl -LiteralPath $Path
    $rules = foreach ($rule in $acl.GetAccessRules($true, $true, $sidType)) {
        [pscustomobject]@{
            Sid    = $rule.IdentityReference.Value
            Rights = ([int64][int]$rule.FileSystemRights) -band [int64]4294967295
            Allow  = ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow)
        }
    }
    return [pscustomobject]@{ Owner = $acl.GetOwner($sidType).Value; Rules = @($rules) }
}

function Get-VeeamExporterAccessProblem {
    <#
    Problems of one item (pure function): the owner must be trusted, and no
    allow rule of another account may contain a right from RightsMask
    (0: rules are not checked). CREATOR OWNER and OWNER RIGHTS stand for the
    owner, which is checked on its own. Deny rules are ignored (conservative).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][object]$Security,
        [Parameter(Mandatory = $true)][string[]]$TrustedSid,
        [Parameter(Mandatory = $true)][string]$Path,
        [int64]$RightsMask = 0
    )
    $problems = New-Object -TypeName System.Collections.Generic.List[string]
    if ($TrustedSid -notcontains [string]$Security.Owner) {
        $problems.Add(('{0}: owner is {1}' -f $Path, (Format-VeeamExporterSid -Sid ([string]$Security.Owner))))
    }
    if ($RightsMask -ne 0) {
        $reported = @()
        foreach ($rule in @($Security.Rules)) {
            if (-not $rule.Allow) { continue }
            $sid = [string]$rule.Sid
            if ($TrustedSid -contains $sid -or $script:SidOwnerPlaceholders -contains $sid -or $reported -contains $sid) { continue }
            if (([int64]$rule.Rights -band $RightsMask) -ne 0) {
                $problems.Add(('{0}: {1} has access' -f $Path, (Format-VeeamExporterSid -Sid $sid)))
                $reported += $sid
            }
        }
    }
    return [string[]]$problems.ToArray()
}

function Get-VeeamExporterPathProblem {
    <#
    Why a directory tree is not safe for SYSTEM: junctions or symbolic links,
    an owner other than SYSTEM/Administrators/TrustedInstaller/the installing
    account, or rights from RightsMask for any other account.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int64]$RightsMask = 0,
        [switch]$NoRecurse
    )
    $trusted = Get-VeeamExporterTrustedSid
    if ($NoRecurse) { $items = @(Get-Item -LiteralPath $Path -Force) }
    else { $items = @(Get-VeeamExporterTreeItem -Path $Path) }
    $problems = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($item in $items) {
        if (Test-VeeamExporterReparsePoint -Item $item) {
            $problems.Add(('{0}: junction or symbolic link' -f $item.FullName))
            continue
        }
        $security = Get-VeeamExporterItemSecurity -Path $item.FullName
        foreach ($p in (Get-VeeamExporterAccessProblem -Security $security -TrustedSid $trusted -Path $item.FullName -RightsMask $RightsMask)) { $problems.Add($p) }
    }
    return [string[]]$problems.ToArray()
}

function Get-VeeamExporterTextfileProblem {
    <#
    The textfile directory and the exporter's own files in it must not be
    writable by other accounts: SYSTEM writes there (link attacks) and
    Prometheus trusts the content (fake metrics).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][string]$Directory)
    $problems = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($p in (Get-VeeamExporterPathProblem -Path $Directory -RightsMask $script:WriteRightsMask -NoRecurse)) { $problems.Add($p) }
    $names = @($script:PromFiles | ForEach-Object { $_; $_ + '.tmp' })
    foreach ($item in @(Get-ChildItem -LiteralPath $Directory -Force | Where-Object { $names -contains $_.Name })) {
        foreach ($p in (Get-VeeamExporterPathProblem -Path $item.FullName -RightsMask $script:WriteRightsMask -NoRecurse)) { $problems.Add($p) }
    }
    return [string[]]$problems.ToArray()
}

function Get-VeeamExporterDirectoryAclSpec {
    <#
    Target permissions (pure data): owner Administrators, no inheritance from
    the parent, full control for SYSTEM and Administrators. The installation
    is also readable for Users (like C:\Program Files), the data directory
    (credential, transfer file, logs) is not.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Install', 'Data')][string]$Kind)
    $rules = @(
        [pscustomobject]@{ Sid = $script:SidSystem; Rights = 'FullControl' }
        [pscustomobject]@{ Sid = $script:SidAdministrators; Rights = 'FullControl' }
    )
    if ($Kind -eq 'Install') { $rules += [pscustomobject]@{ Sid = $script:SidUsers; Rights = 'ReadAndExecute' } }
    return [pscustomobject]@{ Owner = $script:SidAdministrators; Protected = $true; Rules = $rules }
}

function New-VeeamExporterDirectorySecurity {
    <#
    DirectorySecurity from Get-VeeamExporterDirectoryAclSpec (Windows only).
    -IncludeOwner also sets the owner (Administrators); without it the
    descriptor only carries the protected DACL.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([System.Security.AccessControl.DirectorySecurity])]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Data')][string]$Kind,
        [switch]$IncludeOwner
    )
    $spec = Get-VeeamExporterDirectoryAclSpec -Kind $Kind
    $acl = New-Object -TypeName System.Security.AccessControl.DirectorySecurity
    if ($IncludeOwner) { $acl.SetOwner((New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList $spec.Owner)) }
    $acl.SetAccessRuleProtection($spec.Protected, $false)
    foreach ($r in $spec.Rules) {
        $identity = New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList $r.Sid
        $rule = New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule -ArgumentList $identity,
        ([System.Security.AccessControl.FileSystemRights]$r.Rights),
        ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'),
        ([System.Security.AccessControl.PropagationFlags]::None),
        ([System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    return $acl
}

function Set-VeeamExporterDirectoryAcl {
    # Applies Get-VeeamExporterDirectoryAclSpec incl. owner (Windows only, mocked in tests).
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Data')][string]$Kind
    )
    $acl = New-VeeamExporterDirectorySecurity -Kind $Kind -IncludeOwner
    if ($PSCmdlet.ShouldProcess($Path, 'Set owner and ACL')) { Set-Acl -LiteralPath $Path -AclObject $acl }
}

function New-VeeamExporterSecureDirectoryItem {
    <#
    Creates a directory directly with the protected target DACL, so it never
    has the inherited permissions of its parent (C:\ProgramData lets every
    user create files and folders in new subfolders). The owner is set
    afterwards by Set-VeeamExporterDirectoryAcl. Windows only, mocked in tests.
    If the directory exists already (created by someone in the meantime),
    nothing happens; the owner check in Initialize-VeeamExporterSecureDirectory
    then refuses it.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Data')][string]$Kind
    )
    if (-not $PSCmdlet.ShouldProcess($Path, ('Create directory with protected ACL ({0})' -f $Kind))) { return }
    $security = New-VeeamExporterDirectorySecurity -Kind $Kind
    $overload = [System.IO.Directory].GetMethod('CreateDirectory', [type[]]@([string], [System.Security.AccessControl.DirectorySecurity]))
    if ($null -ne $overload) {
        # .NET Framework (Windows PowerShell 5.1)
        $null = [System.IO.Directory]::CreateDirectory($Path, $security)
    }
    else {
        # .NET (PowerShell 7)
        $null = [System.IO.FileSystemAclExtensions]::Create((New-Object -TypeName System.IO.DirectoryInfo -ArgumentList $Path), $security)
    }
}

function Initialize-VeeamExporterSecureDirectory {
    <#
    Creates the directory (with the protected DACL from the start) or takes
    over an existing one, but only when it and everything in it is owned by a
    trusted account and contains no junction or symbolic link. Then sets
    owner and ACL (Get-VeeamExporterDirectoryAclSpec).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Data')][string]$Kind
    )
    if (-not $PSCmdlet.ShouldProcess($Path, ('Create or secure directory ({0})' -f $Kind))) { return }
    # New directories get the protected DACL at creation, no window with the
    # parent's inherited permissions. A directory someone else creates in the
    # meantime is caught by the owner check below.
    if (-not (Test-Path -LiteralPath $Path)) { New-VeeamExporterSecureDirectoryItem -Path $Path -Kind $Kind -Confirm:$false }
    $problems = @(Get-VeeamExporterPathProblem -Path $Path)
    if ($problems.Count -gt 0) {
        throw ("Refusing to use {0}: it was not created by an administrator (or contains links). Check it, remove it and run the installation again.`n  {1}" -f $Path, ($problems -join "`n  "))
    }
    Set-VeeamExporterDirectoryAcl -Path $Path -Kind $Kind -Confirm:$false
}

function Assert-VeeamExporterDirectorySecure {
    # Final check after setting the ACL and copying files: no other account
    # may write to the installation or access the data directory at all.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Data')][string]$Kind
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $mask = $script:WriteRightsMask
    if ($Kind -eq 'Data') { $mask = $script:AnyRightsMask }
    $problems = @(Get-VeeamExporterPathProblem -Path $Path -RightsMask $mask)
    if ($problems.Count -gt 0) {
        throw ("{0} is not protected:`n  {1}" -f $Path, ($problems -join "`n  "))
    }
}

function Initialize-VeeamExporterDataDirectory {
    <#
    Data directory (credential, logs): access only for SYSTEM and
    Administrators, no inheritance. SIDs, so it works on any language.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not $PSCmdlet.ShouldProcess($Path, 'Create data directory (SYSTEM and Administrators only)')) { return }
    Initialize-VeeamExporterSecureDirectory -Path $Path -Kind Data -Confirm:$false
    $logs = Join-Path -Path $Path -ChildPath 'logs'
    if (-not (Test-Path -LiteralPath $logs)) { $null = New-Item -ItemType Directory -Path $logs }
    Assert-VeeamExporterDirectorySecure -Path $Path -Kind Data
}

# ---------------------------------------------------------------- credential --

function Initialize-ProtectedDataType {
    if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
        Add-Type -AssemblyName System.Security
    }
}

function Write-VeeamExporterTransferFile {
    <#
    Hand-over of the Veeam credential from the admin session to the SYSTEM
    task: password encrypted with DPAPI (LocalMachine scope), file in the data
    directory (SYSTEM and Administrators only), deleted right after use.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Credential
    )
    Initialize-ProtectedDataType
    $plain = [System.Text.Encoding]::UTF8.GetBytes($Credential.GetNetworkCredential().Password)
    try {
        $protected = [System.Security.Cryptography.ProtectedData]::Protect($plain, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    }
    finally {
        [System.Array]::Clear($plain, 0, $plain.Length)
    }
    $json = (New-Object -TypeName PSObject -Property @{
            UserName = $Credential.UserName
            Password = [System.Convert]::ToBase64String($protected)
        }) | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($Path, $json, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
}

function Read-VeeamExporterTransferFile {
    <#
    .SYNOPSIS
    Reads the transfer file written by Write-VeeamExporterTransferFile (DPAPI LocalMachine).
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCredential])]
    param([Parameter(Mandatory = $true)][string]$Path)
    Initialize-ProtectedDataType
    $data = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([System.Convert]::FromBase64String($data.Password), $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    $secure = New-Object -TypeName System.Security.SecureString
    try {
        foreach ($c in [System.Text.Encoding]::UTF8.GetChars($bytes)) { $secure.AppendChar($c) }
    }
    finally {
        [System.Array]::Clear($bytes, 0, $bytes.Length)
    }
    $secure.MakeReadOnly()
    return (New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $data.UserName, $secure)
}

function Save-VeeamExporterCredentialAsSystem {
    <#
    Stores the credential for SYSTEM (DPAPI, Export-Clixml) via a one-shot
    task that runs Save-VeeamExporterSystemCredential.ps1 as SYSTEM. Task and
    transfer file are removed afterwards in every case.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory = $true)][string]$DataPath,
        [Parameter(Mandatory = $true)][string]$WorkerScript,
        [Parameter(Mandatory = $true)][string]$HostPath,
        [int]$TimeoutSeconds = 120
    )
    $credentialPath = Join-Path -Path $DataPath -ChildPath $script:CredentialFileName
    if (-not $PSCmdlet.ShouldProcess($credentialPath, 'Store Veeam credential for SYSTEM (DPAPI)')) { return }

    $id = [guid]::NewGuid().ToString('N')
    $transfer = Join-Path -Path $DataPath -ChildPath ('transfer-{0}.bin' -f $id)
    $definition = [pscustomobject]@{
        TaskPath           = $script:TaskPath
        TaskName           = 'Credential Setup ' + $id
        Description        = 'One-shot: stores the Veeam exporter credential for SYSTEM. Removed after the run.'
        Execute            = $HostPath
        Argument           = (Join-TaskArgument -Argument @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned', '-File', $WorkerScript, '-TransferFile', $transfer, '-Path', $credentialPath))
        Trigger            = $null
        ExecutionTimeLimit = [timespan]::FromMinutes(5)
    }
    $before = $null
    if (Test-Path -LiteralPath $credentialPath) { $before = (Get-Item -LiteralPath $credentialPath).LastWriteTimeUtc }
    try {
        Write-VeeamExporterTransferFile -Path $transfer -Credential $Credential
        Register-VeeamExporterTask -Definition $definition -Confirm:$false
        try {
            $startedAt = Get-Date
            Start-ScheduledTask -TaskPath $definition.TaskPath -TaskName $definition.TaskName
            $info = Wait-VeeamExporterTask -TaskPath $definition.TaskPath -TaskName $definition.TaskName -StartedAt $startedAt -TimeoutSeconds $TimeoutSeconds
            if ($info.LastTaskResult -ne 0) { throw ('Credential task failed with result {0}.' -f $info.LastTaskResult) }
        }
        finally {
            Unregister-ScheduledTask -TaskPath $definition.TaskPath -TaskName $definition.TaskName -Confirm:$false
        }
    }
    finally {
        if (Test-Path -LiteralPath $transfer) { Remove-Item -LiteralPath $transfer -Force }
    }
    if (-not (Test-Path -LiteralPath $credentialPath)) { throw "Credential file was not created: $credentialPath" }
    $after = (Get-Item -LiteralPath $credentialPath).LastWriteTimeUtc
    if ($null -ne $before -and $after -le $before) { throw "Credential file was not updated: $credentialPath" }
}

# ----------------------------------------------------------------- uninstall --

function Remove-VeeamExporterPromFile {
    # Removes only the exporter's own .prom files (and their .tmp files).
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][string]$TextfileDirectory)
    $removed = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($name in $script:PromFiles) {
        foreach ($candidate in @($name, ($name + '.tmp'))) {
            $path = Join-Path -Path $TextfileDirectory -ChildPath $candidate
            if (Test-Path -LiteralPath $path -PathType Container) {
                Write-Warning "Not removing ${path}: it is a directory, not a .prom file."
                continue
            }
            if ((Test-Path -LiteralPath $path) -and $PSCmdlet.ShouldProcess($path, 'Remove')) {
                Remove-Item -LiteralPath $path -Force
                $removed.Add($candidate)
            }
        }
    }
    return [string[]]$removed.ToArray()
}

function Test-VeeamExporterInstallDirectory {
    # Safety check before deleting: the folder must look like an installation.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Test-Path -LiteralPath (Join-Path -Path $Path -ChildPath 'Invoke-VeeamExporter.ps1')) -and
    (Test-Path -LiteralPath (Join-Path -Path (Join-Path -Path $Path -ChildPath 'VeeamExporter') -ChildPath 'VeeamExporter.psd1'))
}

function Test-VeeamExporterDataDirectory {
    # Safety check: only the credential, logs\ and transfer files are expected.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Path)
    foreach ($item in Get-ChildItem -LiteralPath $Path -Force) {
        if ($item.Name -eq $script:CredentialFileName) { continue }
        if ($item.Name -eq 'logs' -and $item.PSIsContainer) { continue }
        if ($item.Name -like 'transfer-*.bin') { continue }
        return $false
    }
    return $true
}

function Assert-VeeamExporterNoReparsePoint {
    # Remove-Item -Recurse in Windows PowerShell 5.1 can follow a junction and
    # delete the files behind it; refuse instead.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $links = @(Get-VeeamExporterReparsePoint -Path $Path)
    if ($links.Count -gt 0) { throw ("Refusing to delete {0}: it contains junctions or symbolic links: {1}" -f $Path, ($links -join ', ')) }
}

# ------------------------------------------------------------ orchestration --

function Install-VeeamExporter {
    <#
    .SYNOPSIS
    Installs or updates the exporter on this VBR server (manual, interactive).
    .DESCRIPTION
    1. Checks: administrator, textfile directory (not writable by other
       accounts), certificate of localhost:9419 (shown for confirmation
       unless -CertificateThumbprint or -Force).
    2. Secures InstallPath (owner Administrators, write access only for
       SYSTEM and Administrators) and copies the exporter there; creates
       DataPath (SYSTEM and Administrators only). An existing directory owned
       by another account, or one with junctions/symbolic links, is refused.
    3. Stores the Veeam credential for SYSTEM if missing or -UpdateCredential.
    4. Registers the REST task (every 15 min) and the license task (daily).
    5. Runs both tasks once and reports the result, unless -NoStart.
    Re-running it updates files and tasks; the credential is kept.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [string]$InstallPath,
        [string]$DataPath,
        [string]$TextfileDirectory,
        [string]$CertificateThumbprint,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$UpdateCredential,
        [string]$VeeamModule,
        [switch]$SkipLicenseTask,
        [ValidateRange(5, 60)][int]$RestIntervalMinutes = 15,
        [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')][string]$LicenseTime = '06:17',
        [string[]]$Collector = @('jobs', 'objects', 'repositories'),
        [ValidateRange(1, 90)][int]$ObjectLookbackDays = 8,
        [switch]$NoStart,
        [switch]$Force,
        [switch]$AllowUnsafeTextfileDirectory
    )
    if (-not $InstallPath) { $InstallPath = Join-Path -Path $env:ProgramFiles -ChildPath 'VeeamExporter' }
    if (-not $DataPath) { $DataPath = Join-Path -Path $env:ProgramData -ChildPath 'VeeamExporter' }
    if (-not (Test-VeeamExporterAdministrator)) { throw 'Run the installation in an elevated PowerShell (Administrator).' }

    # textfile directory
    if (-not $TextfileDirectory) {
        $found = Find-WindowsExporterTextfileDirectory
        if (-not $found.ServiceFound) { Write-Warning 'Service windows_exporter not found; using the default textfile directory.' }
        if (-not $found.TextfileEnabled) { Write-Warning 'windows_exporter runs without the textfile collector (--collectors.enabled). Enable it, otherwise the .prom files are not exported.' }
        $TextfileDirectory = $found.Directory
        Write-Information ('Textfile directory ({0}): {1}' -f $found.Source, $TextfileDirectory)
    }
    if (-not (Test-Path -LiteralPath $TextfileDirectory -PathType Container)) {
        throw "Textfile directory does not exist: $TextfileDirectory (pass -TextfileDirectory)."
    }
    $textfileProblems = @(Get-VeeamExporterTextfileProblem -Directory $TextfileDirectory)
    if ($textfileProblems.Count -gt 0) {
        $message = ("Textfile directory {0} is writable by other accounts. SYSTEM writes there, and Prometheus trusts the content. Restrict it to SYSTEM and Administrators (read access for others is fine).`n  {1}" -f $TextfileDirectory, ($textfileProblems -join "`n  "))
        if ($AllowUnsafeTextfileDirectory) { Write-Warning $message }
        else { throw ($message + "`nOverride with -AllowUnsafeTextfileDirectory.") }
    }

    # certificate of the local REST API
    if ($CertificateThumbprint) {
        $CertificateThumbprint = Format-CertificateThumbprint -Thumbprint $CertificateThumbprint
    }
    else {
        $cert = Get-TlsCertificateInfo -HostName 'localhost' -Port 9419
        Write-Information ('Certificate of localhost:9419: {0}, valid until {1:yyyy-MM-dd}, thumbprint {2}' -f $cert.Subject, $cert.NotAfter, $cert.Thumbprint)
        if (-not $Force -and -not $PSCmdlet.ShouldContinue(('Pin thumbprint {0} ({1})?' -f $cert.Thumbprint, $cert.Subject), 'Certificate of the local Veeam REST API')) {
            throw 'Installation cancelled: certificate not confirmed.'
        }
        $CertificateThumbprint = $cert.Thumbprint
    }

    # PowerShell hosts
    $hosts = Find-PowerShellHost
    $restHost = $hosts.WindowsPowerShell
    if (-not $restHost) { throw 'powershell.exe (Windows PowerShell 5.1) not found.' }
    $licenseHostPath = $null
    if (-not $SkipLicenseTask) {
        $moduleVersion = $null
        if (-not $VeeamModule) {
            $module = Find-VeeamPowerShellModule
            if (-not $module) { throw 'Veeam PowerShell module not found. Pass -VeeamModule <path> or -SkipLicenseTask.' }
            $VeeamModule = $module.Module
            $moduleVersion = $module.Version
        }
        elseif ($VeeamModule -like '*.psd1' -and (Test-Path -LiteralPath $VeeamModule)) {
            $moduleVersion = Get-VeeamModuleManifestVersion -Path $VeeamModule
        }
        $licenseHostPath = Resolve-VeeamLicenseHost -ModuleVersion $moduleVersion -PwshPath $hosts.Pwsh
        Write-Information ('License task: {0} with {1}' -f $licenseHostPath, $VeeamModule)
    }

    # files
    # Installation and data directory: owner and ACL first, then the files.
    Initialize-VeeamExporterSecureDirectory -Path $InstallPath -Kind Install
    $null = Copy-VeeamExporterFile -SourceRoot $SourceRoot -InstallPath $InstallPath
    if (-not $WhatIfPreference) { Assert-VeeamExporterDirectorySecure -Path $InstallPath -Kind Install }
    Initialize-VeeamExporterDataDirectory -Path $DataPath

    # credential
    $credentialPath = Join-Path -Path $DataPath -ChildPath $script:CredentialFileName
    if (($UpdateCredential -or -not (Test-Path -LiteralPath $credentialPath)) -and
        $PSCmdlet.ShouldProcess($credentialPath, 'Store Veeam credential for SYSTEM (DPAPI)')) {
        if (-not $Credential) {
            $Credential = Get-Credential -Message 'Veeam account for the REST API (role Backup Viewer), e.g. VBR01\veeam-exporter'
        }
        if (-not $Credential) { throw 'No credential entered.' }
        $worker = Join-Path -Path (Join-Path -Path $InstallPath -ChildPath 'deploy') -ChildPath 'Save-VeeamExporterSystemCredential.ps1'
        Save-VeeamExporterCredentialAsSystem -Credential $Credential -DataPath $DataPath -WorkerScript $worker -HostPath $restHost -Confirm:$false
        Write-Information "Credential stored for SYSTEM: $credentialPath"
    }
    elseif (Test-Path -LiteralPath $credentialPath) {
        Write-Information "Credential kept: $credentialPath (use -UpdateCredential to replace it)"
    }

    # tasks
    $definitions = @(Get-VeeamExporterTaskDefinition -Kind Rest -HostPath $restHost -InstallPath $InstallPath -DataPath $DataPath `
            -TextfileDirectory $TextfileDirectory -CertificateThumbprint $CertificateThumbprint -Collector $Collector `
            -ObjectLookbackDays $ObjectLookbackDays -RestIntervalMinutes $RestIntervalMinutes)
    if (-not $SkipLicenseTask) {
        $definitions += Get-VeeamExporterTaskDefinition -Kind License -HostPath $licenseHostPath -InstallPath $InstallPath -DataPath $DataPath `
            -TextfileDirectory $TextfileDirectory -VeeamModule $VeeamModule -LicenseTime $LicenseTime
    }
    elseif (Get-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:LicenseTaskName -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($script:LicenseTaskName, 'Unregister (SkipLicenseTask)')) {
            Unregister-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:LicenseTaskName -Confirm:$false
        }
    }
    foreach ($d in $definitions) { Register-VeeamExporterTask -Definition $d -Confirm:$false }

    # first run
    $results = New-Object -TypeName System.Collections.Generic.List[object]
    if (-not $NoStart -and -not $WhatIfPreference) {
        foreach ($d in $definitions) {
            $startedAt = Get-Date
            Start-ScheduledTask -TaskPath $d.TaskPath -TaskName $d.TaskName
            $info = Wait-VeeamExporterTask -TaskPath $d.TaskPath -TaskName $d.TaskName -StartedAt $startedAt
            $results.Add([pscustomobject]@{ Task = $d.TaskName; LastTaskResult = $info.LastTaskResult; Ok = ($info.LastTaskResult -eq 0) })
        }
        foreach ($healthFile in @('veeam_exporter.prom', 'veeam_exporter_license.prom')) {
            $path = Join-Path -Path $TextfileDirectory -ChildPath $healthFile
            if (Test-Path -LiteralPath $path) {
                foreach ($line in ([System.IO.File]::ReadAllText($path) -split "`n" | Where-Object { $_ -like 'veeam_exporter_collector_success*' })) {
                    Write-Information $line
                }
            }
        }
        if (@($results | Where-Object { -not $_.Ok }).Count -gt 0) {
            Write-Warning ('A task reported an error. Logs: {0}' -f (Join-Path -Path $DataPath -ChildPath 'logs'))
        }
    }

    return [pscustomobject]@{
        InstallPath           = $InstallPath
        DataPath              = $DataPath
        TextfileDirectory     = $TextfileDirectory
        CertificateThumbprint = $CertificateThumbprint
        Tasks                 = @($definitions | ForEach-Object { $_.TaskPath + $_.TaskName })
        FirstRun              = $results.ToArray()
    }
}

function Uninstall-VeeamExporter {
    <#
    .SYNOPSIS
    Removes tasks, files and the exporter's .prom files from this server.
    .DESCRIPTION
    Deletes InstallPath and DataPath only when they look like an exporter
    installation (safety check). -KeepData keeps the credential and logs.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [string]$InstallPath,
        [string]$DataPath,
        [string]$TextfileDirectory,
        [switch]$KeepData
    )
    if (-not $InstallPath) { $InstallPath = Join-Path -Path $env:ProgramFiles -ChildPath 'VeeamExporter' }
    if (-not $DataPath) { $DataPath = Join-Path -Path $env:ProgramData -ChildPath 'VeeamExporter' }
    if (-not (Test-VeeamExporterAdministrator)) { throw 'Run the uninstallation in an elevated PowerShell (Administrator).' }
    if (-not $TextfileDirectory) { $TextfileDirectory = (Find-WindowsExporterTextfileDirectory).Directory }

    foreach ($task in @(Get-ScheduledTask -TaskPath $script:TaskPath -ErrorAction SilentlyContinue)) {
        if ($null -eq $task) { continue }
        if ($PSCmdlet.ShouldProcess(($task.TaskPath + $task.TaskName), 'Unregister scheduled task')) {
            Unregister-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -Confirm:$false
        }
    }

    $removedProm = @()
    if (Test-Path -LiteralPath $TextfileDirectory) { $removedProm = Remove-VeeamExporterPromFile -TextfileDirectory $TextfileDirectory }

    if (Test-Path -LiteralPath $InstallPath) {
        if (-not (Test-VeeamExporterInstallDirectory -Path $InstallPath)) { throw "Refusing to delete ${InstallPath}: it does not look like an exporter installation." }
        Assert-VeeamExporterNoReparsePoint -Path $InstallPath
        if ($PSCmdlet.ShouldProcess($InstallPath, 'Remove directory')) { Remove-Item -LiteralPath $InstallPath -Recurse -Force }
    }
    if (-not $KeepData -and (Test-Path -LiteralPath $DataPath)) {
        if (-not (Test-VeeamExporterDataDirectory -Path $DataPath)) { throw "Refusing to delete ${DataPath}: it contains unexpected files." }
        Assert-VeeamExporterNoReparsePoint -Path $DataPath
        if ($PSCmdlet.ShouldProcess($DataPath, 'Remove directory (credential, logs)')) { Remove-Item -LiteralPath $DataPath -Recurse -Force }
    }
    return [pscustomobject]@{ RemovedPromFiles = $removedProm; InstallPath = $InstallPath; DataPath = $DataPath; KeptData = [bool]$KeepData }
}

Export-ModuleMember -Function @(
    'Install-VeeamExporter', 'Uninstall-VeeamExporter',
    'Test-VeeamExporterLocalSystem', 'Read-VeeamExporterTransferFile', 'Get-TlsCertificateInfo'
)
