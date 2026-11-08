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
    elseif ($ConfigText -and $ConfigText -match '(?m)^\s*director(?:y|ies)\s*:[ \t]*(?:"((?:[^"\\]|\\.)*)"|''([^'']*)''|([^\r\n]+))') {
        if ($Matches[1]) { $directory = $Matches[1] -replace '\\\\', '\' }
        elseif ($Matches[2]) { $directory = $Matches[2] }
        else {
            # Plain YAML value: the rest of the line, may contain spaces
            # (C:\Program Files\...); a comment starts with " #".
            $directory = ($Matches[3] -replace '\s+#.*$', '').Trim()
        }
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

    # Textfile collector enabled? $true/$false if the collector list says so,
    # $null if it depends on the default set: windows_exporter 0.32 does not
    # include textfile in its defaults any more (lab test, 0.32.1), older
    # versions did. Find-WindowsExporterTextfileDirectory asks the running
    # service instead whenever it can.
    $enabled = $null
    $list = $null
    if ($ImagePath -and $ImagePath -match '--collectors\.enabled(?:=|\s+)(?:"([^"]*)"|''([^'']*)''|(\S+))') {
        $list = (@($Matches[1], $Matches[2], $Matches[3]) | Where-Object { $_ } | Select-Object -First 1)
    }
    elseif ($ConfigText -and $ConfigText -match '(?m)^\s*enabled\s*:\s*(?:"([^"\r\n]*)"|''([^''\r\n]*)''|([^\r\n#]+))') {
        $list = (@($Matches[1], $Matches[2], $Matches[3]) | Where-Object { $_ } | Select-Object -First 1)
    }
    if ($list) {
        $names = @($list -split ',' | ForEach-Object { $_.Trim() })
        if ($names -contains 'textfile') { $enabled = $true }
        elseif (-not ($names -contains '[defaults]')) { $enabled = $false }
    }

    # Address of /metrics: --web.listen-address or web.listen-address in the
    # config file, default :9182. A wildcard host is reached via localhost.
    $listen = ':9182'
    if ($ImagePath -and $ImagePath -match '--web\.listen-address(?:=|\s+)(?:"([^"]*)"|(\S+))') {
        $listen = (@($Matches[1], $Matches[2]) | Where-Object { $_ } | Select-Object -First 1)
    }
    elseif ($ConfigText -and $ConfigText -match '(?m)^\s*listen-address\s*:\s*(?:"([^"\r\n]*)"|''([^''\r\n]*)''|([^\r\n#\s]+))') {
        $listen = (@($Matches[1], $Matches[2], $Matches[3]) | Where-Object { $_ } | Select-Object -First 1)
    }
    $listen = ($listen -split ',')[0].Trim()
    $listenHost = 'localhost'
    $port = '9182'
    if ($listen -match '^(.*):(\d+)$') {
        $port = $Matches[2]
        if ($Matches[1] -and $Matches[1] -notin @('0.0.0.0', '[::]', '::')) { $listenHost = $Matches[1] }
    }

    return [pscustomobject]@{
        Directory       = $directory.TrimEnd('\')
        Source          = $source
        TextfileEnabled = $enabled
        MetricsUri      = ('http://{0}:{1}/metrics' -f $listenHost, $port)
    }
}

function Test-WindowsExporterTextfileCollector {
    <#
    Asks the running windows_exporter whether the textfile collector is active:
    $true if /metrics has windows_exporter_collector_success{collector="textfile"},
    $false if /metrics answers without it, $null if /metrics is not reachable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$MetricsUri)
    try {
        $response = Invoke-WebRequest -Uri $MetricsUri -UseBasicParsing -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop
    }
    catch {
        Write-Verbose ('{0} not reachable: {1}' -f $MetricsUri, $_.Exception.Message)
        return $null
    }
    return ([string]$response.Content -match '(?m)^windows_exporter_collector_success\{collector="textfile"\}\s')
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
    # The running service is the reliable source: the default collector set
    # depends on the windows_exporter version.
    $check = 'config'
    if ($imagePath) {
        $live = Test-WindowsExporterTextfileCollector -MetricsUri $result.MetricsUri
        if ($null -ne $live) { $result.TextfileEnabled = $live; $check = 'metrics' }
    }
    $result | Add-Member -NotePropertyName TextfileCheck -NotePropertyValue $check
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
    # The 40 hex digits of a SHA-1 thumbprint, upper case. Blanks, colons and
    # hyphens are dropped as separators, and so are invisible format
    # characters (the certificate dialog prepends U+200E when copying).
    # Anything else, e.g. a label like "SHA1:", or a length other than 40
    # (SHA-256) is refused: the task would pin a value that never matches.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Thumbprint)
    $hex = New-Object -TypeName System.Text.StringBuilder
    foreach ($c in $Thumbprint.ToCharArray()) {
        if ([char]::GetUnicodeCategory($c) -eq [System.Globalization.UnicodeCategory]::Format) { continue }
        if ([char]::IsWhiteSpace($c) -or $c -eq ':' -or $c -eq '-') { continue }
        if ("$c" -notmatch '^[0-9A-Fa-f]$') {
            throw ("Certificate thumbprint contains '{0}'. Give only the 40 hex digits of the SHA-1 thumbprint (blanks and colons are fine)." -f $c)
        }
        $null = $hex.Append($c)
    }
    if ($hex.Length -ne 40) {
        throw ('Certificate thumbprint has {0} hex digits, expected the 40 of a SHA-1 thumbprint.' -f $hex.Length)
    }
    return $hex.ToString().ToUpperInvariant()
}

function ConvertTo-VeeamExporterFullPath {
    # Absolute path, relative to the current PowerShell location. The SYSTEM
    # tasks run in C:\Windows\System32, so a relative path in their arguments
    # would point somewhere else.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
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

function Split-TaskArgument {
    # Inverse of Join-TaskArgument: splits a command line by the
    # CommandLineToArgvW rules (2n backslashes + quote: n backslashes and the
    # quote toggles; 2n+1: n backslashes and a literal quote; other
    # backslashes are literal).
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$CommandLine)
    $result = New-Object -TypeName System.Collections.Generic.List[string]
    $current = New-Object -TypeName System.Text.StringBuilder
    $inQuotes = $false
    $hasToken = $false
    $backslashes = 0
    foreach ($c in $CommandLine.ToCharArray()) {
        if ($c -eq '\') { $backslashes++; continue }
        if ($c -eq '"') {
            [void]$current.Append([char]'\', [math]::Floor($backslashes / 2))
            if ($backslashes % 2 -eq 1) { [void]$current.Append('"') }
            else { $inQuotes = -not $inQuotes }
            $backslashes = 0
            $hasToken = $true
            continue
        }
        if ($backslashes -gt 0) { [void]$current.Append([char]'\', $backslashes); $backslashes = 0; $hasToken = $true }
        if (-not $inQuotes -and [char]::IsWhiteSpace($c)) {
            if ($hasToken) { $result.Add($current.ToString()); [void]$current.Clear(); $hasToken = $false }
            continue
        }
        [void]$current.Append($c)
        $hasToken = $true
    }
    if ($backslashes -gt 0) { [void]$current.Append([char]'\', $backslashes); $hasToken = $true }
    if ($hasToken) { $result.Add($current.ToString()) }
    return [string[]]$result.ToArray()
}

function Get-VeeamExporterTaskTextfileDirectory {
    # Textfile directories the given tasks write to, from their -TextfileDirectory argument.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowNull()][object[]]$Task)
    $directories = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($t in @($Task)) {
        if ($null -eq $t -or -not $t.PSObject.Properties['Actions']) { continue }
        foreach ($action in @($t.Actions)) {
            if ($null -eq $action) { continue }
            $arguments = @(Split-TaskArgument -CommandLine ([string]$action.Arguments))
            for ($i = 0; $i -lt $arguments.Count - 1; $i++) {
                if ($arguments[$i] -eq '-TextfileDirectory' -and -not $directories.Contains($arguments[$i + 1])) { $directories.Add($arguments[$i + 1]) }
            }
        }
    }
    return [string[]]$directories.ToArray()
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

function Wait-VeeamExporterTaskIdle {
    # Waits until no instance of the task runs. The tasks use MultipleInstances
    # IgnoreNew, so Start-ScheduledTask during a scheduled run would be dropped.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskPath,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [int]$TimeoutSeconds = 300
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $announced = $false
    while ([string](Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue).State -eq 'Running') {
        if (-not $announced) {
            Write-Information ('Task {0}{1} is running; waiting for it to finish before the first run.' -f $TaskPath, $TaskName)
            $announced = $true
        }
        if ((Get-Date) -gt $deadline) { throw ('Task {0}{1} was still running after {2} s.' -f $TaskPath, $TaskName, $TimeoutSeconds) }
        Start-Sleep -Seconds 2
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
        [switch]$NoRecurse,
        # From Get-VeeamExporterTrustedSid; pass it when checking several
        # paths, it asks the local Administrators group every time.
        [string[]]$TrustedSid
    )
    $trusted = $TrustedSid
    if (-not $trusted) { $trusted = Get-VeeamExporterTrustedSid }
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
    $trusted = Get-VeeamExporterTrustedSid
    foreach ($p in (Get-VeeamExporterPathProblem -Path $Directory -RightsMask $script:WriteRightsMask -NoRecurse -TrustedSid $trusted)) { $problems.Add($p) }
    $names = @($script:PromFiles | ForEach-Object { $_; $_ + '.tmp' })
    foreach ($item in @(Get-ChildItem -LiteralPath $Directory -Force | Where-Object { $names -contains $_.Name })) {
        foreach ($p in (Get-VeeamExporterPathProblem -Path $item.FullName -RightsMask $script:WriteRightsMask -NoRecurse -TrustedSid $trusted)) { $problems.Add($p) }
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

function Assert-VeeamExporterDirectoryTrusted {
    # An existing directory is only used when it and everything in it is
    # owned by a trusted account and contains no junction or symbolic link.
    # Read-only; a missing directory passes.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $problems = @(Get-VeeamExporterPathProblem -Path $Path)
    if ($problems.Count -gt 0) {
        throw ("Refusing to use {0}: it was not created by an administrator (or contains links). Check it, remove it and run the installation again.`n  {1}" -f $Path, ($problems -join "`n  "))
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
    Assert-VeeamExporterDirectoryTrusted -Path $Path
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
    # Removes only the exporter's own .prom files (and their .tmp files);
    # -Name narrows it to some of them.
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][string]$TextfileDirectory,
        [string[]]$Name = $script:PromFiles
    )
    foreach ($n in $Name) { if ($script:PromFiles -notcontains $n) { throw "Not an exporter file: $n" } }
    $removed = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($promFile in $Name) {
        foreach ($candidate in @($promFile, ($promFile + '.tmp'))) {
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
       by another account, or one with junctions/symbolic links, is refused
       before anything is created or copied.
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
        # At most 30: VeeamExporterStale fires once a REST file is older than 1 hour.
        [ValidateRange(5, 30)][int]$RestIntervalMinutes = 15,
        [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')][string]$LicenseTime = '06:17',
        [string[]]$Collector = @('jobs', 'objects', 'repositories'),
        [ValidateRange(1, 90)][int]$ObjectLookbackDays = 8,
        [switch]$NoStart,
        [switch]$Force,
        [switch]$AllowUnsafeTextfileDirectory
    )
    if (-not $InstallPath) { $InstallPath = Join-Path -Path $env:ProgramFiles -ChildPath 'VeeamExporter' }
    if (-not $DataPath) { $DataPath = Join-Path -Path $env:ProgramData -ChildPath 'VeeamExporter' }
    # The paths go into the SYSTEM tasks: absolute before anything uses them.
    $InstallPath = ConvertTo-VeeamExporterFullPath -Path $InstallPath
    $DataPath = ConvertTo-VeeamExporterFullPath -Path $DataPath
    if ($TextfileDirectory) { $TextfileDirectory = ConvertTo-VeeamExporterFullPath -Path $TextfileDirectory }
    if ($VeeamModule -and ($VeeamModule -match '[\\/]' -or $VeeamModule -like '*.psd1')) { $VeeamModule = ConvertTo-VeeamExporterFullPath -Path $VeeamModule }
    if (-not (Test-VeeamExporterAdministrator)) { throw 'Run the installation in an elevated PowerShell (Administrator).' }

    # Existing installation and data directory: refuse an untrusted one before
    # anything is created or copied. Initialize-VeeamExporterSecureDirectory
    # checks again right before it takes a directory over.
    Assert-VeeamExporterDirectoryTrusted -Path $InstallPath
    Assert-VeeamExporterDirectoryTrusted -Path $DataPath

    # textfile directory
    if (-not $TextfileDirectory) {
        $found = Find-WindowsExporterTextfileDirectory
        if (-not $found.ServiceFound) { Write-Warning 'Service windows_exporter not found; using the default textfile directory.' }
        if ($found.TextfileEnabled -eq $false) {
            Write-Warning "windows_exporter runs without the textfile collector, so the .prom files are not exported. Enable it, e.g. in config.yaml: collectors: enabled: '[defaults],textfile' (windows_exporter 0.32 does not enable it by default), then restart the service."
        }
        elseif ($null -eq $found.TextfileEnabled) {
            Write-Warning ('Could not verify that windows_exporter runs the textfile collector ({0} not reachable). windows_exporter 0.32 does not enable it by default; check that /metrics contains windows_exporter_collector_success{{collector="textfile"}}.' -f $found.MetricsUri)
        }
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
    # Where the installed tasks wrote so far, before they are replaced.
    $previousDirectories = @(Get-VeeamExporterTaskTextfileDirectory -Task @(Get-ScheduledTask -TaskPath $script:TaskPath -ErrorAction SilentlyContinue))
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

    # Files that no task writes any more would stay exported with frozen
    # values (and the stale alerts would fire on them for good): those of
    # dropped collectors, the license files with -SkipLicenseTask, and all
    # exporter files in a previous textfile directory.
    $collectorNames = @(@($Collector) -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    $outdated = @(foreach ($c in 'jobs', 'objects', 'repositories') { if ($collectorNames -notcontains $c) { 'veeam_{0}.prom' -f $c } })
    if ($SkipLicenseTask) { $outdated += @('veeam_license.prom', 'veeam_exporter_license.prom') }
    $removedOutdated = @()
    if ($outdated.Count -gt 0) { $removedOutdated += @(Remove-VeeamExporterPromFile -TextfileDirectory $TextfileDirectory -Name $outdated) }
    foreach ($previous in $previousDirectories) {
        $same = [string]::Equals([System.IO.Path]::GetFullPath($previous).TrimEnd('\', '/'), [System.IO.Path]::GetFullPath($TextfileDirectory).TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $same -and (Test-Path -LiteralPath $previous -PathType Container)) {
            $removedOutdated += @(Remove-VeeamExporterPromFile -TextfileDirectory $previous | ForEach-Object { Join-Path -Path $previous -ChildPath $_ })
        }
    }
    if ($removedOutdated.Count -gt 0) { Write-Information ('Removed files no task writes any more: {0}' -f ($removedOutdated -join ', ')) }

    # first run
    $results = New-Object -TypeName System.Collections.Generic.List[object]
    if (-not $NoStart -and -not $WhatIfPreference) {
        foreach ($d in $definitions) {
            # As long as the task itself may run, plus a minute.
            $timeout = [int]$d.ExecutionTimeLimit.TotalSeconds + 60
            $entry = [pscustomobject]@{ Task = $d.TaskName; LastTaskResult = $null; Ok = $false }
            try {
                Wait-VeeamExporterTaskIdle -TaskPath $d.TaskPath -TaskName $d.TaskName -TimeoutSeconds $timeout
                $startedAt = Get-Date
                Start-ScheduledTask -TaskPath $d.TaskPath -TaskName $d.TaskName
                $info = Wait-VeeamExporterTask -TaskPath $d.TaskPath -TaskName $d.TaskName -StartedAt $startedAt -TimeoutSeconds $timeout
                $entry.LastTaskResult = $info.LastTaskResult
                $entry.Ok = ($info.LastTaskResult -eq 0)
            }
            catch {
                # The installation itself is complete; go on with the next task.
                Write-Warning ("First run of {0} not checked: {1} Check later with: Get-ScheduledTaskInfo -TaskPath '{2}' -TaskName '{0}'" -f $d.TaskName, $_.Exception.Message, $d.TaskPath)
            }
            $results.Add($entry)
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
    $tasks = @(Get-ScheduledTask -TaskPath $script:TaskPath -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })
    # The directories the installed tasks write to; the service config only as fallback.
    if ($TextfileDirectory) { $textfileDirectories = @($TextfileDirectory) }
    else {
        $textfileDirectories = @(Get-VeeamExporterTaskTextfileDirectory -Task $tasks)
        if ($textfileDirectories.Count -eq 0) { $textfileDirectories = @((Find-WindowsExporterTextfileDirectory).Directory) }
    }

    foreach ($task in $tasks) {
        if ($PSCmdlet.ShouldProcess(($task.TaskPath + $task.TaskName), 'Stop and unregister scheduled task')) {
            # A running instance would write its .prom files again or keep its log open.
            if ([string]$task.State -eq 'Running') {
                Stop-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName
                $deadline = (Get-Date).AddSeconds(30)
                while ([string](Get-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction SilentlyContinue).State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
            }
            Unregister-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -Confirm:$false
        }
    }

    $removedProm = @()
    foreach ($directory in $textfileDirectories) {
        if (Test-Path -LiteralPath $directory) { $removedProm += @(Remove-VeeamExporterPromFile -TextfileDirectory $directory) }
    }

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
