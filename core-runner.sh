#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$SCRIPT_DIR/state"
REPO_DIR="$SCRIPT_DIR/repo"
BASE_BRANCH="${BASE_BRANCH:-develop}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
fail() { log "ERROR: $*"; exit 1; }

# ── Validate required env vars ──────────────────────────────────────────────
for var in GEMINI_API_TOKEN GH_TOKEN GITHUB_OWNER TRIGGER_LABEL WAITING_LABEL READY_LABEL MAX_LOOP_RETRIES; do
    [[ -z "${!var:-}" ]] && fail "Required env var $var is not set"
done

# ── Auth with GitHub CLI ─────────────────────────────────────────────────────
log "Authenticating with GitHub..."
echo "$GH_TOKEN" | gh auth login --with-token --hostname "github.com"

# ── Run bootstrap hooks (once per container) ────────────────────────────────
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

# ── Discover target issue ────────────────────────────────────────────────────
log "Searching for issues with label '$TRIGGER_LABEL' in org '$GITHUB_OWNER'..."
SEARCH_RESULTS=$(gh search issues \
    --owner "$GITHUB_OWNER" \
    --label "$TRIGGER_LABEL" \
    --state open \
    --json repository,number,title,body,url \
    --limit 1)

if [[ "$SEARCH_RESULTS" == "[]" ]] || [[ -z "$SEARCH_RESULTS" ]]; then
    log "Workspace idle. No issues found with label '$TRIGGER_LABEL'."
    exit 0
fi

TARGET_REPO=$(echo "$SEARCH_RESULTS" | jq -r '.[0].repository.name')
ISSUE_NUM=$(echo "$SEARCH_RESULTS"   | jq -r '.[0].number')
ISSUE_TITLE=$(echo "$SEARCH_RESULTS" | jq -r '.[0].title')
ISSUE_BODY=$(echo "$SEARCH_RESULTS"  | jq -r '.[0].body')
ISSUE_URL=$(echo "$SEARCH_RESULTS"   | jq -r '.[0].url')

log "Picked up: [$TARGET_REPO#$ISSUE_NUM] $ISSUE_TITLE"
log "  $ISSUE_URL"

# Export for child scripts
export TARGET_REPO ISSUE_NUM ISSUE_TITLE ISSUE_BODY ISSUE_URL BASE_BRANCH REPO_DIR

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

# ── Create agent working branch ──────────────────────────────────────────────
SLUG=$(echo "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-40)
AGENT_BRANCH="agent/${ISSUE_NUM}-${SLUG}"
git checkout -b "$AGENT_BRANCH"
export AGENT_BRANCH

log "Working branch: $AGENT_BRANCH"

# ── Recursive loop ───────────────────────────────────────────────────────────
RETRIES=0
VERIFY_ERRORS_FILE="$REPO_DIR/VERIFY_ERRORS.md"

while [[ $RETRIES -lt $MAX_LOOP_RETRIES ]]; do
    log "─── Loop iteration $((RETRIES + 1)) / $MAX_LOOP_RETRIES ───"

    # Stage 01: Plan
    log "Stage 01: Generating blueprint..."
    node "$SCRIPT_DIR/loop-stages/01_plan/generate_blueprint.js" \
        || fail "Blueprint generation failed"

    # Stage 02: Execute
    log "Stage 02: Running agent..."
    bash "$SCRIPT_DIR/loop-stages/02_execute/run_opencode_agent.sh"

    # Check for blocked state
    if [[ -f "$REPO_DIR/PROGRESS.md" ]] && grep -q "^BLOCKED:" "$REPO_DIR/PROGRESS.md"; then
        BLOCKED_MSG=$(grep "^BLOCKED:" "$REPO_DIR/PROGRESS.md" | head -1)
        log "Agent is blocked: $BLOCKED_MSG"
        gh issue comment "$ISSUE_NUM" \
            --repo "$GITHUB_OWNER/$TARGET_REPO" \
            --body "**Agent Blocked** (iteration $((RETRIES + 1)))

$BLOCKED_MSG

The agent requires human input before it can continue. Once the issue is updated, re-apply the \`$TRIGGER_LABEL\` label."
        gh issue edit "$ISSUE_NUM" \
            --repo "$GITHUB_OWNER/$TARGET_REPO" \
            --add-label "$WAITING_LABEL" \
            --remove-label "$TRIGGER_LABEL"
        exit 0
    fi

    # Stage 03: Verify
    log "Stage 03: Running verification..."
    ALL_PASSED=true
    > "$VERIFY_ERRORS_FILE"

    for verify_script in "$SCRIPT_DIR/loop-stages/03_verify"/*; do
        SCRIPT_NAME=$(basename "$verify_script")
        log "  Checking: $SCRIPT_NAME"
        if [[ "$verify_script" == *.sh ]]; then
            if ! bash "$verify_script" >> "$VERIFY_ERRORS_FILE" 2>&1; then
                log "  FAILED: $SCRIPT_NAME"
                echo "" >> "$VERIFY_ERRORS_FILE"
                echo "--- $SCRIPT_NAME failed ---" >> "$VERIFY_ERRORS_FILE"
                ALL_PASSED=false
                break
            fi
        elif [[ "$verify_script" == *.js ]]; then
            if ! node "$verify_script" >> "$VERIFY_ERRORS_FILE" 2>&1; then
                log "  FAILED: $SCRIPT_NAME"
                echo "" >> "$VERIFY_ERRORS_FILE"
                echo "--- $SCRIPT_NAME failed ---" >> "$VERIFY_ERRORS_FILE"
                ALL_PASSED=false
                break
            fi
        fi
        log "  PASSED: $SCRIPT_NAME"
    done

    if [[ "$ALL_PASSED" == "true" ]]; then
        log "All verify stages passed!"
        # Stage 04: Deliver
        log "Stage 04: Opening PR..."
        bash "$SCRIPT_DIR/loop-stages/04_deliver/open_github_pr.sh"
        exit 0
    fi

    log "Verify failed. Errors captured in VERIFY_ERRORS.md. Retrying..."
    ((RETRIES++))
done

# ── Max retries reached ──────────────────────────────────────────────────────
log "Max retries ($MAX_LOOP_RETRIES) reached without passing verification."
ERROR_EXCERPT=$(head -50 "$VERIFY_ERRORS_FILE" 2>/dev/null || echo "No error file found.")
gh issue comment "$ISSUE_NUM" \
    --repo "$GITHUB_OWNER/$TARGET_REPO" \
    --body "**Agent reached max retries ($MAX_LOOP_RETRIES)**

The loop was unable to pass all verification checks after $MAX_LOOP_RETRIES attempts.

<details>
<summary>Last verification errors</summary>

\`\`\`
$ERROR_EXCERPT
\`\`\`
</details>

Human review required."
gh issue edit "$ISSUE_NUM" \
    --repo "$GITHUB_OWNER/$TARGET_REPO" \
    --add-label "$WAITING_LABEL" \
    --remove-label "$TRIGGER_LABEL"
exit 1
