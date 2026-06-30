#!/bin/bash
# Verify: Run PHPUnit test suite in WordPress multisite mode.
#
# Expected DB state:
#   The pre-issue hook (01_reset_wp_db.sh) drops and recreates the test database
#   before each issue, leaving it empty. The PHPUnit bootstrap file
#   ($WP_TESTS_DIR/includes/bootstrap.php) calls wp_install() on startup, which
#   re-creates all WordPress tables into that empty database. This means every
#   PHPUnit run starts from a known-clean WP install — no leftover rows or options
#   from previous issues or test runs.
#
# Bootstrap prerequisite:
#   The container-level bootstrap hook (hooks/bootstrap/02_setup_test_db.sh) must
#   have run first. It executes install-wp-tests.sh, which:
#     1. Downloads WordPress to $WP_INSTALL_PATH (/tmp/wordpress by default)
#     2. Installs the WP test library at $WP_TESTS_DIR (/tmp/wordpress-tests-lib)
#     3. Writes wp-tests-config.php with the DB credentials below
#   That setup is reused for every issue; only the database tables are reset.
#
# Repo phpunit.xml bootstrap files should include:
#   require getenv('WP_TESTS_DIR') . '/includes/bootstrap.php';
set -euo pipefail

cd "$REPO_DIR"

echo "=== PHPUnit Tests ==="

# ── Test environment ──────────────────────────────────────────────────────────
# These must match the credentials used when install-wp-tests.sh ran during
# the container bootstrap. If WP_TESTS_DIR is customised, override the env var.
export WP_TESTS_DIR="${WP_TESTS_DIR:-/tmp/wordpress-tests-lib}"
export WP_TESTS_DB_HOST="${WP_DB_HOST}"
export WP_TESTS_DB_NAME="${WP_DB_NAME}"
export WP_TESTS_DB_USER="${WP_DB_USER}"
export WP_TESTS_DB_PASS="${WP_DB_PASS}"

echo "  WP_TESTS_DIR: $WP_TESTS_DIR"
echo "  DB host:      $WP_TESTS_DB_HOST / $WP_TESTS_DB_NAME"

# ── Guard: test library must exist ───────────────────────────────────────────
if [[ ! -d "$WP_TESTS_DIR" ]]; then
    echo ""
    echo "ERROR: WordPress test library not found at $WP_TESTS_DIR"
    echo "The container bootstrap hook (hooks/bootstrap/02_setup_test_db.sh) must"
    echo "run before the verify stage. Verify that WP_DB_* env vars are set and"
    echo "that the bootstrap completed without errors."
    exit 1
fi

# ── PHP dependencies ──────────────────────────────────────────────────────────
# The pre-issue hook (02_update_core_deps.sh) already runs composer install for
# the cloned repo. This guard covers the rare case where the agent modified
# composer.json during execution.
if [[ ! -f "vendor/bin/phpunit" ]]; then
    echo "PHPUnit not found in vendor/ — running composer install..."
    composer install --no-interaction --prefer-dist --optimize-autoloader
fi

# ── PHPUnit config ────────────────────────────────────────────────────────────
if [[ -f "phpunit.xml" ]]; then
    CONFIG_FLAG="--configuration phpunit.xml"
elif [[ -f "phpunit.xml.dist" ]]; then
    CONFIG_FLAG="--configuration phpunit.xml.dist"
else
    echo "WARNING: No phpunit.xml or phpunit.xml.dist found — running without config."
    CONFIG_FLAG=""
fi

echo ""
echo "Running PHPUnit (WP_MULTISITE=1)..."
WP_MULTISITE=1 ./vendor/bin/phpunit $CONFIG_FLAG --testdox

echo "PHPUnit passed."
