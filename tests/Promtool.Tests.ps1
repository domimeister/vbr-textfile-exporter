BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    $script:Promtool = Get-Command -Name 'promtool' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1

    function Invoke-PromtoolCheck {
        # Feeds the raw UTF-8 bytes to "promtool check metrics" via stdin.
        # A pipeline into a native exe would re-encode under Windows PowerShell 5.1.
        param([Parameter(Mandatory = $true)][byte[]]$Bytes)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:Promtool.Source
        $psi.Arguments = 'check metrics'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($psi)
        try {
            $process.StandardInput.BaseStream.Write($Bytes, 0, $Bytes.Length)
            $process.StandardInput.Close()
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = ($stdout + $stderr).Trim() }
        }
        finally {
            $process.Dispose()
        }
    }
}

Describe 'promtool check metrics' {
    It 'accepts <Name>' -TestCases @(
        @{ Name = 'veeam_jobs.prom' }
        @{ Name = 'veeam_jobs_escaping.prom' }
        @{ Name = 'veeam_objects_edgecases.prom' }
        @{ Name = 'doc/1.2-rev1/veeam_jobs.prom' }
        @{ Name = 'doc/1.2-rev1/veeam_objects.prom' }
        @{ Name = 'doc/1.3-rev2/veeam_jobs.prom' }
        @{ Name = 'doc/1.3-rev2/veeam_objects.prom' }
        @{ Name = 'veeam_repositories_sobr.prom' }
        @{ Name = 'doc/1.2-rev1/veeam_repositories.prom' }
        @{ Name = 'doc/1.3-rev0/veeam_repositories.prom' }
        @{ Name = 'license/veeam_license_rental.prom' }
        @{ Name = 'license/veeam_license_perpetual-socket.prom' }
        @{ Name = 'license/veeam_license_expired.prom' }
    ) {
        param($Name)
        if (-not $script:Promtool) { Set-ItResult -Skipped -Because 'promtool not in PATH'; return }
        $result = Invoke-PromtoolCheck -Bytes ([System.IO.File]::ReadAllBytes((Join-Path -Path $script:ExpectedDir -ChildPath $Name)))
        $result.Output | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
    }

    It 'accepts the files of a complete run' {
        if (-not $script:Promtool) { Set-ItResult -Skipped -Because 'promtool not in PATH'; return }
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest {
            switch ($Path) {
                '/api/oauth2/token' { return New-HttpResponse -StatusCode 200 -Content $script:TokenJson }
                '/api/v1/serverInfo' { return New-HttpResponse -StatusCode 200 -Content '{"buildVersion":"12.3.1.1139"}' }
                '/api/v1/jobs/states' { return New-HttpResponse -StatusCode 200 -Content (Get-FixtureText -Name 'jobs-states-escaping.json') }
                '/api/v1/sessions' { return New-HttpResponse -StatusCode 200 -Content (Get-FixtureText -Name 'objects-edge-sessions.json') }
                '/api/v1/taskSessions' { return New-HttpResponse -StatusCode 200 -Content (Get-FixtureText -Name 'objects-edge-taskSessions.json') }
                '/api/v1/backupInfrastructure/repositories/states' { return New-HttpResponse -StatusCode 200 -Content (Get-FixtureText -Name 'repositories-sobr-states.json') }
                '/api/v1/backupInfrastructure/scaleOutRepositories' { return New-HttpResponse -StatusCode 200 -Content (Get-FixtureText -Name 'doc/1.3-rev2/scaleOutRepositories.json') }
            }
            return New-HttpResponse -StatusCode 200
        }
        $dir = Join-Path -Path $TestDrive -ChildPath 'promtool'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $null = Invoke-VeeamExporterRun -TextfileDirectory $dir -Credential (New-TestCredential) -WarningAction SilentlyContinue

        $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.prom')
        $files.Count | Should -Be 4
        foreach ($file in $files) {
            $result = Invoke-PromtoolCheck -Bytes ([System.IO.File]::ReadAllBytes($file.FullName))
            $result.Output | Should -BeNullOrEmpty -Because $file.Name
            $result.ExitCode | Should -Be 0 -Because $file.Name
        }
    }
}
