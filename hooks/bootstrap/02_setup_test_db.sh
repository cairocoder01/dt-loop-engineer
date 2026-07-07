#!/bin/bash
# Download the WordPress test suite install script and prepare the test database.
# This runs once per container lifetime; the pre-issue hook resets DB state per issue.
set -euo pipefail

WP_VERSION="${WP_VERSION:-latest}"
# Exported so wp-cli's install-wp-tests.sh (a child process) installs to the same
# location the verify stage reads from. docker-compose sets this to a path under
# the persistent wp_data volume.
export WP_TESTS_DIR="${WP_TESTS_DIR:-/tmp/wordpress-tests-lib}"

echo "Setting up WordPress test suite (WP $WP_VERSION)..."

# Guard on the definitive marker file, NOT the directory. install-wp-tests.sh only
# downloads includes/ when $WP_TESTS_DIR does not already exist, so we must not
# pre-create it here — doing so makes that script skip the includes/ download and
# leaves a half-installed tree (config present, functions.php missing). Checking the
# marker file also lets a previously-broken install on the persistent volume self-heal.
if [[ ! -f "$WP_TESTS_DIR/includes/functions.php" ]]; then
    # Clear any partial install so install-wp-tests.sh's own `[ ! -d ]` check passes
    # and it fetches includes/ and data/.
    rm -rf "$WP_TESTS_DIR"

    curl -s \
        "https://raw.githubusercontent.com/wp-cli/scaffold-command/main/templates/install-wp-tests.sh" \
        -o /tmp/install-wp-tests.sh
    chmod +x /tmp/install-wp-tests.sh

    echo "y" | bash /tmp/install-wp-tests.sh \
        "$WP_DB_NAME" \
        "$WP_DB_USER" \
        "$WP_DB_PASS" \
        "$WP_DB_HOST" \
        "$WP_VERSION"

    echo "WordPress test suite installed at $WP_TESTS_DIR"
else
    echo "WordPress test suite already installed, skipping."
fi
