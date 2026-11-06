# Fixtures

## `doc/<version>/` – unverändert aus der Veeam-Doku

Response-Beispiele aus den OpenAPI-Specs der [REST-Referenz](https://helpcenter.veeam.com/references/vbr/13/rest/1.3-rev0/tag/SectionOverview) (`components.examples`), je unterstützte Revision 1.2-rev1, 1.3-rev0, 1.3-rev1, 1.3-rev2. Nur neu formatiert, Inhalt unverändert.

| Datei | Beispiel in der Spec |
| --- | --- |
| `jobs-states.json` | `JobStatesResultExample` |
| `sessions.json` | `SessionsResultExample` |
| `taskSessions.json` | `TaskSessionsResultExample` |
| `repositories-states.json` | `RepositoryStatesResultExample` |
| `scaleOutRepositories.json` (nur 1.3-rev2, ältere Specs haben kein Beispiel) | `ScaleOutRepositoriesResultExample` |

Auffällig: Die Beispiele schreiben Enum-Werte je nach Version klein oder gross (`stopped`/`Stopped`, `vm`/`Vm`), `taskSessions` liefert Zeitstempel ohne Offset (siehe OP-9 in `docs/metrics.md`), und in 1.3-rev0 ist `isOutOfDate` ein String (`"false"`).

## Abgeleitete Fixtures

- `objects-doc-sessions.json`, `objects-doc-jobs-states.json`: Die Doku-Beispiele für Sessions und Task-Sessions passen nicht zusammen (andere IDs). Diese Dateien ordnen die sechs `sessionId` aus `TaskSessionsResultExample` drei Jobs zu, im Aufbau von `SessionsResultExample`. Der NFS-Share-Job fehlt absichtlich in `jobs/states` (Fallback auf den Session-Namen).
- `objects-edge-*.json`: Grenzfälle für den Objects-Collector: erfolgreicher Retry nach Fehler, laufender Task, umbenannter und gelöschter Job, Gross-/Kleinschreibung im Objektnamen, Escaping, lange mehrzeilige Meldung, `endTime` = `0001-01-01T00:00:00`, gleiche creationTime (höhere `usn` gewinnt), unbekannte Session, Task ohne Namen.
- `repositories-sobr-states.json`: Repository-States passend zu den Extent-IDs aus `ScaleOutRepositoriesResultExample`: Performance-Extent mit `scaleOutRepositoryDetails`, Performance-Extent nur über die Extent-Liste (wie unter 1.2-rev1, ID in Grossbuchstaben), Archive-Extent mit Kapazität 0, Object Storage ohne Kapazität, eigenständiges Repository, Extent eines unbekannten SOBR (`membership`), Escaping, 0,1 GB, `isOnline`/`isOutOfDate` als String, Repository ohne Status.
- `jobs-states.json`: selbst gebaut, deckt Success/Warning/Failed/None, running/disabled, verkettete Jobs ohne `nextRun` und nie gelaufene Jobs ohne `lastRun` ab.
- `jobs-states-escaping.json`: Grenzfälle für Labelwerte (Anführungszeichen, Backslashes, Zeilenumbruch, Umlaute) und unbekannte Werte in `lastResult`/`status`.

## `expected/`

Erwartete Ausgabe, zeilengenau, UTF-8 ohne BOM, LF, Zeilenumbruch am Ende. Die Dateien für Objects und die Doku-Beispiele wurden mit einer unabhängigen Python-Referenzimplementierung erzeugt, nicht mit dem Exporter selbst. Zeitstempel ohne Offset gelten in den Tests als +01:00 (`Set-TestTimeZone`).
