#!/usr/bin/env bash
# Council — Configuration loader
# Reads .council/config.json for user-defined role assignments and settings

declare -A CONFIG_ROLES=()         # role -> pinned agent name
declare -A CONFIG_AGENT_PROMPTS=() # agent -> custom prompt instructions
CONFIG_OLLAMA_MODEL=""              # override for ollama model
CONFIG_MAX_ITERATIONS=""            # override for consensus max iterations
CONFIG_LOADED=0

# Load config from .council/config.json
config_load() {
    local dir="$1"
    local config_file="$dir/$COUNCIL_DIR/config.json"

    CONFIG_ROLES=()
    CONFIG_AGENT_PROMPTS=()
    CONFIG_OLLAMA_MODEL=""
    CONFIG_MAX_ITERATIONS=""
    CONFIG_LOADED=0

    [[ ! -f "$config_file" ]] && return 0

    if ! has_cmd jq; then
        ui_warn "config.json found but jq not available — skipping config"
        return 0
    fi

    # Validate JSON
    if ! jq empty "$config_file" 2>/dev/null; then
        ui_warn "config.json is invalid JSON — skipping config"
        return 0
    fi

    CONFIG_LOADED=1

    # Load role assignments
    local roles_json
    roles_json="$(jq -r '.roles // {} | to_entries[] | "\(.key)=\(.value)"' "$config_file" 2>/dev/null)"
    while IFS='=' read -r role agent; do
        [[ -z "$role" || -z "$agent" ]] && continue
        CONFIG_ROLES[$role]="$agent"
    done <<< "$roles_json"

    # Load agent custom prompts
    local prompts_keys
    prompts_keys="$(jq -r '.agent_prompts // {} | keys[]' "$config_file" 2>/dev/null)"
    while IFS= read -r agent; do
        [[ -z "$agent" ]] && continue
        local prompt_val
        prompt_val="$(jq -r ".agent_prompts[\"$agent\"] // \"\"" "$config_file" 2>/dev/null)"
        [[ -n "$prompt_val" ]] && CONFIG_AGENT_PROMPTS[$agent]="$prompt_val"
    done <<< "$prompts_keys"

    # Load ollama model override
    CONFIG_OLLAMA_MODEL="$(jq -r '.ollama_model // ""' "$config_file" 2>/dev/null)"

    # Load max iterations override
    CONFIG_MAX_ITERATIONS="$(jq -r '.max_iterations // ""' "$config_file" 2>/dev/null)"

    # Report loaded config
    local pinned_count="${#CONFIG_ROLES[@]}"
    if [[ $pinned_count -gt 0 ]]; then
        local pins=""
        for role in "${!CONFIG_ROLES[@]}"; do
            pins+="$role=${CONFIG_ROLES[$role]} "
        done
        ui_info "Config loaded: ${pins% }"
    fi
    local prompt_count="${#CONFIG_AGENT_PROMPTS[@]}"
    if [[ $prompt_count -gt 0 ]]; then
        local agents_with_prompts=""
        for agent in "${!CONFIG_AGENT_PROMPTS[@]}"; do
            agents_with_prompts+="$agent "
        done
        ui_info "Custom prompts: ${agents_with_prompts% }"
    fi
    [[ -n "$CONFIG_OLLAMA_MODEL" ]] && ui_info "Ollama model: $CONFIG_OLLAMA_MODEL"
    [[ -n "$CONFIG_MAX_ITERATIONS" ]] && ui_info "Max iterations: $CONFIG_MAX_ITERATIONS"
}

# Get pinned agent for a role (empty string = use dynamic assignment)
config_get_role_agent() {
    local role="$1"
    echo "${CONFIG_ROLES[$role]:-}"
}

# Get custom prompt for an agent (empty string = no custom prompt)
config_get_agent_prompt() {
    local agent="$1"
    echo "${CONFIG_AGENT_PROMPTS[$agent]:-}"
}

# Apply config overrides to global settings
config_apply() {
    # Override ollama model if configured
    if [[ -n "$CONFIG_OLLAMA_MODEL" ]]; then
        OLLAMA_MODEL="$CONFIG_OLLAMA_MODEL"
    fi

    # Override consensus max iterations if configured
    if [[ -n "$CONFIG_MAX_ITERATIONS" ]]; then
        CONSENSUS_MAX_ITERATIONS="$CONFIG_MAX_ITERATIONS"
    fi
}

# Generate a starter config.json
config_init() {
    local dir="${1:-.}"
    dir="$(cd "$dir" && pwd)"
    local config_file="$dir/$COUNCIL_DIR/config.json"

    mkdir -p "$dir/$COUNCIL_DIR"

    if [[ -f "$config_file" ]]; then
        ui_warn "Config already exists: $config_file"
        return 1
    fi

    # Discover agents for reference
    agents_discover

    cat > "$config_file" <<'EOJSON'
{
  "roles": {
    "planner": "",
    "architect": "",
    "implementer": "",
    "critic": "",
    "debugger": "",
    "tester": "",
    "verifier": ""
  },
  "agent_prompts": {
    "claude": "",
    "codex": "",
    "gemini": "",
    "ollama": ""
  },
  "ollama_model": "",
  "max_iterations": 3
}
EOJSON

    ui_success "Created $config_file"
    echo ""
    echo -e "${_BOLD}Available agents:${_RESET}"
    for name in claude codex gemini ollama; do
        if agents_is_available "$name"; then
            echo -e "  ${_GREEN}●${_RESET} $name"
        else
            echo -e "  ${_DIM}○ $name (not installed)${_RESET}"
        fi
    done
    echo ""
    echo "Set agent names in roles to pin them."
    echo "Add custom instructions in agent_prompts."
    echo "Leave empty for defaults."
}
