#!/bin/bash
# Source this file to load a mock environment for running individual stages locally.
#
# Usage:
#   source tests/mock-env.sh
#   bash loop-stages/01_plan/generate_blueprint.sh
#
# Real credentials in a local .env file take precedence — source it after this file:
#   source tests/mock-env.sh && set -o allexport && source .env && set +o allexport
#
# Set DRY_RUN=true (the default here) so no actual GitHub writes happen.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── GitHub ────────────────────────────────────────────────────────────────────
export GH_TOKEN="${GH_TOKEN:-mock_gh_token_replace_before_real_run}"
export GITHUB_OWNER="${GITHUB_OWNER:-cairocoder01}"
export TARGET_REPO="${TARGET_REPO:-my-test-plugin}"
export TRIGGER_LABEL="${TRIGGER_LABEL:-dt-agent-build}"
export PROCESSING_LABEL="${PROCESSING_LABEL:-dt-agent-processing}"
export WAITING_LABEL="${WAITING_LABEL:-dt-agent-waiting-for-human}"
export READY_LABEL="${READY_LABEL:-ready-for-human-review}"

# ── Issue ─────────────────────────────────────────────────────────────────────
export ISSUE_NUM="${ISSUE_NUM:-42}"
export ISSUE_TITLE="${ISSUE_TITLE:-Add baptism date field to Contact post type}"
export ISSUE_URL="${ISSUE_URL:-https://github.com/cairocoder01/my-test-plugin/issues/42}"
export ISSUE_BODY="${ISSUE_BODY:-$(cat "$SCRIPT_DIR/fixtures/sample-issue.json" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['body'])" 2>/dev/null \
    || echo 'Add a date field named baptism_date to the Contact post type. Show it in the milestone tile.')}"

# ── Branch / loop state ───────────────────────────────────────────────────────
export BASE_BRANCH="${BASE_BRANCH:-develop}"
export AGENT_BRANCH="${AGENT_BRANCH:-agent/42-add-baptism-date-field-to-contact-post-type}"
export RECOVERY_MODE="${RECOVERY_MODE:-false}"
export PR_MODE="${PR_MODE:-false}"
export PR_NUM="${PR_NUM:-}"
export LOOP_ITERATIONS="${LOOP_ITERATIONS:-1}"
export MAX_LOOP_RETRIES="${MAX_LOOP_RETRIES:-5}"

# ── AI provider ───────────────────────────────────────────────────────────────
export GEMINI_API_TOKEN="${GEMINI_API_TOKEN:-mock_gemini_token}"
export OPENCODE_MODEL="${OPENCODE_MODEL:-google/gemini-2.0-flash}"
export AGENT_TIMEOUT="${AGENT_TIMEOUT:-1800}"

# ── WordPress ─────────────────────────────────────────────────────────────────
export WP_DB_HOST="${WP_DB_HOST:-localhost}"
export WP_DB_NAME="${WP_DB_NAME:-wordpress_test}"
export WP_DB_USER="${WP_DB_USER:-wp}"
export WP_DB_PASS="${WP_DB_PASS:-wp}"
export WP_VERSION="${WP_VERSION:-latest}"
export WP_TEST_URL="${WP_TEST_URL:-http://localhost:8080}"
export WP_E2E_PORT="${WP_E2E_PORT:-8080}"
export WP_OPTIONS_FILE="${WP_OPTIONS_FILE:-}"
export DT_BASE_THEME_REPO="${DT_BASE_THEME_REPO:-DiscipleTools/disciple-tools-theme}"

# ── REPO_DIR: use fixture repo unless overridden ──────────────────────────────
# Override REPO_DIR to point at a real checkout if you want to test against live code.
export REPO_DIR="${REPO_DIR:-$SCRIPT_DIR/fixtures/sample-repo}"

# ── Dry-run by default ────────────────────────────────────────────────────────
# DRY_RUN=true means stages run fully but no GitHub writes (push, PR, labels) happen.
export DRY_RUN="${DRY_RUN:-true}"

echo "[mock-env] Environment loaded."
echo "  REPO_DIR=$REPO_DIR"
echo "  TARGET_REPO=$TARGET_REPO  ISSUE_NUM=$ISSUE_NUM"
echo "  DRY_RUN=$DRY_RUN"
