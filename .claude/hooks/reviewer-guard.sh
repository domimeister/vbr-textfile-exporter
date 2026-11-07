#!/usr/bin/env bash
# PreToolUse guard for the reviewer subagent (.claude/agents/reviewer.md).
#
# The reviewer needs Bash (gh, git fetch/worktree, Pester), so this hook
# blocks the commands that would change the repository or GitHub: commits,
# pushes, merges, approvals, PR/issue/repo edits, write calls via gh api.
# The only write the reviewer may make is one review of type COMMENT, via
# gh pr review --comment, the GitHub MCP tool or the REST call below.
#
# Input: the hook JSON on stdin. Exit code 2 blocks the tool call.
# Needs bash, sed, grep, tr and wc only (works in Git Bash on Windows, no jq).
# This is a safety net against mistakes, not a sandbox.

set -u
input=$(cat)

block() {
    printf 'reviewer-guard: blocked (%s). The reviewer is read-only and may only post a COMMENT review. Do not work around this.\n' "$1" >&2
    exit 2
}

# GitHub MCP review tool: only COMMENT reviews, never APPROVE or REQUEST_CHANGES.
if printf '%s' "$input" | grep -Eq '"tool_name"[[:space:]]*:[[:space:]]*"mcp__github__pull_request_review_write"'; then
    if printf '%s' "$input" | grep -Eiq '"event"[[:space:]]*:[[:space:]]*"(APPROVE|REQUEST_CHANGES)"'; then
        block 'review event other than COMMENT'
    fi
    exit 0
fi

