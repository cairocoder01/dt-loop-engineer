#!/bin/bash
# Run a single loop stage with a mock environment for local development and debugging.
#
# Usage:
#   ./tests/run_stage.sh <stage-key>
#
# Stage keys:
#   01        → loop-stages/01_plan/generate_blueprint.sh
#   02        → loop-stages/02_execute/run_opencode_agent.sh
#   03/01     → loop-stages/03_verify/01_php_lint.sh
#   03/02     → loop-stages/03_verify/02_phpunit.sh
#   03/02b    → loop-stages/03_verify/02b_prep_e2e_site.sh
#   03/03     → loop-stages/03_verify/03_chrome_mcp_e2e.js
#   04        → loop-stages/04_deliver/open_github_pr.sh
#   bootstrap/<n>  → hooks/bootstrap/<n>_*.sh
#   pre-issue/<n>  → hooks/pre-issue/<n>_*.sh
#
# Override any mock env var on the command line:
#   DRY_RUN=false ISSUE_NUM=99 ./tests/run_stage.sh 01
#
# To use real credentials from a .env file:
#   source .env && ./tests/run_stage.sh 01

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STAGE_KEY="${1:-}"

if [[ -z "$STAGE_KEY" ]]; then
    echo "Usage: $0 <stage-key>"
    echo "  Stage keys: 01  02  03/01  03/02  03/02b  03/03  04"
    echo "              bootstrap/<n>  pre-issue/<n>"
    exit 1
fi

# ── Load mock environment (won't overwrite vars already set in shell) ─────────
# shellcheck source=tests/mock-env.sh
source "$SCRIPT_DIR/mock-env.sh"

# ── Resolve stage key to script path ─────────────────────────────────────────
resolve_stage() {
    local key="$1"
    case "$key" in
        01) echo "$ROOT_DIR/loop-stages/01_plan/generate_blueprint.sh" ;;
        02) echo "$ROOT_DIR/loop-stages/02_execute/run_opencode_agent.sh" ;;
        03/01|3/01) echo "$ROOT_DIR/loop-stages/03_verify/01_php_lint.sh" ;;
        03/02|3/02) echo "$ROOT_DIR/loop-stages/03_verify/02_phpunit.sh" ;;
        03/02b|3/02b) echo "$ROOT_DIR/loop-stages/03_verify/02b_prep_e2e_site.sh" ;;
        03/03|3/03) echo "$ROOT_DIR/loop-stages/03_verify/03_chrome_mcp_e2e.js" ;;
        04) echo "$ROOT_DIR/loop-stages/04_deliver/open_github_pr.sh" ;;
        bootstrap/*|pre-issue/*)
            local hook_dir hook_num glob_pattern
            hook_dir="${key%%/*}"
            hook_num="${key##*/}"
            glob_pattern="$ROOT_DIR/hooks/$hook_dir/${hook_num}_*.sh"
            # shellcheck disable=SC2086
            local found
            found=$(ls $glob_pattern 2>/dev/null | head -1)
            echo "$found"
            ;;
        *)
            # Maybe it's a direct path
            if [[ -f "$ROOT_DIR/$key" ]]; then
                echo "$ROOT_DIR/$key"
            elif [[ -f "$key" ]]; then
                echo "$key"
            else
                echo ""
            fi
            ;;
    esac
}

SCRIPT_PATH=$(resolve_stage "$STAGE_KEY")

if [[ -z "$SCRIPT_PATH" || ! -f "$SCRIPT_PATH" ]]; then
    echo "ERROR: Could not find script for stage key: $STAGE_KEY"
    echo "Resolved path: ${SCRIPT_PATH:-<empty>}"
    exit 1
fi

echo ""
echo "=== Running stage: $STAGE_KEY ==="
echo "    Script: $SCRIPT_PATH"
echo "    REPO_DIR: $REPO_DIR"
echo "    DRY_RUN: $DRY_RUN"
echo ""

if [[ "$SCRIPT_PATH" == *.sh ]]; then
    bash "$SCRIPT_PATH"
elif [[ "$SCRIPT_PATH" == *.js ]]; then
    node "$SCRIPT_PATH"
else
    echo "ERROR: Unknown script type: $SCRIPT_PATH"
    exit 1
fi
