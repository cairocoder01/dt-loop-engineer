#!/bin/bash
# Shared helper: run opencode with automatic model fallback on quota/rate-limit errors.
# Source this file; do not execute it directly.
#
# Usage:
#   source "$SCRIPT_DIR/loop-stages/lib/opencode_runner.sh"
#   opencode_with_fallback "$MODEL" "$REPO_DIR" "$PROMPT_FILE" "$TIMEOUT_SECS"
#   agent_exit=$OPENCODE_LAST_EXIT
#   model_used=$OPENCODE_USED_MODEL
#
# After the call, the caller inspects $OPENCODE_LAST_EXIT for timeout (124) and
# other conditions — the fallback logic only retries on rate-limit signals, not
# on every non-zero exit code.

# Globals written by opencode_with_fallback:
OPENCODE_LAST_EXIT=0
OPENCODE_USED_MODEL=""

_oc_is_rate_limited() {
    # $1 = path to captured output file
    grep -qiE '429|RESOURCE_EXHAUSTED|rate[ _-]?limit|quota.?exceed|too.?many.?request|rateLimitExceeded' "$1"
}

_oc_is_connection_error() {
    # $1 = path to captured output file
    # Catches Ollama host unreachable and generic network failures.
    grep -qiE 'connection refused|dial tcp|ECONNREFUSED|no such host|network unreachable|failed to connect' "$1"
}

opencode_with_fallback() {
    local primary_model="$1"
    local repo_dir="$2"
    local prompt_file="$3"
    local timeout_secs="${4:-0}"
    local output_capture="${5:-}"   # optional: path to copy the final attempt's output into

    # Build ordered model list: primary first, then comma-separated fallbacks
    local -a models=("$primary_model")
    if [[ -n "${OPENCODE_FALLBACK_MODELS:-}" ]]; then
        IFS=',' read -ra _fallbacks <<< "$OPENCODE_FALLBACK_MODELS"
        for _m in "${_fallbacks[@]}"; do
            _m="${_m// /}"   # strip spaces
            [[ -n "$_m" ]] && models+=("$_m")
        done
    fi

    local attempt=0
    local tmp_out
    OPENCODE_LAST_EXIT=0
    OPENCODE_USED_MODEL=""

    for model in "${models[@]}"; do
        attempt=$((attempt + 1))
        OPENCODE_USED_MODEL="$model"
        tmp_out=$(mktemp /tmp/opencode-out.XXXXXX)

        if [[ $attempt -gt 1 ]]; then
            echo "  [fallback] switching to model: $model (attempt $attempt / ${#models[@]})"
        fi

        # Run opencode, streaming output live AND capturing it for rate-limit detection.
        # 'set +e' so a non-zero exit from the pipeline doesn't kill the sourcing script;
        # we read the real exit code from PIPESTATUS and handle it ourselves.
        set +e
        if [[ "$timeout_secs" -gt 0 ]]; then
            timeout "$timeout_secs" \
                opencode run --model "$model" --dir "$repo_dir" --auto \
                < "$prompt_file" 2>&1 | tee "$tmp_out"
        else
            opencode run --model "$model" --dir "$repo_dir" --auto \
                < "$prompt_file" 2>&1 | tee "$tmp_out"
        fi
        OPENCODE_LAST_EXIT=${PIPESTATUS[0]}
        set -e

        # Non-zero exit: check whether to retry with the next model.
        if [[ $OPENCODE_LAST_EXIT -ne 0 && $attempt -lt ${#models[@]} ]]; then
            if [[ $OPENCODE_LAST_EXIT -eq 124 ]]; then
                echo "  [timeout] $model timed out after ${timeout_secs}s — will try next model."
                rm -f "$tmp_out"
                continue
            fi
            if _oc_is_rate_limited "$tmp_out"; then
                echo "  [rate-limit] $model quota exceeded — will try next model."
                rm -f "$tmp_out"
                continue
            fi
            if _oc_is_connection_error "$tmp_out"; then
                echo "  [connection] $model unreachable — will try next model."
                rm -f "$tmp_out"
                continue
            fi
        fi

        [[ -n "$output_capture" ]] && cp "$tmp_out" "$output_capture" 2>/dev/null || true
        rm -f "$tmp_out"
        return $OPENCODE_LAST_EXIT
    done

    # All models exhausted (rate limits or timeouts)
    [[ -n "$output_capture" && -f "${tmp_out:-}" ]] && cp "$tmp_out" "$output_capture" 2>/dev/null || true
    rm -f "$tmp_out" 2>/dev/null || true
    echo "  [fallback] all ${#models[@]} model(s) failed — no more fallbacks."
    return $OPENCODE_LAST_EXIT
}
