# One value that cannot be converted only drops its own series, with a warning
# (docs/metrics.md, "Architecture & Data Source").
# Keep this file ASCII-only (Windows PowerShell 5.1 reads it as ANSI).

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Set-TestTimeZone
}

Describe 'Faulty values: jobs collector' {
    BeforeAll {
        $json = @'
[
  { "id": "11111111-1111-1111-1111-111111111111", "name": "Good Job", "type": "Backup", "status": "Inactive", "workload": "Vm", "repositoryName": "R",
    "lastResult": "Success", "lastRun": "2026-11-08T08:00:00+01:00", "nextRun": "2026-11-09T08:00:00+01:00", "nextRunPolicy": "08:00 every day", "objectsCount": 2 },
  { "id": "22222222-2222-2222-2222-222222222222", "name": "Bad Job", "type": "Backup", "status": "Inactive", "workload": "Vm", "repositoryName": "R",
    "lastResult": "Failed", "lastRun": "yesterday-ish", "nextRun": "not a date", "nextRunPolicy": "08:00 every day", "objectsCount": "many" }
]
'@
        $script:Jobs = @($json | ConvertFrom-Json)
        $script:Text = ConvertTo-PromText -Metric (Get-VeeamJobMetric -JobState $script:Jobs -WarningVariable w -WarningAction SilentlyContinue)
        $script:Warnings = @($w | ForEach-Object { [string]$_ })
    }

    It 'writes every series of the good job' {
        foreach ($m in 'veeam_job_info', 'veeam_job_last_result', 'veeam_job_enabled', 'veeam_job_running', 'veeam_job_last_run_timestamp_seconds', 'veeam_job_next_run_timestamp_seconds', 'veeam_job_objects') {
            $script:Text | Should -Match ('(?m)^' + $m + '\{[^}]*job_name="Good Job"')
        }
    }

    It 'keeps the readable series of the faulty job and leaves out the faulty ones' {
        foreach ($m in 'veeam_job_info', 'veeam_job_last_result', 'veeam_job_enabled', 'veeam_job_running') {
            $script:Text | Should -Match ('(?m)^' + $m + '\{[^}]*job_name="Bad Job"')
        }
        foreach ($m in 'veeam_job_last_run_timestamp_seconds', 'veeam_job_next_run_timestamp_seconds', 'veeam_job_objects') {
            $script:Text | Should -Not -Match ('(?m)^' + $m + '\{[^}]*job_name="Bad Job"')
        }
        $script:Text | Should -Match 'veeam_job_last_result\{job_name="Bad Job",job_type="Backup"\} 2'
        $script:Text | Should -Match 'job_name="Bad Job".*schedule="unknown"'
    }

    It 'warns once per faulty field, naming job and field' {
        ($script:Warnings -join "`n") | Should -Match "Job 'Bad Job': field lastRun skipped: Invalid timestamp"
        ($script:Warnings -join "`n") | Should -Match "Job 'Bad Job': field nextRun skipped: Invalid timestamp"
        ($script:Warnings -join "`n") | Should -Match "Job 'Bad Job': field objectsCount skipped"
        $script:Warnings.Count | Should -Be 3
    }
}

Describe 'Faulty values: repositories collector' {
    It 'leaves out only the size that cannot be read' {
        $json = @'
[
  { "id": "a", "name": "Repo A", "type": "WinLocal", "hostName": "h", "capacityGB": "n/a", "freeGB": 10.5, "usedSpaceGB": 1, "isOnline": true, "isOutOfDate": false },
  { "id": "b", "name": "Repo B", "type": "WinLocal", "hostName": "h", "capacityGB": 100, "freeGB": 50, "usedSpaceGB": 5, "isOnline": true, "isOutOfDate": false }
]
'@
        $text = ConvertTo-PromText -Metric (Get-VeeamRepositoryMetric -RepositoryState @($json | ConvertFrom-Json) -ScaleOutRepository @() -WarningVariable w -WarningAction SilentlyContinue)
        $text | Should -Not -Match 'veeam_repository_capacity_bytes\{repository="Repo A"'
        $text | Should -Match 'veeam_repository_free_bytes\{repository="Repo A"[^}]*\} 11274289152'
        $text | Should -Match 'veeam_repository_online\{repository="Repo A"\} 1'
        $text | Should -Match 'veeam_repository_capacity_bytes\{repository="Repo B"[^}]*\} 107374182400'
        @($w).Count | Should -Be 1
        [string]@($w)[0] | Should -Match "Repository 'Repo A': field capacityGB skipped"
    }
}

