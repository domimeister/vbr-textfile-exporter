# Veeam Prometheus Exporter (windows_exporter Textfile)

PowerShell exporter for Veeam Backup & Replication (v13 or later; v12 is not supported). Runs as a scheduled task locally on the VBR server, reads the REST API on `localhost:9419` and writes `.prom` files into the textfile directory of the windows_exporter. No listener of its own, no new port.

**The specification is `docs/metrics.md`.** Metric names, labels, value codes and alerts come from there. If any of it has to change: update `docs/metrics.md` first, then the code.

## Repo structure (target)

```text
.claude/agents/reviewer.md    # read-only PR reviewer subagent (+ .claude/hooks/reviewer-guard.sh)
.github/                      # CI workflow, PR template
src/
  VeeamExporter/              # module: Public/ and Private/ functions
  Invoke-VeeamExporter.ps1    # REST collectors: jobs, objects, repositories
  Invoke-VeeamLicenseExporter.ps1  # license via Get-VBRInstalledLicense (separate task)
deploy/                       # task definitions, install script, credential setup
alerting/veeam-alerts.json    # Grafana alert rules (file provisioning)
dashboards/                   # Grafana
tests/                        # Pester 5
  fixtures/                   # JSON responses from the Veeam REST docs
docs/metrics.md
```

## Hard rules

- **Read-only.** GET requests only, plus `POST /api/oauth2/token` and `POST /api/oauth2/logout`. Never call endpoints that change anything in VBR (start/stop jobs, license, repositories, credentials).
- **Compatible with PowerShell 5.1 and 7.** No PS7-only syntax (`?:`, `??`, `&&`, `||`, `ForEach-Object -Parallel`, `-SkipCertificateCheck`). In 5.1 set `-UseBasicParsing` and enable TLS 1.2.
- **Certificate:** never disable validation wholesale. Pin the thumbprint of the local VBR certificate (configuration), under 5.1 via a validation callback, under 7 via the handler.
- **REST:** `x-api-version` in every request, including the token request. Pick the highest available revision: 1.3-rev2, 1.3-rev1, 1.3-rev0. Always page via `skip`/`limit` to the end.
- **Writing files:** UTF-8 without BOM, LF, newline at end of file. Write `<name>.prom.tmp` first, then replace the target in one step (`Move-VeeamPromFile`, retried while windows_exporter reads the file); never delete the target first. Never `Out-File` or `Set-Content` without an explicit encoding.
- **One file per collector** (`veeam_jobs.prom`, `veeam_objects.prom`, `veeam_repositories.prom`, `veeam_license.prom`), replaced only on success. Write `veeam_exporter.prom` with the health metrics on every run.
- **Isolate failures:** try/catch per collector. A failed collector must not stop the others.
- **Prometheus format:** `# HELP` and `# TYPE` exactly once per metric. Escape label values (`\` → `\\`, `"` → `\"`, newline → `\n`). No timestamps on samples. snake_case with unit suffix (`_bytes`, `_seconds`, `_timestamp_seconds`).
- **Labels:** `job_name`, never `job` or `instance` (Prometheus sets those itself).
- **Value codes:** Success 0, Warning 1, Failed 2, None -1.
- **Units:** multiply GB from the API by 1073741824 (GB means GiB, confirmed in the lab, OP-5).
- **Secrets:** password only via DPAPI (`Export-Clixml`) for the task account. No credentials in the repo, in logs or in `.prom` files.

## Tests

- Pester 5, runnable under `powershell.exe` (5.1) and `pwsh` (7): `Invoke-Pester -Path tests`
- Lint: `Invoke-ScriptAnalyzer -Path src -Recurse`
- Mock REST calls in tests. Fixtures in `tests/fixtures/` taken from the response examples of the Veeam docs (jobs/states, sessions, taskSessions, repositories/states) and real responses recorded in the lab (`tests/fixtures/lab/`).
- Tests check the generated `.prom` files line by line, including escaping, encoding (no BOM) and line endings.
- If `promtool` is available: `Get-Content <file> | promtool check metrics`. For the files the tests generate: set `$env:VEEAM_TEST_PROM_OUTPUT` to an empty directory before `Invoke-Pester`, then run `./tests/Invoke-PromtoolCheck.ps1 -Path $env:VEEAM_TEST_PROM_OUTPUT, 'tests/fixtures/expected'`.
- CI (`.github/workflows/ci.yml`, `windows-latest`) runs Pester (`-CI`), PSScriptAnalyzer on `src` and `deploy` (errors fail the build) and the promtool check, once under Windows PowerShell 5.1 and once under PowerShell 7. Both jobs also run `tests/reviewer-guard.test.sh` (Git Bash) against the reviewer's hook.

## Way of working

- Order: skeleton (auth, version probe, writer) → jobs → objects → repositories → license → deploy.
- Open points are listed at the end of `docs/metrics.md`. Mark assumptions in the code with `# ASSUMPTION:` and link them there instead of settling them silently.

## Git-Workflow

- One issue = one branch = one PR. Branch names: `feat/<topic>`, `fix/<topic>`, `chore/<topic>` (lowercase, hyphen-separated).
- Never push directly to `main`. Never approve or merge PRs and never enable auto-merge: only Domi does that. Agents push their branch, open the PR and stop there.
- Parallel work only in a separate `git worktree` per branch, e.g. `git worktree add ../vbr-<topic> -b feat/<topic> origin/main`. Never switch branches in a checkout that another agent is using.
- Small PRs with one concern each. Tests go into the same PR as the change they cover.
- PR description follows `.github/pull_request_template.md`: issue (`Closes #<n>`), what and why, hard-rules checklist, test evidence.
- CI must be green. The job names `test (Windows PowerShell 5.1)` and `test (PowerShell 7)` are required checks on `main`; renaming them means updating the ruleset as well.
- Review: the `reviewer` subagent (`.claude/agents/reviewer.md`) checks a PR against these rules, runs the tests and posts a COMMENT review. It never approves or merges.
- No claude.ai session links in commit messages or PR descriptions.
- Language: instructions may be given in German, but everything that goes into the repo or onto GitHub is in English: code, comments, identifiers, log and error messages, docs, commit messages, branch names, PR titles and descriptions, issues and review comments.
