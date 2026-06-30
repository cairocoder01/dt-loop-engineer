#!/bin/bash
# Verify WP-CLI is available (pre-installed in Dockerfile; this is a health check).
set -euo pipefail

if ! command -v wp &>/dev/null; then
    echo "WP-CLI not found, installing..."
    curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
fi

wp --info --allow-root
echo "WP-CLI ready."
