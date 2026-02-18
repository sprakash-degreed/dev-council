#!/usr/bin/env bash
# Kannan — Utility functions

# Check if a command exists
has_cmd() { command -v "$1" &>/dev/null; }

# Check if jq is available (required dependency)
require_jq() {
    if ! has_cmd jq; then
        echo "ERROR: jq is required but not installed. Install it: https://jqlang.github.io/jq/download/" >&2
        exit 1
    fi
}

# Generate a short unique ID
gen_id() { head -c 8 /dev/urandom | xxd -p 2>/dev/null || date +%s%N | tail -c 12; }

# Slugify a string (lowercase, hyphens, no special chars)
slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | head -c 50
}

# Timestamp
now_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Read a JSON field from a file
json_get() {
    local file="$1" path="$2"
    jq -r "$path" "$file" 2>/dev/null || echo ""
}

# Create temp file that cleans up on exit
kannan_tmpfile() {
    local tmp
    tmp="$(mktemp)"
    trap "rm -f '$tmp'" EXIT
    echo "$tmp"
}

# Initialize the .kannan directory for a project
kannan_init() {
    local dir="$1"
    mkdir -p "$dir/$KANNAN_DIR/cache"
    mkdir -p "$dir/$KANNAN_DIR/patches"
    mkdir -p "$dir/$KANNAN_DIR/memory"
}

# Get the .kannan dir path for a project
kannan_state_dir() {
    local dir="$1"
    echo "$dir/$KANNAN_DIR"
}

# Simple key-value store using flat files
state_set() {
    local dir="$1" key="$2" value="$3"
    echo "$value" > "$dir/$KANNAN_DIR/cache/$key"
}

state_get() {
    local dir="$1" key="$2"
    local file="$dir/$KANNAN_DIR/cache/$key"
    [[ -f "$file" ]] && cat "$file" || echo ""
}

# --- Token Usage Tracking ---

# Global accumulators for current session
declare -A TOKEN_INPUT=()   # agent -> total input tokens
declare -A TOKEN_OUTPUT=()  # agent -> total output tokens
declare -A TOKEN_CALLS=()   # agent -> number of calls

# Record tokens for an agent call
tokens_record() {
    local agent="$1" input_tokens="$2" output_tokens="$3"
    TOKEN_INPUT[$agent]=$(( ${TOKEN_INPUT[$agent]:-0} + input_tokens ))
    TOKEN_OUTPUT[$agent]=$(( ${TOKEN_OUTPUT[$agent]:-0} + output_tokens ))
    TOKEN_CALLS[$agent]=$(( ${TOKEN_CALLS[$agent]:-0} + 1 ))
}

# Get total tokens across all agents
tokens_total() {
    local total=0
    for agent in "${!TOKEN_INPUT[@]}"; do
        total=$(( total + ${TOKEN_INPUT[$agent]:-0} + ${TOKEN_OUTPUT[$agent]:-0} ))
    done
    echo "$total"
}

# Reset token counters
tokens_reset() {
    TOKEN_INPUT=()
    TOKEN_OUTPUT=()
    TOKEN_CALLS=()
}

# Snapshot current token state as a JSON object for persistence
# Returns: {"claude":{"in":123,"out":456,"calls":3},"codex":{...}}
tokens_snapshot_json() {
    if ! has_cmd jq; then
        echo "{}"
        return
    fi

    local json="{}"
    for agent in "${!TOKEN_CALLS[@]}"; do
        local calls="${TOKEN_CALLS[$agent]:-0}"
        [[ $calls -eq 0 ]] && continue
        local input="${TOKEN_INPUT[$agent]:-0}"
        local output="${TOKEN_OUTPUT[$agent]:-0}"
        json="$(echo "$json" | jq -c \
            --arg agent "$agent" \
            --argjson in "$input" \
            --argjson out "$output" \
            --argjson calls "$calls" \
            '.[$agent] = {in: $in, out: $out, calls: $calls}'
        )"
    done
    echo "$json"
}
