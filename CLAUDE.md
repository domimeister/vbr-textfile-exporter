# Veeam Prometheus Exporter (windows_exporter Textfile)

PowerShell-Exporter für Veeam Backup & Replication (v12.3.1 und v13). Läuft als geplanter Task lokal auf dem VBR-Server, liest die REST API auf `localhost:9419` und schreibt `.prom`-Dateien ins Textfile-Verzeichnis des windows_exporter. Kein eigener Listener, kein neuer Port.

**Die Spezifikation ist `docs/metrics.md`.** Metriknamen, Labels, Wertecodes und Alerts kommen von dort. Wenn sich etwas daran ändern muss: erst `docs/metrics.md` anpassen, dann den Code.

## Repo-Struktur (Ziel)

```text
src/
  VeeamExporter/              # Modul: Public/ und Private/ Funktionen
  Invoke-VeeamExporter.ps1    # REST-Collectors: jobs, objects, repositories
  Invoke-VeeamLicenseExporter.ps1  # Lizenz via Get-VBRInstalledLicense (eigener Task)
deploy/                       # Task-Definitionen, Install-Script, Credential-Setup
rules/veeam.rules.yml         # Prometheus-Alerts
dashboards/                   # Grafana
tests/                        # Pester 5
  fixtures/                   # JSON-Responses aus der Veeam-REST-Doku
docs/metrics.md
```

## Harte Regeln

- **Nur lesen.** Ausschliesslich GET-Requests, dazu `POST /api/oauth2/token` und `POST /api/oauth2/logout`. Niemals Endpoints aufrufen, die in VBR etwas ändern (Jobs starten/stoppen, Lizenz, Repositories, Credentials).
- **PowerShell 5.1 und 7 kompatibel.** Keine PS7-only-Syntax (`?:`, `??`, `&&`, `||`, `ForEach-Object -Parallel`, `-SkipCertificateCheck`). In 5.1 `-UseBasicParsing` setzen und TLS 1.2 aktivieren.
- **Zertifikat:** Kein pauschales Abschalten der Prüfung. Thumbprint des lokalen VBR-Zertifikats pinnen (Konfiguration), unter 5.1 über einen Validation-Callback, unter 7 über den Handler.
- **REST:** `x-api-version` in jedem Request, auch beim Token. Höchste verfügbare Revision wählen: 1.3-rev2, 1.3-rev1, 1.3-rev0, 1.2-rev1. Paging über `skip`/`limit` immer bis zum Ende.
- **Dateien schreiben:** UTF-8 ohne BOM, LF, Zeilenumbruch am Dateiende. Erst `<name>.prom.tmp` schreiben, dann `Move-Item -Force` (atomar). Nie `Out-File` oder `Set-Content` ohne explizites Encoding.
- **Eine Datei pro Collector** (`veeam_jobs.prom`, `veeam_objects.prom`, `veeam_repositories.prom`, `veeam_license.prom`), nur bei Erfolg ersetzen. `veeam_exporter.prom` mit den Health-Metriken bei jedem Lauf schreiben.
- **Fehler isolieren:** try/catch pro Collector. Ein fehlgeschlagener Collector darf die anderen nicht stoppen.
- **Prometheus-Format:** `# HELP` und `# TYPE` genau einmal pro Metrik. Labelwerte escapen (`\` → `\\`, `"` → `\"`, Zeilenumbruch → `\n`). Keine Timestamps an Samples. snake_case mit Einheiten-Suffix (`_bytes`, `_seconds`, `_timestamp_seconds`).
- **Labels:** `job_name`, nie `job` oder `instance` (setzt Prometheus selbst).
- **Wertecodes:** Success 0, Warning 1, Failed 2, None -1.
- **Einheiten:** GB aus der API mit 1073741824 multiplizieren (Annahme GiB, siehe offene Punkte).
- **Secrets:** Passwort nur per DPAPI (`Export-Clixml`) für das Task-Konto. Keine Credentials im Repo, in Logs oder in `.prom`-Dateien.

## Tests

- Pester 5, lauffähig unter `powershell.exe` (5.1) und `pwsh` (7): `Invoke-Pester -Path tests`
- Lint: `Invoke-ScriptAnalyzer -Path src -Recurse`
- REST-Aufrufe in Tests mocken. Fixtures in `tests/fixtures/` aus den Response-Beispielen der Veeam-Doku (jobs/states, sessions, taskSessions, repositories/states).
- Tests prüfen die erzeugten `.prom`-Dateien zeilengenau, inklusive Escaping, Encoding (kein BOM) und Zeilenenden.
- Falls `promtool` verfügbar ist: `Get-Content <datei> | promtool check metrics`.

## Arbeitsweise

- Reihenfolge: Skelett (Auth, Versions-Probe, Writer) → Jobs → Objects → Repositories → Lizenz → Deploy.
- Offene Punkte stehen am Ende von `docs/metrics.md`. Annahmen im Code mit `# ANNAHME:` markieren und dort verlinken, statt sie stillschweigend festzulegen.
