#!/bin/bash
# Verify: PHP syntax check and PHPCS on files changed by the agent.
#
# Scope: changed files only — not the whole repo. The agent is responsible
# only for what it touched. Pre-existing PHPCS violations in untouched files
# are not the agent's fault and would cause false failures if we linted
# the entire codebase on every iteration.
set -euo pipefail

cd "$REPO_DIR"

echo "=== PHP Lint & Code Standards ==="

# Collect PHP files the agent modified. Since the agent never commits, all
# changes appear as either:
#   - modifications to tracked files  → git diff HEAD
#   - new untracked files             → git ls-files --others
mapfile -t CHANGED_PHP < <(
    {
        git diff --name-only HEAD -- '*.php'
        git ls-files --others --exclude-standard | grep '\.php$' || true
    } | sort -u
)

if [[ ${#CHANGED_PHP[@]} -eq 0 ]]; then
    echo "No PHP files changed — skipping lint."
    exit 0
fi

echo "Checking ${#CHANGED_PHP[@]} PHP file(s):"
printf '  %s\n' "${CHANGED_PHP[@]}"
echo ""

# ── PHP syntax check ──────────────────────────────────────────────────────────
echo "Running php -l on changed files..."
SYNTAX_FAIL=0
for file in "${CHANGED_PHP[@]}"; do
    [[ -f "$file" ]] || continue
    php -l "$file" || SYNTAX_FAIL=1
done

if [[ $SYNTAX_FAIL -ne 0 ]]; then
    echo "PHP syntax errors found."
    exit 1
fi

echo "PHP syntax OK."
echo ""

# ── PHPCS ─────────────────────────────────────────────────────────────────────
# Each file is passed as a separate argument — never pass a newline-delimited
# string as a single variable (it would be treated as one filename).
if [[ ! -f "vendor/bin/phpcs" ]]; then
    echo "WARNING: vendor/bin/phpcs not found — skipping PHPCS."
    echo "Run 'composer install' to install PHP_CodeSniffer."
    exit 0
fi

if [[ -f ".phpcs.xml" ]] || [[ -f "phpcs.xml" ]]; then
    echo "Running PHPCS with local config..."
    ./vendor/bin/phpcs "${CHANGED_PHP[@]}"
else
    echo "Running PHPCS with WordPress standard..."
    ./vendor/bin/phpcs --standard=WordPress "${CHANGED_PHP[@]}"
fi

echo "PHP lint passed."
