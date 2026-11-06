# Veeam Prometheus Exporter (windows_exporter Textfile)

PowerShell-Exporter für Veeam Backup & Replication 12.3.1 und 13. Läuft als geplanter Task auf dem VBR-Server, liest die REST API auf `localhost:9419` (nur lesend) und schreibt `.prom`-Dateien ins Textfile-Verzeichnis des windows_exporter.

Spezifikation: [`docs/metrics.md`](docs/metrics.md). Regeln für die Entwicklung: [`CLAUDE.md`](CLAUDE.md).

## Stand

| Teil | Status |
| --- | --- |
| Auth (OAuth2 Password-Grant, Logout), Versions-Probe | fertig |
| Zertifikat-Pinning (5.1: Validation-Callback, 7: HttpClientHandler) | fertig |
| Writer (atomar, UTF-8 ohne BOM, LF) | fertig |
| Collector `jobs` → `veeam_jobs.prom` | fertig |
| Collector `objects` → `veeam_objects.prom` | fertig |
| Collector `repositories` → `veeam_repositories.prom` | fertig |
| Health → `veeam_exporter.prom` | fertig |
| Lizenz-Task → `veeam_license.prom`, Health → `veeam_exporter_license.prom` | fertig |
| Deploy (Tasks, Install-Script), Alert-Regeln, Dashboard | offen |

## Aufruf

Das Veeam-Konto braucht die Rolle **Backup Viewer**. `vbr_version` in `veeam_exporter_info` bleibt damit leer, weil `/api/v1/serverInfo` nur Backup Administrator lesen darf (OP-13 in `docs/metrics.md`).

Credential einmalig **als Task-Konto** anlegen (DPAPI, nur dieses Konto auf diesem Server kann es lesen):

```powershell
Get-Credential -UserName 'veeam-exporter' | Export-Clixml -Path 'C:\ProgramData\VeeamExporter\veeam.cred.xml'
```

Thumbprint des Zertifikats ermitteln, das VBR auf Port 9419 ausliefert (in der Regel in `Cert:\LocalMachine\My`), und übergeben:

```powershell
.\src\Invoke-VeeamExporter.ps1 `
    -CredentialPath 'C:\ProgramData\VeeamExporter\veeam.cred.xml' `
    -CertificateThumbprint '<SHA-1-Thumbprint>' `
    -TextfileDirectory 'C:\Program Files\windows_exporter\textfile_inputs'
```

Ohne `-CertificateThumbprint` gilt die normale .NET-Zertifikatsprüfung; das selbstsignierte VBR-Zertifikat wird dann abgelehnt. `-ApiVersion` überspringt die Versions-Probe. Exit-Code 0, wenn alle Collectors erfolgreich waren, sonst 1.

| Parameter | Standard | Bedeutung |
| --- | --- | --- |
| `-Collector` | `jobs`, `objects`, `repositories` | Welche Collectors laufen. |
| `-ObjectLookbackDays` | `8` | Wie weit `objects` Task-Sessions zurückliest. |
| `-ObjectSessionType` | `BackupJob`, `ReplicaJob` | Session-Typen für `objects` (siehe OP-11 in `docs/metrics.md`). |
| `-TimeoutSec` | `60` | Timeout pro HTTP-Request. |

## Lizenz-Task

Eigener geplanter Task, einmal täglich, als **SYSTEM** oder als lokales Konto mit der VBR-Rolle Backup Administrator; kein gespeichertes Passwort. Liest die Lizenz mit `Get-VBRInstalledLicense` aus dem Veeam-PowerShell-Modul (keine REST-API).

```powershell
# VBR 13: PowerShell 7 und installierte Veeam-Console nötig
pwsh.exe -NoProfile -File .\src\Invoke-VeeamLicenseExporter.ps1 -TextfileDirectory 'C:\Program Files\windows_exporter\textfile_inputs'
# VBR 12: Windows PowerShell 5.1
powershell.exe -NoProfile -File .\src\Invoke-VeeamLicenseExporter.ps1
```

Der Task schreibt seinen Health-Status in `veeam_exporter_license.prom` (`collector="license"`), damit er `veeam_exporter.prom` des REST-Tasks nicht überschreibt.

## Tests

```powershell
Invoke-Pester -Path tests                      # Pester >= 5.2, unter powershell.exe und pwsh
Invoke-ScriptAnalyzer -Path src -Recurse
```

Liegt `promtool` im PATH, prüft `tests/Promtool.Tests.ps1` die erwarteten und die erzeugten `.prom`-Dateien zusätzlich mit `promtool check metrics`; sonst werden diese Tests übersprungen.

Quell- und Testdateien sind reines ASCII (wird getestet), weil Windows PowerShell 5.1 Dateien ohne BOM als ANSI liest.
