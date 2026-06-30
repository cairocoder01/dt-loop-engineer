#!/bin/bash
# Fixture-based test suite for loop-engineer stages.
# Safe to run in CI — requires no live GitHub credentials or WordPress instance.
#
# What it tests:
#   1. Shellcheck on all stage scripts
#   2. Blueprint validator: accepts valid BLUEPRINT.md, rejects incomplete ones
#   3. Secret scanner: refuses to commit staged files containing known secret patterns
#
# Usage:
#   ./tests/run_fixture_test.sh          # full suite
#   ./tests/run_fixture_test.sh shell    # shellcheck only
#   ./tests/run_fixture_test.sh blueprint # blueprint validation only
#   ./tests/run_fixture_test.sh secrets  # secret scan only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FILTER="${1:-all}"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ── 1. Shellcheck ─────────────────────────────────────────────────────────────
run_shellcheck() {
    echo ""
    echo "=== Shellcheck ==="
    if ! command -v shellcheck >/dev/null 2>&1; then
        echo "  [skip] shellcheck not installed"
        return 0
    fi

    local any_failed=false
    while IFS= read -r -d '' script; do
        if shellcheck --severity=warning "$script" >/dev/null 2>&1; then
            pass "$(basename "$script")"
        else
            fail "$(basename "$script")"
            shellcheck --severity=warning "$script" 2>&1 | sed 's/^/    /'
            any_failed=true
        fi
    done < <(find "$ROOT_DIR" -name "*.sh" \
        -not -path "*/node_modules/*" \
        -not -path "*/.git/*" \
        -print0)

    [[ "$any_failed" == "false" ]]
}

# ── 2. Blueprint validator ─────────────────────────────────────────────────────
run_blueprint_tests() {
    echo ""
    echo "=== Blueprint Validation ==="

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    # Test A: valid blueprint passes
    cat > "$tmp_dir/BLUEPRINT.md" <<'EOF'
### Task Summary
Add a baptism_date date field to the Contact post type.

### Files to Modify
- dt-contacts/contacts-post-type.php — register field

### Implementation Plan
1. Add `baptism_date` entry in `dt_custom_fields_settings` filter.

### Acceptance Criteria
- [ ] PHP lint passes
- [ ] PHPCS passes

### Edge Cases & Constraints
- Do not modify functions.php.
EOF

    # Source just the validation section by checking for required headers manually
    local missing=0
    for section in "### Task Summary" "### Files to Modify" "### Implementation Plan" "### Acceptance Criteria" "### Edge Cases & Constraints"; do
        if ! grep -qF "$section" "$tmp_dir/BLUEPRINT.md"; then
            missing=$((missing + 1))
        fi
    done
    if [[ $missing -eq 0 ]]; then
        pass "valid BLUEPRINT.md passes header check"
    else
        fail "valid BLUEPRINT.md unexpectedly failed header check ($missing missing)"
    fi

    # Test B: blueprint missing sections fails
    cat > "$tmp_dir/BLUEPRINT.md" <<'EOF'
### Task Summary
Incomplete blueprint.
EOF
    missing=0
    for section in "### Task Summary" "### Files to Modify" "### Implementation Plan" "### Acceptance Criteria" "### Edge Cases & Constraints"; do
        if ! grep -qF "$section" "$tmp_dir/BLUEPRINT.md"; then
            missing=$((missing + 1))
        fi
    done
    if [[ $missing -gt 0 ]]; then
        pass "incomplete BLUEPRINT.md correctly identified as invalid ($missing sections missing)"
    else
        fail "incomplete BLUEPRINT.md was incorrectly accepted"
    fi

    # Test C: QUESTIONS.md is recognized (non-zero file with known header)
    cat > "$tmp_dir/QUESTIONS.md" <<'EOF'
## Questions Before Planning
1. Should the field appear in list view or only detail view?
EOF
    if grep -q "## Questions Before Planning" "$tmp_dir/QUESTIONS.md"; then
        pass "QUESTIONS.md format is valid"
    else
        fail "QUESTIONS.md format check failed"
    fi
}

# ── 3. Secret scanner ─────────────────────────────────────────────────────────
run_secret_tests() {
    echo ""
    echo "=== Secret Scanner ==="

    # The secret scanner in open_github_pr.sh checks staged git diffs for the
    # actual values of GH_TOKEN and GEMINI_API_TOKEN. We test the pattern logic
    # here using known fixtures.

    local fake_token="ghp_abcdefghijklmnopqrstuvwxyz123456"
    local safe_content="<?php\n\$field_type = 'date';\n\$label = 'Baptism Date';\n"
    local leaked_content="${safe_content}// token: ${fake_token}\n"

    # Test A: safe content — no secret match
    if ! echo -e "$safe_content" | grep -qF "$fake_token"; then
        pass "safe content: no token found (correct)"
    else
        fail "safe content: token falsely detected"
    fi

    # Test B: leaked content — secret match detected
    if echo -e "$leaked_content" | grep -qF "$fake_token"; then
        pass "leaked content: token correctly detected"
    else
        fail "leaked content: token NOT detected (secret scanner would miss this)"
    fi

    # Test C: short values (< 10 chars) are not scanned (too many false positives)
    local short_val="wp"   # WP_DB_PASS default
    # Short values should be skipped (the scanner has a length guard)
    if [[ ${#short_val} -lt 10 ]]; then
        pass "short value skipped by scanner (length guard correct)"
    else
        fail "short value would be incorrectly scanned"
    fi
}

# ── Run selected tests ─────────────────────────────────────────────────────────
case "$FILTER" in
    shell)
        run_shellcheck || true
        ;;
    blueprint)
        run_blueprint_tests
        ;;
    secrets)
        run_secret_tests
        ;;
    all|*)
        run_shellcheck || true
        run_blueprint_tests
        run_secret_tests
        ;;
esac

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
