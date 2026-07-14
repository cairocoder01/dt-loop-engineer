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
# Repo checkouts are cached per-target under REPO_CACHE_DIR (a Docker volume — see
# docker-compose.yml) so runs against the same repo reuse the clone instead of
# re-fetching every object. REPO_DIR is the per-target subfolder; it's set once
# TARGET_REPO is known (after issue discovery), not here.
REPO_CACHE_DIR="${REPO_CACHE_DIR:-$SCRIPT_DIR/repo-cache}"
REPO_DIR=""
BASE_BRANCH="${BASE_BRANCH:-}"   # auto-detected after clone; override via env var

# ── Loop artifacts ───────────────────────────────────────────────────────────
# Working-state files the loop produces (the plan, progress trail, verify errors,
# gathered review feedback, and clarification questions). They are NEVER committed
# to the repo — they're mirrored into the per-issue state volume the moment they're
# written, so crash recovery restores them without polluting the branch's git
# history. See stash_artifacts / restore_artifacts / finalize_issue_state below.
LOOP_ARTIFACTS=(BLUEPRINT.md QUESTIONS.md PROGRESS.md VERIFY_ERRORS.md REQUESTED_CHANGES.md)

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
#
# Uses the REST issues/labels endpoints via `gh api`, NOT `gh pr edit --add-label`.
# The bundled gh (Alpine's github-cli, 2.39.x) builds a GraphQL query for
# `gh pr edit`/`gh issue edit` that references the now-sunset Projects-classic
# `projectCards` field, so every label mutation through those commands fails with a
# GraphQL error and exits non-zero. The previous `2>/dev/null || true` hid both the
# error and the failure, so labels silently never changed while the log claimed
# success. REST doesn't touch projectCards and works on any gh version. PRs and issues
# share the same /issues/:n/labels endpoints, so one number covers both modes.
apply_labels() {
    local add_label="${1:-}"
    local remove_label="${2:-}"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "[DRY-RUN] labels skipped: add='${add_label:-}' remove='${remove_label:-}'"
        return 0
    fi
    local num
    if [[ "$PR_MODE" == "true" ]]; then num="$PR_NUM"; else num="$ISSUE_NUM"; fi

    if [[ -n "$add_label" ]]; then
        if gh api -X POST "repos/$GITHUB_OWNER/$TARGET_REPO/issues/$num/labels" \
                -f "labels[]=$add_label" >/dev/null 2>&1; then
            log "  label +'$add_label' (#$num)"
        else
            log "  WARNING: failed to add label '$add_label' to #$num"
        fi
    fi
    if [[ -n "$remove_label" ]]; then
        # DELETE returns 404 when the label isn't currently applied — expected and
        # harmless (the desired end state is "not present"), so don't warn on it.
        if gh api -X DELETE "repos/$GITHUB_OWNER/$TARGET_REPO/issues/$num/labels/$remove_label" >/dev/null 2>&1; then
            log "  label -'$remove_label' (#$num)"
        else
            log "  label -'$remove_label' (#$num) — not present / already removed"
        fi
    fi
}

cleanup_processing_label() {
    local extra_label="${1:-}"
    apply_labels "$extra_label" "$PROCESSING_LABEL"
}

# ── Loop-artifact ↔ state-volume mirroring ───────────────────────────────────
# Artifacts are never committed. Instead they live in the per-issue state volume
# (keyed by repo+issue, so stable across PR-review iterations). We stash them there
# the moment they're written and restore them at run start, so a crashed/timed-out
# run resumes with its plan and progress intact — the branch carries only real code.

# Keep git from ever staging the artifacts. .git/info/exclude is local to this clone
# and never committed, so we don't touch the target repo's tracked .gitignore. Also
# untrack any artifact a pre-change branch already committed (one-time cleanup — the
# working copy is left in place; the index removal lands in the next checkpoint).
exclude_artifacts_from_git() {
    [[ -d "$REPO_DIR/.git" ]] || return 0
    local exclude_file="$REPO_DIR/.git/info/exclude" f
    for f in "${LOOP_ARTIFACTS[@]}"; do
        grep -qxF "$f" "$exclude_file" 2>/dev/null || printf '%s\n' "$f" >> "$exclude_file"
        if git -C "$REPO_DIR" ls-files --error-unmatch "$f" >/dev/null 2>&1; then
            git -C "$REPO_DIR" rm --cached --quiet "$f" >/dev/null 2>&1 || true
            log "Untracked legacy committed artifact: $f (will stop being committed)"
        fi
    done
}

