# Veeam Prometheus Exporter (windows_exporter Textfile)

> **Status: experimental.** This exporter has not been run against a real Veeam Backup & Replication server yet. All tests run in CI against mocked REST responses taken from the Veeam documentation. Expect bugs and breaking changes, try it on a non-production VBR server first, and use it at your own risk. Feedback and issues are welcome.

PowerShell exporter for Veeam Backup & Replication 12.3.1 and 13. Runs as a scheduled task on the VBR server, reads the REST API on `localhost:9419` (read-only) and writes `.prom` files into the textfile directory of the windows_exporter.

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
| Veeam Backup & Replication | 12.3.1 or 13, REST API on `localhost:9419` (REST revision 1.2-rev1 to 1.3-rev2, detected automatically) |
| windows_exporter | as a service on the VBR server, textfile collector enabled (default) |
| PowerShell | Windows PowerShell 5.1 (REST task, installation). License task under VBR 13: PowerShell 7 and the installed Veeam console |
| Veeam account | local Windows user with the VBR role **Backup Viewer** for the REST task |
| Permissions | installation in a PowerShell **as Administrator** |
| Prometheus | scrapes the windows_exporter (default port 9182) |

Details in [`deploy/README.md`](deploy/README.md#prerequisites).

## Status

"Implemented" means written and covered by Pester tests against mocks in CI. None of it has been verified on a live VBR server yet.

| Part | Status |
| --- | --- |
| Auth (OAuth2 password grant, logout), version probe | implemented |
| Certificate pinning (5.1: validation callback, 7: HttpClientHandler) | implemented |
| Writer (atomic, UTF-8 without BOM, LF) | implemented |
| Collector `jobs` → `veeam_jobs.prom` | implemented |
| Collector `objects` → `veeam_objects.prom` | implemented |
| Collector `repositories` → `veeam_repositories.prom` | implemented |
| Health → `veeam_exporter.prom` | implemented |
| License task → `veeam_license.prom`, health → `veeam_exporter_license.prom` | implemented |
| Deploy: install script, tasks, credential for SYSTEM, uninstall | implemented |
| Verified on a live VBR 12.3.1 and 13 server | open |
| Grafana dashboard (`dashboards/`) | implemented, tried against mocked data only |
| Alert rules (`rules/`) | open |

## Grafana dashboard

`dashboards/veeam-vbr.json` shows what the exporter collects, for one or several VBR servers:

- status tiles: failed jobs and objects, jobs with warnings, offline and nearly full repositories, days until the license expires, failing collectors, textfile read errors
- jobs: last result, enabled, running, time since the last run (yellow after 26 h, like `VeeamJobNotRun`), next run
- objects whose last task run ended with Warning or Failed, with the error message
- repositories: fill level (`1 - free / capacity`) now and over time, online and out-of-date status, sizes
- license and exporter health: validity, expiration, instance usage, success, duration and data age per collector

Import it in Grafana under *Dashboards > New > Import*. It needs a Prometheus data source that scrapes the windows_exporter of the VBR servers. Variables: `datasource` (Prometheus data source) and `instance` (one or more VBR servers, taken from `veeam_exporter_info`). Status colours always come with a symbol and a label (Success, Warning, Failed).

Built and checked with Grafana 13.3 and Prometheus 3.16 against the fixtures in `tests/fixtures/expected`, not against a live VBR server yet. `tests/Dashboard.Tests.ps1` checks that every query uses the data source variable, filters by `instance` and only uses metrics from `docs/metrics.md`.

## Installation

Manually per VBR server, in a PowerShell as Administrator:

```powershell
.\deploy\Install-VeeamExporter.ps1
```

The script reads the thumbprint of the REST API (with confirmation), asks for the Veeam account (role **Backup Viewer**), stores it with DPAPI for SYSTEM and sets up two tasks: REST every 15 minutes, license daily. It then starts both once. Details, prerequisites, update and uninstallation: [`deploy/README.md`](deploy/README.md).

With the Viewer role, `vbr_version` in `veeam_exporter_info` stays empty, because only Backup Administrator may read `/api/v1/serverInfo` (OP-13 in `docs/metrics.md`).

## Running by hand (testing, troubleshooting)

```powershell
.\src\Invoke-VeeamExporter.ps1 `
    -CredentialPath 'C:\ProgramData\VeeamExporter\veeam.cred.xml' `
    -CertificateThumbprint '<SHA-1 thumbprint>' `
    -TextfileDirectory 'C:\Program Files\windows_exporter\textfile_inputs'
.\src\Invoke-VeeamLicenseExporter.ps1 -TextfileDirectory 'C:\Program Files\windows_exporter\textfile_inputs'
```

The credential is encrypted for SYSTEM; when run by hand, `Invoke-VeeamExporter.ps1` therefore needs its own credential, created in your own account with `Get-Credential | Export-Clixml -LiteralPath <file>`. Without `-CertificateThumbprint` the normal .NET certificate validation applies, and the self-signed VBR certificate is rejected. Exit code 0 if all collectors succeeded, otherwise 1.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-Collector` | `jobs,objects,repositories` | Which collectors run (also as a comma-separated list). |
| `-ObjectLookbackDays` | `8` | How far back `objects` reads task sessions. |
| `-ObjectSessionType` | `BackupJob,ReplicaJob` | Session types for `objects` (see OP-11 in `docs/metrics.md`). |
| `-ApiVersion` | probe | Fixed `x-api-version`, skips the version probe. |
| `-TimeoutSec` | `60` | Timeout per HTTP request. |
| `-LogPath` | – | Transcript of the run (overwritten every time). |

The license task runs as SYSTEM without a stored password and reads the license with `Get-VBRInstalledLicense`. Under VBR 13 it needs PowerShell 7 and the Veeam console. It writes its health status to `veeam_exporter_license.prom` (`collector="license"`), so it does not overwrite the REST task's `veeam_exporter.prom`.

## Tests

```powershell
Invoke-Pester -Path tests                      # Pester >= 5.2, under powershell.exe and pwsh
Invoke-ScriptAnalyzer -Path src -Recurse
Invoke-ScriptAnalyzer -Path deploy -Recurse
```

If `promtool` is in the PATH, `tests/Promtool.Tests.ps1` additionally checks the expected and the generated `.prom` files with `promtool check metrics`; otherwise these tests are skipped.

CI (`.github/workflows/ci.yml`) runs on every pull request and on pushes to `main`, on `windows-latest`, under Windows PowerShell 5.1 and PowerShell 7: Pester, PSScriptAnalyzer (errors fail the build) and `promtool check metrics` on all `.prom` files the tests generated. Locally the same check works like this:

```powershell
$env:VEEAM_TEST_PROM_OUTPUT = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'veeam-prom'
Invoke-Pester -Path tests
./tests/Invoke-PromtoolCheck.ps1 -Path $env:VEEAM_TEST_PROM_OUTPUT, 'tests/fixtures/expected'
```

Source and test files are pure ASCII (this is tested), because Windows PowerShell 5.1 reads files without a BOM as ANSI.

## License

[MIT](LICENSE). Veeam and Veeam Backup & Replication are trademarks of Veeam Software Group GmbH; this project is not an official Veeam product.
