#!/bin/bash
# Stage 01: Blueprint Generation
#
# Runs opencode to produce exactly one of:
#   BLUEPRINT.md  — structured plan the execute stage will follow  → exit 0
#   QUESTIONS.md  — questions requiring a human decision first     → exit 2
#
# core-runner.sh reads the exit code and either continues the loop (0),
# posts the questions as a GitHub comment then applies WAITING_LABEL (2),
# or treats any other non-zero as a hard failure.
set -euo pipefail

cd "$REPO_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODEL="${OPENCODE_MODEL:-gemini}"
BLUEPRINT="$REPO_DIR/BLUEPRINT.md"
QUESTIONS="$REPO_DIR/QUESTIONS.md"

echo "=== Stage 01: Blueprint generation (model: $MODEL) ==="

# Clear stale planning artifacts from any previous iteration
rm -f "$BLUEPRINT" "$QUESTIONS"

# ── Repo context (12,000-char budget, priority order) ────────────────────────
# CLAUDE.md is highest value; config files fill the remainder.
CONTEXT_BUDGET=12000
CONTEXT_USED=0
REPO_CONTEXT=""

for ctx_file in CLAUDE.md README.md .phpcs.xml phpunit.xml; do
    local_path="$REPO_DIR/$ctx_file"
    [[ -f "$local_path" ]] || continue
    remaining=$((CONTEXT_BUDGET - CONTEXT_USED))
    if [[ $remaining -le 0 ]]; then
        echo "  Context budget exhausted — skipping $ctx_file"
        continue
    fi
    content=$(head -c "$remaining" "$local_path")
    actual_len=${#content}
    file_len=$(wc -c < "$local_path")
    if [[ $actual_len -lt $file_len ]]; then
        echo "  $ctx_file: $actual_len / $file_len bytes (truncated to fit budget)"
    else
        echo "  $ctx_file: $actual_len bytes"
    fi
    REPO_CONTEXT="${REPO_CONTEXT}
### ${ctx_file}
${content}
"
    CONTEXT_USED=$((CONTEXT_USED + actual_len))
done
[[ -z "$REPO_CONTEXT" ]] && REPO_CONTEXT="(No context files found in repo root)"
echo "  Total context: ${CONTEXT_USED} / ${CONTEXT_BUDGET} chars"

# ── Coding standards (local override beats system fallback) ──────────────────
LOCAL_STANDARDS="$REPO_DIR/.loop-engineer/STANDARDS.md"
SYSTEM_STANDARDS="$SCRIPT_DIR/skills/WP_STANDARDS.md"
if [[ -f "$LOCAL_STANDARDS" ]]; then
    STANDARDS=$(cat "$LOCAL_STANDARDS")
    echo "  Standards: local override (.loop-engineer/STANDARDS.md)"
else
    STANDARDS=$(cat "$SYSTEM_STANDARDS" 2>/dev/null \
        || echo "(No standards file found — apply WordPress coding standards defaults)")
    echo "  Standards: system fallback (skills/WP_STANDARDS.md)"
fi

# ── Issue/PR comments (last 5 from each, oldest→newest) ─────────────────────
# Answers from the human to prior QUESTIONS.md often live in comments, not the
# issue body, so we always include recent comment history regardless of recovery
# mode. In PR mode we also pull from the PR thread.
COMMENT_CONTEXT=""

issue_comments=$(gh issue view "$ISSUE_NUM" \
    --repo "$GITHUB_OWNER/$TARGET_REPO" \
    --json comments \
    --jq '.comments[-5:] | map("**" + .author.login + "**: " + .body) | join("\n\n---\n\n")' \
    2>/dev/null || echo "")
if [[ -n "$issue_comments" ]]; then
    COMMENT_CONTEXT="${COMMENT_CONTEXT}
### Issue #${ISSUE_NUM} — Recent Comments (oldest first)
${issue_comments}
"
    echo "  Fetched issue #${ISSUE_NUM} comments"
else
    echo "  No issue comments found"
fi

if [[ "${PR_MODE:-false}" == "true" && -n "${PR_NUM:-}" ]]; then
    pr_comments=$(gh pr view "$PR_NUM" \
        --repo "$GITHUB_OWNER/$TARGET_REPO" \
        --json comments \
        --jq '.comments[-5:] | map("**" + .author.login + "**: " + .body) | join("\n\n---\n\n")' \
        2>/dev/null || echo "")
    if [[ -n "$pr_comments" ]]; then
        COMMENT_CONTEXT="${COMMENT_CONTEXT}
### PR #${PR_NUM} — Recent Comments (oldest first)
${pr_comments}
"
        echo "  Fetched PR #${PR_NUM} comments"
    fi
fi

# ── Planning prompt ───────────────────────────────────────────────────────────
PROMPT_FILE=$(mktemp /tmp/loop-plan-prompt.XXXXXX.md)
trap 'rm -f "$PROMPT_FILE"' EXIT

# Use a variable for triple-backtick to avoid heredoc command-substitution
TICK='```'

cat > "$PROMPT_FILE" <<PROMPT
You are a senior WordPress engineer planning a code change for the Disciple.Tools ecosystem.
Your ONLY task right now is to PLAN — do not write any implementation code.

## Coding Standards

${STANDARDS}

## Repository Context

${REPO_CONTEXT}

## Recent Discussion (issue/PR comments)

${COMMENT_CONTEXT:-_(No comments found)_}

---

## Issue to Plan

Repository: ${TARGET_REPO}
Issue #${ISSUE_NUM}: ${ISSUE_TITLE}

${ISSUE_BODY}

---

## Decision: Blueprint or Questions?

Read the issue above. Then decide:

**Choose BLUEPRINT.md** if you can produce a complete, unambiguous, step-by-step plan right now.
You must be able to name the specific files, functions, hooks, and patterns to use.

**Choose QUESTIONS.md** if ANY of the following are true:
- The issue does not specify which post type, field type, or data structure to use.
- Two or more valid implementations exist with meaningfully different trade-offs.
- The scope is underspecified (e.g., "add to contacts" without saying list view, detail view, or both).
- A migration or schema change must be designed before code can be written.
- Any answer in the comments above explicitly changes or contradicts the original issue scope.

Do not write both files. Do not write any source code.

---

## Option A — Write BLUEPRINT.md

Use this exact structure. The section headers must match character-for-character.

${TICK}markdown
### Task Summary
One paragraph: what changes, which component, and why.

### Files to Modify
- path/to/file.php — reason
- path/to/another.js — reason

### Implementation Plan
1. First concrete step. Name the function or hook. Example: "Add a filter on \`dt_custom_fields_settings\` in \`dt-contacts/contacts-post-type.php\` to register the new \`baptism_date\` field as type \`date\`."
2. Second step — equally specific.
3. Continue until done.

### Acceptance Criteria
- [ ] PHP lint passes with no errors
- [ ] PHPCS reports no violations on modified files
- [ ] PHPUnit multisite suite passes
- [ ] <feature-specific testable outcome>
- [ ] <feature-specific testable outcome>

### Edge Cases & Constraints
- Do not modify functions.php entry point.
- Do not drop or alter existing database tables.
- <other constraint specific to this issue>
${TICK}

**Example of a well-formed BLUEPRINT.md** (for reference — do not copy this content):

${TICK}markdown
### Task Summary
Add a \`baptism_date\` date field to the Contact post type so discipleship milestones can be
tracked. The field should appear in the milestone tile and be filterable in the list view.

### Files to Modify
- dt-contacts/contacts-post-type.php — register field via \`dt_custom_fields_settings\`
- dt-contacts/contacts.php — add field to the milestone tile template
- dt-contacts/contacts-endpoints.php — include field in REST update handler

### Implementation Plan
1. In \`contacts-post-type.php\`, locate the \`dt_custom_fields_settings\` filter callback.
   Add a new entry: \`'baptism_date' => ['type' => 'date', 'name' => 'Baptism Date', 'tile' => 'milestone']\`.
2. In \`contacts.php\`, find the milestone tile render function and add a date-picker input
   bound to \`baptism_date\`, following the same pattern as \`baptism\` (boolean field nearby).
3. In \`contacts-endpoints.php\`, confirm \`DT_Posts::update_post()\` handles \`date\` field type
   natively (it does via \`DT_Posts\`) — no custom endpoint logic needed. Add a note in the
   REST schema docblock.

### Acceptance Criteria
- [ ] PHP lint passes on all three modified files
- [ ] PHPCS reports zero violations
- [ ] PHPUnit suite passes (no regressions)
- [ ] Field appears in Contact detail view milestone tile
- [ ] Field is filterable via \`DT_Posts::list_posts()\` date range query

### Edge Cases & Constraints
- Do not modify \`functions.php\`.
- Existing contacts without a value must display the field as empty, not error.
- The field label must be wrapped in \`__( 'Baptism Date', 'disciple_tools' )\`.
${TICK}

---

## Option B — Write QUESTIONS.md

Use this exact structure:

${TICK}markdown
## Questions Before Planning

The following must be answered before implementation can begin:

1. <specific, answerable question>
2. <specific, answerable question>
${TICK}

Keep questions concrete. "Should this be a key_select or multi_select field?" is good.
"Can you clarify the requirements?" is not.

---

Write the appropriate file now. Do not write any other files.
PROMPT

# ── Run opencode ──────────────────────────────────────────────────────────────
echo "Invoking opencode planner ($MODEL)..."

# TODO: confirm exact opencode CLI flags once CLI API is finalized
opencode \
    --agent "$MODEL" \
    --token "$GEMINI_API_TOKEN" \
    --workdir "$REPO_DIR" \
    --prompt-file "$PROMPT_FILE" \
    || true  # Don't fail here — check which output file was written instead

# ── Validate BLUEPRINT.md sections ───────────────────────────────────────────
# Required headers must be present exactly so downstream tools can parse them.
if [[ -f "$BLUEPRINT" && -s "$BLUEPRINT" ]]; then
    REQUIRED_SECTIONS=(
        "### Task Summary"
        "### Files to Modify"
        "### Implementation Plan"
        "### Acceptance Criteria"
        "### Edge Cases & Constraints"
    )
    MISSING=()
    for section in "${REQUIRED_SECTIONS[@]}"; do
        grep -qF "$section" "$BLUEPRINT" || MISSING+=("$section")
    done

    if [[ ${#MISSING[@]} -gt 0 ]]; then
        echo "ERROR: BLUEPRINT.md is missing required sections:"
        printf '  - %s\n' "${MISSING[@]}"
        echo ""
        echo "--- Generated content ---"
        cat "$BLUEPRINT"
        exit 1
    fi

    echo "BLUEPRINT.md validated ($(wc -l < "$BLUEPRINT") lines, all sections present)."
    exit 0
fi

# ── Check for questions ───────────────────────────────────────────────────────
if [[ -f "$QUESTIONS" && -s "$QUESTIONS" ]]; then
    echo "QUESTIONS.md written ($(wc -l < "$QUESTIONS") lines) — human clarification required."
    exit 2
fi

echo "ERROR: opencode produced neither BLUEPRINT.md nor QUESTIONS.md."
exit 1
