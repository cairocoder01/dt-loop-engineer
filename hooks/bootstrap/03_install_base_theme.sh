#!/bin/bash
# Install the latest released disciple-tools-theme into the WordPress test install.
#
# This runs ONCE per container lifetime (after 02_setup_test_db.sh creates /tmp/wordpress).
# The theme is always installed from the latest GitHub release so every repo being worked
# on has a known-good base theme available for E2E testing.
#
# When the loop engineer is working on the theme itself (TARGET_REPO=disciple-tools-theme),
# 02b_prep_e2e_site.sh will overwrite this installation with the agent's changed version.
# For all other repos, this bootstrap copy is used as-is.
#
# Override DT_BASE_THEME_REPO if you maintain a fork of the theme.
set -euo pipefail

WP_INSTALL_PATH="${WP_INSTALL_PATH:-/tmp/wordpress}"
DT_BASE_THEME_REPO="${DT_BASE_THEME_REPO:-DiscipleTools/disciple-tools-theme}"
THEME_DIR="$WP_INSTALL_PATH/wp-content/themes/disciple-tools-theme"

echo "=== Base Theme Install (disciple-tools-theme) ==="

if [[ ! -d "$WP_INSTALL_PATH/wp-content" ]]; then
    echo "  WordPress install not found at $WP_INSTALL_PATH — skipping."
    echo "  Ensure 02_setup_test_db.sh ran successfully first."
    exit 0
fi

if [[ -d "$THEME_DIR" ]]; then
    echo "  disciple-tools-theme already present — skipping."
    exit 0
fi

mkdir -p "$(dirname "$THEME_DIR")"

# ── Try latest GitHub release first ───────────────────────────────────────────
# Releases include pre-built compiled assets (Vite CSS/JS bundles), which the
# raw source from git does not. Using a release avoids needing npm install + build.
LATEST_TAG=""
LATEST_TAG=$(gh release view \
    --repo "$DT_BASE_THEME_REPO" \
    --json tagName \
    -q .tagName 2>/dev/null || true)

if [[ -n "$LATEST_TAG" ]]; then
    echo "  Downloading release $LATEST_TAG from $DT_BASE_THEME_REPO..."

    TMPDIR=$(mktemp -d)
    TMPZIP="$TMPDIR/theme.zip"

    # Download the first .zip asset from the release
    gh release download "$LATEST_TAG" \
        --repo "$DT_BASE_THEME_REPO" \
        --pattern "*.zip" \
        --output "$TMPZIP" 2>/dev/null

    echo "  Extracting..."
    unzip -q "$TMPZIP" -d "$TMPDIR/extracted"

    # GitHub release ZIPs typically contain a single top-level directory.
    # If so, use that directory as the theme root; if not (flat ZIP), use extracted/ directly.
    INNER_DIRS=$(find "$TMPDIR/extracted" -maxdepth 1 -mindepth 1 -type d)
    INNER_DIR_COUNT=$(echo "$INNER_DIRS" | grep -c . || true)

    if [[ "$INNER_DIR_COUNT" -eq 1 ]]; then
        mv "$INNER_DIRS" "$THEME_DIR"
    else
        mv "$TMPDIR/extracted" "$THEME_DIR"
    fi

    rm -rf "$TMPDIR"
    echo "  Installed disciple-tools-theme $LATEST_TAG"
else
    # ── Fallback: clone the default branch ───────────────────────────────────
    # Used when no release is published or gh CLI cannot reach the API.
    # NOTE: source clone lacks compiled assets — theme may not render correctly
    # until `npm install && npm run build` is run inside the theme directory.
    echo "  No release found — cloning $DT_BASE_THEME_REPO (--depth 1)..."
    git clone --depth 1 \
        "https://x-access-token:${GH_TOKEN}@github.com/${DT_BASE_THEME_REPO}.git" \
        "$THEME_DIR"
    echo "  Installed disciple-tools-theme (latest commit — compiled assets may be missing)"
fi
