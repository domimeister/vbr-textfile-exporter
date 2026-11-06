# Fixtures

- `jobs-states.json`: Antwort von `GET /api/v1/jobs/states`, aufgebaut nach dem Schema und Beispiel in der [Jobs-Referenz](https://helpcenter.veeam.com/references/vbr/13/rest/1.3-rev0/tag/Jobs#operation/GetAllJobsStates). Die vier Jobs decken Success/Warning/Failed/None, running/disabled, verkettete Jobs ohne `nextRun` und nie gelaufene Jobs ohne `lastRun` ab. Beim ersten Lab-Test gegen echte Antworten von v12.3.1 und v13 abgleichen.
- `jobs-states-escaping.json`: Grenzfälle für Labelwerte (Anführungszeichen, Backslashes, Zeilenumbruch, Umlaute) und unbekannte Werte in `lastResult`/`status`.
- `expected/*.prom`: erwartete Ausgabe, zeilengenau. UTF-8 ohne BOM, LF, Zeilenumbruch am Ende.
