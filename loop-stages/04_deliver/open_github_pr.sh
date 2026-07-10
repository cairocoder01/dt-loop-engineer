#!/bin/bash
# Stage 04: Deliver
#
# PR mode  (PR_MODE=true):  push changes to the existing PR branch, comment on the PR,
#                           update labels on the PR.
# Issue mode (PR_MODE=false): commit, push a new branch, open a PR, update issue labels.
#
# Branch collision handling: before every push this script fetches the remote branch
# (no-op if it doesn't exist) so --force-with-lease knows the expected ref. This lets
# us safely overwrite our own previous push on retry without clobbering human commits
# made by mistake to the agent branch.
set -euo pipefail

cd "$REPO_DIR"

BLUEPRINT="$REPO_DIR/BLUEPRINT.md"
BASE_BRANCH="${BASE_BRANCH:-main}"   # core-runner.sh auto-detects and exports this
PR_MODE="${PR_MODE:-false}"
PR_NUM="${PR_NUM:-}"
# Exported by core-runner.sh; fallback here so this script works run standalone.
BOT_SIGNATURE="${BOT_SIGNATURE:-🤖 _From **@loop_engineer_bot** — automated comment._}"
LOOP_ITERATIONS="${LOOP_ITERATIONS:-1}"
OPENCODE_MODEL="${OPENCODE_MODEL:-unknown}"

echo "=== Delivering (PR mode: $PR_MODE, iterations: $LOOP_ITERATIONS) ==="

# ── Label helpers (REST) ──────────────────────────────────────────────────────
# Use the REST issues/labels endpoints, NOT `gh pr edit`/`gh issue edit --add-label`:
# the bundled gh (2.39.x) references the sunset Projects-classic `projectCards` field
# in those commands' GraphQL query, so they fail and — when their errors were hidden —
# silently left labels unchanged (delivered PRs never got READY_LABEL). PRs and issues
# share the /issues/:n/labels endpoints. Never abort delivery over a label hiccup.
add_label_rest() {  # <number> <label>
    gh api -X POST "repos/$GITHUB_OWNER/$TARGET_REPO/issues/$1/labels" -f "labels[]=$2" >/dev/null 2>&1 \
        || echo "  WARNING: failed to add label '$2' to #$1"
}
remove_label_rest() {  # <number> <label>  (404 when not applied — expected)
    gh api -X DELETE "repos/$GITHUB_OWNER/$TARGET_REPO/issues/$1/labels/$2" >/dev/null 2>&1 || true
}

# ── Git author ────────────────────────────────────────────────────────────────
# Consistent identity for all agent commits — identifiable in git log and blame.
git config user.email "loop-engineer[bot]@disciple.tools"
git config user.name  "DT Loop Engineer"

# ── Strip loop artifacts from the branch tip ─────────────────────────────────
# During the loop these files were checkpoint-committed to the branch so an
# interrupted run could resume. They must not appear in the PR, so remove them now
# and let the final commit record the deletion. Because they were added and then
# removed on the same branch, the net base...head diff GitHub renders omits them.
rm -f BLUEPRINT.md QUESTIONS.md PROGRESS.md VERIFY_ERRORS.md REQUESTED_CHANGES.md
git add --all

STAGED=$(git diff --cached --name-only)

# ── Confirm the branch actually contains work relative to the base branch ──────
# Real code lives in the checkpoint commits made during the loop, not just in the
# staging area — so assess "did we build anything" against the base branch, not the
# index. (Artifacts still show here because their removal isn't committed yet; once
# the commit below lands, the rendered PR diff excludes them.)
git fetch origin "$BASE_BRANCH" 2>/dev/null || true
REAL_CHANGES=$(git diff --name-only "origin/${BASE_BRANCH}...HEAD" 2>/dev/null || echo "")
if [[ -z "$REAL_CHANGES" && -z "$STAGED" ]]; then
    echo "No changes relative to '${BASE_BRANCH}'."
    # In PR mode the agent may have confirmed no changes were needed — not an error.
    # In issue mode a no-op run means something went wrong upstream.
    [[ "$PR_MODE" == "false" ]] && exit 1
fi

