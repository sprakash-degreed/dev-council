# CLAUDE.md — Council Development Guide

## What is this project?

Council is a shell-based multi-agent orchestrator. It coordinates AI coding agents (Claude, Codex, Gemini, Ollama) to collaboratively work on software projects. Written entirely in bash.

## Project Structure

- `council` — main entry point, sources all libs, defines CLI commands
- `lib/` — modular shell libraries (each file is sourced, not executed standalone)
  - `util.sh` — shared helpers (gen_id, slugify, state_get/set, council_init)
  - `ui.sh` — terminal output (colors, gum integration, agent-prefixed streaming)
  - `repo.sh` — repository analysis (3-phase: filesystem scan → dependency parsing → project model)
  - `agents.sh` — agent discovery via `command -v`, capability registry, adapter dispatch
  - `roles.sh` — role definitions, system prompts per role, role inference from task keywords
  - `consensus.sh` — critique/revision loop (critic reviews → verdict → revise or accept)
  - `runtime.sh` — main orchestration (decompose → execute → critique → patch)
- `adapters/` — one file per agent CLI, each exports a `<name>_execute()` function
- `.council/` — runtime state directory (gitignored), contains project_model.json and patches

## Key Conventions

- All lib files are sourced into the main `council` script — they share the same shell context
- Global associative arrays are used for registries (AGENTS_AVAILABLE, AGENT_CAPABILITIES, etc.)
- Agent adapters follow the pattern: `<agent>_execute "$system_prompt" "$user_prompt"` → stdout
- UI functions prefix all agent output with colored `[agent:role]` tags
- jq is required for JSON handling — always guard with `has_cmd jq` or `require_jq`
- The `COUNCIL_DIR` variable (`.council`) is used everywhere for state paths

## Testing

```sh
./council version          # Smoke test
./council agent list       # Check agent discovery
make check                 # Verify all dependencies
make test                  # Run version + agent list
```

## Adding a New Agent Adapter

1. Create `adapters/<name>.sh` with a `<name>_execute()` function
2. Add discovery check in `agents_discover()` in `lib/agents.sh`
3. Add capabilities in `_init_capabilities()` in `lib/agents.sh`
4. The adapter receives (system_prompt, user_prompt) and writes output to stdout

## Common Patterns

- `adapter_execute "$agent" "$system_prompt" "$user_prompt"` — run any agent by name
- `role_assign "$role"` — get the best available agent for a role
- `role_prompt "$role"` — get the system prompt for a role
- `repo_summary "$dir"` — get a text summary of the project for agent context
- `ui_agent_output "$agent" "$role" "$text"` — display agent output with colored prefix