Describe 'Faulty values: objects collector' {
    It 'keeps the object with the readable values and warns about the rest' {
        $jobs = @('[{ "id": "11111111-1111-1111-1111-111111111111", "name": "Job 1" }]' | ConvertFrom-Json)
        $sessions = @(@'
[
  { "id": "aaaaaaaa-0000-0000-0000-000000000001", "jobId": "11111111-1111-1111-1111-111111111111", "name": "Job 1", "creationTime": "garbage" },
  { "id": "aaaaaaaa-0000-0000-0000-000000000002", "jobId": "11111111-1111-1111-1111-111111111111", "name": "Job 1", "creationTime": "2026-11-08T08:00:00+01:00" }
]
'@ | ConvertFrom-Json)
        $tasks = @(@'
[
  { "id": "t1", "sessionId": "aaaaaaaa-0000-0000-0000-000000000002", "name": "vm01", "usn": 5, "creationTime": "2026-11-08T08:00:00", "endTime": "broken",
    "result": { "result": "Failed", "message": "disk full" }, "progress": { "processedSize": "lots" } },
  { "id": "t2", "sessionId": "aaaaaaaa-0000-0000-0000-000000000001", "name": "vm02", "usn": "x", "creationTime": "also broken", "endTime": "2026-11-08T09:00:00",
    "result": { "result": "Success", "message": "" }, "progress": { "processedSize": 1024 } }
]
'@ | ConvertFrom-Json)
        $text = ConvertTo-PromText -Metric (Get-VeeamObjectMetric -JobState $jobs -JobSession $sessions -TaskSession $tasks -WarningVariable w -WarningAction SilentlyContinue)
        $warnings = (@($w | ForEach-Object { [string]$_ }) -join "`n")
        # vm01: end time broken -> run time falls back to the creation time; size broken -> no series.
        $text | Should -Match 'veeam_object_last_result\{job_name="Job 1",object="vm01"\} 2'
        $text | Should -Match 'veeam_object_last_run_timestamp_seconds\{job_name="Job 1",object="vm01"\} \d+'
        $text | Should -Not -Match 'veeam_object_last_processed_bytes\{job_name="Job 1",object="vm01"\}'
        $text | Should -Match 'veeam_object_last_failure_info\{job_name="Job 1",object="vm01",message="disk full"\} 1'
        # vm02: creation time and usn broken, end time readable.
        $text | Should -Match 'veeam_object_last_result\{job_name="Job 1",object="vm02"\} 0'
        $text | Should -Match 'veeam_object_last_run_timestamp_seconds\{job_name="Job 1",object="vm02"\} \d+'
        $text | Should -Match 'veeam_object_last_processed_bytes\{job_name="Job 1",object="vm02"\} 1024'
        $warnings | Should -Match "Session aaaaaaaa-0000-0000-0000-000000000001: field creationTime skipped"
        $warnings | Should -Match "Object 'vm01' in job 'Job 1': field endTime skipped"
        $warnings | Should -Match "Object 'vm01' in job 'Job 1': field processedSize skipped"
        $warnings | Should -Match "Task 'vm02' in job 'Job 1': field usn skipped"
        $warnings | Should -Match "Object 'vm02' in job 'Job 1': field creationTime skipped"
    }
}