# ── Secret scan ───────────────────────────────────────────────────────────────
# Guard against prompt injection attacks that instruct the agent to embed the
# container's actual secret values into committed files. Checks exact token values
# (not patterns) — short/mock values (< 10 chars) are skipped to avoid noise.
if [[ -n "$STAGED" ]]; then
    STAGED_DIFF=$(git diff --cached 2>/dev/null || true)
    for secret_var in GH_TOKEN GEMINI_API_TOKEN; do
        secret_val="${!secret_var:-}"
        [[ ${#secret_val} -lt 10 ]] && continue
        if echo "$STAGED_DIFF" | grep -qF "$secret_val"; then
            echo "ERROR: Secret scan: value of \$${secret_var} found in staged diff."
            echo "This may be a prompt injection attack. Aborting. Review: git diff --cached"
            git reset HEAD -- . 2>/dev/null || true
            exit 1
        fi
    done
fi

if [[ -n "$STAGED" ]]; then
    echo "Committing:"
    echo "$STAGED"
    git commit -m "fix(#${ISSUE_NUM}): ${ISSUE_TITLE}

Automated implementation by DT Loop Engineer.
Loop iterations: ${LOOP_ITERATIONS}
Closes #${ISSUE_NUM}

Co-authored-by: loop-engineer[bot] <loop-engineer[bot]@disciple.tools>"
fi

# ── Fetch remote branch before push (collision safety) ───────────────────────
# Updates the local tracking ref so --force-with-lease can compare against the
# remote state. Suppressed output; no-op when the branch doesn't exist yet.
git fetch origin "$AGENT_BRANCH" 2>/dev/null || true

# ── Build PR body ─────────────────────────────────────────────────────────────
BLUEPRINT_CONTENT=""
if [[ -f "$BLUEPRINT" ]]; then
    BLUEPRINT_CONTENT=$(cat "$BLUEPRINT")
fi

# Verify checklist — names must stay in sync with loop-stages/03_verify/ filenames.
VERIFY_CHECKLIST="- [x] PHP syntax & coding standards (PHPCS)
- [x] PHPUnit test suite (WordPress multisite)
- [x] Browser E2E baseline (Playwright)"

# Append per-repo verify scripts if any ran
REPO_VERIFY_DIR="$REPO_DIR/.loop-engineer/verify"
if [[ -d "$REPO_VERIFY_DIR" ]]; then
    for f in "$REPO_VERIFY_DIR"/*.sh "$REPO_VERIFY_DIR"/*.js; do
        [[ -f "$f" ]] || continue
        VERIFY_CHECKLIST="$VERIFY_CHECKLIST
- [x] $(basename "$f") (repo-specific)"
    done
fi

PR_BODY="$(cat <<PREOF
${BOT_SIGNATURE}

## Summary

Closes #${ISSUE_NUM}

This PR was generated automatically by the **DT Loop Engineer** autonomous agent.

| Field | Value |
|-------|-------|
| Issue | #${ISSUE_NUM} |
| Model | \`${OPENCODE_MODEL}\` |
| Loop iterations | ${LOOP_ITERATIONS} |
| Agent branch | \`${AGENT_BRANCH}\` |

---

## Verification

All automated checks passed on the final iteration:

${VERIFY_CHECKLIST}

---

## Blueprint

<details>
<summary>View implementation plan (generated before execution)</summary>

${BLUEPRINT_CONTENT}

</details>

---

> This PR was opened automatically by the agent and is ready for human review.
PREOF
)"

# ── Dry-run: skip all GitHub write operations ────────────────────────────────
if [[ "${DRY_RUN:-false}" == "true" ]]; then
    echo "[DRY-RUN] Skipping: git push, PR creation/update, and label mutations."
    echo "[DRY-RUN] Staged files that would have been committed:"
    git diff --cached --name-only || echo "  (none staged)"
    if [[ "$PR_MODE" == "false" ]]; then
        echo "[DRY-RUN] Would open PR: [Agent] $ISSUE_TITLE → $BASE_BRANCH"
        echo "[DRY-RUN] PR body preview (first 15 lines):"
        echo "$PR_BODY" | head -15
    else
        echo "[DRY-RUN] Would update existing PR #$PR_NUM"
    fi
    echo "[DRY-RUN] Done — no remote changes made."
    exit 0
fi

if [[ "$PR_MODE" == "true" ]]; then
    # ── PR mode: update the existing PR ──────────────────────────────────────
    git push --force-with-lease origin "$AGENT_BRANCH"

    gh pr comment "$PR_NUM" \
        --repo "$GITHUB_OWNER/$TARGET_REPO" \
        --body "${BOT_SIGNATURE}

**Agent completed work** after ${LOOP_ITERATIONS} iteration(s). All verification checks passed — ready for review.

${VERIFY_CHECKLIST}"

    add_label_rest    "$PR_NUM" "$READY_LABEL"
    remove_label_rest "$PR_NUM" "$PROCESSING_LABEL"
    remove_label_rest "$PR_NUM" "$TRIGGER_LABEL"

    echo "PR #$PR_NUM updated. Done."

else
    # ── Issue mode: push branch and open a PR ────────────────────────────────
    git push --force-with-lease origin "$AGENT_BRANCH"

    PR_URL=$(gh pr create \
        --repo "$GITHUB_OWNER/$TARGET_REPO" \
        --base "$BASE_BRANCH" \
        --head "$AGENT_BRANCH" \
        --title "[Agent] $ISSUE_TITLE" \
        --body "$PR_BODY")

    echo "PR opened: $PR_URL"

    add_label_rest    "$ISSUE_NUM" "$READY_LABEL"
    remove_label_rest "$ISSUE_NUM" "$PROCESSING_LABEL"
    remove_label_rest "$ISSUE_NUM" "$TRIGGER_LABEL"

    gh issue comment "$ISSUE_NUM" \
        --repo "$GITHUB_OWNER/$TARGET_REPO" \
        --body "${BOT_SIGNATURE}

**Agent completed work** after ${LOOP_ITERATIONS} iteration(s). PR ready for review: $PR_URL"

    echo "Issue #${ISSUE_NUM} updated. Done."
fi
