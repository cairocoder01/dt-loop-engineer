#!/bin/bash
# Download the WordPress test suite install script and prepare the test database.
# This runs once per container lifetime; the pre-issue hook resets DB state per issue.
set -euo pipefail

WP_VERSION="${WP_VERSION:-latest}"
WP_TESTS_DIR="${WP_TESTS_DIR:-/tmp/wordpress-tests-lib}"

echo "Setting up WordPress test suite (WP $WP_VERSION)..."

# Download the test suite install script if not already cached
if [[ ! -d "$WP_TESTS_DIR" ]]; then
    mkdir -p "$WP_TESTS_DIR"
    curl -s \
        "https://raw.githubusercontent.com/wp-cli/scaffold-command/main/templates/install-wp-tests.sh" \
        -o /tmp/install-wp-tests.sh
    chmod +x /tmp/install-wp-tests.sh

    bash /tmp/install-wp-tests.sh \
        "$WP_DB_NAME" \
        "$WP_DB_USER" \
        "$WP_DB_PASS" \
        "$WP_DB_HOST" \
        "$WP_VERSION"

    echo "WordPress test suite installed at $WP_TESTS_DIR"
else
    echo "WordPress test suite already installed, skipping."
fi
