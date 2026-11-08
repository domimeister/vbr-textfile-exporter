# Deploy (manually per VBR server)

The install script sets up the exporter on a VBR server: files, encrypted credential and two scheduled tasks. It changes nothing in VBR itself.

## Prerequisites

| What | Details |
| --- | --- |
| VBR | 13 or later (REST API on `localhost:9419`). VBR 12 is not supported; the install script refuses a Veeam module older than 13. |
| windows_exporter | installed as a service, with the **textfile collector enabled**. windows_exporter 0.32 does not enable it by default, see below. |
| Veeam account for REST | local Windows user with the VBR role **Backup Viewer** (console: *Users and Roles*). It needs no Windows admin rights. |
| License task | The Veeam PowerShell module, **PowerShell 7** and the installed Veeam console (VBR 13 setup installs all three). The task runs as SYSTEM; SYSTEM must be Backup Administrator in VBR (default via the local Administrators group). |
| Execution | Windows PowerShell 5.1, **as Administrator** |

Enabling the textfile collector, e.g. in the `config.yaml` that the MSI installs next to `windows_exporter.exe` (the quotes are needed because of `[`):

```yaml
collectors:
  enabled: '[defaults],textfile'
```

Then `Restart-Service windows_exporter`. `(Invoke-WebRequest -UseBasicParsing http://localhost:9182/metrics).Content -split "`n" | Select-String 'collector="textfile"'` must show `windows_exporter_collector_success{collector="textfile"} 1`. The install script asks the running service the same way and warns if the collector is off or cannot be checked.

Example for the REST account:

```powershell
$pw = Read-Host -AsSecureString 'Password for veeam-exporter'
New-LocalUser -Name 'veeam-exporter' -Password $pw -PasswordNeverExpires -UserMayNotChangePassword -Description 'Veeam Exporter (REST, Backup Viewer)'
# then in the Veeam console: Menu > Users and Roles > Add > VBR01\veeam-exporter, role Veeam Backup Viewer
```

## Installation

1. Copy the repository or release folder to the server, e.g. to `C:\Install\vbr-textfile-exporter`.
2. Open PowerShell **as Administrator**:

```powershell
cd C:\Install\vbr-textfile-exporter
Get-ChildItem -Recurse | Unblock-File      # only after downloading as ZIP
.\deploy\Install-VeeamExporter.ps1
```

The script asks twice:

- **Certificate:** it reads the certificate from `localhost:9419` and shows subject, expiration date and thumbprint. Answering *Yes* pins the thumbprint; from then on the exporter accepts only this certificate. If you already know the thumbprint, pass `-CertificateThumbprint`.
- **Credential:** user and password of the REST account, e.g. `VBR01\veeam-exporter`.

It then starts both tasks once and shows the result:

```text
veeam_exporter_collector_success{collector="jobs"} 1
veeam_exporter_collector_success{collector="objects"} 1
veeam_exporter_collector_success{collector="repositories"} 1
veeam_exporter_collector_success{collector="license"} 1
```

Test without changes: `.\deploy\Install-VeeamExporter.ps1 -WhatIf`.

## What gets installed

