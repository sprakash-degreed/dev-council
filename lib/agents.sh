#!/usr/bin/env bash
# Kannan — Agent Discovery and Management

# Agent registry (populated by agents_discover)
declare -A AGENTS_AVAILABLE=()
declare -A AGENT_CAPABILITIES=()

# Static capability map
_init_capabilities() {
    AGENT_CAPABILITIES=(
        [claude]="code,review,plan,test,debug,general"
        [codex]="code,test,debug"
        [gemini]="code,review,plan,general"
        [ollama]="review,plan,general"
    )
}

# Discover which agent CLIs are installed
agents_discover() {
    _init_capabilities
    AGENTS_AVAILABLE=()

    if has_cmd claude; then
        AGENTS_AVAILABLE[claude]="$(claude --version 2>/dev/null | head -1 || echo "available")"
    fi
    if has_cmd codex; then
        AGENTS_AVAILABLE[codex]="$(codex --version 2>/dev/null | head -1 || echo "available")"
    fi
    if has_cmd gemini; then
        AGENTS_AVAILABLE[gemini]="$(gemini --version 2>/dev/null | head -1 || echo "available")"
    fi
    if has_cmd ollama; then
        AGENTS_AVAILABLE[ollama]="$(ollama --version 2>/dev/null | head -1 || echo "available")"
    fi
}

agents_available_count() {
    echo "${#AGENTS_AVAILABLE[@]}"
}

agents_available_names() {
    local names=""
    for name in "${!AGENTS_AVAILABLE[@]}"; do
        names+="$name "
    done
    echo "${names% }"
}

agents_is_available() {
    [[ -n "${AGENTS_AVAILABLE[$1]+x}" ]]
}

agents_list_pretty() {
    local found=0
    echo ""
    echo -e "${_BOLD}Available Agents${_RESET}"
    ui_separator

    for name in claude codex gemini ollama; do
        if agents_is_available "$name"; then
            local ver="${AGENTS_AVAILABLE[$name]}"
            local caps="${AGENT_CAPABILITIES[$name]}"
            echo -e "  ${_GREEN}●${_RESET} ${_BOLD}$name${_RESET}  ${_DIM}$ver${_RESET}"
            echo -e "    capabilities: ${_CYAN}$caps${_RESET}"
            found=$((found + 1))
        else
            echo -e "  ${_DIM}○ $name (not installed)${_RESET}"
        fi
    done

    echo ""
    echo -e "  ${_DIM}$found agent(s) available${_RESET}"
    echo ""
}

# Check if agent has a specific capability
agent_has_capability() {
    local agent="$1" cap="$2"
    local caps="${AGENT_CAPABILITIES[$agent]:-}"
    [[ ",$caps," == *",$cap,"* ]]
}

# Get the best agent for a given capability
agent_best_for() {
    local cap="$1"
    # Priority order: claude > codex > gemini > ollama
    for name in claude codex gemini ollama; do
        if agents_is_available "$name" && agent_has_capability "$name" "$cap"; then
            echo "$name"
            return
        fi
    done
    # Fallback: any available agent
    for name in "${!AGENTS_AVAILABLE[@]}"; do
        echo "$name"
        return
    done
    echo ""
}

# Execute a prompt using a specific agent adapter
adapter_execute() {
    local agent="$1" system_prompt="$2" user_prompt="$3"
    local adapter="$SCRIPT_DIR/adapters/${agent}.sh"

    if [[ ! -f "$adapter" ]]; then
        ui_error "No adapter for agent: $agent"
        return 1
    fi

    # Prepend custom agent prompt from config if set
    local custom_prompt
    custom_prompt="$(config_get_agent_prompt "$agent")"
    if [[ -n "$custom_prompt" ]]; then
        if [[ -n "$system_prompt" ]]; then
            system_prompt="$custom_prompt

$system_prompt"
        else
            system_prompt="$custom_prompt"
        fi
    fi

    source "$adapter"
    "${agent}_execute" "$system_prompt" "$user_prompt"
}

# Execute and capture full output (blocking)
adapter_execute_capture() {
    local agent="$1" system_prompt="$2" user_prompt="$3"
    adapter_execute "$agent" "$system_prompt" "$user_prompt" 2>/dev/null
}
