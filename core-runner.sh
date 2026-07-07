#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Per-run log file ──────────────────────────────────────────────────────────
# All output (stdout + stderr from this script and every child stage) is tee'd
# to a timestamped file under LOG_DIR. The compose volume mounts LOG_DIR to
# ./logs on the host so files survive container restarts and can be read with
# a normal text editor.
LOG_DIR="${LOG_DIR:-/var/log/loop-engineer}"
mkdir -p "$LOG_DIR"
find "$LOG_DIR" -name "*.log" -mtime +"${LOG_RETENTION_DAYS:-30}" -delete 2>/dev/null || true
LOG_FILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Log: $LOG_FILE"
STATE_DIR="$SCRIPT_DIR/state"
REPO_DIR="$SCRIPT_DIR/repo"
BASE_BRANCH="${BASE_BRANCH:-}"   # auto-detected after clone; override via env var

log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() { log "ERROR: $*"; exit 1; }

# ── Validate required env vars ──────────────────────────────────────────────
for var in GEMINI_API_TOKEN GH_TOKEN GITHUB_OWNER TRIGGER_LABEL PROCESSING_LABEL WAITING_LABEL READY_LABEL MAX_LOOP_RETRIES; do
    [[ -z "${!var:-}" ]] && fail "Required env var $var is not set"
done

# ── Auth with GitHub CLI ─────────────────────────────────────────────────────
log "Authenticating with GitHub..."
# gh exits 1 when GH_TOKEN is already set in the environment (it uses the env var
# automatically and refuses to store credentials on top of it). That's fine — subsequent
# gh commands will authenticate via GH_TOKEN regardless.
echo "$GH_TOKEN" | gh auth login --with-token --hostname "github.com" || true
# Configure git to use gh as the credential helper for GitHub HTTPS remotes, so
# `git push`/`git fetch` authenticate via GH_TOKEN instead of dropping to an
# interactive username prompt.
gh auth setup-git --hostname "github.com"
# Fail loudly instead of hanging on an interactive prompt if credentials are ever missing.
export GIT_TERMINAL_PROMPT=0