# Mirror the CURRENT set of artifacts in the working tree into the state volume:
# copy the ones that exist, drop the ones that no longer do (so a regenerated plan
# that removed QUESTIONS.md, say, doesn't leave a stale copy behind). Safe to call
# often — it only runs after restore_artifacts has repopulated the fresh clone.
stash_artifacts() {
    [[ -n "${STATE_ISSUE_DIR:-}" ]] || return 0
    mkdir -p "$STATE_ISSUE_DIR"
    local f
    for f in "${LOOP_ARTIFACTS[@]}"; do
        if [[ -f "$REPO_DIR/$f" ]]; then
            cp "$REPO_DIR/$f" "$STATE_ISSUE_DIR/$f"
        else
            rm -f "$STATE_ISSUE_DIR/$f"
        fi
    done
}

# Repopulate a freshly cloned working tree from the volume (crash/timeout recovery).
restore_artifacts() {
    [[ -n "${STATE_ISSUE_DIR:-}" && -d "$STATE_ISSUE_DIR" ]] || return 0
    local f restored=()
    for f in "${LOOP_ARTIFACTS[@]}"; do
        [[ -f "$STATE_ISSUE_DIR/$f" ]] && { cp "$STATE_ISSUE_DIR/$f" "$REPO_DIR/$f"; restored+=("$f"); }
    done
    [[ ${#restored[@]} -gt 0 ]] && log "Restored artifacts from state volume: ${restored[*]}"
}

# Called on successful delivery. Only the blueprint is carried across delivered
# iterations — it lets a later PR-review pass skip re-planning. The run-scoped
# artifacts are cleared so that pass doesn't resume against a stale COMPLETE trail.
finalize_issue_state() {
    [[ -n "${STATE_ISSUE_DIR:-}" ]] || return 0
    mkdir -p "$STATE_ISSUE_DIR"
    [[ -f "$REPO_DIR/BLUEPRINT.md" ]] && cp "$REPO_DIR/BLUEPRINT.md" "$STATE_ISSUE_DIR/BLUEPRINT.md"
    local f
    for f in QUESTIONS.md PROGRESS.md VERIFY_ERRORS.md REQUESTED_CHANGES.md; do
        rm -f "$STATE_ISSUE_DIR/$f"
    done
    # Advance the feedback marker to when this run STARTED gathering (not now), so a
    # comment posted mid-run is reprocessed next iteration rather than silently skipped.
    printf '%s\n' "${FEEDBACK_MARKER_NEXT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" > "$STATE_ISSUE_DIR/last_processed_at"
    log "Finalized issue state (kept blueprint, cleared run-scoped artifacts)."
}

# Collect PR review feedback posted since the last delivery into REQUESTED_CHANGES.md,
# which the execute stage treats as the highest-priority instruction. This is what
# turns a re-triggered PR from "re-implement the blueprint" into "address the review".
gather_pr_feedback() {
    # Capture the cutoff for the NEXT run before doing anything, so finalize_issue_state
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

# When a PR was picked up because its GitHub checks are FAILING (CI_FAILURE_MODE), fetch
# the failing check names and append them to REQUESTED_CHANGES.md — the same file the
# execute stage treats as the highest-priority instruction. The local verify stage (03)
# re-runs most checks anyway, but naming exactly what CI flagged points the agent at the
# right failure (and at checks the local verify can't reproduce, e.g. the built-asset
# diff). Appends (>>) so it composes with any review feedback gathered just above.
gather_ci_failures() {
    [[ "${CI_FAILURE_MODE:-false}" == "true" && "${PR_MODE:-false}" == "true" && -n "${PR_NUM:-}" ]] || return 0
    local out failing
    out="$REPO_DIR/REQUESTED_CHANGES.md"
    # bucket normalizes each check's state; anything not pass/skipping is a problem.
    failing=$(gh pr checks "$PR_NUM" --repo "$GITHUB_OWNER/$TARGET_REPO" --json name,bucket,link 2>/dev/null \
        | jq -r '[.[] | select(.bucket != "pass" and .bucket != "skipping")]
            | map("- **" + .name + "** [" + .bucket + "]" + (if (.link // "") != "" then " — " + .link else "" end))
            | join("\n")' 2>/dev/null || echo "")
    if [[ -z "$failing" ]]; then
        log "CI-failure mode but no failing checks reported now (possibly transient/rerun)."
        return 0
    fi
    {
        echo "# Failing CI checks (PR #$PR_NUM)"
        echo
        echo "This PR was delivered as ready for review, but the following GitHub checks are FAILING."
        echo "Reproduce each locally, fix the underlying cause, and make the checks pass:"
        echo
        echo "$failing"
    } >> "$out"
    log "Recorded $(printf '%s\n' "$failing" | grep -c '^- ') failing CI check(s) into REQUESTED_CHANGES.md."
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
# Commits the agent's real CODE work on the branch and pushes it. The loop artifacts
# are NOT committed (they're excluded from git and mirrored to the state volume via
# stash_artifacts instead) — so recovery is two-part: the pushed branch carries the
# code, and the volume carries the plan/progress. Requires AGENT_BRANCH and git identity
# to be set. Always returns 0 — a failed checkpoint must never abort the loop.
checkpoint() {
    local msg="$1"
    # Mirror artifacts to the volume first, so they survive even if the code commit
    # below is a no-op or the push fails.
    stash_artifacts
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
    CI_FAILURE_MODE=false
    TRIGGER_PICKUP=false
    DISCOVERED_ISSUE="[]"

    # --- Priority 0: PRs delivered as ready-for-review but with FAILING CI checks ---
    # These are the most urgent: the agent already handed the PR off as "done", yet the
    # automated GitHub checks disagree — we shipped something broken. Re-open and fix it
    # immediately, ahead of any other work. (A PR mid-rework carries PROCESSING, not
    # READY, so it's recovered via Priority 1b instead — these sets never overlap.)
    log "Checking for ready-for-review PRs with FAILING checks (label: '$READY_LABEL')..."
    local failing_prs
    failing_prs=$(gh search prs \
        --owner "$GITHUB_OWNER" \
        --label "$READY_LABEL" \
        --state open \
        --checks failure \
        --json repository,number,title,body,url \
        --sort updated --order asc \
        --limit 1 2>/dev/null || echo "[]")

    if [[ "$failing_prs" != "[]" && -n "$failing_prs" && "$failing_prs" != "null" ]]; then
        local pr_num_f
        pr_num_f=$(echo "$failing_prs" | jq -r '.[0].number')
        if extract_pr_details "$failing_prs"; then
            CI_FAILURE_MODE=true
            log "CI-failure recovery: ready PR #$pr_num_f has failing checks → issue #$(echo "$DISCOVERED_ISSUE" | jq -r '.[0].number')"
            return 0
        fi
        log "WARNING: PR #$pr_num_f is ready with failing checks but has no linked issue — skipping."
    fi

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
            TRIGGER_PICKUP=true   # human re-applied the trigger → deliberate re-trigger
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

    TRIGGER_PICKUP=true   # fresh trigger-labeled issue → deliberate new work
    DISCOVERED_ISSUE="$issues"
    return 0
}

RECOVERY_MODE=false
RECOVERY_BRANCH=""
PR_MODE=false
PR_NUM=""
CI_FAILURE_MODE=false
TRIGGER_PICKUP=false
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

# Per-target repo checkout inside the persistent cache volume.
REPO_DIR="$REPO_CACHE_DIR/$TARGET_REPO"

log "Issue:    [$TARGET_REPO#$ISSUE_NUM] $ISSUE_TITLE"
log "          $ISSUE_URL"
log "PR mode:  $PR_MODE${PR_MODE:+ (PR #$PR_NUM)}"
log "Recovery: $RECOVERY_MODE"

# Export for child scripts
export TARGET_REPO ISSUE_NUM ISSUE_TITLE ISSUE_BODY ISSUE_URL BASE_BRANCH REPO_DIR
export RECOVERY_MODE PR_MODE PR_NUM CI_FAILURE_MODE

# Per-issue state dir on the persistent volume (keyed by repo+issue so it's stable
# across PR-review iterations). Holds the reusable blueprint and the feedback marker.
STATE_ISSUE_DIR="$STATE_DIR/issues/$TARGET_REPO/$ISSUE_NUM"
export STATE_ISSUE_DIR

# ── Bounded auto-retry for CI-failure recovery ───────────────────────────────
# A ready PR with failing checks (Priority 0) is picked WITHOUT a human in the loop,
# so unlike the human-triggered path there's no natural gate. If the agent can't make
# CI green, it would re-deliver → re-enter the ready+failing set → be re-picked forever,
# burning API tokens. Bound it: after MAX_CI_FIX_ATTEMPTS auto-attempts, hand the PR to
# a human (WAITING label) instead. The counter lives in the per-issue state volume.
# Any NON-CI pickup (human re-applies TRIGGER_LABEL, or fresh issue work) resets it, so
# a human who investigates and re-triggers grants a fresh batch of attempts.
CI_ATTEMPTS_FILE="$STATE_ISSUE_DIR/ci_fix_attempts"
MAX_CI_FIX_ATTEMPTS="${MAX_CI_FIX_ATTEMPTS:-3}"
if [[ "$CI_FAILURE_MODE" == "true" ]]; then
    mkdir -p "$STATE_ISSUE_DIR"
    CI_ATTEMPTS=$(cat "$CI_ATTEMPTS_FILE" 2>/dev/null || echo 0)
    [[ "$CI_ATTEMPTS" =~ ^[0-9]+$ ]] || CI_ATTEMPTS=0
    if [[ "$CI_ATTEMPTS" -ge "$MAX_CI_FIX_ATTEMPTS" ]]; then
        log "CI-failure auto-retry exhausted for PR #$PR_NUM ($CI_ATTEMPTS/$MAX_CI_FIX_ATTEMPTS). Handing off to a human."
        post_comment "**Agent could not make CI pass** after $CI_ATTEMPTS automated attempt(s).

This PR's automated checks are still failing. Auto-retry is paused to avoid a loop — a human needs to look at it. After fixing (or to let the agent try again), re-apply the \`$TRIGGER_LABEL\` label."
        apply_labels "$WAITING_LABEL" "$READY_LABEL"
        exit 0
    fi
    printf '%s\n' "$((CI_ATTEMPTS + 1))" > "$CI_ATTEMPTS_FILE"
    log "CI-failure auto-retry attempt $((CI_ATTEMPTS + 1))/$MAX_CI_FIX_ATTEMPTS for PR #$PR_NUM."
elif [[ "$TRIGGER_PICKUP" == "true" ]]; then
    # A human deliberately (re-)applied the trigger label — grant a fresh CI-fix budget.
    # Crash-recovery pickups (PROCESSING label) are NOT trigger pickups, so a resumed
    # CI-fix run keeps its running count instead of silently resetting it.
    rm -f "$CI_ATTEMPTS_FILE" 2>/dev/null || true
fi

# ── Apply PROCESSING_LABEL immediately (atomic claim) ────────────────────────
# In PR mode this goes on the PR; in issue mode it goes on the issue.
# Removes TRIGGER_LABEL at the same time so another container doesn't double-pick.
#
# This runs UNCONDITIONALLY — including recovery runs. Priority-2 discovery finds
# PRs *by* their TRIGGER_LABEL (a human re-applied it to request another pass) and
# reaches here with RECOVERY_MODE=true; if we skipped re-labeling those, the trigger
# label would linger and the PR would be re-picked on every poll cycle (the
# "re-running over and over" symptom). add/remove-label are idempotent, so this is a
# harmless no-op for genuine Priority-1 recovery (processing already on, trigger
# already gone).
apply_labels "$PROCESSING_LABEL" "$TRIGGER_LABEL"
log "Label applied: '$PROCESSING_LABEL' (removed '$TRIGGER_LABEL')"
# A CI-failure rework was picked up by its READY_LABEL; it's no longer "ready for
# review" while we rework it, so drop that label too. Deliver re-adds it on success.
if [[ "$CI_FAILURE_MODE" == "true" ]]; then
    apply_labels "" "$READY_LABEL"
    log "Label removed: '$READY_LABEL' (CI-failure rework in progress)"
fi

# ── Sync repo (reuse cached checkout when available) ─────────────────────────
# A cached checkout for this target is fetched + reset rather than re-cloned: a
# fetch pulls only new objects, while a fresh clone re-downloads the whole history
# every run. Ignored build dirs (vendor/, node_modules/) survive the reset below,
# so composer/npm also start warm. If the cache is missing or doesn't look like a
# clean clone of THIS repo, we fall back to a fresh clone.
# Use plain HTTPS — gh auth login configured the credential helper, so the token
# is injected transparently without appearing in the remote URL or process list.
REPO_URL="https://github.com/$GITHUB_OWNER/$TARGET_REPO.git"
mkdir -p "$REPO_CACHE_DIR"

clone_fresh() {
    log "Cloning $GITHUB_OWNER/$TARGET_REPO..."
    rm -rf "$REPO_DIR"
    git clone "$REPO_URL" "$REPO_DIR"
    cd "$REPO_DIR"
}

repo_cache_is_valid() {
    [[ -d "$REPO_DIR/.git" ]] || return 1
    git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 || return 1
    # Reject a leftover checkout that points at a different repo.
    local origin
    origin=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null) || return 1
    [[ "$origin" == "$REPO_URL" ]]
}

if repo_cache_is_valid; then
    log "Reusing cached checkout: $REPO_DIR"
    cd "$REPO_DIR"
    # Clear any half-finished operation a crashed prior run may have left behind,
    # so the fetch/reset below can't be blocked by an in-progress merge/rebase/am.
    git merge --abort  >/dev/null 2>&1 || true
    git rebase --abort >/dev/null 2>&1 || true
    git am --abort     >/dev/null 2>&1 || true
    if ! git fetch --prune origin; then
        log "Fetch failed on cached checkout — falling back to a fresh clone."
        cd "$REPO_CACHE_DIR"
        clone_fresh
    fi
else
    clone_fresh
fi

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

# ── Reset onto a pristine base branch before hooks run ───────────────────────
# For a fresh clone HEAD is already here; for a reused cache this discards the
# previous run's branch, commits, and tracked edits so dependency install and the
# worktree-clean hook operate on a clean base. --force drops local modifications
# that would otherwise block the switch. Ignored build dirs are left untouched.
git checkout --force -B "$BASE_BRANCH" "origin/$BASE_BRANCH"

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
    # Force-sync to the remote ref: a cached checkout may hold a stale local branch of
    # the same name from an earlier run, so -B resets it to exactly what origin has.
    git checkout --force -B "$EXISTING_BRANCH" "origin/$EXISTING_BRANCH"
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
    # -B (not -b) so a leftover local branch of this name in a reused cache can't
    # collide; HEAD is already on the pristine base, so this branches from there.
    git checkout -B "$AGENT_BRANCH"
else
    # --- Fresh start ---
    git checkout -B "$AGENT_BRANCH"
    log "Working branch: $AGENT_BRANCH"
fi

export AGENT_BRANCH

# Keep loop artifacts out of git for this clone (and untrack any a legacy branch
# committed). Must run before any checkpoint so `git add --all` never stages them.
exclude_artifacts_from_git

# ── Restore persisted context + gather PR review feedback ────────────────────
# The branch never carries artifacts, so pull the plan/progress back from the state
# volume (crash/timeout recovery, or a post-delivery review pass reusing the plan).
# Then, on a PR-review iteration, collect the reviewer's new comments so the execute
# stage addresses them incrementally rather than re-implementing the original plan.
restore_artifacts
gather_pr_feedback
gather_ci_failures
# Persist the just-gathered feedback (REQUESTED_CHANGES.md) so a crash before the
# first checkpoint doesn't lose it.
stash_artifacts

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

    # Save the plan stage's output (BLUEPRINT.md or QUESTIONS.md) to the volume now,
    # before the exit-2 path returns without ever reaching a checkpoint.
    stash_artifacts

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

    # Checkpoint: pushes any code work + mirrors the blueprint to the volume, so
    # recovery has the plan even if the execute stage crashes. On the first iteration
    # there's usually no code yet, so this is often just an artifact stash.
    checkpoint "wip(#${ISSUE_NUM}): blueprint — ${ISSUE_TITLE}"

    # Stage 02: Execute
    log "Stage 02: Running agent..."
    bash "$SCRIPT_DIR/loop-stages/02_execute/run_opencode_agent.sh"

    # Checkpoint partial work immediately — before any decision below — so an interrupted
    # (or timed-out) execution is preserved: code on the remote branch, progress in the volume.
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

    # Persist VERIFY_ERRORS.md so a crash before the next retry's checkpoint doesn't
    # lose it — the next run needs it to know what to fix.
    stash_artifacts

    if [[ "$ALL_PASSED" == "true" ]]; then
        log "All verify stages passed!"
        # Keep the blueprint in the volume for a later review pass and clear the
        # run-scoped artifacts, before delivery opens the PR.
        finalize_issue_state
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
