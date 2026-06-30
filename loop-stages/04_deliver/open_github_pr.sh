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
BASE_BRANCH="${BASE_BRANCH:-develop}"
PR_MODE="${PR_MODE:-false}"
PR_NUM="${PR_NUM:-}"
LOOP_ITERATIONS="${LOOP_ITERATIONS:-1}"
OPENCODE_MODEL="${OPENCODE_MODEL:-unknown}"

echo "=== Delivering (PR mode: $PR_MODE, iterations: $LOOP_ITERATIONS) ==="

# ── Git author ────────────────────────────────────────────────────────────────
# Consistent identity for all agent commits — identifiable in git log and blame.
git config user.email "loop-engineer[bot]@disciple.tools"
git config user.name  "DT Loop Engineer"

# ── Stage changes (exclude loop artifact files) ───────────────────────────────
git add --all
git reset HEAD -- BLUEPRINT.md QUESTIONS.md PROGRESS.md VERIFY_ERRORS.md 2>/dev/null || true

STAGED=$(git diff --cached --name-only)
if [[ -z "$STAGED" ]]; then
    echo "No changes to commit."
    # In PR mode the agent may have confirmed no changes were needed — not an error.
    # In issue mode a no-op commit means something went wrong upstream.
    [[ "$PR_MODE" == "false" ]] && exit 1
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

if [[ "$PR_MODE" == "true" ]]; then
    # ── PR mode: update the existing PR ──────────────────────────────────────
    git push --force-with-lease origin "$AGENT_BRANCH"

    gh pr comment "$PR_NUM" \
        --repo "$GITHUB_OWNER/$TARGET_REPO" \
        --body "**Agent completed work** after ${LOOP_ITERATIONS} iteration(s). All verification checks passed — ready for review.

${VERIFY_CHECKLIST}"

    gh pr edit "$PR_NUM" \
        --repo "$GITHUB_OWNER/$TARGET_REPO" \
        --remove-label "$PROCESSING_LABEL" \
        --add-label "$READY_LABEL" \
        2>/dev/null || true
    gh pr edit "$PR_NUM" \
        --repo "$GITHUB_OWNER/$TARGET_REPO" \
        --remove-label "$TRIGGER_LABEL" \
        2>/dev/null || true

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

    gh issue edit "$ISSUE_NUM" \
        --repo "$GITHUB_OWNER/$TARGET_REPO" \
        --remove-label "$PROCESSING_LABEL" \
        --add-label "$READY_LABEL" \
        2>/dev/null || true
    gh issue edit "$ISSUE_NUM" \
        --repo "$GITHUB_OWNER/$TARGET_REPO" \
        --remove-label "$TRIGGER_LABEL" \
        2>/dev/null || true

    gh issue comment "$ISSUE_NUM" \
        --repo "$GITHUB_OWNER/$TARGET_REPO" \
        --body "**Agent completed work** after ${LOOP_ITERATIONS} iteration(s). PR ready for review: $PR_URL"

    echo "Issue #${ISSUE_NUM} updated. Done."
fi
