#!/bin/bash
# Update Composer and npm dependencies in the cloned repo before the loop starts.
set -euo pipefail

cd "$REPO_DIR"

if [[ -f "composer.json" ]]; then
    echo "Installing Composer dependencies..."
    composer install --no-interaction --prefer-dist --optimize-autoloader

    # NOTE: We deliberately do NOT add phpunit when it's missing. Most DT plugins
    # (scaffolded from the plugin starter template) don't ship phpunit and verify
    # via PHPCS + syntax/installation checks instead; only the theme declares it.
    # Injecting phpunit here mutates the repo's composer.json and pulls in the DT
    # theme test bootstrap, whose migrations fail offline (location-grid download).
    # Stage 03 (02_phpunit.sh) skips cleanly when a repo doesn't declare phpunit.
fi

if [[ -f "package.json" ]]; then
    echo "Installing npm dependencies..."
    npm ci --prefer-offline
fi

echo "Dependencies ready."