# ── Run bootstrap hooks (once per container lifetime) ────────────────────────
BOOTSTRAP_DONE="$STATE_DIR/.bootstrap_complete"
# Re-run bootstrap if /tmp was cleared by a container restart (flag persists in state
# volume but WP test library and WordPress install live in ephemeral /tmp).
if [[ ! -f "$BOOTSTRAP_DONE" || ! -d "${WP_TESTS_DIR:-/tmp/wordpress-tests-lib}" ]]; then
    log "Running bootstrap hooks..."
    for hook in "$SCRIPT_DIR/hooks/bootstrap"/*.sh; do
        log "  → $(basename "$hook")"
        bash "$hook" || fail "Bootstrap hook failed: $hook"
    done
    mkdir -p "$STATE_DIR"
    touch "$BOOTSTRAP_DONE"
    log "Bootstrap complete."
fi

# ── Comment/label helpers — route to PR or issue depending on mode ───────────
# These are defined early so discover_issue can reference them after it sets globals.

# Marker prepended to every comment. Comments post under the GH_TOKEN owner's
# account (there's no dedicated bot user), so this makes it clear a bot authored
# them. Exported so the deliver stage (a child process) reuses the same string.
BOT_SIGNATURE="🤖 _From **@loop_engineer_bot** — automated comment._"
export BOT_SIGNATURE

post_comment() {
    local body="${BOT_SIGNATURE}"$'\n\n'"$1"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "[DRY-RUN] comment suppressed (${#body} chars): ${body:0:80}..."
        return 0
    fi
    if [[ "$PR_MODE" == "true" ]]; then
        gh pr comment "$PR_NUM" --repo "$GITHUB_OWNER/$TARGET_REPO" --body "$body"
    else
        gh issue comment "$ISSUE_NUM" --repo "$GITHUB_OWNER/$TARGET_REPO" --body "$body"
    fi
}

# apply_labels <add-label-or-empty> <remove-label-or-empty>
apply_labels() {
    local add_label="${1:-}"
    local remove_label="${2:-}"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "[DRY-RUN] labels skipped: add='${add_label:-}' remove='${remove_label:-}'"
        return 0
    fi
    if [[ "$PR_MODE" == "true" ]]; then
        [[ -n "$add_label" ]]    && gh pr edit "$PR_NUM"    --repo "$GITHUB_OWNER/$TARGET_REPO" --add-label    "$add_label"    2>/dev/null || true
        [[ -n "$remove_label" ]] && gh pr edit "$PR_NUM"    --repo "$GITHUB_OWNER/$TARGET_REPO" --remove-label "$remove_label" 2>/dev/null || true
    else
        [[ -n "$add_label" ]]    && gh issue edit "$ISSUE_NUM" --repo "$GITHUB_OWNER/$TARGET_REPO" --add-label    "$add_label"    2>/dev/null || true
        [[ -n "$remove_label" ]] && gh issue edit "$ISSUE_NUM" --repo "$GITHUB_OWNER/$TARGET_REPO" --remove-label "$remove_label" 2>/dev/null || true
    fi
}

cleanup_processing_label() {
    local extra_label="${1:-}"
    apply_labels "$extra_label" "$PROCESSING_LABEL"
}

# ── Persistent per-issue state (survives PR delivery) ────────────────────────
# The blueprint is stripped from the branch at delivery so it doesn't pollute the
# PR diff. We stash it in the state volume (keyed by repo+issue) so a later
# PR-review iteration reuses it instead of re-planning, and so we can tell which
# review comments are new. STATE_ISSUE_DIR is set once the issue is known.
persist_issue_state() {
    [[ -n "${STATE_ISSUE_DIR:-}" ]] || return 0
    mkdir -p "$STATE_ISSUE_DIR"
    # Only the blueprint is carried across delivered iterations — it's what lets
    # stage 01 skip regeneration. PROGRESS is run-scoped and intentionally not kept
    # (restoring a COMPLETE trail would mislead the next run into "resuming").
    [[ -f "$REPO_DIR/BLUEPRINT.md" ]] && cp "$REPO_DIR/BLUEPRINT.md" "$STATE_ISSUE_DIR/BLUEPRINT.md"
    # Advance the feedback marker to when this run STARTED gathering (not now), so a
    # comment posted mid-run is reprocessed next iteration rather than silently skipped.
    printf '%s\n' "${FEEDBACK_MARKER_NEXT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" > "$STATE_ISSUE_DIR/last_processed_at"
    log "Persisted issue state to $STATE_ISSUE_DIR"
}

restore_issue_state() {
    [[ -n "${STATE_ISSUE_DIR:-}" && -d "$STATE_ISSUE_DIR" ]] || return 0
    # A branch-tip blueprint (from an interrupted, not-yet-delivered run) is fresher —
    # never overwrite it. Only fill it in when the branch no longer carries one
    # (i.e. a post-delivery review iteration, where delivery stripped it).
    if [[ ! -f "$REPO_DIR/BLUEPRINT.md" && -f "$STATE_ISSUE_DIR/BLUEPRINT.md" ]]; then
        cp "$STATE_ISSUE_DIR/BLUEPRINT.md" "$REPO_DIR/BLUEPRINT.md"
        log "Restored BLUEPRINT.md from persisted state (post-delivery review iteration)."
    fi
}

# Collect PR review feedback posted since the last delivery into REQUESTED_CHANGES.md,
# which the execute stage treats as the highest-priority instruction. This is what
# turns a re-triggered PR from "re-implement the blueprint" into "address the review".
gather_pr_feedback() {
    # Capture the cutoff for the NEXT run before doing anything, so persist_issue_state
    # can advance the marker to run-start time (see the comment there).
    FEEDBACK_MARKER_NEXT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    export FEEDBACK_MARKER_NEXT
    [[ "${PR_MODE:-false}" == "true" && -n "${PR_NUM:-}" ]] || return 0
    local since out reviews inline comments
    since=$(cat "$STATE_ISSUE_DIR/last_processed_at" 2>/dev/null || echo "1970-01-01T00:00:00Z")
    out="$REPO_DIR/REQUESTED_CHANGES.md"

    # Review summaries (e.g. "Changes requested") with a non-empty body.
    reviews=$(gh pr view "$PR_NUM" --repo "$GITHUB_OWNER/$TARGET_REPO" --json reviews 2>/dev/null \
        | jq -r --arg since "$since" '(.reviews // [])
            | map(select((.submittedAt > $since) and ((.body // "") != "")))
            | map("- **" + .author.login + "** [" + .state + "]: " + .body) | join("\n")' 2>/dev/null || echo "")
    # Inline (line-level) review comments.
    inline=$(gh api "repos/$GITHUB_OWNER/$TARGET_REPO/pulls/$PR_NUM/comments" 2>/dev/null \
        | jq -r --arg since "$since" 'map(select(.created_at > $since))
            | map("- `" + .path + ":" + ((.line // .original_line // 0) | tostring) + "` — **" + .user.login + "**: " + .body) | join("\n")' 2>/dev/null || echo "")
    # General PR conversation comments, excluding the loop bot's own (identified by
    # the signature marker prepended to every bot comment).
    comments=$(gh pr view "$PR_NUM" --repo "$GITHUB_OWNER/$TARGET_REPO" --json comments 2>/dev/null \
        | jq -r --arg since "$since" '(.comments // [])
            | map(select((.createdAt > $since) and ((.body | contains("@loop_engineer_bot")) | not)))
            | map("- **" + .author.login + "**: " + .body) | join("\n")' 2>/dev/null || echo "")

    if [[ -z "$reviews" && -z "$inline" && -z "$comments" ]]; then
        log "No new PR feedback since $since."
        return 0
    fi

    {
        echo "# Requested Changes (PR #$PR_NUM review, since $since)"
        [[ -n "$reviews" ]]  && { echo; echo "## Review summaries";      echo "$reviews"; }
        [[ -n "$inline" ]]   && { echo; echo "## Inline code comments";  echo "$inline"; }
        [[ -n "$comments" ]] && { echo; echo "## PR comments";           echo "$comments"; }
    } > "$out"
    log "Gathered new PR feedback into REQUESTED_CHANGES.md."
}

# Remove persisted state for issues whose issue/PR has closed (e.g. merged). Runs
# only on the idle path, so it costs nothing during active work.
gc_closed_state() {
    local issues_root="$STATE_DIR/issues" repo_dir issue_dir repo issue state
    [[ -d "$issues_root" ]] || return 0
    for repo_dir in "$issues_root"/*/; do
        [[ -d "$repo_dir" ]] || continue
        repo=$(basename "$repo_dir")
        for issue_dir in "$repo_dir"*/; do
            [[ -d "$issue_dir" ]] || continue
            issue=$(basename "$issue_dir")
            state=$(gh issue view "$issue" --repo "$GITHUB_OWNER/$repo" --json state --jq '.state' 2>/dev/null || echo "")
            if [[ "$state" == "CLOSED" ]]; then
                rm -rf "$issue_dir"
                log "GC: removed persisted state for closed $repo#$issue"
            fi
        done
    done
}

