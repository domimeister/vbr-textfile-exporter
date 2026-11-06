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
