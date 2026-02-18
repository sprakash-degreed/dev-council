#!/usr/bin/env bash
# Council — Runtime Orchestration
# The main execution loop: intent → plan → execute → critique → patch

# Record session to memory after pipeline completes
_runtime_record_memory() {
    local project_dir="$1"
    local intent="$2"

    local verdict iterations issues_json tokens
    verdict="$(consensus_meta_get "$project_dir" "verdict")"
    iterations="$(consensus_meta_get "$project_dir" "iterations")"
    issues_json="$(consensus_meta_get "$project_dir" "issues")"
    tokens="$(tokens_total)"

    [[ -z "$verdict" ]] && verdict="accept"
    [[ -z "$iterations" ]] && iterations="1"
    [[ -z "$issues_json" || "$issues_json" == "" ]] && issues_json="[]"

    # Build roles JSON from what we can determine
    local planner_agent impl_agent critic_agent
    planner_agent="$(role_assign planner)"
    impl_agent="$(consensus_meta_get "$project_dir" "impl_agent")"
    critic_agent="$(consensus_meta_get "$project_dir" "critic_agent")"
    [[ -z "$impl_agent" ]] && impl_agent="$(role_assign implementer)"

    local roles_json="{}"
    if has_cmd jq; then
        roles_json="$(jq -n -c \
            --arg planner "$planner_agent" \
            --arg implementer "$impl_agent" \
            --arg critic "$critic_agent" \
            '{planner: $planner, implementer: $implementer, critic: $critic} | with_entries(select(.value != ""))'
        )"
    fi

    # Capture per-agent token breakdown
    local token_usage
    token_usage="$(tokens_snapshot_json)"

    memory_record_session "$project_dir" "$intent" "$roles_json" "$verdict" "$iterations" "$issues_json" "$tokens" "$token_usage"

    # Also record implementer stats on final verdict
    if [[ -n "$impl_agent" && -n "$verdict" ]]; then
        memory_update_stats "$project_dir" "$impl_agent" "implementer" "$verdict"
    fi
    if [[ -n "$planner_agent" ]]; then
        memory_update_stats "$project_dir" "$planner_agent" "planner" "$verdict"
    fi
}

# Decompose user intent into tasks using a planner agent
runtime_decompose() {
    local project_dir="$1"
    local intent="$2"

    local planner_agent
    planner_agent="$(role_assign planner)"

    if [[ -z "$planner_agent" ]]; then
        # No planner available — treat entire intent as single task
        echo "1. $intent"
        return
    fi

    local system_prompt
    system_prompt="$(role_prompt planner)"
    local user_prompt
    user_prompt="$(role_build_prompt planner "$project_dir" "$intent")"

    ui_agent_output "$planner_agent" "planner" "Breaking down task..."
    echo ""

    local plan
    plan="$(adapter_execute_capture "$planner_agent" "$system_prompt" "$user_prompt")"

    if [[ -z "$plan" ]]; then
        ui_warn "Planner returned empty response — treating as single task"
        echo "1. $intent"
        return
    fi

    echo "$plan"
}

