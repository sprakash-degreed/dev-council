#!/usr/bin/env bash
# Council — Claude CLI Adapter

claude_execute() {
    local system_prompt="$1"
    local user_prompt="$2"

    local args=("-p" "--output-format" "stream-json")

    if [[ -n "$system_prompt" ]]; then
        args+=("--system-prompt" "$system_prompt")
    fi

    args+=("$user_prompt")

    local tmpout
    tmpout="$(mktemp)"

    claude "${args[@]}" 2>/dev/null > "$tmpout"

    # Parse token usage from the stream-json result message
    local input_tokens=0 output_tokens=0
    if has_cmd jq; then
        input_tokens="$(grep '"type":"result"' "$tmpout" | jq -r '.usage.input_tokens // 0' 2>/dev/null | tail -1)"
        output_tokens="$(grep '"type":"result"' "$tmpout" | jq -r '.usage.output_tokens // 0' 2>/dev/null | tail -1)"
        input_tokens="${input_tokens:-0}"
        output_tokens="${output_tokens:-0}"
    fi
    tokens_record "claude" "$input_tokens" "$output_tokens"

    # Extract text content from assistant messages and deltas
    grep '"type":"assistant"' "$tmpout" | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null
    grep '"type":"content_block_delta"' "$tmpout" | jq -r '.delta.text // empty' 2>/dev/null

    rm -f "$tmpout"
}
