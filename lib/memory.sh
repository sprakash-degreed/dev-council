#!/usr/bin/env bash
# Kannan — Project Memory
# Persistent learning across sessions: decisions, patterns, agent performance

MEMORY_DIR="memory"
MEMORY_MAX_SESSIONS=5  # How many past sessions to include in context
KANNAN_GLOBAL_DIR="${KANNAN_GLOBAL_DIR:-$HOME/.kannan}"

# Initialize memory directories (project-local + global)
memory_init() {
    local dir="$1"
    mkdir -p "$dir/$KANNAN_DIR/$MEMORY_DIR"
    mkdir -p "$KANNAN_GLOBAL_DIR"
}

# Load memory context for injection into agent prompts
# Returns a text block with recent sessions, patterns, and agent insights
memory_load_context() {
    local dir="$1"
    local mem_dir="$dir/$KANNAN_DIR/$MEMORY_DIR"

    local has_content=0
    local context=""

    # Recent sessions (last N from sessions.jsonl)
    local sessions_file="$mem_dir/sessions.jsonl"
    if [[ -f "$sessions_file" ]] && has_cmd jq; then
        local recent
        recent="$(tail -n "$MEMORY_MAX_SESSIONS" "$sessions_file" 2>/dev/null)"
        if [[ -n "$recent" ]]; then
            has_content=1
            context+="### Recent Sessions
"
            while IFS= read -r line; do
                local ts intent verdict iterations issues
                ts="$(echo "$line" | jq -r '.ts // ""' 2>/dev/null)"
                intent="$(echo "$line" | jq -r '.intent // ""' 2>/dev/null)"
                verdict="$(echo "$line" | jq -r '.verdict // ""' 2>/dev/null)"
                iterations="$(echo "$line" | jq -r '.iterations // 0' 2>/dev/null)"
                issues="$(echo "$line" | jq -r '(.issues // [])[] | "  - [\(.severity)] \(.description)"' 2>/dev/null)"

                context+="- **$intent** → $verdict"
                [[ "$iterations" -gt 1 ]] && context+=" (${iterations} iterations)"
                context+="
"
                [[ -n "$issues" ]] && context+="$issues
"
            done <<< "$recent"
            context+="
"
        fi
    fi

    # Learned patterns
    local patterns_file="$mem_dir/patterns.md"
    if [[ -f "$patterns_file" ]]; then
        local patterns
        patterns="$(cat "$patterns_file" 2>/dev/null)"
        if [[ -n "$patterns" ]]; then
            has_content=1
            context+="### Learned Patterns
$patterns
"
        fi
    fi

    # Agent performance summary
    local stats_file="$mem_dir/agent_stats.json"
    if [[ -f "$stats_file" ]] && has_cmd jq; then
        local stats_summary
        stats_summary="$(jq -r '
            to_entries[] |
            .key as $agent |
            .value | to_entries[] |
            "\($agent) as \(.key): \(.value.runs) runs, \(.value.accept // 0) accepted, \(.value.revise // 0) revised, \(.value.reject // 0) rejected"
        ' "$stats_file" 2>/dev/null)"
        if [[ -n "$stats_summary" ]]; then
            has_content=1
            context+="### Agent Track Record
"
            while IFS= read -r line; do
                context+="- $line
"
            done <<< "$stats_summary"
        fi
    fi

    [[ $has_content -eq 1 ]] && echo "$context"
}

# Record a completed session to the append-only log
memory_record_session() {
    local dir="$1"
    local intent="$2"
    local roles_json="$3"      # JSON object: {"planner":"claude","implementer":"codex",...}
    local verdict="$4"
    local iterations="$5"
    local issues_json="$6"     # JSON array: [{"severity":"major","description":"..."}]
    local tokens="$7"
    local token_usage="${8:-}"  # JSON object: {"claude":{"in":N,"out":N,"calls":N},...}

    local mem_dir="$dir/$KANNAN_DIR/$MEMORY_DIR"
    local sessions_file="$mem_dir/sessions.jsonl"

    [[ -z "$intent" ]] && return

    # Default empty structures
    [[ -z "$roles_json" || "$roles_json" == "null" ]] && roles_json="{}"
    [[ -z "$issues_json" || "$issues_json" == "null" ]] && issues_json="[]"
    [[ -z "$verdict" ]] && verdict="accept"
    [[ -z "$iterations" ]] && iterations="1"
    [[ -z "$tokens" ]] && tokens="0"
    [[ -z "$token_usage" || "$token_usage" == "null" ]] && token_usage="{}"

    if has_cmd jq; then
        local entry
        entry="$(jq -n -c \
            --arg ts "$(now_ts)" \
            --arg intent "$intent" \
            --argjson roles "$roles_json" \
            --arg verdict "$verdict" \
            --argjson iterations "$iterations" \
            --argjson issues "$issues_json" \
            --argjson tokens "$tokens" \
            --argjson token_usage "$token_usage" \
            '{ts: $ts, intent: $intent, roles: $roles, verdict: $verdict, iterations: $iterations, issues: $issues, tokens: $tokens, token_usage: $token_usage}'
        )"

        # Write to project-local log
        echo "$entry" >> "$sessions_file"

        # Write to global log (with project path)
        local global_file="$KANNAN_GLOBAL_DIR/usage.jsonl"
        echo "$entry" | jq -c --arg project "$dir" '. + {project: $project}' >> "$global_file" 2>/dev/null
    fi
}

# Record a learned pattern (appends to patterns.md)
memory_record_pattern() {
    local dir="$1"
    local pattern="$2"

    [[ -z "$pattern" ]] && return

    local patterns_file="$dir/$KANNAN_DIR/$MEMORY_DIR/patterns.md"
    echo "- $pattern" >> "$patterns_file"
}

# Update agent stats after a consensus verdict
memory_update_stats() {
    local dir="$1"
    local agent="$2"
    local role="$3"
    local verdict="$4"   # accept|revise|reject

    [[ -z "$agent" || -z "$role" || -z "$verdict" ]] && return

    local stats_file="$dir/$KANNAN_DIR/$MEMORY_DIR/agent_stats.json"

    # Initialize if missing
    if [[ ! -f "$stats_file" ]]; then
        echo '{}' > "$stats_file"
    fi

    if has_cmd jq; then
        local tmp
        tmp="$(mktemp)"

        # Ensure the agent and role path exists, then increment
        jq --arg agent "$agent" --arg role "$role" --arg verdict "$verdict" '
            .[$agent] //= {} |
            .[$agent][$role] //= {"runs": 0, "accept": 0, "revise": 0, "reject": 0} |
            .[$agent][$role].runs += 1 |
            .[$agent][$role][$verdict] += 1
        ' "$stats_file" > "$tmp" 2>/dev/null && mv "$tmp" "$stats_file" || rm -f "$tmp"
    fi
}

# Suggest the best agent for a role based on historical stats
# Returns agent name or empty string (caller should use as advisory hint)
memory_suggest_agent() {
    local dir="$1"
    local role="$2"

    local stats_file="$dir/$KANNAN_DIR/$MEMORY_DIR/agent_stats.json"
    [[ ! -f "$stats_file" ]] && return

    if has_cmd jq; then
        # Pick agent with highest accept rate for this role (min 3 runs)
        jq -r --arg role "$role" '
            to_entries |
            map(select(.value[$role] != null and .value[$role].runs >= 3)) |
            map({agent: .key, rate: ((.value[$role].accept // 0) / .value[$role].runs)}) |
            sort_by(-.rate) |
            first | .agent // empty
        ' "$stats_file" 2>/dev/null
    fi
}

# Extract patterns from critic acceptance output
# Looks for lines that indicate learned conventions
_extract_patterns_from_critique() {
    local critique_output="$1"

    # Try to extract from JSON issues with "minor" severity (style observations)
    local json_block
    json_block="$(echo "$critique_output" | sed -n '/```json/,/```/p' | grep -v '```')"

    if [[ -n "$json_block" ]] && has_cmd jq; then
        echo "$json_block" | jq -r '
            (.issues // [])[] |
            select(.severity == "minor") |
            .description
        ' 2>/dev/null
    fi
}

# Pretty-print memory summary
memory_show() {
    local dir="$1"
    local mem_dir="$dir/$KANNAN_DIR/$MEMORY_DIR"

    echo ""
    echo -e "${_BOLD}Project Memory${_RESET}"
    ui_separator

    # Session count
    local sessions_file="$mem_dir/sessions.jsonl"
    if [[ -f "$sessions_file" ]]; then
        local count
        count="$(wc -l < "$sessions_file" | tr -d ' ')"
        local accepts revises rejects
        accepts="$(grep -c '"accept"' "$sessions_file" 2>/dev/null || echo 0)"
        revises="$(grep -c '"revise"' "$sessions_file" 2>/dev/null || echo 0)"
        rejects="$(grep -c '"reject"' "$sessions_file" 2>/dev/null || echo 0)"
        echo -e "  ${_BOLD}Sessions:${_RESET} $count total — ${_GREEN}$accepts accepted${_RESET}, ${_YELLOW}$revises revised${_RESET}, ${_RED}$rejects rejected${_RESET}"

        # Last 3 sessions
        echo -e "  ${_DIM}Recent:${_RESET}"
        tail -n 3 "$sessions_file" 2>/dev/null | while IFS= read -r line; do
            local ts intent verdict
            ts="$(echo "$line" | jq -r '.ts // ""' 2>/dev/null)"
            intent="$(echo "$line" | jq -r '.intent // ""' 2>/dev/null)"
            verdict="$(echo "$line" | jq -r '.verdict // ""' 2>/dev/null)"
            local vc
            case "$verdict" in
                accept) vc="$_GREEN" ;;
                revise) vc="$_YELLOW" ;;
                reject) vc="$_RED" ;;
                *)      vc="$_DIM" ;;
            esac
            echo -e "    ${_DIM}$ts${_RESET} $intent → ${vc}$verdict${_RESET}"
        done
    else
        echo -e "  ${_DIM}No sessions recorded yet${_RESET}"
    fi

    echo ""

    # Patterns
    local patterns_file="$mem_dir/patterns.md"
    if [[ -f "$patterns_file" ]]; then
        local pattern_count
        pattern_count="$(wc -l < "$patterns_file" | tr -d ' ')"
        echo -e "  ${_BOLD}Patterns:${_RESET} $pattern_count learned"
        while IFS= read -r line; do
            echo -e "    ${_CYAN}$line${_RESET}"
        done < "$patterns_file"
    else
        echo -e "  ${_DIM}No patterns learned yet${_RESET}"
    fi

    echo ""

    # Agent stats
    local stats_file="$mem_dir/agent_stats.json"
    if [[ -f "$stats_file" ]] && has_cmd jq; then
        echo -e "  ${_BOLD}Agent Performance:${_RESET}"
        jq -r '
            to_entries[] |
            .key as $agent |
            .value | to_entries[] |
            "    \($agent) → \(.key): \(.value.runs) runs (\(.value.accept // 0)✓ \(.value.revise // 0)↻ \(.value.reject // 0)✗)"
        ' "$stats_file" 2>/dev/null | while IFS= read -r line; do
            echo -e "$line"
        done
    else
        echo -e "  ${_DIM}No agent stats yet${_RESET}"
    fi

    echo ""
}

# Show cumulative token usage table across all sessions
memory_usage_table() {
    local dir="$1"
    local mem_dir="$dir/$KANNAN_DIR/$MEMORY_DIR"
    local sessions_file="$mem_dir/sessions.jsonl"

    echo ""
    echo -e "${_BOLD}Cumulative Token Usage${_RESET}"
    ui_separator

    if [[ ! -f "$sessions_file" ]]; then
        echo -e "  ${_DIM}No sessions recorded yet${_RESET}"
        echo ""
        return
    fi

    if ! has_cmd jq; then
        echo -e "  ${_DIM}jq required for usage table${_RESET}"
        echo ""
        return
    fi

    # Aggregate token_usage across all sessions
    local aggregated
    aggregated="$(jq -s -c '
        map(.token_usage // {}) |
        reduce .[] as $session ({};
            reduce ($session | to_entries[]) as $entry (.;
                .[$entry.key].in += ($entry.value.in // 0) |
                .[$entry.key].out += ($entry.value.out // 0) |
                .[$entry.key].calls += ($entry.value.calls // 0)
            )
        )
    ' "$sessions_file" 2>/dev/null)"

    if [[ -z "$aggregated" || "$aggregated" == "{}" || "$aggregated" == "null" ]]; then
        echo -e "  ${_DIM}No per-agent token data recorded yet${_RESET}"
        echo ""
        return
    fi

    # Count sessions
    local session_count
    session_count="$(wc -l < "$sessions_file" | tr -d ' ')"

    # Print table header
    printf "  ${_BOLD}%-12s %8s %10s %10s %10s${_RESET}\n" "Agent" "Calls" "Input" "Output" "Total"
    echo -e "  ${_DIM}────────────────────────────────────────────────────${_RESET}"

    # Print per-agent rows
    local grand_calls=0 grand_in=0 grand_out=0

    for agent in claude codex gemini ollama; do
        local calls in_tok out_tok
        calls="$(echo "$aggregated" | jq -r ".\"$agent\".calls // 0" 2>/dev/null)"
        in_tok="$(echo "$aggregated" | jq -r ".\"$agent\".in // 0" 2>/dev/null)"
        out_tok="$(echo "$aggregated" | jq -r ".\"$agent\".out // 0" 2>/dev/null)"

        [[ "$calls" == "0" || "$calls" == "null" ]] && continue

        local total=$((in_tok + out_tok))
        local ac="${AGENT_COLORS[$agent]:-$_RESET}"

        printf "  ${ac}%-12s${_RESET} %8s %10s %10s %10s\n" \
            "$agent" "$calls" "$in_tok" "$out_tok" "$total"

        grand_calls=$((grand_calls + calls))
        grand_in=$((grand_in + in_tok))
        grand_out=$((grand_out + out_tok))
    done

    echo -e "  ${_DIM}────────────────────────────────────────────────────${_RESET}"
    printf "  ${_BOLD}%-12s${_RESET} %8s %10s %10s %10s\n" \
        "Total" "$grand_calls" "$grand_in" "$grand_out" "$((grand_in + grand_out))"

    echo ""
    echo -e "  ${_DIM}Across $session_count session(s)${_RESET}"
    echo ""
}

# Show global token usage across all projects
memory_usage_global() {
    local global_file="$KANNAN_GLOBAL_DIR/usage.jsonl"

    echo ""
    echo -e "${_BOLD}Global Token Usage (all projects)${_RESET}"
    ui_separator

    if [[ ! -f "$global_file" ]]; then
        echo -e "  ${_DIM}No usage recorded yet${_RESET}"
        echo ""
        return
    fi

    if ! has_cmd jq; then
        echo -e "  ${_DIM}jq required for usage table${_RESET}"
        echo ""
        return
    fi

    local session_count
    session_count="$(wc -l < "$global_file" | tr -d ' ')"

    # --- Per-agent token table ---
    local aggregated
    aggregated="$(jq -s -c '
        map(.token_usage // {}) |
        reduce .[] as $session ({};
            reduce ($session | to_entries[]) as $entry (.;
                .[$entry.key].in += ($entry.value.in // 0) |
                .[$entry.key].out += ($entry.value.out // 0) |
                .[$entry.key].calls += ($entry.value.calls // 0)
            )
        )
    ' "$global_file" 2>/dev/null)"

    if [[ -n "$aggregated" && "$aggregated" != "{}" && "$aggregated" != "null" ]]; then
        printf "  ${_BOLD}%-12s %8s %10s %10s %10s${_RESET}\n" "Agent" "Calls" "Input" "Output" "Total"
        echo -e "  ${_DIM}────────────────────────────────────────────────────${_RESET}"

        local grand_calls=0 grand_in=0 grand_out=0

        for agent in claude codex gemini ollama; do
            local calls in_tok out_tok
            calls="$(echo "$aggregated" | jq -r ".\"$agent\".calls // 0" 2>/dev/null)"
            in_tok="$(echo "$aggregated" | jq -r ".\"$agent\".in // 0" 2>/dev/null)"
            out_tok="$(echo "$aggregated" | jq -r ".\"$agent\".out // 0" 2>/dev/null)"

            [[ "$calls" == "0" || "$calls" == "null" ]] && continue

            local total=$((in_tok + out_tok))
            local ac="${AGENT_COLORS[$agent]:-$_RESET}"

            printf "  ${ac}%-12s${_RESET} %8s %10s %10s %10s\n" \
                "$agent" "$calls" "$in_tok" "$out_tok" "$total"

            grand_calls=$((grand_calls + calls))
            grand_in=$((grand_in + in_tok))
            grand_out=$((grand_out + out_tok))
        done

        echo -e "  ${_DIM}────────────────────────────────────────────────────${_RESET}"
        printf "  ${_BOLD}%-12s${_RESET} %8s %10s %10s %10s\n" \
            "Total" "$grand_calls" "$grand_in" "$grand_out" "$((grand_in + grand_out))"
    fi

    echo ""

    # --- Per-project breakdown ---
    echo -e "  ${_BOLD}By Project${_RESET}"
    echo -e "  ${_DIM}────────────────────────────────────────────────────${_RESET}"

    jq -s -c '
        group_by(.project) |
        map({
            project: (.[0].project // "unknown"),
            sessions: length,
            tokens: (map(.tokens // 0) | add)
        }) |
        sort_by(-.tokens)
    ' "$global_file" 2>/dev/null | jq -r '.[] | "\(.project)\t\(.sessions)\t\(.tokens)"' 2>/dev/null | \
    while IFS=$'\t' read -r project sessions tokens; do
        local name
        name="$(basename "$project")"
        printf "  %-30s %4s session(s)  %10s tokens\n" "$name" "$sessions" "$tokens"
    done

    echo ""
    echo -e "  ${_DIM}$session_count session(s) total across all projects${_RESET}"
    echo ""
}

# Clear all memory (requires confirmation handled by caller)
memory_clear() {
    local dir="$1"
    local mem_dir="$dir/$KANNAN_DIR/$MEMORY_DIR"

    rm -f "$mem_dir/sessions.jsonl"
    rm -f "$mem_dir/patterns.md"
    rm -f "$mem_dir/agent_stats.json"

    ui_success "Memory cleared"
}
