#!/bin/bash
# Verify: Run PHPUnit test suite in WordPress multisite mode.
set -euo pipefail

cd "$REPO_DIR"

echo "=== PHPUnit Tests ==="

if [[ ! -f "vendor/bin/phpunit" ]]; then
    echo "PHPUnit not found. Run 'composer install' first."
    exit 1
fi

# Use local phpunit.xml if present
if [[ -f "phpunit.xml" ]]; then
    CONFIG_FLAG="--configuration phpunit.xml"
elif [[ -f "phpunit.xml.dist" ]]; then
    CONFIG_FLAG="--configuration phpunit.xml.dist"
else
    CONFIG_FLAG=""
fi

echo "Running PHPUnit (multisite mode)..."
WP_MULTISITE=1 ./vendor/bin/phpunit $CONFIG_FLAG --testdox

echo "PHPUnit passed."
