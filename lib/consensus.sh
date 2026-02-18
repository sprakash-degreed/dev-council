#!/usr/bin/env bash
# Kannan — Consensus / Critique Loop

CONSENSUS_MAX_ITERATIONS="${KANNAN_MAX_ITERATIONS:-3}"

# Parse critique verdict from agent output
# Expects JSON block with verdict field
_parse_verdict() {
    local output="$1"

    # Try to extract JSON block from output
    local json_block
    json_block="$(echo "$output" | sed -n '/```json/,/```/p' | grep -v '```')"

    if [[ -z "$json_block" ]]; then
        # Try to find inline JSON with verdict
        json_block="$(echo "$output" | grep -o '{[^}]*"verdict"[^}]*}' | head -1)"
    fi

    if [[ -n "$json_block" ]] && has_cmd jq; then
        local verdict
        verdict="$(echo "$json_block" | jq -r '.verdict // "accept"' 2>/dev/null)"
        case "$verdict" in
            accept|revise|reject) echo "$verdict" ;;
            *) echo "accept" ;;
        esac
    else
        # No structured verdict found — default to accept
        echo "accept"
    fi
}

# Extract issues from critique output (human-readable)
_parse_issues() {
    local output="$1"
    local json_block
    json_block="$(echo "$output" | sed -n '/```json/,/```/p' | grep -v '```')"

    if [[ -n "$json_block" ]] && has_cmd jq; then
        echo "$json_block" | jq -r '.issues[]? | "[\(.severity)] \(.description)"' 2>/dev/null
    fi
}

# Extract issues as JSON array (for memory recording)
_parse_issues_json() {
    local output="$1"
    local json_block
    json_block="$(echo "$output" | sed -n '/```json/,/```/p' | grep -v '```')"

    if [[ -n "$json_block" ]] && has_cmd jq; then
        echo "$json_block" | jq -c '.issues // []' 2>/dev/null
    else
        echo "[]"
    fi
}

# Store consensus metadata via state files (survives subshell capture)
_consensus_meta_set() {
    local dir="$1" key="$2" value="$3"
    state_set "$dir" "consensus_$key" "$value"
}

consensus_meta_get() {
    local dir="$1" key="$2"
    state_get "$dir" "consensus_$key"
}

# Run the critique/revision loop
# Arguments: project_dir, implementation_output, original_task
# Returns: final accepted output (or last revision)
consensus_run() {
    local project_dir="$1"
    local impl_output="$2"
    local original_task="$3"

    # Reset consensus metadata (written to state files for subshell survival)
    _consensus_meta_set "$project_dir" "verdict" ""
    _consensus_meta_set "$project_dir" "iterations" "0"
    _consensus_meta_set "$project_dir" "issues" "[]"
    _consensus_meta_set "$project_dir" "critic_agent" ""
    _consensus_meta_set "$project_dir" "impl_agent" ""

    local critic_agent
    critic_agent="$(role_assign critic)"
    _consensus_meta_set "$project_dir" "critic_agent" "$critic_agent"

    if [[ -z "$critic_agent" ]]; then
        ui_warn "No agent available for critic role — skipping review"
        _consensus_meta_set "$project_dir" "verdict" "accept"
        echo "$impl_output"
        return 0
    fi

    local iteration=0
    local current_output="$impl_output"

    while [[ $iteration -lt $CONSENSUS_MAX_ITERATIONS ]]; do
        iteration=$((iteration + 1))
        ui_info "Critique iteration $iteration/$CONSENSUS_MAX_ITERATIONS"

        # Critic reviews the implementation
        local critique_prompt
        critique_prompt="$(cat <<EOF
## Original Task
$original_task

## Implementation to Review
$current_output

Review this implementation. At the end, output a JSON verdict block.
EOF
)"
        local system_prompt
        system_prompt="$(role_prompt critic)"

        ui_agent_output "$critic_agent" "critic" "Reviewing implementation..."
        local critique_output
        critique_output="$(adapter_execute_capture "$critic_agent" "$system_prompt" "$critique_prompt")"

        if [[ -z "$critique_output" ]]; then
            ui_warn "Critic returned empty response — accepting implementation"
            echo "$current_output"
            return 0
        fi

        # Display critique
        echo "$critique_output" | ui_stream_agent "$critic_agent" "critic"
        echo ""

        # Parse verdict
        local verdict
        verdict="$(_parse_verdict "$critique_output")"
        ui_info "Verdict: $verdict"

        # Record memory: update agent stats for the critic
        memory_update_stats "$project_dir" "$critic_agent" "critic" "$verdict"

        case "$verdict" in
            accept)
                ui_success "Implementation accepted by critic"
                _consensus_meta_set "$project_dir" "verdict" "accept"
                _consensus_meta_set "$project_dir" "iterations" "$iteration"
                _consensus_meta_set "$project_dir" "issues" "$(_parse_issues_json "$critique_output")"

                # Extract and record any patterns from the critique
                local patterns
                patterns="$(_extract_patterns_from_critique "$critique_output")"
                if [[ -n "$patterns" ]]; then
                    while IFS= read -r pattern; do
                        [[ -n "$pattern" ]] && memory_record_pattern "$project_dir" "$pattern"
                    done <<< "$patterns"
                fi

                echo "$current_output"
                return 0
                ;;
            reject)
                ui_warn "Implementation rejected by critic"
                _consensus_meta_set "$project_dir" "verdict" "reject"
                _consensus_meta_set "$project_dir" "iterations" "$iteration"
                _consensus_meta_set "$project_dir" "issues" "$(_parse_issues_json "$critique_output")"

                # Show issues
                _parse_issues "$critique_output" | while IFS= read -r issue; do
                    echo -e "  ${_RED}!${_RESET} $issue"
                done
                echo "$current_output"
                return 1
                ;;
            revise)
                if [[ $iteration -ge $CONSENSUS_MAX_ITERATIONS ]]; then
                    ui_warn "Max iterations reached — accepting current implementation"
                    _consensus_meta_set "$project_dir" "verdict" "revise"
                    _consensus_meta_set "$project_dir" "iterations" "$iteration"
                    _consensus_meta_set "$project_dir" "issues" "$(_parse_issues_json "$critique_output")"
                    echo "$current_output"
                    return 0
                fi

                # Get implementer to revise
                local impl_agent
                impl_agent="$(role_assign implementer)"
                _consensus_meta_set "$project_dir" "impl_agent" "$impl_agent"

                # Record memory: implementer got a revise
                memory_update_stats "$project_dir" "$impl_agent" "implementer" "revise"

                local revision_prompt
                revision_prompt="$(cat <<EOF
## Original Task
$original_task

## Your Previous Implementation
$current_output

## Critique Feedback
$critique_output

Revise your implementation based on the feedback. Output only the revised implementation.
EOF
)"
                local impl_system
                impl_system="$(role_prompt implementer)"

                ui_agent_output "$impl_agent" "implementer" "Revising based on feedback..."
                current_output="$(adapter_execute_capture "$impl_agent" "$impl_system" "$revision_prompt")"

                if [[ -z "$current_output" ]]; then
                    ui_warn "Implementer returned empty revision — keeping previous version"
                    current_output="$impl_output"
                fi
                ;;
        esac
    done

    _consensus_meta_set "$project_dir" "verdict" "accept"
    _consensus_meta_set "$project_dir" "iterations" "$iteration"
    echo "$current_output"
    return 0
}
