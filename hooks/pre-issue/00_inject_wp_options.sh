#!/bin/bash
# Inject WordPress options from a secrets file into the test WP install.
#
# Set WP_OPTIONS_FILE=/path/to/secrets.env in your .env (mounted into the container).
# Format: one KEY=VALUE per line; lines starting with # are ignored.
# Each key is written to wp_options via WP-CLI so plugins can read them during tests.
#
# Example secrets.env:
#   dt_google_maps_api_key=AIzaSy...
#   dt_twilio_account_sid=ACxxx
set -euo pipefail

WP_INSTALL_PATH="${WP_INSTALL_PATH:-/tmp/wordpress}"

if [[ -z "${WP_OPTIONS_FILE:-}" ]]; then
    echo "WP_OPTIONS_FILE not set — skipping wp_options injection."
    exit 0
fi

if [[ ! -f "$WP_OPTIONS_FILE" ]]; then
    echo "WARNING: WP_OPTIONS_FILE=$WP_OPTIONS_FILE not found — skipping injection."
    exit 0
fi

if [[ ! -d "$WP_INSTALL_PATH" ]]; then
    echo "WordPress install not found at $WP_INSTALL_PATH — skipping injection."
    exit 0
fi

echo "Injecting WordPress options from $WP_OPTIONS_FILE..."
COUNT=0

while IFS='=' read -r key value || [[ -n "$key" ]]; do
    # Skip comments and blank lines
    [[ -z "$key" || "$key" == \#* ]] && continue
    # Trim whitespace
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    [[ -z "$key" ]] && continue

    wp option update "$key" "$value" \
        --path="$WP_INSTALL_PATH" \
        --allow-root \
        --quiet
    echo "  set: $key"
    ((COUNT++))
done < "$WP_OPTIONS_FILE"

echo "Injected $COUNT option(s) into wp_options."
