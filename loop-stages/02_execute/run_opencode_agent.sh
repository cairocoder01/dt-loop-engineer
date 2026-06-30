#!/bin/bash
# Stage 02: Agent Execution
#
# Launches opencode with Gemini and Playwright MCP bindings.
# The agent reads BLUEPRINT.md and modifies files in the repo worktree.
# Any prior verify errors from VERIFY_ERRORS.md are appended to the prompt.
set -euo pipefail

cd "$REPO_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BLUEPRINT="$REPO_DIR/BLUEPRINT.md"
VERIFY_ERRORS="$REPO_DIR/VERIFY_ERRORS.md"
PROGRESS="$REPO_DIR/PROGRESS.md"
MODEL="${OPENCODE_MODEL:-gemini}"
MCP_PORT="${MCP_PORT:-9222}"

if [[ ! -f "$BLUEPRINT" ]]; then
    echo "BLUEPRINT.md not found — stage 01 must run first"
    exit 1
fi

# Initialize PROGRESS.md
echo "Starting agent execution at $(date -u)" > "$PROGRESS"

# Build the agent prompt from BLUEPRINT.md + any prior errors
PROMPT=$(cat "$BLUEPRINT")

if [[ -f "$VERIFY_ERRORS" ]] && [[ -s "$VERIFY_ERRORS" ]]; then
    PROMPT="$PROMPT

---

## Previous Attempt Errors

The previous implementation attempt failed verification. Fix these issues before marking complete:

\`\`\`
$(cat "$VERIFY_ERRORS")
\`\`\`

Update PROGRESS.md with 'COMPLETE' when all errors are resolved and you are confident the code is correct."
fi

PROMPT="$PROMPT

---

## Agent Instructions

- Work entirely within the current directory.
- Do not modify files outside this repository.
- Maintain PROGRESS.md: write 'BLOCKED: <reason>' if you need human input, or 'COMPLETE' when done.
- Follow the acceptance criteria in BLUEPRINT.md exactly.
- Commit nothing — the runner handles git operations."

# Start Playwright MCP server in background (if not already running)
if ! curl -sf "http://localhost:${MCP_PORT}" &>/dev/null; then
    echo "Starting Playwright MCP server on port $MCP_PORT..."
    npx @playwright/mcp --port "$MCP_PORT" &
    MCP_PID=$!
    sleep 2
    echo "MCP server PID: $MCP_PID"
fi

# Write prompt to a temp file to avoid shell escaping issues
PROMPT_FILE=$(mktemp /tmp/loop-prompt.XXXXXX.md)
echo "$PROMPT" > "$PROMPT_FILE"

echo "Invoking opencode agent ($MODEL)..."

# TODO: confirm exact opencode CLI flags once CLI API is finalized
opencode \
    --agent "$MODEL" \
    --token "$GEMINI_API_TOKEN" \
    --workdir "$REPO_DIR" \
    --mcp-server "http://localhost:${MCP_PORT}" \
    --prompt-file "$PROMPT_FILE" \
    || true  # Don't fail here — check PROGRESS.md instead

rm -f "$PROMPT_FILE"

echo "Agent execution complete. PROGRESS.md state:"
cat "$PROGRESS" || echo "(PROGRESS.md not found)"