# Execute a single task with the appropriate role/agent
runtime_execute_task() {
    local project_dir="$1"
    local task_description="$2"

    local role
    role="$(role_infer "$task_description")"
    local agent
    agent="$(role_assign "$role")"

    if [[ -z "$agent" ]]; then
        ui_error "No agent available for role: $role"
        return 1
    fi

    ui_agent_output "$agent" "$role" "Working on: $task_description"
    echo ""

    local system_prompt
    system_prompt="$(role_prompt "$role")"
    local user_prompt
    user_prompt="$(role_build_prompt "$role" "$project_dir" "$task_description")"

    # Add relevant file contents to context
    local model_file="$project_dir/$COUNCIL_DIR/project_model.json"
    if [[ -f "$model_file" ]]; then
        local relevant_files
        relevant_files="$(jq -r '.entry_points[]? // empty' "$model_file" 2>/dev/null)"
        if [[ -n "$relevant_files" ]]; then
            user_prompt+="

## Key Files
"
            while IFS= read -r f; do
                if [[ -f "$project_dir/$f" ]]; then
                    local content
                    content="$(head -100 "$project_dir/$f")"
                    user_prompt+="
### $f
\`\`\`
$content
\`\`\`
"
                fi
            done <<< "$relevant_files"
        fi
    fi

    local output
    output="$(adapter_execute_capture "$agent" "$system_prompt" "$user_prompt")"

    if [[ -z "$output" ]]; then
        ui_error "Agent returned empty response"
        return 1
    fi

    # Display output
    echo "$output" | ui_stream_agent "$agent" "$role"
    echo ""

    # Return output for consensus
    echo "$output"
}

# Create a git branch and apply changes
runtime_create_patch() {
    local project_dir="$1"
    local intent="$2"
    local output="$3"

    if [[ ! -d "$project_dir/.git" ]]; then
        ui_warn "Not a git repo — saving output to .council/patches/ instead"
        local patch_file
        patch_file="$project_dir/$COUNCIL_DIR/patches/$(slugify "$intent")-$(date +%s).md"
        echo "$output" > "$patch_file"
        ui_info "Output saved to: $patch_file"
        return
    fi

    local branch_name="council/$(slugify "$intent")-$(date +%s)"

    ui_info "Creating branch: $branch_name"
    git -C "$project_dir" checkout -b "$branch_name" 2>/dev/null || {
        ui_warn "Could not create branch — saving to patches directory"
        local patch_file
        patch_file="$project_dir/$COUNCIL_DIR/patches/$(slugify "$intent")-$(date +%s).md"
        echo "$output" > "$patch_file"
        ui_info "Output saved to: $patch_file"
        return
    }

    # Save the council output as a reference
    local patch_file="$project_dir/$COUNCIL_DIR/patches/$(slugify "$intent").md"
    mkdir -p "$(dirname "$patch_file")"
    cat > "$patch_file" <<EOF
# Council Output: $intent
Generated: $(now_ts)

$output
EOF

    ui_success "Changes prepared on branch: $branch_name"
    ui_info "Review with: git diff main...$branch_name"
}

# Run verification (tests) if possible
runtime_verify() {
    local project_dir="$1"
    local model_file="$project_dir/$COUNCIL_DIR/project_model.json"

    if [[ ! -f "$model_file" ]]; then
        return 0
    fi

    local test_cmd
    test_cmd="$(jq -r '.test_command // ""' "$model_file" 2>/dev/null)"

    if [[ -z "$test_cmd" ]]; then
        ui_info "No test command detected — skipping verification"
        return 0
    fi

    if ui_confirm "Run tests ($test_cmd)?"; then
        ui_phase "Running verification..."
        if (cd "$project_dir" && eval "$test_cmd"); then
            ui_success "Tests passed"
            return 0
        else
            ui_warn "Tests failed"
            return 1
        fi
    fi
    return 0
}

# Main interactive loop
runtime_loop() {
    local project_dir="$1"

    while true; do
        local intent
        intent="$(ui_prompt "What would you like to do?")"

        # Handle exit commands
        case "$intent" in
            ""|quit|exit|q)
                ui_info "Goodbye!"
                break
                ;;
        esac

        ui_separator
        ui_phase "Processing: $intent"
        echo ""

        # Step 1: Decompose intent into tasks
        ui_task_status "running" "Planning"
        local plan
        plan="$(runtime_decompose "$project_dir" "$intent")"

        if [[ -z "$plan" ]]; then
            ui_error "Could not decompose intent"
            continue
        fi

        echo ""
        echo -e "${_BOLD}Plan:${_RESET}"
        echo "$plan"
        echo ""

        if ! ui_confirm "Proceed with this plan?"; then
            ui_info "Skipped"
            continue
        fi

        ui_task_status "done" "Planning"

        # Step 2: Execute tasks
        ui_task_status "running" "Implementing"
        local implementation
        implementation="$(runtime_execute_task "$project_dir" "$intent

Plan:
$plan")"

        if [[ $? -ne 0 || -z "$implementation" ]]; then
            ui_task_status "failed" "Implementing"
            ui_error "Implementation failed"
            continue
        fi
        ui_task_status "done" "Implementing"

        # Step 3: Critique/consensus loop
        ui_task_status "running" "Reviewing"
        local final_output
        final_output="$(consensus_run "$project_dir" "$implementation" "$intent")"
        local consensus_result=$?
        ui_task_status "done" "Reviewing"

        if [[ $consensus_result -ne 0 ]]; then
            ui_warn "Implementation was rejected by critic"
            if ! ui_confirm "Apply anyway?"; then
                ui_info "Discarded"
                continue
            fi
        fi

        # Step 4: Present results
        ui_separator
        ui_phase "Results"
        echo ""
        echo "$final_output"
        echo ""

        # Step 5: Optionally create patch/branch
        if ui_confirm "Create a branch with these changes?"; then
            runtime_create_patch "$project_dir" "$intent" "$final_output"
        fi

        # Step 6: Optionally verify
        runtime_verify "$project_dir"

        # Step 7: Record session to memory
        _runtime_record_memory "$project_dir" "$intent"

        # Step 8: Show token usage
        ui_token_summary

        ui_separator
        echo ""
    done
}

# Single-shot execution (non-interactive, for -p flag)
runtime_once() {
    local project_dir="$1"
    local intent="$2"

    ui_separator
    ui_phase "Processing: $intent"
    echo ""

    # Step 1: Decompose
    ui_task_status "running" "Planning"
    local plan
    plan="$(runtime_decompose "$project_dir" "$intent")"

    if [[ -z "$plan" ]]; then
        ui_error "Could not decompose intent"
        return 1
    fi

    echo ""
    echo -e "${_BOLD}Plan:${_RESET}"
    echo "$plan"
    echo ""
    ui_task_status "done" "Planning"

    # Step 2: Execute
    ui_task_status "running" "Implementing"
    local implementation
    implementation="$(runtime_execute_task "$project_dir" "$intent

Plan:
$plan")"

    if [[ $? -ne 0 || -z "$implementation" ]]; then
        ui_task_status "failed" "Implementing"
        ui_error "Implementation failed"
        ui_token_summary
        return 1
    fi
    ui_task_status "done" "Implementing"

    # Step 3: Critique
    ui_task_status "running" "Reviewing"
    local final_output
    final_output="$(consensus_run "$project_dir" "$implementation" "$intent")"
    local consensus_result=$?
    ui_task_status "done" "Reviewing"

    # Step 4: Present results
    ui_separator
    ui_phase "Results"
    echo ""
    echo "$final_output"
    echo ""

    # Step 5: Record session to memory
    _runtime_record_memory "$project_dir" "$intent"

    # Step 6: Token usage
    ui_token_summary

    return $consensus_result
}
