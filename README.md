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
| Deploy: Install-Script, Tasks, Credential für SYSTEM, Uninstall | fertig |
| Alert-Regeln (`rules/`), Dashboard (`dashboards/`) | offen |

## Installation

Manuell pro VBR-Server, in einer PowerShell als Administrator:

```powershell
.\deploy\Install-VeeamExporter.ps1
```

Das Script liest den Thumbprint der REST-API (mit Rückfrage), fragt das Veeam-Konto ab (Rolle **Backup Viewer**), speichert es per DPAPI für SYSTEM und richtet zwei Tasks ein: REST alle 15 Minuten, Lizenz täglich. Danach startet es beide einmal. Details, Voraussetzungen, Update und Deinstallation: [`deploy/README.md`](deploy/README.md).

`vbr_version` in `veeam_exporter_info` bleibt mit der Viewer-Rolle leer, weil `/api/v1/serverInfo` nur Backup Administrator lesen darf (OP-13 in `docs/metrics.md`).

## Aufruf von Hand (Test, Fehlersuche)

```powershell
.\src\Invoke-VeeamExporter.ps1 `
    -CredentialPath 'C:\ProgramData\VeeamExporter\veeam.cred.xml' `
    -CertificateThumbprint '<SHA-1-Thumbprint>' `
    -TextfileDirectory 'C:\Program Files\windows_exporter\textfile_inputs'
.\src\Invoke-VeeamLicenseExporter.ps1 -TextfileDirectory 'C:\Program Files\windows_exporter\textfile_inputs'
```

Das Credential ist für SYSTEM verschlüsselt; von Hand aufgerufen braucht `Invoke-VeeamExporter.ps1` deshalb ein eigenes, mit `Get-Credential | Export-Clixml -Path <datei>` im eigenen Konto erzeugtes Credential. Ohne `-CertificateThumbprint` gilt die normale .NET-Zertifikatsprüfung, und das selbstsignierte VBR-Zertifikat wird abgelehnt. Exit-Code 0, wenn alle Collectors erfolgreich waren, sonst 1.

| Parameter | Standard | Bedeutung |
| --- | --- | --- |
| `-Collector` | `jobs,objects,repositories` | Welche Collectors laufen (auch als Kommaliste). |
| `-ObjectLookbackDays` | `8` | Wie weit `objects` Task-Sessions zurückliest. |
| `-ObjectSessionType` | `BackupJob,ReplicaJob` | Session-Typen für `objects` (siehe OP-11 in `docs/metrics.md`). |
| `-ApiVersion` | Probe | Feste `x-api-version`, überspringt die Versions-Probe. |
| `-TimeoutSec` | `60` | Timeout pro HTTP-Request. |
| `-LogPath` | – | Transcript des Laufs (wird jedes Mal überschrieben). |

Der Lizenz-Task läuft als SYSTEM ohne gespeichertes Passwort und liest die Lizenz mit `Get-VBRInstalledLicense`. Unter VBR 13 braucht er PowerShell 7 und die Veeam-Console. Seinen Health-Status schreibt er in `veeam_exporter_license.prom` (`collector="license"`), damit er `veeam_exporter.prom` des REST-Tasks nicht überschreibt.

## Tests

```powershell
Invoke-Pester -Path tests                      # Pester >= 5.2, unter powershell.exe und pwsh
Invoke-ScriptAnalyzer -Path src -Recurse
Invoke-ScriptAnalyzer -Path deploy -Recurse
```

Liegt `promtool` im PATH, prüft `tests/Promtool.Tests.ps1` die erwarteten und die erzeugten `.prom`-Dateien zusätzlich mit `promtool check metrics`; sonst werden diese Tests übersprungen.

Quell- und Testdateien sind reines ASCII (wird getestet), weil Windows PowerShell 5.1 Dateien ohne BOM als ANSI liest.
