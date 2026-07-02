#!/bin/bash
# Update Composer and npm dependencies in the cloned repo before the loop starts.
set -euo pipefail

cd "$REPO_DIR"

if [[ -f "composer.json" ]]; then
    echo "Installing Composer dependencies..."
    composer install --no-interaction --prefer-dist --optimize-autoloader

    # Ensure phpunit is available for the agent's self-verification and for stage 03.
    # Many DT plugin starters ship without phpunit in require-dev; add it if missing
    # so the agent can run tests during execution. This change lands in the PR, which
    # is correct — DT plugins should declare their test dependencies.
    if [[ ! -f "vendor/bin/phpunit" ]]; then
        echo "phpunit not in vendor/ — adding phpunit/phpunit:^10 to require-dev..."
        composer require --dev "phpunit/phpunit:^10" --no-interaction --quiet
    fi
fi

if [[ -f "package.json" ]]; then
    echo "Installing npm dependencies..."
    npm ci --prefer-offline
fi

echo "Dependencies ready."
