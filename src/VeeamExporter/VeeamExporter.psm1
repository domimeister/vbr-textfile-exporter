# Loader for the VeeamExporter module.
# Source files must stay ASCII-only: Windows PowerShell 5.1 reads BOM-less
# scripts as ANSI, so non-ASCII characters would be corrupted.

$ErrorActionPreference = 'Stop'

# Highest revision first. 1.3-rev2 = VBR 13.1, 1.3-rev1 = 13.0.1,
# 1.3-rev0 = 13.0, 1.2-rev1 = 12.3.1.
$script:VeeamApiVersions = @('1.3-rev2', '1.3-rev1', '1.3-rev0', '1.2-rev1')

# The only POST endpoints this exporter may ever call (hard rule: read-only).
$script:VeeamAllowedPostPaths = @('/api/oauth2/token', '/api/oauth2/logout')

$script:VeeamDefaultPageSize = 200

# Time zone for API timestamps without offset (docs/metrics.md#OP-9). The
# exporter runs on the VBR server, so this is the server's local time zone.
# Tests replace it with a fixed zone.
$script:VeeamTimeZone = [System.TimeZoneInfo]::Local

foreach ($folder in @('Private', 'Public')) {
    $path = Join-Path -Path $PSScriptRoot -ChildPath $folder
    if (Test-Path -LiteralPath $path) {
        Get-ChildItem -LiteralPath $path -Filter '*.ps1' -File | Sort-Object -Property Name | ForEach-Object {
            . $_.FullName
        }
    }
}
