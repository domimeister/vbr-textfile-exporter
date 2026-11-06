# Deploy (manuell pro VBR-Server)

Das Install-Script richtet den Exporter auf einem VBR-Server ein: Dateien, verschlüsseltes Credential und zwei geplante Tasks. Es ändert nichts an VBR selbst.

## Voraussetzungen

| Was | Details |
| --- | --- |
| VBR | 12.3.1 oder 13 (REST-API auf `localhost:9419`) |
| windows_exporter | als Dienst installiert, Textfile-Collector aktiv (Standard) |
| Veeam-Konto für REST | lokaler Windows-Benutzer, in VBR mit der Rolle **Backup Viewer** (Console: *Users and Roles*). Er braucht keine Windows-Adminrechte. |
| Lizenz-Task | Das Veeam-PowerShell-Modul. Bei VBR 13 zusätzlich **PowerShell 7** und die installierte Veeam-Console. Der Task läuft als SYSTEM; SYSTEM muss in VBR Backup Administrator sein (Standard über die lokale Gruppe Administratoren). |
| Ausführung | Windows PowerShell 5.1, **als Administrator** |

Beispiel für das REST-Konto:

```powershell
$pw = Read-Host -AsSecureString 'Passwort fuer veeam-exporter'
New-LocalUser -Name 'veeam-exporter' -Password $pw -PasswordNeverExpires -UserMayNotChangePassword -Description 'Veeam Exporter (REST, Backup Viewer)'
# danach in der Veeam-Console: Menu > Users and Roles > Add > VBR01\veeam-exporter, Rolle Veeam Backup Viewer
```

## Installation

1. Repository bzw. Release-Ordner auf den Server kopieren, z. B. nach `C:\Install\vbr-textfile-exporter`.
2. PowerShell **als Administrator** öffnen:

```powershell
cd C:\Install\vbr-textfile-exporter
Get-ChildItem -Recurse | Unblock-File      # nur nach Download als ZIP
.\deploy\Install-VeeamExporter.ps1
```

Das Script fragt zweimal nach:

- **Zertifikat:** Es liest das Zertifikat von `localhost:9419` und zeigt Subject, Ablaufdatum und Thumbprint. Mit *Ja* wird der Thumbprint gepinnt; der Exporter akzeptiert danach nur noch dieses Zertifikat. Wer den Thumbprint schon kennt, übergibt `-CertificateThumbprint`.
- **Credential:** Benutzer und Passwort des REST-Kontos, z. B. `VBR01\veeam-exporter`.

Danach startet es beide Tasks einmal und zeigt das Ergebnis:

```text
veeam_exporter_collector_success{collector="jobs"} 1
veeam_exporter_collector_success{collector="objects"} 1
veeam_exporter_collector_success{collector="repositories"} 1
veeam_exporter_collector_success{collector="license"} 1
```

Ohne Änderung testen: `.\deploy\Install-VeeamExporter.ps1 -WhatIf`.

## Was installiert wird

| Pfad / Objekt | Inhalt |
| --- | --- |
| `C:\Program Files\VeeamExporter\` | Skripte, Modul `VeeamExporter`, `deploy\` (für Updates und Deinstallation) |
| `C:\ProgramData\VeeamExporter\veeam.cred.xml` | Credential des REST-Kontos, DPAPI für SYSTEM |
| `C:\ProgramData\VeeamExporter\logs\` | `rest.log`, `license.log`: Transcript des letzten Laufs |
| Task `\VeeamExporter\Veeam Exporter REST` | alle 15 Minuten, SYSTEM, Windows PowerShell 5.1, Zeitlimit 10 Minuten |
| Task `\VeeamExporter\Veeam Exporter License` | täglich 06:17, SYSTEM, PowerShell 5.1 (VBR 12) oder 7 (VBR 13), Zeitlimit 30 Minuten |
| Textfile-Verzeichnis des windows_exporter | `veeam_*.prom`, wird aus dem Dienst gelesen (`--collector.textfile.directories` oder Konfigurationsdatei) |

`C:\ProgramData\VeeamExporter` ist nur für SYSTEM und Administratoren lesbar, ohne Vererbung. Die Tasks starten mit `-ExecutionPolicy RemoteSigned`.

### Wie das Credential zu SYSTEM kommt

DPAPI verschlüsselt pro Konto: Was ein Admin mit `Export-Clixml` speichert, kann SYSTEM nicht lesen. Das Install-Script macht deshalb Folgendes:

1. Es fragt das Credential in der Admin-Sitzung ab.
2. Es schreibt das Passwort mit DPAPI (Bereich *LocalMachine*) in eine Übergabedatei unter `C:\ProgramData\VeeamExporter`. Diese Datei ist nur für SYSTEM und Administratoren lesbar.
3. Es startet einen einmaligen Task als SYSTEM (`Save-VeeamExporterSystemCredential.ps1`), der das Credential mit `Export-Clixml` für SYSTEM speichert.
4. Task und Übergabedatei werden danach in jedem Fall gelöscht, auch bei einem Fehler.

Das Passwort steht nie im Klartext auf der Platte, in einer Kommandozeile oder in einem Log.

## Betrieb

| Aufgabe | Befehl (als Administrator) |
| --- | --- |
| Update auf neue Version | im neuen Ordner `.\deploy\Install-VeeamExporter.ps1` (Credential bleibt erhalten) |
| Passwort des REST-Kontos geändert | `.\deploy\Install-VeeamExporter.ps1 -UpdateCredential` |
| VBR-Zertifikat erneuert | `.\deploy\Install-VeeamExporter.ps1` und den neuen Thumbprint bestätigen. Bis dahin meldet der REST-Task `collector_success 0`. |
| Lauf von Hand | `Start-ScheduledTask -TaskPath '\VeeamExporter\' -TaskName 'Veeam Exporter REST'` |
| Fehlersuche | `C:\ProgramData\VeeamExporter\logs\rest.log` bzw. `license.log` |
| Prüfen, was Prometheus sieht | `(Invoke-WebRequest -UseBasicParsing http://localhost:9182/metrics).Content -split "`n" \| Select-String '^veeam_'` |