# ── Checkpoint helper — commit WIP + push branch so a crashed/timed-out run resumes ──
# Commits everything on the agent branch (including the loop artifacts BLUEPRINT.md /
# PROGRESS.md / VERIFY_ERRORS.md) and pushes it. While the loop runs, the pushed branch
# IS the recovery trail: the next container checks it out and picks up exactly where this
# one stopped. The artifacts are stripped from the branch tip at delivery (stage 04) so
# they never appear in the final PR. Requires AGENT_BRANCH and git identity to be set.
# Always returns 0 — a failed checkpoint must never abort the loop.
checkpoint() {
    local msg="$1"
    (
        cd "$REPO_DIR" || exit 0
        git add --all

        # Secret guard: never let a checkpoint push leak token values (prompt-injection defense).
        local staged_diff secret_var secret_val
        staged_diff=$(git diff --cached 2>/dev/null || true)
        for secret_var in GH_TOKEN GEMINI_API_TOKEN; do
            secret_val="${!secret_var:-}"
            [[ ${#secret_val} -lt 10 ]] && continue
            if echo "$staged_diff" | grep -qF "$secret_val"; then
                log "Checkpoint ABORTED: value of \$$secret_var found in staged diff (possible prompt injection). Not committing."
                git reset HEAD -- . >/dev/null 2>&1 || true
                exit 0
            fi
        done

        if git diff --cached --quiet; then
            log "Checkpoint: nothing to commit ($msg)"
            exit 0
        fi

        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            log "[DRY-RUN] checkpoint commit+push suppressed: $msg"
            git reset HEAD -- . >/dev/null 2>&1 || true
            exit 0
        fi

        git commit -q -m "$msg" || { log "Checkpoint commit failed: $msg"; exit 0; }
        # Update the remote-tracking ref so --force-with-lease has a baseline (no-op for a
        # brand-new branch). We only ever overwrite our own previous checkpoint.
        git fetch origin "$AGENT_BRANCH" >/dev/null 2>&1 || true
        local push_err
        if push_err=$(git push -u --force-with-lease origin "$AGENT_BRANCH" 2>&1); then
            log "Checkpoint pushed → $AGENT_BRANCH: $msg"
        else
            log "Checkpoint push FAILED (work is committed locally; next checkpoint will retry): $msg"
            # Surface the underlying git error (indented) so auth/ref failures are diagnosable.
            # Redact token values defensively before logging (matches the secret guard above).
            [[ ${#GH_TOKEN} -ge 10 ]] && push_err="${push_err//$GH_TOKEN/***}"
            log "  git push error: ${push_err//$'\n'/ | }"
        fi
    )
    return 0
}

# ── Issue discovery (3-tier priority) ───────────────────────────────────────
# Sets globals: DISCOVERED_ISSUE, RECOVERY_MODE, RECOVERY_BRANCH, PR_MODE, PR_NUM

extract_pr_details() {
    # Given a JSON array of PR search results in $1, populate PR fields and
    # set DISCOVERED_ISSUE from the linked issue. Returns 0 on success, 1 if
    # no linked issue can be found.
    local prs="$1"
    local pr_num pr_body pr_branch pr_repo linked_num issue_json

    pr_num=$(echo "$prs"    | jq -r '.[0].number')
    pr_body=$(echo "$prs"   | jq -r '.[0].body // ""')
    pr_repo=$(echo "$prs"   | jq -r '.[0].repository.name')
    # `gh search prs` cannot return headRefName (it's not a valid search field),
    # so fetch the branch name separately with `gh pr view`, which does support it.
    pr_branch=$(gh pr view "$pr_num" --repo "$GITHUB_OWNER/$pr_repo" \
        --json headRefName --jq '.headRefName' 2>/dev/null || echo "")

    linked_num=$(echo "$pr_body" | grep -oiE '(closes|fixes|resolves) #[0-9]+' | grep -oE '[0-9]+' | head -1)
    [[ -z "$linked_num" ]] && return 1

    issue_json=$(gh issue view "$linked_num" \
        --repo "$GITHUB_OWNER/$pr_repo" \
        --json number,title,body,url 2>/dev/null || echo "")
    [[ -z "$issue_json" ]] && return 1

    DISCOVERED_ISSUE="[$(echo "$issue_json" | jq --arg repo "$pr_repo" '. + {repository: {name: $repo}}')]"
    RECOVERY_MODE=true
    RECOVERY_BRANCH="$pr_branch"
    PR_MODE=true
    PR_NUM="$pr_num"
    return 0
}

discover_issue() {
    RECOVERY_MODE=false
    RECOVERY_BRANCH=""
    PR_MODE=false
    PR_NUM=""
    DISCOVERED_ISSUE="[]"

    # --- Priority 1a: Issues already marked as processing (crash recovery) ---
    log "Checking for in-progress issues (label: '$PROCESSING_LABEL')..."
    local processing_issues
    processing_issues=$(gh search issues \
        --owner "$GITHUB_OWNER" \
        --label "$PROCESSING_LABEL" \
        --state open \
        --json repository,number,title,body,url \
        --sort created --order asc \
        --limit 1)

    if [[ "$processing_issues" != "[]" && -n "$processing_issues" ]]; then
        log "Recovery mode: found in-progress issue"
        RECOVERY_MODE=true
        DISCOVERED_ISSUE="$processing_issues"
        return 0
    fi

    # --- Priority 1b: PRs already marked as processing (PR-mode crash recovery) ---
    log "Checking for in-progress PRs (label: '$PROCESSING_LABEL')..."
    local processing_prs
    processing_prs=$(gh search prs \
        --owner "$GITHUB_OWNER" \
        --label "$PROCESSING_LABEL" \
        --state open \
        --json repository,number,title,body,url \
        --sort created --order asc \
        --limit 1 2>/dev/null || echo "[]")

    if [[ "$processing_prs" != "[]" && -n "$processing_prs" && "$processing_prs" != "null" ]]; then
        local pr_num_p
        pr_num_p=$(echo "$processing_prs" | jq -r '.[0].number')
        if extract_pr_details "$processing_prs"; then
            log "Recovery mode: found in-progress PR #$pr_num_p → issue #$(echo "$DISCOVERED_ISSUE" | jq -r '.[0].number')"
            return 0
        fi
        log "WARNING: PR #$pr_num_p has $PROCESSING_LABEL but no linked issue found — skipping."
    fi

    # --- Priority 2: Open PRs with TRIGGER_LABEL (agent must fix existing work) ---
    log "Checking for open PRs with label '$TRIGGER_LABEL'..."
    local trigger_prs
    trigger_prs=$(gh search prs \
        --owner "$GITHUB_OWNER" \
        --label "$TRIGGER_LABEL" \
        --state open \
        --json repository,number,title,body,url \
        --sort created --order asc \
        --limit 1 2>/dev/null || echo "[]")

    if [[ "$trigger_prs" != "[]" && -n "$trigger_prs" && "$trigger_prs" != "null" ]]; then
        local pr_num_t
        pr_num_t=$(echo "$trigger_prs" | jq -r '.[0].number')
        if extract_pr_details "$trigger_prs"; then
            log "Open PR #$pr_num_t → linked issue #$(echo "$DISCOVERED_ISSUE" | jq -r '.[0].number'), branch: $RECOVERY_BRANCH"
            return 0
        fi
        log "WARNING: PR #$pr_num_t has $TRIGGER_LABEL but no linked issue found — falling through to issues."
    fi

    # --- Priority 3: Oldest open issue with TRIGGER_LABEL (new work) ---
    log "Searching for oldest open issue with label '$TRIGGER_LABEL'..."
    local issues
    issues=$(gh search issues \
        --owner "$GITHUB_OWNER" \
        --label "$TRIGGER_LABEL" \
        --state open \
        --json repository,number,title,body,url \
        --sort created --order asc \
        --limit 1)

    if [[ "$issues" == "[]" || -z "$issues" ]]; then
        log "Workspace idle. No issues or PRs found."
        return 1
    fi

    DISCOVERED_ISSUE="$issues"
    return 0
}

RECOVERY_MODE=false
RECOVERY_BRANCH=""
PR_MODE=false
PR_NUM=""
DISCOVERED_ISSUE="[]"

if ! discover_issue; then
    # Nothing to do — opportunistically clean up state for closed/merged issues.
    gc_closed_state
    # Sleep before exiting so that restart: unless-stopped in docker-compose
    # produces a ~60s polling interval rather than a tight busy-loop.
    IDLE_SLEEP="${IDLE_SLEEP:-60}"
    [[ "$IDLE_SLEEP" -gt 0 ]] && sleep "$IDLE_SLEEP"
    exit 0
fi

# ── Extract issue fields ─────────────────────────────────────────────────────
TARGET_REPO=$(echo "$DISCOVERED_ISSUE" | jq -r '.[0].repository.name')
ISSUE_NUM=$(echo "$DISCOVERED_ISSUE"   | jq -r '.[0].number')
ISSUE_TITLE=$(echo "$DISCOVERED_ISSUE" | jq -r '.[0].title')
ISSUE_BODY=$(echo "$DISCOVERED_ISSUE"  | jq -r '.[0].body')
ISSUE_URL=$(echo "$DISCOVERED_ISSUE"   | jq -r '.[0].url')

# ── Ensure required labels exist in target repo ──────────────────────────────
ensure_repo_labels() {
    local repo="$1"
    log "Ensuring labels exist in $GITHUB_OWNER/$repo..."
    # gh label create --force creates or updates; never errors if label already exists
    gh label create "$TRIGGER_LABEL"    --repo "$GITHUB_OWNER/$repo" --color "0075ca" --force 2>/dev/null || log "WARNING: could not create label '$TRIGGER_LABEL'"
    gh label create "$PROCESSING_LABEL" --repo "$GITHUB_OWNER/$repo" --color "e4e669" --force 2>/dev/null || log "WARNING: could not create label '$PROCESSING_LABEL'"
    gh label create "$WAITING_LABEL"    --repo "$GITHUB_OWNER/$repo" --color "d93f0b" --force 2>/dev/null || log "WARNING: could not create label '$WAITING_LABEL'"
    gh label create "$READY_LABEL"      --repo "$GITHUB_OWNER/$repo" --color "0e8a16" --force 2>/dev/null || log "WARNING: could not create label '$READY_LABEL'"
}
ensure_repo_labels "$TARGET_REPO"

log "Issue:    [$TARGET_REPO#$ISSUE_NUM] $ISSUE_TITLE"
log "          $ISSUE_URL"
log "PR mode:  $PR_MODE${PR_MODE:+ (PR #$PR_NUM)}"
log "Recovery: $RECOVERY_MODE"

# Export for child scripts
export TARGET_REPO ISSUE_NUM ISSUE_TITLE ISSUE_BODY ISSUE_URL BASE_BRANCH REPO_DIR
export RECOVERY_MODE PR_MODE PR_NUM

# Per-issue state dir on the persistent volume (keyed by repo+issue so it's stable
# across PR-review iterations). Holds the reusable blueprint and the feedback marker.
STATE_ISSUE_DIR="$STATE_DIR/issues/$TARGET_REPO/$ISSUE_NUM"
export STATE_ISSUE_DIR

# ── Apply PROCESSING_LABEL immediately (atomic claim) ────────────────────────
# In PR mode this goes on the PR; in issue mode it goes on the issue.
# Removes TRIGGER_LABEL at the same time so another container doesn't double-pick.
if [[ "$RECOVERY_MODE" == "false" ]]; then
    apply_labels "$PROCESSING_LABEL" "$TRIGGER_LABEL"
    log "Label applied: '$PROCESSING_LABEL' (removed '$TRIGGER_LABEL')"
fi

# ── Clone repo ───────────────────────────────────────────────────────────────
rm -rf "$REPO_DIR"
log "Cloning $GITHUB_OWNER/$TARGET_REPO..."
# Use plain HTTPS — gh auth login configured the credential helper, so the token
# is injected transparently without appearing in the remote URL or process list.
git clone "https://github.com/$GITHUB_OWNER/$TARGET_REPO.git" "$REPO_DIR"
cd "$REPO_DIR"

# ── Detect base branch ───────────────────────────────────────────────────────
# Prefer an explicit env var override; otherwise probe the remote in priority order.
if [[ -z "$BASE_BRANCH" ]]; then
    for candidate in develop main master; do
        if git ls-remote --heads origin "$candidate" | grep -q .; then
            BASE_BRANCH="$candidate"
            break
        fi
    done
    : "${BASE_BRANCH:=main}"  # ultimate fallback if none of the above exist
fi
log "Base branch: $BASE_BRANCH"
export BASE_BRANCH

# ── Run pre-issue hooks ──────────────────────────────────────────────────────
log "Running pre-issue hooks..."
for hook in "$SCRIPT_DIR/hooks/pre-issue"/*.sh; do
    log "  → $(basename "$hook")"
    bash "$hook" || fail "Pre-issue hook failed: $hook"
done

# ── Set up agent branch ──────────────────────────────────────────────────────
SLUG=$(echo "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-40)
AGENT_BRANCH="agent/${ISSUE_NUM}-${SLUG}"
VERIFY_ERRORS_FILE="$REPO_DIR/VERIFY_ERRORS.md"

# Look for an already-pushed branch to resume, regardless of how we got here.
# The branch is the source of truth for "work exists" — checkpoint commits push it
# after every stage, so a resumable run always has one. We adopt it whether this is
# an explicit recovery (PROCESSING_LABEL / linked PR) OR a re-triggered issue whose
# earlier run already checkpointed work (e.g. resumed after a BLOCKED clarification).
EXISTING_BRANCH=""
if [[ -n "${RECOVERY_BRANCH:-}" ]]; then
    EXISTING_BRANCH=$(git ls-remote --heads origin "refs/heads/${RECOVERY_BRANCH}" 2>/dev/null \
        | awk '{print $2}' | sed 's|refs/heads/||' | head -1)
fi
if [[ -z "$EXISTING_BRANCH" ]]; then
    EXISTING_BRANCH=$(git ls-remote --heads origin "refs/heads/agent/${ISSUE_NUM}-*" 2>/dev/null \
        | awk '{print $2}' | sed 's|refs/heads/||' | head -1)
fi

if [[ -n "$EXISTING_BRANCH" ]]; then
    # --- Resume: check out the previously pushed branch (committed work + artifacts) ---
    git checkout "$EXISTING_BRANCH"
    AGENT_BRANCH="$EXISTING_BRANCH"
    log "Resuming on existing branch: $AGENT_BRANCH"
    # No "starting work" comment on purpose — the label flip to PROCESSING_LABEL is
    # the visible "picked up" signal, and it keeps the PR thread free of noise. Only
    # terminal states (needs-clarification / blocked / done / exhausted) get comments.
elif [[ "$RECOVERY_MODE" == "true" ]]; then
    # Recovery was expected (PROCESSING_LABEL or linked PR) but no branch was ever pushed
    # — the previous run crashed before its first checkpoint. Nothing to resume, so start
    # fresh on the branch and redo the work from the plan.
    log "Recovery expected but no pushed branch found — starting fresh on $AGENT_BRANCH"
    git checkout -b "$AGENT_BRANCH"
else
    # --- Fresh start ---
    git checkout -b "$AGENT_BRANCH"
    log "Working branch: $AGENT_BRANCH"
fi

export AGENT_BRANCH

# ── Restore persisted context + gather PR review feedback ────────────────────
# After a delivery the branch no longer carries the blueprint; pull it back from the
# state volume so stage 01 reuses it instead of re-planning. Then, on a PR-review
# iteration, collect the reviewer's new comments so the execute stage addresses them
# incrementally rather than re-implementing the original plan.
restore_issue_state
gather_pr_feedback

# ── Git identity for checkpoint + delivery commits ───────────────────────────
# Set once here so checkpoint() can commit throughout the loop, not just at delivery.
git config user.email "loop-engineer[bot]@disciple.tools"
git config user.name  "DT Loop Engineer"

# ── Verify helper ────────────────────────────────────────────────────────────
# run_verify_script <path>
#   Runs one verify script, captures its combined stdout+stderr to a temp file.
#   On failure: appends the output to VERIFY_ERRORS_FILE under a section header
#   and sets ALL_PASSED=false. On success: discards output (already logged).
#   Always returns 0 so the caller can run all scripts before checking ALL_PASSED.
run_verify_script() {
    local verify_script="$1"
    local SCRIPT_NAME SCRIPT_OUT SCRIPT_EXIT
    SCRIPT_NAME=$(basename "$verify_script")
    SCRIPT_EXIT=0
    log "  Checking: $SCRIPT_NAME"

    SCRIPT_OUT=$(mktemp)
    if [[ "$verify_script" == *.sh ]]; then
        bash "$verify_script" > "$SCRIPT_OUT" 2>&1 || SCRIPT_EXIT=$?
    elif [[ "$verify_script" == *.js ]]; then
        node "$verify_script" > "$SCRIPT_OUT" 2>&1 || SCRIPT_EXIT=$?
    fi

    if [[ $SCRIPT_EXIT -ne 0 ]]; then
        log "  FAILED: $SCRIPT_NAME (exit $SCRIPT_EXIT)"
        {
            echo "### $SCRIPT_NAME (exit $SCRIPT_EXIT)"
            cat "$SCRIPT_OUT"
            echo ""
        } >> "$VERIFY_ERRORS_FILE"
        ALL_PASSED=false
    else
        log "  PASSED: $SCRIPT_NAME"
    fi

    rm -f "$SCRIPT_OUT"
    return 0
}

# ── Recursive loop ───────────────────────────────────────────────────────────
RETRIES=0

while [[ $RETRIES -lt $MAX_LOOP_RETRIES ]]; do
    log "─── Loop iteration $((RETRIES + 1)) / $MAX_LOOP_RETRIES ───"

    # Stage 01: Plan
    log "Stage 01: Generating blueprint..."
    PLAN_EXIT=0
    bash "$SCRIPT_DIR/loop-stages/01_plan/generate_blueprint.sh" || PLAN_EXIT=$?

    if [[ $PLAN_EXIT -eq 2 ]]; then
        # Planner wrote QUESTIONS.md — needs human decision before work can begin
        QUESTIONS_CONTENT=$(cat "$REPO_DIR/QUESTIONS.md" 2>/dev/null \
            || echo "(No questions file found — check container logs)")
        log "Planner requires clarification. Posting questions and waiting."
        post_comment "**Agent needs clarification before planning can begin.**

$QUESTIONS_CONTENT

Please answer the questions above, then re-apply the \`$TRIGGER_LABEL\` label to resume."
        cleanup_processing_label "$WAITING_LABEL"
        exit 0
    fi

    [[ $PLAN_EXIT -ne 0 ]] && fail "Blueprint generation failed (exit $PLAN_EXIT)"

    # Checkpoint the plan: pushes the branch so recovery has the blueprint even if the
    # execute stage crashes. No-op on later iterations when the blueprint is unchanged.
    checkpoint "wip(#${ISSUE_NUM}): blueprint — ${ISSUE_TITLE}"

    # Stage 02: Execute
    log "Stage 02: Running agent..."
    bash "$SCRIPT_DIR/loop-stages/02_execute/run_opencode_agent.sh"

    # Checkpoint partial work immediately — before any decision below — so an interrupted
    # (or timed-out) execution is preserved on the remote branch for the next run.
    checkpoint "wip(#${ISSUE_NUM}): iteration $((RETRIES + 1)) — agent execution"

    # Agent execution timed out: work is checkpointed, but the task isn't finished. Skip
    # verification (it would report noise on incomplete code) and retry — the next
    # iteration reuses the checked-in plan and continues from the committed partial work.
    if [[ -f "$REPO_DIR/PROGRESS.md" ]] && grep -q "^TIMEOUT:" "$REPO_DIR/PROGRESS.md"; then
        log "Agent timed out — partial work checkpointed. Retrying to continue ($((RETRIES + 1))/$MAX_LOOP_RETRIES)."
        RETRIES=$((RETRIES + 1))
        continue
    fi

    # Check for blocked state
    if [[ -f "$REPO_DIR/PROGRESS.md" ]] && grep -q "^BLOCKED:" "$REPO_DIR/PROGRESS.md"; then
        BLOCKED_MSG=$(grep "^BLOCKED:" "$REPO_DIR/PROGRESS.md" | head -1)
        log "Agent is blocked: $BLOCKED_MSG"
        post_comment "**Agent Blocked** (iteration $((RETRIES + 1)) / $MAX_LOOP_RETRIES)

$BLOCKED_MSG

Human input is needed before the agent can continue. Update the issue with the required information, then re-apply the \`$TRIGGER_LABEL\` label."
        cleanup_processing_label "$WAITING_LABEL"
        exit 0
    fi

    # Stage 03: Verify
    log "Stage 03: Running verification..."
    ALL_PASSED=true
    : > "$VERIFY_ERRORS_FILE"

    # Run all system verify scripts — do NOT stop on the first failure.
    # Collecting every failing script's output in one pass gives the agent the
    # full picture so it can fix everything in a single retry instead of one
    # error class per iteration.
    for verify_script in "$SCRIPT_DIR/loop-stages/03_verify"/*; do
        [[ "$verify_script" == *.sh || "$verify_script" == *.js ]] || continue
        run_verify_script "$verify_script"
    done

    # Per-repo verify scripts supplement (not replace) the system ones.
    # A repo can ship additional checks in .loop-engineer/verify/*.sh|js.
    REPO_VERIFY_DIR="$REPO_DIR/.loop-engineer/verify"
    if [[ -d "$REPO_VERIFY_DIR" ]]; then
        log "  Running per-repo verify scripts (.loop-engineer/verify/)..."
        for verify_script in "$REPO_VERIFY_DIR"/*.sh "$REPO_VERIFY_DIR"/*.js; do
            [[ -f "$verify_script" ]] || continue
            run_verify_script "$verify_script"
        done
    fi

    if [[ "$ALL_PASSED" == "true" ]]; then
        log "All verify stages passed!"
        # Stash the blueprint + feedback marker before delivery strips artifacts
        # from the branch, so the next review iteration can reuse them.
        persist_issue_state
        log "Stage 04: Delivering..."
        export LOOP_ITERATIONS=$((RETRIES + 1))
        bash "$SCRIPT_DIR/loop-stages/04_deliver/open_github_pr.sh"
        # PROCESSING_LABEL removal and READY_LABEL application happen inside the deliver script
        exit 0
    fi

    log "Verify failed. Errors written to VERIFY_ERRORS.md. Retrying ($((RETRIES + 1))/$MAX_LOOP_RETRIES)..."
    RETRIES=$((RETRIES + 1))
done

# ── Max retries reached ──────────────────────────────────────────────────────
log "Max retries ($MAX_LOOP_RETRIES) reached without passing verification."
ERROR_EXCERPT=$(head -60 "$VERIFY_ERRORS_FILE" 2>/dev/null || echo "No error log found.")
post_comment "**Agent exhausted retries** ($MAX_LOOP_RETRIES / $MAX_LOOP_RETRIES)

The loop could not pass all verification checks after $MAX_LOOP_RETRIES attempts. Human review required.

<details>
<summary>Last verification errors</summary>

\`\`\`
$ERROR_EXCERPT
\`\`\`
</details>

Branch with partial work: \`$AGENT_BRANCH\`"
cleanup_processing_label "$WAITING_LABEL"
exit 1