# Bash: the command string, still JSON-escaped.
cmd=$(printf '%s' "$input" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p')
[ -z "$cmd" ] && exit 0

# Unescape newlines, tabs and quotes, then drop heredoc bodies: the review
# text (passed via <<'EOF') may quote forbidden commands without running them.
text=$(printf '%s' "$cmd" | sed -e 's/\\n/\n/g' -e 's/\\t/\t/g' -e 's/\\"/"/g' -e 's/\\\\/\\/g')
visible=''
delim=''
heredoc_re='(^|[^<])<<-?[[:space:]]*["'\'']?([A-Za-z_][A-Za-z0-9_]*)["'\'']?'
while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$delim" ]; then
        trimmed=${line#"${line%%[!$'\t']*}"}
        [ "$trimmed" = "$delim" ] && delim=''
        continue
    fi
    if [[ $line =~ $heredoc_re ]]; then
        delim=${BASH_REMATCH[2]}
        line=${line/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]}"}
    fi
    visible+="$line"$'\n'
done <<< "$text"

has() { printf '%s' "$visible" | grep -Eq -- "$1"; }

b='(^|[^A-Za-z0-9_.-])'
git_opts='([[:space:]]+(-C|-c)[[:space:]]+[^[:space:]]+|[[:space:]]+--?[A-Za-z][A-Za-z-]*(=[^[:space:]]+)?)*'
end='([[:space:]]|;|&|\||\)|$)'

has "${b}git${git_opts}[[:space:]]+(push|pull|commit|merge|rebase|reset|revert|cherry-pick|am|apply|tag|stash|clean|checkout|switch|restore|rm|mv|update-ref|filter-branch|filter-repo|replace|notes|gc)${end}" &&
    block 'git command that changes the repository'
has "${b}git${git_opts}[[:space:]]+branch[[:space:]][^;&|]*(-[dDmMcCf]|--delete|--move|--copy|--force)" &&
    block 'git branch change'
has "${b}gh[[:space:]]+pr[[:space:]]+(merge|close|reopen|edit|ready|create|comment|lock|unlock|update-branch|revert)${end}" &&
    block 'gh pr write command'
has "${b}gh[[:space:]]+pr[[:space:]]+review[^;&|]*[[:space:]](--approve|-a|--request-changes|-r)([[:space:]=]|$)" &&
    block 'gh pr review other than --comment'
if has "${b}gh[[:space:]]+pr[[:space:]]+review${end}"; then
    has "${b}gh[[:space:]]+pr[[:space:]]+review[^;&|]*[[:space:]](--comment|-c)([[:space:]=]|$)" ||
        block 'gh pr review without --comment'
fi
has "${b}gh[[:space:]]+(repo[[:space:]]+(edit|delete|archive|unarchive|rename|create|fork|sync|set-default|deploy-key)|release[[:space:]]+(create|edit|delete|upload)|workflow[[:space:]]+(run|enable|disable)|run[[:space:]]+(rerun|cancel|delete)|issue[[:space:]]+(create|edit|close|reopen|comment|delete|transfer|pin|unpin|lock|unlock|develop)|label[[:space:]]+(create|edit|delete|clone)|ruleset[[:space:]]+(create|edit|delete)|cache[[:space:]]+delete|auth[[:space:]]+(login|logout|refresh|setup-git|token)|secret|variable|gist|extension|alias)${end}" &&
    block 'gh write command'
# gh api: reads are allowed. The only allowed write is the COMMENT review on
# a PR of this repository (gh pr review needs GraphQL, which cloud sessions
# block), in exactly this form:
#   gh api -X POST repos/domimeister/vbr-textfile-exporter/pulls/<n>/reviews \
#     -f commit_id=<sha> -f event=COMMENT -F body=@- <<'EOF'
# Every gh api call is checked on its own: split at ; & | ( ) and backticks.
field_re='(-f|-F|--field|--raw-field)[[:space:]=]+'
review_path_re='[[:space:]]/?repos/domimeister/vbr-textfile-exporter/pulls/[0-9]+/reviews([[:space:]]|$)'

is_comment_review_post() {
    local s=$1 name
    printf '%s' "$s" | grep -Eq -- "[[:space:]](-X|--method)[[:space:]=]*POST([[:space:]]|$)" || return 1
    printf '%s' "$s" | grep -Eq -- "$review_path_re" || return 1
    [ "$(printf '%s' "$s" | grep -Eo -- '/?repos/' | wc -l)" -eq 1 ] || return 1
    printf '%s' "$s" | grep -Eq -- '[[:space:]]--input([[:space:]=]|$)' && return 1
    printf '%s' "$s" | grep -Eq -- "${field_re}event=COMMENT([[:space:]]|$)" || return 1
    while IFS= read -r name; do
        case "$name" in
            event|body|commit_id) ;;
            *) return 1 ;;
        esac
    done < <(printf '%s' "$s" | grep -Eo -- "${field_re}[^[:space:]=]*" | sed -E "s/^${field_re}//")
    # event may appear only once (no second event=APPROVE after the COMMENT one)
    [ "$(printf '%s' "$s" | grep -Eo -- "${field_re}event=" | wc -l)" -eq 1 ] || return 1
    return 0
}

while IFS= read -r seg || [ -n "$seg" ]; do
    printf '%s' "$seg" | grep -Eq -- "${b}gh[[:space:]]+api([[:space:]]|$)" || continue
    write=''
    printf '%s' "$seg" | grep -Eq -- "[[:space:]](-X|--method)[[:space:]=]*(POST|PUT|PATCH|DELETE)" && write='method'
    if [ -z "$write" ] &&
        printf '%s' "$seg" | grep -Eq -- "[[:space:]](-f|-F|--field|--raw-field|--input)([[:space:]=]|$)" &&
        ! printf '%s' "$seg" | grep -Eq -- "[[:space:]](-X|--method)[[:space:]=]*GET"; then
        write='fields'
    fi
    [ -z "$write" ] && continue
    is_comment_review_post "$seg" && continue
    if [ "$write" = 'fields' ]; then
        block 'gh api with fields defaults to POST; add -X GET for reads'
    fi
    block 'gh api write call other than a COMMENT review on this repository'
done < <(printf '%s' "$visible" | tr ';&|()`' '\n\n\n\n\n\n')

exit 0
