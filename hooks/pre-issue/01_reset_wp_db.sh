#!/bin/bash
# Drop and recreate the test database so each issue starts with a clean state.
set -euo pipefail

echo "Resetting test database: $WP_DB_NAME"

mysql \
    -h "$WP_DB_HOST" \
    -u "$WP_DB_USER" \
    -p"$WP_DB_PASS" \
    -e "DROP DATABASE IF EXISTS \`${WP_DB_NAME}\`; CREATE DATABASE \`${WP_DB_NAME}\`;"

echo "Database reset complete."