## Deinstallation

```powershell
C:\Program Files\VeeamExporter\deploy\Uninstall-VeeamExporter.ps1
```

Das Script entfernt Folgendes:
- alle Tasks unter `\VeeamExporter\`,
- die `veeam_*.prom`-Dateien im Textfile-Verzeichnis, damit Prometheus keine veralteten Werte mehr sieht,
- die Installation,
- Credential und Logs, ausser bei `-KeepData`.

Es löscht nur Ordner, die nach einer Exporter-Installation aussehen.

## Parameter von Install-VeeamExporter.ps1

| Parameter | Standard | Bedeutung |
| --- | --- | --- |
| `-CertificateThumbprint` | aus `localhost:9419`, mit Rückfrage | Zertifikat der REST-API |
| `-Credential` | Abfrage | REST-Konto, nur nötig bei erster Installation oder `-UpdateCredential` |
| `-UpdateCredential` | – | Credential neu setzen |
| `-TextfileDirectory` | aus dem windows_exporter-Dienst | Ziel der `.prom`-Dateien |
| `-InstallPath` / `-DataPath` | `C:\Program Files\VeeamExporter` / `C:\ProgramData\VeeamExporter` | |
| `-VeeamModule` | gesucht in PSModulePath und Console-Ordner | Name oder Pfad (`.psd1`) des Veeam-Moduls |
| `-LicenseHost` | `Auto` | `WindowsPowerShell` oder `PowerShell7` erzwingen |
| `-SkipLicenseTask` | – | nur den REST-Task einrichten |
| `-RestIntervalMinutes` | `15` | Intervall des REST-Tasks |
| `-LicenseTime` | `06:17` | Uhrzeit des Lizenz-Tasks |
| `-Collector` | `jobs,objects,repositories` | REST-Collectors |
| `-ObjectLookbackDays` | `8` | Lookback des Objects-Collectors |
| `-NoStart` | – | Tasks nach der Installation nicht starten |
| `-Force` | – | Zertifikat ohne Rückfrage übernehmen |
| `-WhatIf` | – | nur anzeigen, was passieren würde |

## Im Lab prüfen

Die Deploy-Logik ist unter Linux mit Pester getestet; die Windows-Cmdlets (Scheduled Tasks, ACLs, DPAPI) sind dabei durch Mocks ersetzt. Auf einem echten Server zu prüfen:

- [ ] Installation unter Windows PowerShell 5.1 auf VBR 12.3.1 und VBR 13, inklusive Credential-Übergabe an SYSTEM.
- [ ] VBR 13: Wo liegt das Veeam-PowerShell-Modul, und findet `pwsh.exe` es unter SYSTEM? Annahme im Script: `C:\Program Files\Veeam\Backup and Replication\Console\Veeam.Backup.PowerShell\Veeam.Backup.PowerShell.psd1`; sonst `-VeeamModule` angeben.
- [ ] Ist SYSTEM in VBR Backup Administrator, sodass `Get-VBRInstalledLicense` funktioniert (OP-3 in `docs/metrics.md`)?
- [ ] Wiederholt der REST-Task auf der Ziel-Windows-Version unbegrenzt? Ohne `RepetitionDuration` ist das ab Windows Server 2016 der Fall.
- [ ] Erzwingt eine GPO `AllSigned`, laufen die unsignierten Skripte nicht. Dann die Skripte signieren oder eine Ausnahme einrichten.
