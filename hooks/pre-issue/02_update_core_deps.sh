#!/bin/bash
# Update Composer and npm dependencies in the cloned repo before the loop starts.
set -euo pipefail

cd "$REPO_DIR"

if [[ -f "composer.json" ]]; then
    echo "Installing Composer dependencies..."
    composer install --no-interaction --prefer-dist --optimize-autoloader
fi

if [[ -f "package.json" ]]; then
    echo "Installing npm dependencies..."
    npm ci --prefer-offline
fi

echo "Dependencies ready."