| Path / object | Content |
| --- | --- |
| `C:\Program Files\VeeamExporter\` | scripts, module `VeeamExporter`, `deploy\` (for updates and uninstallation) |
| `C:\ProgramData\VeeamExporter\veeam.cred.xml` | credential of the REST account, DPAPI for SYSTEM |
| `C:\ProgramData\VeeamExporter\logs\` | `rest.log`, `license.log`: transcript of the last run |
| Task `\VeeamExporter\Veeam Exporter REST` | every 15 minutes, SYSTEM, Windows PowerShell 5.1, time limit 10 minutes |
| Task `\VeeamExporter\Veeam Exporter License` | daily at 06:17, SYSTEM, PowerShell 7, time limit 30 minutes |
| Textfile directory of the windows_exporter | `veeam_*.prom`, read from the service (`--collector.textfile.directories` or config file) |

### Permissions

The tasks run as SYSTEM. Everything they execute, read or write must therefore be protected from normal accounts. Otherwise a local user could swap a script or use a junction to make SYSTEM write arbitrary files. The install script sets and checks:

| Directory | Owner | Permissions (no inheritance) |
| --- | --- | --- |
| Installation (`C:\Program Files\VeeamExporter`) | Administrators | SYSTEM, Administrators: full control; Users: read and execute |
| Data (`C:\ProgramData\VeeamExporter`) | Administrators | SYSTEM and Administrators only |

- **New directories** are created directly with this ACL (`CreateDirectory` with a security descriptor). There is thus no moment in which a new folder under `C:\ProgramData` has the inherited permissions that let any user create files and folders in it. The owner is set right afterwards.
- **Existing directories** are taken over only if they and everything in them belong to SYSTEM, the Administrators, TrustedInstaller or a local administrator, and contain no junctions or symbolic links. Otherwise the script aborts. Reason: any user may create folders under `C:\ProgramData`, and the owner of a folder can change its permissions again at any time. In that case, inspect the folder, delete it and run the installation again.
- **After copying** it checks once more: no other account may write to the installation or read the data directory at all.
- **Textfile directory:** the script aborts if other accounts may write there. Reading is allowed. With `-AllowUnsafeTextfileDirectory` it only warns instead. Independently of that, the exporter never writes through an existing `.tmp` file and refuses a directory in place of a `.prom` file.
- **Uninstallation:** if the installation or the data directory contains a junction or symbolic link, the script deletes nothing. Windows PowerShell 5.1 can follow a junction when deleting recursively.

The tasks start with `-ExecutionPolicy RemoteSigned`.

### How the credential gets to SYSTEM

DPAPI encrypts per account: what an admin stores with `Export-Clixml` cannot be read by SYSTEM. The install script therefore does the following:

1. It asks for the credential in the admin session.
2. It writes the password with DPAPI (scope *LocalMachine*) to a handover file under `C:\ProgramData\VeeamExporter`. Only SYSTEM and Administrators can read this file.
3. It starts a one-time task as SYSTEM (`Save-VeeamExporterSystemCredential.ps1`) that stores the credential for SYSTEM with `Export-Clixml`.
4. Task and handover file are deleted afterwards in every case, including on failure.

The password never appears in plain text on disk, on a command line or in a log.

## Operation

| Task | Command (as Administrator) |
| --- | --- |
| Update to a new version | in the new folder `.\deploy\Install-VeeamExporter.ps1` (the credential is kept) |
| Password of the REST account changed | `.\deploy\Install-VeeamExporter.ps1 -UpdateCredential` |
| VBR certificate renewed | `.\deploy\Install-VeeamExporter.ps1` and confirm the new thumbprint. Until then the REST task reports `collector_success 0`. |
| Manual run | `Start-ScheduledTask -TaskPath '\VeeamExporter\' -TaskName 'Veeam Exporter REST'` |
| Troubleshooting | `C:\ProgramData\VeeamExporter\logs\rest.log` or `license.log` |
| Check what Prometheus sees | `(Invoke-WebRequest -UseBasicParsing http://localhost:9182/metrics).Content -split "`n" \| Select-String '^veeam_'` |

## Uninstallation

```powershell
C:\Program Files\VeeamExporter\deploy\Uninstall-VeeamExporter.ps1
```

