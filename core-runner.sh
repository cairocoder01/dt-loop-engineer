#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$SCRIPT_DIR/state"
REPO_DIR="$SCRIPT_DIR/repo"
BASE_BRANCH="${BASE_BRANCH:-develop}"

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
fail() { log "ERROR: $*"; exit 1; }

# ── Validate required env vars ──────────────────────────────────────────────
for var in GEMINI_API_TOKEN GH_TOKEN GITHUB_OWNER TRIGGER_LABEL PROCESSING_LABEL WAITING_LABEL READY_LABEL MAX_LOOP_RETRIES; do
    [[ -z "${!var:-}" ]] && fail "Required env var $var is not set"
done

# ── Auth with GitHub CLI ─────────────────────────────────────────────────────
log "Authenticating with GitHub..."
echo "$GH_TOKEN" | gh auth login --with-token --hostname "github.com"

# ── Run bootstrap hooks (once per container lifetime) ────────────────────────
BOOTSTRAP_DONE="$STATE_DIR/.bootstrap_complete"
if [[ ! -f "$BOOTSTRAP_DONE" ]]; then
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

post_comment() {
    local body="$1"
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
    pr_branch=$(echo "$prs" | jq -r '.[0].headRefName // ""')
    pr_repo=$(echo "$prs"   | jq -r '.[0].repository.name')

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
        --json repository,number,title,body,url,headRefName \
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
        --json repository,number,title,body,url,headRefName \
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
    exit 0
fi

# ── Extract issue fields ─────────────────────────────────────────────────────
TARGET_REPO=$(echo "$DISCOVERED_ISSUE" | jq -r '.[0].repository.name')
ISSUE_NUM=$(echo "$DISCOVERED_ISSUE"   | jq -r '.[0].number')
ISSUE_TITLE=$(echo "$DISCOVERED_ISSUE" | jq -r '.[0].title')
ISSUE_BODY=$(echo "$DISCOVERED_ISSUE"  | jq -r '.[0].body')
ISSUE_URL=$(echo "$DISCOVERED_ISSUE"   | jq -r '.[0].url')

log "Issue:    [$TARGET_REPO#$ISSUE_NUM] $ISSUE_TITLE"
log "          $ISSUE_URL"
log "PR mode:  $PR_MODE${PR_MODE:+ (PR #$PR_NUM)}"
log "Recovery: $RECOVERY_MODE"

# Export for child scripts
export TARGET_REPO ISSUE_NUM ISSUE_TITLE ISSUE_BODY ISSUE_URL BASE_BRANCH REPO_DIR
export RECOVERY_MODE PR_MODE PR_NUM

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
git clone "https://x-access-token:${GH_TOKEN}@github.com/$GITHUB_OWNER/$TARGET_REPO.git" "$REPO_DIR"
cd "$REPO_DIR"

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

if [[ "$RECOVERY_MODE" == "true" ]]; then
    # --- Recovery: resume on existing branch ---
    TARGET_BRANCH="${RECOVERY_BRANCH:-$AGENT_BRANCH}"
    EXISTING_BRANCH=$(git ls-remote --heads origin "refs/heads/${TARGET_BRANCH}" 2>/dev/null \
        | awk '{print $2}' | sed 's|refs/heads/||' | head -1)

    # Fallback: search for any agent/<issue-num>-* branch
    if [[ -z "$EXISTING_BRANCH" ]]; then
        EXISTING_BRANCH=$(git ls-remote --heads origin "refs/heads/agent/${ISSUE_NUM}-*" 2>/dev/null \
            | awk '{print $2}' | sed 's|refs/heads/||' | head -1)
    fi

    if [[ -n "$EXISTING_BRANCH" ]]; then
        git checkout "$EXISTING_BRANCH"
        AGENT_BRANCH="$EXISTING_BRANCH"
        log "Resuming on branch: $AGENT_BRANCH"

        LAST_COMMITS=$(git log --oneline -5 2>/dev/null || echo "(none)")
        VERIFY_SUMMARY=""
        if [[ -f "$VERIFY_ERRORS_FILE" ]]; then
            VERIFY_SUMMARY="$(head -30 "$VERIFY_ERRORS_FILE")"
        fi

        post_comment "**Loop Engineer resuming** — previous container run was interrupted.

Branch: \`$AGENT_BRANCH\`
Last commits:
\`\`\`
$LAST_COMMITS
\`\`\`
${VERIFY_SUMMARY:+Last verify errors:
\`\`\`
$VERIFY_SUMMARY
\`\`\`}"
    else
        log "Recovery failed: no branch found matching 'agent/${ISSUE_NUM}-*' or '${TARGET_BRANCH}'"
        post_comment "**Recovery failed** — could not locate previous work.

No branch found matching \`agent/${ISSUE_NUM}-*\` or \`${TARGET_BRANCH}\`.

Please check whether the previous run left any partial changes and re-apply \`$TRIGGER_LABEL\` when ready to retry."
        cleanup_processing_label "$WAITING_LABEL"
        exit 1
    fi
else
    # Fresh start
    git checkout -b "$AGENT_BRANCH"
    log "Working branch: $AGENT_BRANCH"
fi

export AGENT_BRANCH

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

    # Stage 02: Execute
    log "Stage 02: Running agent..."
    bash "$SCRIPT_DIR/loop-stages/02_execute/run_opencode_agent.sh"

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
    > "$VERIFY_ERRORS_FILE"

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
        log "Stage 04: Delivering..."
        export LOOP_ITERATIONS=$((RETRIES + 1))
        bash "$SCRIPT_DIR/loop-stages/04_deliver/open_github_pr.sh"
        # PROCESSING_LABEL removal and READY_LABEL application happen inside the deliver script
        exit 0
    fi

    log "Verify failed. Errors written to VERIFY_ERRORS.md. Retrying ($((RETRIES + 1))/$MAX_LOOP_RETRIES)..."
    ((RETRIES++))
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
