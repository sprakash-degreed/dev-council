#!/usr/bin/env bash
# Council — Ollama Adapter

# Default model (can be overridden via COUNCIL_OLLAMA_MODEL env var or config.json)
OLLAMA_MODEL="${COUNCIL_OLLAMA_MODEL:-llama3.2}"

ollama_execute() {
    local system_prompt="$1"
    local user_prompt="$2"

    local prompt="$user_prompt"
    if [[ -n "$system_prompt" ]]; then
        prompt="[System: $system_prompt]

$user_prompt"
    fi

    local tmpout
    tmpout="$(mktemp)"

    ollama run "$OLLAMA_MODEL" "$prompt" 2>/dev/null > "$tmpout"

    # Estimate tokens (~4 chars per token)
    local prompt_chars=${#prompt}
    local output_chars
    output_chars="$(wc -c < "$tmpout")"
    tokens_record "ollama" "$(( prompt_chars / 4 ))" "$(( output_chars / 4 ))"

    cat "$tmpout"
    rm -f "$tmpout"
}
