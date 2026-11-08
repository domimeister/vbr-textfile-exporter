# Shared helpers, dot-sourced in BeforeAll of every test file.
# Keep this file ASCII-only (Windows PowerShell 5.1 reads it as ANSI).

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:SrcRoot = Join-Path -Path $script:RepoRoot -ChildPath 'src'
$script:ModuleManifest = Join-Path -Path (Join-Path -Path $script:SrcRoot -ChildPath 'VeeamExporter') -ChildPath 'VeeamExporter.psd1'
$script:FixtureDir = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures'
$script:ExpectedDir = Join-Path -Path $script:FixtureDir -ChildPath 'expected'

Import-Module -Name $script:ModuleManifest -Force

function Get-FixtureText {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [System.IO.File]::ReadAllText((Join-Path -Path $script:FixtureDir -ChildPath $Name), (New-Object System.Text.UTF8Encoding $false))
}

function Get-ExpectedText {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [System.IO.File]::ReadAllText((Join-Path -Path $script:ExpectedDir -ChildPath $Name), (New-Object System.Text.UTF8Encoding $false))
}

function Get-FileText {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding $false))
}

function New-HttpResponse {
    param(
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [AllowEmptyString()][string]$Content = ''
    )
    return [pscustomobject]@{ StatusCode = $StatusCode; Content = $Content }
}

function New-TestCredential {
    $secure = ConvertTo-SecureString -String 'S3cret!pw' -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential -ArgumentList 'veeam-viewer', $secure
}

function New-TestSession {
    return [pscustomobject]@{
        BaseUri      = 'https://localhost:9419'
        TimeoutSec   = 5
        HttpClient   = $null
        ApiVersion   = '1.3-rev2'
        AccessToken  = 'access-123'
        RefreshToken = 'refresh-456'
    }
}

$script:TokenJson = '{"access_token":"access-123","token_type":"bearer","refresh_token":"refresh-456","expires_in":900}'
$script:UnsupportedVersionJson = '{"errorCode":"BadRequest","message":"The specified API version is not supported."}'
$script:InvalidGrantJson = '{"error":"invalid_grant","error_description":"Invalid username or password."}'
# Real answers of VBR 13.1 (lab) to POST /api/oauth2/token.
$script:UnsupportedVersionJsonVbr131 = '{"errorCode":"NotImplemented","message":"The HTTP resource that matches the request URI ''https://localhost:9419/api/oauth2/token'' does not support the API version ''1.3-rev3''.","title":"The HTTP resource that matches the request URI ''https://localhost:9419/api/oauth2/token'' does not support the API version ''1.3-rev3''.","status":400}'
$script:AccessDeniedJsonVbr131 = '{"errorCode":"AccessDenied","message":"Unable to perform authorization: The provided user credentials are invalid.","title":"Unable to perform authorization: The provided user credentials are invalid.","status":401}'

$script:SupportedDocVersions = @('1.3-rev0', '1.3-rev1', '1.3-rev2')

function Get-FixtureData {
    # data array of a fixture response
    param([Parameter(Mandatory = $true)][string]$Name)
    return @((Get-FixtureText -Name $Name | ConvertFrom-Json).data)
}

function Set-TestTimeZone {
    # Fixed zone (+01:00, no DST) for timestamps without offset, docs/metrics.md#OP-9.
    InModuleScope VeeamExporter {
        $script:VeeamTimeZone = [System.TimeZoneInfo]::CreateCustomTimeZone('Test+01', [timespan]::FromHours(1), 'Test+01', 'Test+01')
    }
}

function Assert-PromText {
    # Line-by-line comparison first (readable failure), then exact match.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Actual,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Expected
    )
    $actualLines = $Actual -split "`n"
    $expectedLines = $Expected -split "`n"
    for ($i = 0; $i -lt [math]::Max($actualLines.Count, $expectedLines.Count); $i++) {
        $actualLines[$i] | Should -BeExactly $expectedLines[$i] -Because "Zeile $($i + 1)"
    }
    $Actual | Should -BeExactly $Expected
}

