# Veeam Prometheus Exporter (windows_exporter Textfile)

> **Status: experimental.** Tested in a lab against a real Veeam Backup & Replication 13.1 server, not yet in production. The issues the lab test found are fixed, see [Status](#status); open points are listed in [`docs/metrics.md`](docs/metrics.md#open-points--next-steps). CI runs against mocked REST responses taken from the Veeam documentation and recorded in the lab. Expect bugs and breaking changes, try it on a non-production VBR server first, and use it at your own risk. Feedback and issues are welcome.

PowerShell exporter for Veeam Backup & Replication 13. Runs as a scheduled task on the VBR server, reads the REST API on `localhost:9419` (read-only) and writes `.prom` files into the textfile directory of the windows_exporter.

## Purpose

Make the Veeam backup state visible in Prometheus and Grafana without an additional service or port on the backup server:

- **Jobs:** last result (Success/Warning/Failed), enabled/running, last and next run, number of objects.
- **Objects:** last result, last run, processed data and last error message per VM or protected object, to find VMs that are not backed up.
- **Repositories:** capacity, free space, space used by backups, online and out-of-date status, SOBR membership.
- **License:** validity, license and support expiration, licensed and used instances.
- **Exporter health:** success and duration of each collector, so a stalled export gets noticed.

The windows_exporter, which runs on the server anyway, serves the files to Prometheus through its textfile collector. The exporter only reads: apart from login and logout it calls GET endpoints exclusively and changes nothing in VBR.

**Specification:** metric names, labels, value codes, example alerts and open points are in [`docs/metrics.md`](docs/metrics.md). Development rules: [`CLAUDE.md`](CLAUDE.md).

## Prerequisites

| What | Details |
| --- | --- |
| Veeam Backup & Replication | 13 (13.0 or later), REST API on `localhost:9419` (REST revision 1.3-rev0 to 1.3-rev2, detected automatically). VBR 12 is not supported. |
| windows_exporter | as a service on the VBR server, with the textfile collector enabled (not a default collector in windows_exporter 0.32, see [`deploy/README.md`](deploy/README.md#prerequisites)) |
| PowerShell | Windows PowerShell 5.1 (REST task, installation). License task: PowerShell 7 and the installed Veeam console (both come with VBR 13) |
| Veeam account | local Windows user with the VBR role **Backup Viewer** for the REST task |
| Permissions | installation in a PowerShell **as Administrator** |
| Prometheus | scrapes the windows_exporter (default port 9182) |
| Grafana | dashboard and alert rules (Grafana-managed alerting), checked with Grafana 13.3 |

Details in [`deploy/README.md`](deploy/README.md#prerequisites).

## Status

"Implemented" means written and covered by Pester tests against mocks in CI. "Lab test" is the result against a real server: VBR 13.1 on Windows Server 2025 with windows_exporter 0.32.1 (November 2026), one server with file share backup jobs (Success, Failed, never run), a standard repository and a scale-out repository with two extents. No VM backup jobs, agents or tape (no hypervisor in the lab), no production use yet.

| Part | Status | Lab test (VBR 13.1) |
| --- | --- | --- |
| Auth (OAuth2 password grant, logout), version probe | implemented | works; the probe skips an unsupported revision under Windows PowerShell 5.1 and 7 (checked by putting an unknown revision first) |
| Certificate pinning (5.1: validation callback, 7: HttpClientHandler) | implemented | works (REST task under 5.1, self-signed VBR certificate) |
| Writer (atomic, UTF-8 without BOM, LF) | implemented | works |
| Collector `jobs` → `veeam_jobs.prom` | implemented | works; file share jobs appear as `job_type="FileBackup"`, `workload="File"`. The configuration backup job is not in `jobs/states` |
| Collector `objects` → `veeam_objects.prom` | implemented | works for file share jobs (object = file server); VM jobs not tested |
| Collector `repositories` → `veeam_repositories.prom` | implemented | works, including SOBR extents (the SOBR itself has no row of its own) |
| Health → `veeam_exporter.prom` | implemented | works; `vbr_version` read locally from the backup service binary (OP-13) |
| License task → `veeam_license.prom`, health → `veeam_exporter_license.prom` | implemented | works as SYSTEM with PowerShell 7 (trial license) |
| Deploy: install script, tasks, credential for SYSTEM, uninstall | implemented | install, update and credential handover work; ACLs as documented; textfile collector check asks the running windows_exporter; uninstallation removes tasks, `veeam_*.prom` files, installation and data; a data directory created beforehand by a normal user aborts the installation; under an `AllSigned` policy the scripts do not run (see [`deploy/README.md`](deploy/README.md#to-verify-in-the-lab)) |
| Grafana dashboard (`dashboards/`) | implemented | works in Grafana 13.3: every panel shows the lab data; status tiles, jobs with result, schedule (scheduled, chained, manual) and next run, the failed object with its message, repositories including the SOBR extents, license and exporter health |
| Grafana alert rules (`alerting/`) | implemented, logic unit-tested with promtool | works in Grafana 13.3: all rules evaluate without errors; the failed job and object (after 45 minutes) and the expiring trial license alert; `VeeamJobNotRun` leaves out jobs without a schedule (also one whose schedule is disabled) and a job that never ran; a test webhook got the notifications. Disabled jobs only in the promtool tests (no disabled job in the lab at the time) |
| Test suite on the VBR server | - | passes under Windows PowerShell 5.1 and PowerShell 7 with VBR 13.1 and its PowerShell module installed: 341 passed, 0 failed; skipped are the tests that need promtool or openssl and the edition-specific certificate test of the other edition |

## Grafana dashboard

`dashboards/veeam-vbr.json` shows what the exporter collects, for one or several VBR servers:

- status tiles: failed jobs and objects, jobs with warnings, offline and nearly full repositories, days until the license expires, failing collectors, textfile read errors
- jobs: last result, enabled, running, time since the last run (yellow after 26 h, like `VeeamJobNotRun`), next run
- objects whose last task run ended with Warning or Failed, with the error message
- repositories: fill level (`1 - free / capacity`) now and over time, online and out-of-date status, sizes
- license and exporter health: validity, expiration, instance usage, success, duration and data age per collector

Import it in Grafana under *Dashboards > New > Import*. It needs a Prometheus data source that scrapes the windows_exporter of the VBR servers. Variables: `datasource` (Prometheus data source) and `instance` (one or more VBR servers, taken from `veeam_exporter_info`). Status colours always come with a symbol and a label (Success, Warning, Failed).

Built with Grafana 13.3 and Prometheus 3.16 against the fixtures in `tests/fixtures/expected`, then checked against the lab VBR 13.1 server (see [Status](#status)). `tests/Dashboard.Tests.ps1` checks that every query uses the data source variable, filters by `instance` and only uses metrics from `docs/metrics.md`.

## Installation

Manually per VBR server, in a PowerShell as Administrator:

```powershell
.\deploy\Install-VeeamExporter.ps1
```

The script reads the thumbprint of the REST API (with confirmation), asks for the Veeam account (role **Backup Viewer**), stores it with DPAPI for SYSTEM and sets up two tasks: REST every 15 minutes, license daily. It then starts both once. Details, prerequisites, update and uninstallation: [`deploy/README.md`](deploy/README.md).

`vbr_version` in `veeam_exporter_info` is the file version of the Veeam backup service on the server, read locally, because only Backup Administrator may read it through REST (`/api/v1/serverInfo`, OP-13 in `docs/metrics.md`).

## Running by hand (testing, troubleshooting)

```powershell
.\src\Invoke-VeeamExporter.ps1 `
    -CredentialPath 'C:\ProgramData\VeeamExporter\veeam.cred.xml' `
    -CertificateThumbprint '<SHA-1 thumbprint>' `
    -TextfileDirectory 'C:\Program Files\windows_exporter\textfile_inputs'
.\src\Invoke-VeeamLicenseExporter.ps1 -TextfileDirectory 'C:\Program Files\windows_exporter\textfile_inputs'
```

The credential is encrypted for SYSTEM; when run by hand, `Invoke-VeeamExporter.ps1` therefore needs its own credential, created in your own account with `Get-Credential | Export-Clixml -LiteralPath <file>`. Without `-CertificateThumbprint` the normal .NET certificate validation applies, and the self-signed VBR certificate is rejected. Exit code 0 if all collectors succeeded, otherwise 1. A parameter value outside its range is a configuration error: the run writes `veeam_exporter.prom` with the requested collectors at 0, then stops with the error.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-Collector` | `jobs,objects,repositories` | Which collectors run (also as a comma-separated list). The case does not matter; each collector runs once, and file names and labels are always lower case. |
| `-ObjectLookbackDays` | `8` | How far back `objects` reads task sessions. |
| `-ObjectSessionType` | `BackupJob,ReplicaJob` | Session types for `objects` (see OP-11 in `docs/metrics.md`). |
| `-ApiVersion` | probe | Fixed `x-api-version`, skips the version probe. |
| `-TimeoutSec` | `60` | Timeout per HTTP request, 1 to 600 seconds. |
| `-LogPath` | – | Transcript of the run (overwritten every time). |

The license task runs as SYSTEM without a stored password and reads the license with `Get-VBRInstalledLicense`. Under VBR 13 it needs PowerShell 7 and the Veeam console. It writes its health status to `veeam_exporter_license.prom` (`collector="license"`), so it does not overwrite the REST task's `veeam_exporter.prom`.

## Alert rules

`alerting/veeam-alerts.json` holds ten Grafana alert rules, specified in [`docs/metrics.md`](docs/metrics.md#example-alerts): failed jobs and objects, jobs with warnings, jobs not run for 26 hours, scheduled jobs that never ran, full and offline repositories, expiring license, and stale exporter files. They are a template: neither the exporter nor the install script touches Grafana, and nothing is imported automatically. Pick the rules you need. The thresholds are proposals; `for: 45m` on the job and object rules covers the Veeam retry window.

Each rule queries Prometheus (`A`, an instant query that returns the value, e.g. hours since the last run) and fires when the threshold `B` is met. Rules come with the label `severity` (`critical` or `warning`) and a `summary` annotation. Contact points and notification policies stay with you: route by `severity`.

Two ways to get them into Grafana:

- **Create them in the Grafana UI** (editable there): a new Grafana-managed alert rule per alert, with the query from `docs/metrics.md` as an instant query `A`, the condition as a threshold on `A`, `for` and the label `severity` from there, and the `summary` from `alerting/veeam-alerts.json`.
- **Provision the file** (read-only in the UI, change the file instead):
  1. Remove the rules you do not want from a copy of `alerting/veeam-alerts.json` and put it into the alerting provisioning directory of Grafana, e.g. `/etc/grafana/provisioning/alerting/`. The rules land in the folder `Veeam`, group `veeam`, evaluated every minute.
  2. Set the environment variable `VEEAM_PROMETHEUS_DATASOURCE_UID` for the Grafana server to the UID of the Prometheus data source that scrapes the VBR servers (shown in the URL of the data source settings, `.../connections/datasources/edit/<uid>`). Grafana replaces `${VEEAM_PROMETHEUS_DATASOURCE_UID}` in the file with it. Without the variable the rules have no data source and show up as `DatasourceError`.
  3. Restart Grafana, or reload the provisioned alerting resources with `POST /api/admin/provisioning/alerting/reload`.

Earlier versions of this repo shipped Prometheus rules (`rules/veeam.rules.yml`); remove them from `rule_files` in Prometheus if you loaded them, otherwise both alert.

`tests/alerting/veeam-alerts.test.yml` tests the logic of every rule with `promtool test rules`, including the cases that must not fire (a failed job that is retrying, a disabled job, a job without a schedule, a job that ran with an unknown result, object storage without capacity). `tests/Alerts.Tests.ps1` builds an equivalent Prometheus rule for each Grafana rule for this (query `A` combined with the threshold of `B`) and checks the file against the spec.

## Tests

```powershell
Invoke-Pester -Path tests                      # Pester >= 5.2, under powershell.exe and pwsh
Invoke-ScriptAnalyzer -Path src -Recurse
Invoke-ScriptAnalyzer -Path deploy -Recurse
```

If `promtool` is in the PATH, `tests/Promtool.Tests.ps1` additionally checks the expected and the generated `.prom` files with `promtool check metrics`, and `tests/Alerts.Tests.ps1` runs the logic tests of the alert rules; otherwise these tests are skipped.

CI (`.github/workflows/ci.yml`) runs on every pull request and on pushes to `main`, on `windows-latest`, under Windows PowerShell 5.1 and PowerShell 7: Pester, PSScriptAnalyzer (errors fail the build) and `promtool check metrics` on all `.prom` files the tests generated. Locally the same check works like this:

```powershell
$env:VEEAM_TEST_PROM_OUTPUT = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'veeam-prom'
Invoke-Pester -Path tests
./tests/Invoke-PromtoolCheck.ps1 -Path $env:VEEAM_TEST_PROM_OUTPUT, 'tests/fixtures/expected'
```

Source and test files are pure ASCII (this is tested), because Windows PowerShell 5.1 reads files without a BOM as ANSI.

## License

[MIT](LICENSE). Veeam and Veeam Backup & Replication are trademarks of Veeam Software Group GmbH; this project is not an official Veeam product.
