#!/bin/bash
# Verify: PHP syntax check and PHPCS on files changed by the agent.
set -euo pipefail

cd "$REPO_DIR"

echo "=== PHP Lint & Code Standards ==="

# Determine which files changed (agent may have unstaged changes)
CHANGED_PHP=$(git diff --name-only HEAD -- '*.php' | head -50)

if [[ -z "$CHANGED_PHP" ]]; then
    # Fall back to all tracked PHP files if nothing staged yet
    CHANGED_PHP=$(git ls-files '*.php' | head -50)
fi

if [[ -z "$CHANGED_PHP" ]]; then
    echo "No PHP files to check."
    exit 0
fi

# PHP syntax check
echo "Running php -l on changed files..."
SYNTAX_FAIL=0
while IFS= read -r file; do
    if [[ -f "$file" ]]; then
        php -l "$file" || SYNTAX_FAIL=1
    fi
done <<< "$CHANGED_PHP"

if [[ $SYNTAX_FAIL -ne 0 ]]; then
    echo "PHP syntax errors found."
    exit 1
fi

# PHPCS — use local config if available, else use WordPress standard
if [[ -f ".phpcs.xml" ]] || [[ -f "phpcs.xml" ]]; then
    echo "Running PHPCS with local config..."
    ./vendor/bin/phpcs $CHANGED_PHP
else
    echo "Running PHPCS with WordPress standard..."
    ./vendor/bin/phpcs --standard=WordPress $CHANGED_PHP
fi

echo "PHP lint passed."
