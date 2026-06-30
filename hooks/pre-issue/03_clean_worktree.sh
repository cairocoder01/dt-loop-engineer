#!/bin/bash
# Ensure the repo worktree is clean before the agent starts writing files.
set -euo pipefail

cd "$REPO_DIR"

echo "Cleaning worktree..."
git checkout -- .
git clean -fd

# Remove any leftover loop artifacts from a prior run
rm -f BLUEPRINT.md QUESTIONS.md PROGRESS.md VERIFY_ERRORS.md

echo "Worktree clean."