The script removes the following:
- all tasks under `\VeeamExporter\`,
- the `veeam_*.prom` files in the textfile directory, so Prometheus no longer sees stale values,
- the installation,
- credential and logs, unless `-KeepData` is given.

It only deletes folders that look like an exporter installation.

## Parameters of Install-VeeamExporter.ps1

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-CertificateThumbprint` | from `localhost:9419`, with confirmation | certificate of the REST API |
| `-Credential` | prompt | REST account, only needed on first installation or with `-UpdateCredential` |
| `-UpdateCredential` | – | set the credential again |
| `-TextfileDirectory` | from the windows_exporter service | target of the `.prom` files |
| `-InstallPath` / `-DataPath` | `C:\Program Files\VeeamExporter` / `C:\ProgramData\VeeamExporter` | |
| `-VeeamModule` | searched in PSModulePath and the console folder | name or path (`.psd1`) of the Veeam module |
| `-SkipLicenseTask` | – | set up only the REST task |
| `-RestIntervalMinutes` | `15` | interval of the REST task |
| `-LicenseTime` | `06:17` | time of day of the license task |
| `-Collector` | `jobs,objects,repositories` | REST collectors |
| `-ObjectLookbackDays` | `8` | lookback of the objects collector |
| `-NoStart` | – | do not start the tasks after installation |
| `-Force` | – | accept the certificate without confirmation |
| `-AllowUnsafeTextfileDirectory` | – | only warn instead of aborting if other accounts may write to the textfile directory |
| `-WhatIf` | – | only show what would happen |

## To verify in the lab

The deploy logic is tested under Linux with Pester; the Windows cmdlets (scheduled tasks, ACLs, DPAPI) are replaced by mocks there. To verify on a real server:

Results of the lab test with VBR 13.1 on Windows Server 2025 (November 2026) are marked; open items still need a check.

- [x] Installation under Windows PowerShell 5.1 on VBR 13, including the credential handover to SYSTEM. An update run (without `-Credential`) keeps the credential.
- [x] VBR 13: the Veeam PowerShell module is at `C:\Program Files\Veeam\Backup and Replication\Console\Veeam.Backup.PowerShell\Veeam.Backup.PowerShell.psd1` (13.1: `ModuleVersion` 13.1.2.57, `PowerShellVersion` 7.6), and `pwsh.exe` finds it under SYSTEM via `PSModulePath`.
- [x] SYSTEM is Backup Administrator in VBR by default (role assignment *Administrators → BackupAdmin*), so `Get-VBRInstalledLicense` works (OP-3 in `docs/metrics.md`).
- [x] The REST task repeats every 15 minutes without an end (`Duration` empty); checked over 2.5 hours on Windows Server 2025, no missed runs.
- [x] Permissions on creation: the test `Windows: new directory has from the start ...` in `tests/Deploy.Tests.ps1` passes under Windows PowerShell 5.1 and PowerShell 7 on Windows Server 2025.
- [x] Permissions after installation: `C:\Program Files\VeeamExporter` and `C:\ProgramData\VeeamExporter` have owner *Administrators*, inheritance off and exactly the permissions from the table above.
- [x] A `C:\ProgramData\VeeamExporter` created beforehand by a normal user leads to an abort. The installation stops before the credential and the tasks with `Refusing to use C:\ProgramData\VeeamExporter: it was not created by an administrator (or contains links)` and lists the directory and each file in it with its owner. At that point the installation directory is already set up and filled; it has the protected ACL, and the next run uses it again. Remove the data directory and run the installation again.
- [x] Uninstallation removes tasks, `.prom` files, installation and data as described, also when started from the installation directory it deletes. Other `.prom` files in the textfile directory stay.
- [x] If a GPO enforces `AllSigned`, the unsigned scripts do not run. In that case sign the scripts or set up an exception. Checked with the registry values of the policy for Windows PowerShell and PowerShell 7: `Install-VeeamExporter.ps1` is refused ("is not digitally signed") despite `-ExecutionPolicy Bypass`, both tasks end with result 1 and the `.prom` files stay unchanged, which `VeeamExporterStale` and `VeeamExporterLicenseStale` are there to catch. PowerShell 7 could not even load its own module `Microsoft.PowerShell.Security` in a non-interactive session under that policy. Without the policy both tasks run again.
