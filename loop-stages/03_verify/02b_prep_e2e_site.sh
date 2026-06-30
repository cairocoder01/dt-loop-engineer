#!/bin/bash
# Verify pre-step: Prepare a web-accessible WordPress for browser E2E tests.
#
# Runs between PHPUnit (02_phpunit.sh) and E2E (03_chrome_mcp_e2e.js).
#
# What this does:
#   1. Auto-detects whether the repo is a theme or plugin
#   2. Syncs $REPO_DIR into the WordPress test install's wp-content directory
#   3. Creates wp-config.php if missing (install-wp-tests.sh only creates wp-tests-config.php)
#   4. Runs `wp core install` to make it browseable (idempotent — safe on retry)
#   5. Activates the theme/plugin
#   6. Starts a PHP built-in server at WP_TEST_URL
#
# Content type auto-detection (priority order):
#   1. .loop-engineer/e2e-config.sh in the repo (set CONTENT_TYPE and CONTENT_DIR_NAME)
#   2. style.css with "Theme Name:" header → theme
#   3. Root-level .php file with "Plugin Name:" header → plugin
#   4. Falls through with a warning; E2E still runs if WP_TEST_URL is already up
#
# Per-repo override (.loop-engineer/e2e-config.sh):
#   CONTENT_TYPE=themes          # "themes" or "plugins"
#   CONTENT_DIR_NAME=my-theme    # directory name under wp-content/{type}/
set -euo pipefail

WP_INSTALL_PATH="${WP_INSTALL_PATH:-/tmp/wordpress}"
WP_E2E_PORT="${WP_E2E_PORT:-8080}"
WP_TEST_URL="${WP_TEST_URL:-http://localhost:${WP_E2E_PORT}}"

echo "=== E2E Site Prep ==="

if [[ ! -d "$WP_INSTALL_PATH" ]]; then
    echo "WordPress install not found at $WP_INSTALL_PATH — skipping E2E prep."
    echo "The container bootstrap hook (02_setup_test_db.sh) must run first."
    exit 0
fi

# ── Determine content type and directory name ─────────────────────────────────
# TARGET_REPO is the GitHub repo name (e.g. "disciple-tools-theme") — use it as
# the wp-content directory name so it matches what the repo expects.
CONTENT_TYPE=""
CONTENT_DIR_NAME="${TARGET_REPO:-$(basename "$REPO_DIR")}"

# Per-repo override takes precedence over auto-detection
E2E_CONFIG="$REPO_DIR/.loop-engineer/e2e-config.sh"
if [[ -f "$E2E_CONFIG" ]]; then
    echo "  Loading per-repo E2E config..."
    # shellcheck source=/dev/null
    source "$E2E_CONFIG"
fi

# Auto-detect if config didn't set CONTENT_TYPE
if [[ -z "$CONTENT_TYPE" ]]; then
    if grep -q "^Theme Name:" "$REPO_DIR/style.css" 2>/dev/null; then
        CONTENT_TYPE="themes"
    elif find "$REPO_DIR" -maxdepth 1 -name "*.php" \
             | xargs grep -l "Plugin Name:" 2>/dev/null \
             | grep -q .; then
        CONTENT_TYPE="plugins"
    fi
fi

if [[ -z "$CONTENT_TYPE" ]]; then
    echo "WARNING: Cannot determine content type (theme/plugin) for '$CONTENT_DIR_NAME'."
    echo "  Create .loop-engineer/e2e-config.sh:"
    echo "    CONTENT_TYPE=themes"
    echo "    CONTENT_DIR_NAME=my-theme-slug"
    echo "  E2E prep skipped — browser tests will still run if WP_TEST_URL is already accessible."
    exit 0
fi

INSTALL_DIR="$WP_INSTALL_PATH/wp-content/${CONTENT_TYPE}/${CONTENT_DIR_NAME}"
echo "  Type:   $CONTENT_TYPE"
echo "  Target: $INSTALL_DIR"

# ── Sync repo to wp-content ───────────────────────────────────────────────────
echo "  Syncing repo changes to WordPress..."
mkdir -p "$INSTALL_DIR"
rsync -a --delete --exclude='.git' --exclude='node_modules' \
    "$REPO_DIR/" "$INSTALL_DIR/"
echo "  Sync complete."

# ── Ensure wp-config.php exists ───────────────────────────────────────────────
# install-wp-tests.sh writes wp-tests-config.php (for PHPUnit) but NOT wp-config.php
# (needed for a browseable WordPress site and for WP-CLI core install/activate commands).
if [[ ! -f "$WP_INSTALL_PATH/wp-config.php" ]]; then
    echo "  Creating wp-config.php..."
    wp config create \
        --path="$WP_INSTALL_PATH" \
        --dbname="$WP_DB_NAME" \
        --dbuser="$WP_DB_USER" \
        --dbpass="$WP_DB_PASS" \
        --dbhost="${WP_DB_HOST:-localhost}" \
        --allow-root \
        --force \
        --quiet
