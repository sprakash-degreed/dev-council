# Council

Adaptive multi-agent development environment. Run `council dev` in any repo, give a high-level instruction, and let multiple AI agents collaboratively produce working code changes.

Council orchestrates Claude, Codex, Gemini, and Ollama — assigning dynamic roles (planner, implementer, critic, etc.) and coordinating execution with a critique/consensus loop.

## Quick Start

```sh
git clone https://github.com/council-dev/council.git
cd council
./council dev /path/to/your/project
```

Or install system-wide:

```sh
make install
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
# Start council in current directory
council dev

# Start in a specific repo
council dev /path/to/project

# List detected agents
council agent list

# Test a specific agent
council agent test claude
```

Once running, give natural language instructions:

```
> add caching to api requests
> fix the failing auth tests
> refactor the database layer to use connection pooling
```

Council will:
1. Analyze your repository (languages, deps, frameworks, structure)
2. Plan the implementation using a planner agent
3. Execute with an implementer agent
4. Review via a critic agent (up to 3 revision rounds)
5. Present results and optionally create a git branch

## How It Works

```
Developer intent
      |
  Repo Analysis ---- .council/project_model.json
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

## Project Structure

```
council/
├── council              # Main entry point
├── lib/
│   ├── util.sh          # Helpers (IDs, slugify, state)
│   ├── ui.sh            # Display (colors, gum, streaming)
│   ├── repo.sh          # Repo understanding engine
│   ├── agents.sh        # Agent discovery + registry
│   ├── roles.sh         # Role assignment + system prompts
│   ├── consensus.sh     # Critique/revision loop
│   └── runtime.sh       # Orchestration loop
├── adapters/
│   ├── claude.sh        # Claude CLI adapter
│   ├── codex.sh         # Codex CLI adapter
│   ├── gemini.sh        # Gemini CLI adapter
│   └── ollama.sh        # Ollama adapter
└── Makefile
```

## Configuration

Council is zero-config by default. Optional environment variables:

```sh
COUNCIL_DEBUG=1              # Enable debug output
COUNCIL_MAX_ITERATIONS=3     # Max critique/revision rounds
COUNCIL_OLLAMA_MODEL=llama3.2  # Ollama model to use
```

## Safety

- Never pushes directly to main — changes go to `council/<slug>` branches
- Asks for confirmation before executing plans
- Runs project tests before finalizing (when detectable)
- All state stays local in `.council/`

## License

MIT
