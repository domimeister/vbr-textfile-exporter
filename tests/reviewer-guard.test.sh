#!/usr/bin/env bash
# Tests for .claude/hooks/reviewer-guard.sh (PreToolUse guard of the reviewer
# subagent). Each case feeds a Bash tool call to the guard and checks whether
# it is allowed (exit 0) or blocked (exit 2).
#
# Run: bash tests/reviewer-guard.test.sh   (Linux, macOS, Git Bash on Windows)
# Needs bash, printf and sed only.

set -u
guard="$(cd "$(dirname "$0")/.." && pwd)/.claude/hooks/reviewer-guard.sh"
repo='repos/domimeister/vbr-textfile-exporter'

# JSON string escaping for the hook input: backslash, quote, newline, tab.
json_string() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\t'/\\t}
    printf '"%s"' "$s"
}

run_guard() {
    printf '{"tool_name":"%s","tool_input":%s}' "$1" "$2" | bash "$guard" 2>/dev/null
}

pass=0
fail=0
check() {
    local want=$1 tool=$2 input=$3 label=$4 rc got
    run_guard "$tool" "$input"
    rc=$?
    case $rc in
        0) got=allow ;;
        2) got=block ;;
        *) got="exit $rc" ;;
    esac
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: want %s, got %s: %s\n' "$want" "$got" "$label"
    fi
}

# want|command; "\n" in the command stands for a line break.
while IFS='|' read -r want cmd; do
    [ -z "$want" ] && continue
    cmd=$(printf '%b' "$cmd")
    check "$want" Bash "{\"command\":$(json_string "$cmd")}" "$(printf '%s' "$cmd" | sed -n 1p)"
done <<CASES
allow|gh api $repo/pulls/9 --jq .title
allow|gh api --paginate $repo/pulls/9/files
allow|gh api $repo/pulls/9 -H 'Accept: application/vnd.github.diff'
allow|gh api -X GET $repo/issues -f state=open
allow|gh api $repo/actions/jobs/123/logs | grep -E 'error' | tail -50
allow|gh pr diff 12
allow|git fetch --no-tags origin pull/12/head && git worktree add --detach ../vbr-review-pr-12 FETCH_HEAD
allow|gh api -X POST $repo/pulls/12/reviews -f commit_id=abc123 -f event=COMMENT -F body=@- <<'EOF'\n## Review\nquoted, not run: gh api -X DELETE $repo/git/refs/heads/main, event=APPROVE, gh pr merge 12\nEOF
allow|gh api -X POST $repo/pulls/12/reviews -f commit_id=abc123 -f event=COMMENT -F body=@- --jq .html_url <<'EOF'\n## Review (reviewer agent)\nEOF
allow|gh api $repo/actions/jobs/42/logs | grep -E '##\\\\[error\\\\]|Tests Passed|reviewer-guard:'
allow|until [ "\$(gh api $repo/commits/abc/check-runs --jq '[.check_runs[]|select(.status!="completed")]|length')" = 0 ]; do sleep 30; done
allow|gh api --method=POST $repo/pulls/12/reviews -f event=COMMENT -F body=@-
allow|gh api -X POST $repo/pulls/12/reviews --raw-field commit_id=abc --field=event=COMMENT -F body=@-
allow|gh pr review 12 --comment --body-file - <<'EOF'\nok\nEOF
block|gh api -X POST $repo/pulls/12/reviews -f event=APPROVE -F body=@-
block|gh api -X POST $repo/pulls/12/reviews -f event=REQUEST_CHANGES -F body=@-
block|gh api -X POST $repo/pulls/12/reviews -f event=COMMENT -f event=APPROVE -F body=@-
block|gh api -X POST $repo/pulls/12/reviews -F body=@-
block|gh api -X POST $repo/pulls/12/reviews --input review.json
block|gh api -X POST $repo/pulls/12/reviews -f event=COMMENT -f comments[][path]=x
block|gh api -X POST $repo/pulls/12/reviews -f event=COMMENT -f =x -F body=@-
block|gh api -X POST $repo/pulls/12/reviews -f event=COMMENT -F body=@- && gh api -X PUT $repo/pulls/12/merge
block|gh api -X POST $repo/pulls/12/reviews -f event=COMMENT -f body="\$(gh api -X DELETE $repo/git/refs/heads/main)"
block|gh api -X POST repos/other/repo/pulls/12/reviews -f event=COMMENT -F body=@-
block|gh api -X POST $repo/pulls/12/comments -f event=COMMENT -F body=@-
block|gh api -X POST $repo/pulls/12/reviews/5/events -f event=APPROVE
block|gh api -X PUT $repo/pulls/12/merge -f merge_method=squash
block|gh api -X DELETE $repo/git/refs/heads/main
block|gh api $repo/issues/8/comments -f body=hi
block|gh api -XPOST $repo/issues/8/comments -f body=hi
block|gh api -X PATCH $repo -f private=true
block|gh pr review 12 --approve
block|gh pr review 12 --body ok
block|gh pr merge 12 --squash
block|git push origin HEAD
block|git commit -m x
CASES

check block mcp__github__pull_request_review_write '{"event":"APPROVE"}' 'MCP review APPROVE'
check block mcp__github__pull_request_review_write '{"event":"REQUEST_CHANGES"}' 'MCP review REQUEST_CHANGES'
check allow mcp__github__pull_request_review_write '{"event":"COMMENT"}' 'MCP review COMMENT'

printf 'reviewer-guard: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