# REST API mock for complete runs (all collectors). Parameters switch
# single endpoints to an error status. The VBR version is read locally
# (docs/metrics.md#OP-13); -VbrVersionFails makes that lookup throw.
function Set-VeeamApiMock {
    param(
        [int]$TokenStatus = 200,
        [string]$TokenContent = $script:TokenJson,
        [int]$JobsStatus = 200,
        [int]$TaskSessionsStatus = 200,
        [string]$VbrVersion = '13.0.1.180',
        [switch]$VbrVersionFails
    )
    $script:MockTokenStatus = $TokenStatus
    $script:MockTokenContent = $TokenContent
    $script:MockJobsStatus = $JobsStatus
    $script:MockTaskSessionsStatus = $TaskSessionsStatus
    $script:MockVbrVersion = $VbrVersion
    if ($VbrVersionFails) {
        Mock -ModuleName VeeamExporter Get-VeeamLocalServerVersion { throw 'Cannot find path HKLM:\SYSTEM\CurrentControlSet\Services\VeeamBackupSvc' }
    }
    else {
        Mock -ModuleName VeeamExporter Get-VeeamLocalServerVersion { $script:MockVbrVersion }
    }
    $script:MockRepositoryStates = Get-FixtureText -Name 'repositories-sobr-states.json'
    $script:MockSobrs = Get-FixtureText -Name 'doc/1.3-rev2/scaleOutRepositories.json'
    $script:MockJobsContent = Get-FixtureText -Name 'jobs-states.json'
    $script:MockSessionsContent = Get-FixtureText -Name 'objects-doc-sessions.json'
    $script:MockTasksContent = (Get-FixtureText -Name 'doc/1.3-rev0/taskSessions.json') -replace '"total": 52', '"total": 6'
    $script:MockEmpty = '{"data":[],"pagination":{"total":0,"count":0,"skip":0,"limit":200}}'
    Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest {
        switch ($Path) {
            '/api/oauth2/token' { return New-HttpResponse -StatusCode $script:MockTokenStatus -Content $script:MockTokenContent }
            '/api/oauth2/logout' { return New-HttpResponse -StatusCode 200 }
            '/api/v1/backupInfrastructure/repositories/states' { return New-HttpResponse -StatusCode 200 -Content $script:MockRepositoryStates }
            '/api/v1/backupInfrastructure/scaleOutRepositories' { return New-HttpResponse -StatusCode 200 -Content $script:MockSobrs }
            '/api/v1/jobs/states' {
                if ($script:MockJobsStatus -ne 200) { return New-HttpResponse -StatusCode $script:MockJobsStatus -Content '{"errorCode":"InternalError","message":"boom"}' }
                return New-HttpResponse -StatusCode 200 -Content $script:MockJobsContent
            }
            '/api/v1/sessions' {
                if ($Query['typeFilter'] -ne 'BackupJob') { return New-HttpResponse -StatusCode 200 -Content $script:MockEmpty }
                return New-HttpResponse -StatusCode 200 -Content $script:MockSessionsContent
            }
            '/api/v1/taskSessions' {
                if ($script:MockTaskSessionsStatus -ne 200) { return New-HttpResponse -StatusCode $script:MockTaskSessionsStatus -Content '{"errorCode":"InternalError","message":"boom"}' }
                if ($Query.Contains('sessionTypeFilter')) { throw 'sessionTypeFilter must not be used (#21)' }
                return New-HttpResponse -StatusCode 200 -Content $script:MockTasksContent
            }
        }
        throw "Unexpected request: $Method $Path"
    }
}

function Set-LicenseMock {
    # Mocks the wrappers around the Veeam PowerShell module.
    param(
        [string]$Fixture = 'license-rental',
        [switch]$ImportFails,
        [switch]$LicenseFails,
        [bool]$Connected = $true
    )
    $script:MockLicense = Get-FixtureText -Name "license/$Fixture.json" | ConvertFrom-Json
    $script:MockConnected = $Connected
    if ($ImportFails) {
        Mock -ModuleName VeeamExporter Import-VeeamBackupModule { throw 'Cannot import module Veeam.Backup.PowerShell: not found' }
    }
    else {
        Mock -ModuleName VeeamExporter Import-VeeamBackupModule { }
    }
    Mock -ModuleName VeeamExporter Connect-VeeamLocalServer { $script:MockConnected }
    Mock -ModuleName VeeamExporter Disconnect-VeeamLocalServer { }
    if ($LicenseFails) {
        Mock -ModuleName VeeamExporter Get-VeeamInstalledLicense { throw 'Get-VBRInstalledLicense: access denied' }
    }
    else {
        Mock -ModuleName VeeamExporter Get-VeeamInstalledLicense { @($script:MockLicense) }
    }
}

function Read-PromFile {
    # Minimal parser for the checks the windows_exporter does across files:
    # returns HELP/TYPE per metric and every sample with its label names.
    param([Parameter(Mandatory = $true)][string]$Path)
    $help = @{}
    $type = @{}
    $samples = New-Object System.Collections.Generic.List[object]
    foreach ($line in ((Get-FileText -Path $Path).TrimEnd("`n") -split "`n")) {
        if ($line -match '^# HELP (\S+) (.*)$') { $help[$Matches[1]] = $Matches[2]; continue }
        if ($line -match '^# TYPE (\S+) (\S+)$') { $type[$Matches[1]] = $Matches[2]; continue }
        if ($line -match '^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{(.*)\})? (\S+)$') {
            $labelText = $Matches[3]
            $names = @()
            if ($labelText) { $names = @([regex]::Matches($labelText, '([a-zA-Z_][a-zA-Z0-9_]*)="(?:[^"\\]|\\.)*"') | ForEach-Object { $_.Groups[1].Value }) }
            $samples.Add([pscustomobject]@{ File = (Split-Path -Leaf $Path); Name = $Matches[1]; Series = $Matches[1] + $Matches[2]; LabelNames = ($names -join ',') })
        }
    }
    return [pscustomobject]@{ Help = $help; Type = $type; Samples = $samples.ToArray() }
}

function Export-GeneratedPromFile {
    # CI sets VEEAM_TEST_PROM_OUTPUT. Tests that run the exporter call this
    # after the run, so a later CI step can check the generated files with
    # "promtool check metrics" (tests/Invoke-PromtoolCheck.ps1). Only call it
    # where the directory holds exporter output alone: a file a test writes
    # itself (e.g. an "old" file without HELP) would fail the lint.
    # No-op when the variable is not set.
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not $env:VEEAM_TEST_PROM_OUTPUT) { return }
    $files = @(Get-ChildItem -LiteralPath $Directory -Filter '*.prom' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return }
    $target = Join-Path -Path $env:VEEAM_TEST_PROM_OUTPUT -ChildPath $Name
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    foreach ($file in $files) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path -Path $target -ChildPath $file.Name) -Force
    }
}

function Get-SortedFileName {
    # File names in ordinal order (Sort-Object depends on the culture).
    param([Parameter(Mandatory = $true)][string]$Directory, [string]$Filter = '*')
    $names = [string[]]@(Get-ChildItem -LiteralPath $Directory -Filter $Filter | ForEach-Object Name)
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    return ($names -join ',')
}
