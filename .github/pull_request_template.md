## Issue

Closes #

<!-- One issue = one branch = one PR. "Closes #<n>" closes the issue on merge. -->

## What

<!-- What changes, in a few bullet points. -->

## Why

<!-- The problem this solves, or the open point in docs/metrics.md it settles. -->

## Hard rules

<!-- From CLAUDE.md and docs/metrics.md. Tick each line, or write "n/a: <reason>" after it. -->

- [ ] Read-only: GET only, plus `POST /api/oauth2/token` and `POST /api/oauth2/logout`
- [ ] Runs under Windows PowerShell 5.1 and PowerShell 7: no `?:`, `??`, `&&`, `||`, `-Parallel`, `-SkipCertificateCheck`; `-UseBasicParsing` and TLS 1.2 under 5.1; source and test files ASCII only
- [ ] Certificate validation never disabled wholesale; thumbprint pinning intact
- [ ] REST: `x-api-version` on every request (token request included); highest available revision; paging via `skip`/`limit` to the end
- [ ] Files: UTF-8 without BOM, LF, newline at the end; `.prom.tmp` then a one-step replace (`Write-PromFile`); no `Out-File`/`Set-Content` without explicit encoding
- [ ] One `.prom` file per collector, replaced only on success; `veeam_exporter.prom` on every run; try/catch per collector
- [ ] Prometheus format: `# HELP`/`# TYPE` once per metric, label values escaped, no timestamps, snake_case with unit suffix
- [ ] Labels `job_name` (never `job`/`instance`); value codes Success 0, Warning 1, Failed 2, None -1; GB * 1073741824
- [ ] Metric names, labels, value codes and alerts match `docs/metrics.md`; spec changes are in this PR, made first
- [ ] New assumptions marked `# ASSUMPTION:` and linked to an open point in `docs/metrics.md`
- [ ] No secrets in code, logs, `.prom` files or fixtures
- [ ] Everything in English; no claude.ai session links in commits or this description

## Test evidence

<!-- Summary lines, not full logs. CI runs the same on windows-latest. -->

- [ ] Tests for every behaviour change are in this PR
- Pester, Windows PowerShell 5.1:
- Pester, PowerShell 7:
- PSScriptAnalyzer (`src`, `deploy`):
- promtool check metrics:
