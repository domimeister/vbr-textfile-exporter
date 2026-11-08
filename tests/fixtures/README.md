# Fixtures

## `doc/<version>/` – unchanged from the Veeam docs

Response examples from the OpenAPI specs of the [REST reference](https://helpcenter.veeam.com/references/vbr/13/rest/1.3-rev0/tag/SectionOverview) (`components.examples`), for each supported revision 1.3-rev0, 1.3-rev1, 1.3-rev2. Only reformatted, content unchanged.

| File | Example in the spec |
| --- | --- |
| `jobs-states.json` | `JobStatesResultExample` |
| `sessions.json` | `SessionsResultExample` |
| `taskSessions.json` | `TaskSessionsResultExample` |
| `repositories-states.json` | `RepositoryStatesResultExample` |
| `scaleOutRepositories.json` (1.3-rev2 only, older specs have no example) | `ScaleOutRepositoriesResultExample` |

Notable: depending on the version, the examples write enum values in lower or upper case (`stopped`/`Stopped`, `vm`/`Vm`), `taskSessions` returns timestamps without offset (see OP-9 in `docs/metrics.md`), and in 1.3-rev0 `isOutOfDate` is a string (`"false"`).

## Derived fixtures

- `objects-doc-sessions.json`, `objects-doc-jobs-states.json`: the doc examples for sessions and task sessions do not match (different IDs). These files map the six `sessionId` values from `TaskSessionsResultExample` to three jobs, in the structure of `SessionsResultExample`. The NFS share job is intentionally missing from `jobs/states` (fallback to the session name).
- `objects-edge-*.json`: edge cases for the objects collector: successful retry after a failure, running task, renamed and deleted job, upper/lower case in the object name, escaping, long multi-line message, `endTime` = `0001-01-01T00:00:00`, identical creationTime (higher `usn` wins), unknown session, task without a name.
- `repositories-sobr-states.json`: repository states matching the extent IDs from `ScaleOutRepositoriesResultExample`: performance extent with `scaleOutRepositoryDetails`, performance extent only via the extent list (without `scaleOutRepositoryDetails`, ID in upper case), archive extent with capacity 0, object storage without capacity, standalone repository, extent of an unknown SOBR (`membership`), escaping, 0.1 GB, `isOnline`/`isOutOfDate` as strings, repository without status.
- `jobs-states.json`: hand-made, covers Success/Warning/Failed/None, running/disabled, chained jobs without `nextRun` and never-run jobs without `lastRun`.
- `jobs-states-escaping.json`: edge cases for label values (quotes, backslashes, line break, umlauts) and unknown values in `lastResult`/`status`. The German names with umlauts are intentional test data for UTF-8 handling.

## `lab/vbr-13.1/` - real responses

Responses of a real VBR 13.1 server (lab, Backup Viewer account, REST 1.3-rev2), reformatted with indentation, content unchanged: `jobs-states.json` (four file share jobs: Success, Success to a SOBR, Failed, never run), `sessions.json` (all session types of that day, including malware detection and the configuration backup), `taskSessions.json` (three file share tasks and one malware detection task). Expected output in `expected/lab/vbr-13.1/`.

## `license/`

License objects as returned by `Get-VBRInstalledLicense`, as JSON. Built from the documented properties of [VBRInstalledLicense](https://helpcenter.veeam.com/docs/vbr/powershell/vbrinstalledlicense.html) and the examples of [Get-VBRInstalledLicense](https://helpcenter.veeam.com/docs/vbr/powershell/get-vbrinstalledlicense.html) (instances 1000/2, socket summary). The docs contain no real output; compare with `Get-VBRInstalledLicense | ConvertTo-Json -Depth 3` during the first lab test.

- `license-rental.json`: Valid, Rental, instance license, escaping and umlaut in `LicensedTo`.
- `license-perpetual-socket.json`: perpetual (`ExpirationDate` = `0001-01-01`), socket-only license without `InstanceLicenseSummary`.
- `license-expired.json`: Expired, support until `9999-12-31` (= not set), over-use with a fraction (57.33 of 50).

## `expected/`

Expected output, line by line, UTF-8 without BOM, LF, newline at end of file. The files for objects and the doc examples were generated with an independent Python reference implementation, not with the exporter itself. In the tests, timestamps without offset are treated as +01:00 (`Set-TestTimeZone`).
