# Kannan

Adaptive multi-agent development environment. Named after Krishna (Kannan in Tamil), the divine strategist and guide who orchestrated the greatest heroes to work together.

Run `kannan dev` in any repo, give a high-level instruction, and let multiple AI agents collaboratively produce working code changes.

Kannan orchestrates Claude, Codex, Gemini, and Ollama — assigning dynamic roles (planner, implementer, critic, etc.) and coordinating execution with a critique/consensus loop.

## Quick Start

```sh
git clone https://github.com/chaoticfly/dev-council.git
cd dev-council
make install    # installs to ~/.local/bin (no sudo)
kannan dev /path/to/your/project
```

Or run directly without installing:

```sh
./kannan dev /path/to/your/project
```

## Requirements

**Required:**
- bash 4+
- [jq](https://jqlang.github.io/jq/)

**At least one agent CLI:**
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — `claude`
- [Codex CLI](https://github.com/openai/codex) — `codex`
- [Gemini CLI](https://github.com/google-gemini/gemini-cli) — `gemini`
- [Ollama](https://ollama.com) — `ollama`

**Optional:**
- [gum](https://github.com/charmbracelet/gum) — enhanced terminal UI
- git — for branch creation and patch management

Check your setup:

```sh
make check
```

## Usage

```sh
# Start kannan in current directory
kannan dev

# Start in a specific repo
kannan dev /path/to/project

# List detected agents
kannan agent list

# Test a specific agent
kannan agent test claude
```

Once running, give natural language instructions:

```
> add caching to api requests
> fix the failing auth tests
> refactor the database layer to use connection pooling
```

Kannan will:
1. Analyze your repository (languages, deps, frameworks, structure)
2. Plan the implementation using a planner agent
3. Execute with an implementer agent
4. Review via a critic agent (up to 3 revision rounds)
5. Present results and optionally create a git branch

## How It Works

```
Developer intent
      |
  Repo Analysis ---- .kannan/project_model.json
      |
  Task Decomposition (planner agent)
      |
  Role Assignment (best agent per task)
      |
  Implementation (implementer agent)
      |
  Critique Loop (critic agent reviews, implementer revises)
      |
  Verification (optional: run tests)
      |
  Output (branch / patch)
```

### Roles

Roles are assigned dynamically per task — agents don't permanently own roles:

| Role | Purpose | Required Capability |
|------|---------|-------------------|
| Planner | Break intent into tasks | plan |
| Architect | Evaluate design decisions | plan |
| Implementer | Write code changes | code |
| Critic | Review implementation | review |
| Debugger | Diagnose issues | debug |
| Tester | Write and run tests | test |
| Verifier | Final validation | code |

### Agent Capabilities

| Agent | Capabilities |
|-------|-------------|
| Claude | code, review, plan, test, debug, general |
| Codex | code, test, debug |
| Gemini | code, review, plan, general |
| Ollama | review, plan, general |

## Installation

```sh
# Option 1: Run the installer (no sudo needed)
./install.sh

# Option 2: make install (defaults to ~/.local)
make install

# Option 3: System-wide (requires sudo)
sudo make install PREFIX=/usr/local

# Option 4: Run directly from the repo
./kannan dev
```

The installer puts the binary at `~/.local/bin/kannan`. If `~/.local/bin` isn't in your PATH, it'll tell you what to add.

To uninstall:

```sh
./install.sh uninstall
# or
make uninstall
```

## Project Structure

```
kannan/
├── kannan               # Main entry point
├── install.sh           # Cross-platform installer
├── lib/
│   ├── util.sh          # Helpers (IDs, slugify, state, token tracking)
│   ├── ui.sh            # Display (colors, gum, streaming)
│   ├── repo.sh          # Repo understanding engine
│   ├── agents.sh        # Agent discovery + registry
│   ├── roles.sh         # Role assignment + system prompts
│   ├── consensus.sh     # Critique/revision loop
│   ├── config.sh        # Config loader (.kannan/config.json)
│   ├── memory.sh        # Project memory (sessions, patterns, stats)
│   └── runtime.sh       # Orchestration loop
├── adapters/
│   ├── claude.sh        # Claude CLI adapter
│   ├── codex.sh         # Codex CLI adapter
│   ├── gemini.sh        # Gemini CLI adapter
│   └── ollama.sh        # Ollama adapter
└── Makefile
```

## Configuration

Kannan is zero-config by default — it discovers agents and assigns roles dynamically. For more control, create a `.kannan/config.json` in your project:

```sh
kannan config init
```

This generates a starter config:

```json
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
```

### Pinning Roles to Agents

Set an agent name in `roles` to always use that agent for a role. Leave empty for dynamic assignment.

```json
{
  "roles": {
    "planner": "claude",
    "implementer": "codex",
    "critic": "gemini"
  }
}
```

With this config, Claude always plans, Codex always implements, and Gemini always reviews. Unset roles (architect, debugger, tester, verifier) are assigned dynamically based on capability matching.

If a pinned agent isn't available, kannan warns and falls back to dynamic assignment.

### Custom Agent Prompts

Add custom instructions that get prepended to every prompt sent to an agent:

```json
{
  "agent_prompts": {
    "claude": "Always use TypeScript. Prefer functional patterns over classes.",
    "codex": "Keep changes minimal. Do not refactor surrounding code."
  }
}
```

### Ollama Model

Override the default Ollama model (defaults to `llama3.2`):

```json
{
  "ollama_model": "mistral"
}
```

Also configurable via environment variable: `KANNAN_OLLAMA_MODEL=mistral`

### Max Iterations

Control how many critique/revision rounds the consensus loop runs (default: 3):

```json
{
  "max_iterations": 5
}
```

### Environment Variables

These work without a config file and override config values:

```sh
KANNAN_DEBUG=1                  # Enable debug output
KANNAN_MAX_ITERATIONS=3         # Max critique/revision rounds
KANNAN_OLLAMA_MODEL=llama3.2    # Ollama model to use
KANNAN_GLOBAL_DIR=~/.kannan     # Global state directory
```

## Memory

Kannan remembers past sessions and gets smarter over time for each project. Memory is stored in `.kannan/memory/` and includes:

- **Sessions log** — what was tried, what got accepted/rejected, and why
- **Learned patterns** — coding conventions discovered by the critic
- **Agent stats** — which agent performs best at which role

Agents automatically see recent memory in their prompts, so they avoid repeating past mistakes and follow established patterns.

```sh
# View project memory
kannan memory show

# View global token usage across all projects
kannan usage global

# View project-local token usage
kannan usage

# Clear project memory
kannan memory clear

# Clear global usage log
kannan usage clear
```

## Safety

- Never pushes directly to main — changes go to `kannan/<slug>` branches
- Asks for confirmation before executing plans
- Runs project tests before finalizing (when detectable)
- All state stays local in `.kannan/`

## License

MIT