fi

# ── Install WordPress core (idempotent) ───────────────────────────────────────
if ! wp core is-installed --path="$WP_INSTALL_PATH" --allow-root 2>/dev/null; then
    echo "  Installing WordPress core..."
    wp core install \
        --path="$WP_INSTALL_PATH" \
        --url="$WP_TEST_URL" \
        --title="Loop Engineer Test Site" \
        --admin_user=admin \
        --admin_password=admin \
        --admin_email=loop@test.local \
        --skip-email \
        --allow-root \
        --quiet
else
    # Update siteurl/home in case WP_TEST_URL changed (e.g. different port on retry)
    wp option update siteurl "$WP_TEST_URL" \
        --path="$WP_INSTALL_PATH" --allow-root --quiet 2>/dev/null || true
    wp option update home "$WP_TEST_URL" \
        --path="$WP_INSTALL_PATH" --allow-root --quiet 2>/dev/null || true
fi

# ── Activate disciple-tools-theme ────────────────────────────────────────────
# The active WordPress theme is always disciple-tools-theme.
# - Working on the theme: the rsync above already replaced the bootstrap copy
#   with the agent's changes; activating it picks up those changes.
# - Working on anything else: the bootstrap-installed latest release is used.
DT_THEME_DIR="$WP_INSTALL_PATH/wp-content/themes/disciple-tools-theme"
if [[ -d "$DT_THEME_DIR" ]]; then
    echo "  Activating theme: disciple-tools-theme"
    wp theme activate disciple-tools-theme \
        --path="$WP_INSTALL_PATH" --allow-root --quiet 2>/dev/null || \
        echo "  WARNING: disciple-tools-theme activation failed"
else
    echo "  WARNING: disciple-tools-theme not found at $DT_THEME_DIR"
    echo "  The bootstrap hook (03_install_base_theme.sh) may not have run."
fi

# ── Activate plugin (if working on a plugin repo) ────────────────────────────
if [[ "$CONTENT_TYPE" == "plugins" ]]; then
    echo "  Activating plugin: $CONTENT_DIR_NAME"
    wp plugin activate "$CONTENT_DIR_NAME" \
        --path="$WP_INSTALL_PATH" --allow-root --quiet 2>/dev/null || \
        echo "  WARNING: plugin activation failed — check plugin slug matches directory name"
fi

# ── Write PHP server router ───────────────────────────────────────────────────
# PHP's built-in server doesn't read .htaccess, so we need a router script to
# replicate WordPress's mod_rewrite rules: serve static files directly,
# route everything else through WordPress's front controller (index.php).
ROUTER="$WP_INSTALL_PATH/router.php"
cat > "$ROUTER" << 'ROUTER_EOF'
<?php
/**
 * WordPress router for PHP built-in development server.
 * Replicates Apache mod_rewrite: static files served directly, everything
 * else dispatched through WordPress's front controller.
 */
$uri = urldecode(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH));
if ($uri !== '/' && file_exists(__DIR__ . $uri)) {
    return false; // serve CSS, JS, images, etc. directly
}
$_SERVER['SCRIPT_FILENAME'] = __DIR__ . '/index.php';
require __DIR__ . '/index.php';
ROUTER_EOF

# ── Start PHP built-in server ─────────────────────────────────────────────────
# Kill any server left over from a previous retry iteration
pkill -f "php -S 0.0.0.0:${WP_E2E_PORT}" 2>/dev/null || true
sleep 1

echo "  Starting PHP server at $WP_TEST_URL..."
nohup php -S "0.0.0.0:${WP_E2E_PORT}" -t "$WP_INSTALL_PATH" "$ROUTER" \
    > /tmp/php-e2e-server.log 2>&1 &
disown

# Wait up to 20s for the server to respond
READY=false
for i in $(seq 1 20); do
    if curl -sf --max-time 2 "http://localhost:${WP_E2E_PORT}/" >/dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 1
done

if [[ "$READY" == "true" ]]; then
    echo "  PHP server ready at $WP_TEST_URL"
else
    echo "WARNING: PHP server did not respond within 20s."
    echo "--- PHP server log ---"
    cat /tmp/php-e2e-server.log 2>/dev/null || true
    echo "--- end ---"
    # Exit 0 — let 03_chrome_mcp_e2e.js surface the real failure with a clear error
fi
