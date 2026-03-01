# GoClaw Wizard

**One-command installer for GoClaw AI gateway** — provisions a fully functional GoClaw stack on any Linux or macOS host with Docker.

## Quick Start

```bash
git clone https://github.com/therichardngai-code/goclaw-wizards.git
cd goclaw-wizards
bash wizard.sh
```

The interactive wizard walks you through 5 steps:

1. **LLM provider** — choose from 13 providers, enter API key
2. **Messaging channels** — pick one or more, enter credentials
3. **Agent identity** — name, purpose, personality, language
4. **Owner profile** — your name + language (so the agent knows you)
5. **Confirm** → stack launches

Working bot in under 3 minutes on a fresh host.

## What Is GoClaw Wizard?

A shell-based installer that drives the official [GoClaw](https://github.com/nextlevelbuilder/goclaw) Docker Compose overlays. It handles:

- **Zero manual config** — generates all secrets, env files, and compose arguments
- **LLM identity generation** — calls your chosen LLM to write the agent's personality files (SOUL.md, IDENTITY.md, USER.md)
- **Agent provisioning** — creates the agent and channels via GoClaw WebSocket RPC
- **Multi-stack support** — run isolated GoClaw instances on the same host with `--name`
- **Scriptable** — `--non-interactive` mode for CI/CD pipelines
- **Post-install tools** — `doctor`, `reseed-agent`, `add-agent`, `channels add`

## Repository Structure

```
goclaw-wizards/
├── wizard.sh                      # Entry point and argument parser
├── lib/                           # Shell library modules (15 scripts, ~2070 LOC)
│   ├── colors.sh                  # ANSI colors, spinner, banner UI
│   ├── detect.sh                  # OS and Docker detection
│   ├── deps.sh                    # Dependency validation with install hints
│   ├── wizard-ui.sh               # Interactive prompts (select, multiselect, text, secret)
│   ├── secrets.sh                 # Cross-platform secret storage (Keychain / secret-tool / file)
│   ├── ports.sh                   # Port allocation and conflict detection
│   ├── compose.sh                 # Docker Compose overlay builder
│   ├── stack.sh                   # Stack lifecycle: clone, env generation, health checks, state
│   ├── bootstrap.sh               # Agent provisioning, welcome message dispatch
│   ├── flow-data.sh               # Provider + channel arrays, lookup utilities
│   ├── flows.sh                   # QuickStart flow: step functions, launch sequence
│   ├── commands.sh                # All post-install commands (add-agent, reseed, channels, etc.)
│   ├── non-interactive.sh         # --non-interactive mode, --reset, status --all
│   ├── doctor.sh                  # Stack diagnostics and auto-repair
│   └── full-flow.sh               # Full configuration flow (advanced)
├── scripts/                       # Python utilities (~490 LOC, stdlib only)
│   ├── provision-agent.py         # GoClaw WebSocket RPC: create/delete/update agents & channels
│   └── identity-wizard.py        # LLM-powered SOUL.md / IDENTITY.md / USER.md generator
├── templates/                     # Fallback templates (~27 LOC)
│   ├── soul-default.md.tpl        # Fallback SOUL.md (used if LLM unavailable)
│   └── identity-default.md.tpl    # Fallback IDENTITY.md
└── docs/                          # Technical documentation
    ├── design.md                  # Full technical design
    ├── architecture-diagram.md    # System architecture diagrams
    └── feature-coverage.md        # Feature compatibility matrix
```

## LLM Providers

| Provider | Default Model |
|----------|--------------|
| Anthropic (Claude) | claude-sonnet-4-6 |
| OpenAI (GPT) | gpt-5.2 |
| Google (Gemini) | gemini-2.5-flash |
| OpenRouter | anthropic/claude-sonnet-4-6 |
| Groq | llama-3.3-70b-versatile |
| DeepSeek | deepseek-chat |
| MiniMax | MiniMax-M2 |
| Mistral | mistral-large-latest |
| xAI (Grok) | grok-3 |
| Cohere | command-a-03-2025 |
| Perplexity | sonar-pro |
| DashScope (Qwen) | qwen-max |
| Custom endpoint | — (OpenAI-compatible) |

## Messaging Channels

| Channel | Credential Required |
|---------|-------------------|
| Telegram | Bot token from @BotFather |
| Discord | Bot token from Dev Portal |
| Feishu / Lark | App ID + App Secret from open.feishu.cn |
| Zalo | OA token from oa.zalo.me |
| WhatsApp | Baileys bridge URL |

## Optional Features

| Flag | What It Adds |
|------|-------------|
| `ui` *(default)* | Web dashboard (React SPA via nginx) |
| `otel` | OpenTelemetry tracing + Jaeger UI |
| `sandbox` | Docker-based agent code execution sandbox |
| `tailscale` | Tailscale VPN overlay network access |

## Usage

### Install (Interactive)

```bash
bash wizard.sh
# or with a stack name and extra features:
bash wizard.sh install --name production --features ui,otel
```

### Non-Interactive / CI-CD

```bash
bash wizard.sh install --non-interactive --accept-risk \
  --name prod \
  --provider anthropic --api-key sk-ant-... \
  --channels telegram --telegram-token 123:abc... \
  --owner-ids 123456789 \
  --agent-name "Aria" --agent-purpose "Personal assistant" \
  --owner-name "Richard" --owner-language "English"
```

All flags also accept env vars — useful for secrets managers:

```bash
export GOCLAW_ANTHROPIC_API_KEY=sk-ant-...
export GOCLAW_TELEGRAM_TOKEN=123:abc...
export GOCLAW_OWNER_IDS=123456789
export GOCLAW_OWNER_NAME=Richard

bash wizard.sh install --non-interactive --accept-risk \
  --provider anthropic --channels telegram \
  --agent-name "Aria" --agent-purpose "Personal assistant"
```

### Agent Management

```bash
# Add a second agent to a running stack
bash wizard.sh add-agent --name default

# Regenerate agent identity in-place (no data loss — updates SOUL.md/IDENTITY.md only)
bash wizard.sh reseed-agent --name default

# Remove an agent
bash wizard.sh remove-agent --name default --agent-key aria

# Add a new channel to an existing agent
bash wizard.sh channels add --name default
```

### Stack Lifecycle

```bash
bash wizard.sh start   --name default
bash wizard.sh stop    --name default
bash wizard.sh restart --name default
bash wizard.sh upgrade --name default
bash wizard.sh uninstall --name default

bash wizard.sh status --name default
bash wizard.sh status --all          # all stacks on this host

bash wizard.sh logs --name default
```

### Diagnostics

```bash
bash wizard.sh doctor --name default           # check health
bash wizard.sh doctor --name default --repair  # auto-fix common issues
```

### Reset Options

```bash
# Keep data, clear config/secrets
bash wizard.sh install --name default --reset --reset-scope config

# Clear config + all agent files
bash wizard.sh install --name default --reset --reset-scope config+sessions

# Full wipe (removes stack directory)
bash wizard.sh install --name default --reset --reset-scope full
```

## Requirements

| Dependency | Minimum Version |
|-----------|----------------|
| Docker | 20.10+ (with Compose v2 plugin) |
| Git | 2.x |
| Python 3 | 3.8+ |
| OpenSSL | 1.1+ |
| curl | any |
| ss or netstat | any |

The wizard checks all dependencies on startup and prints OS-specific install commands for anything missing.

## State & Data

All persistent state is kept outside the wizard source tree in `~/.goclaw-wizard/`:

```
~/.goclaw-wizard/
└── stacks/
    └── {stack-name}/
        ├── .secrets          # Encrypted credentials (chmod 600)
        ├── state.json        # Ports, agent list, metadata
        ├── agents/
        │   └── {agent-key}/
        │       ├── SOUL.md       # Agent personality (LLM-generated or template)
        │       ├── IDENTITY.md   # Agent identity card
        │       └── USER.md       # Owner profile
        └── goclaw/           # Shallow clone of GoClaw source (for docker compose)
```

## Docker Compose Architecture

The wizard assembles Docker Compose overlay files from the official GoClaw repo. Each layer is optional and composable:

```
docker-compose.yml                  # Always: goclaw service skeleton, security hardening
  + docker-compose.managed.yml      # Mode: adds Postgres (pgvector), managed multi-tenant mode
  + docker-compose.selfservice.yml  # Feature ui: adds web dashboard (nginx + React SPA)
  + docker-compose.otel.yml         # Feature otel: adds Jaeger tracing
  + docker-compose.sandbox.yml      # Feature sandbox: enables agent code execution
  + docker-compose.tailscale.yml    # Feature tailscale: Tailscale VPN overlay
```

Default install (managed + ui) produces 3 containers:

```
goclaw-{name}-postgres-1    Postgres (pgvector) — agent/user storage
goclaw-{name}-goclaw-1      Gateway API + WebSocket RPC
goclaw-{name}-goclaw-ui-1   Web dashboard (port auto-assigned ~3010+)
```

## Implementation Status

All phases complete and end-to-end tested.

| Component | Status |
|-----------|--------|
| Core shell library (15 modules) | ✅ Complete |
| Docker Compose orchestration | ✅ Complete |
| Agent provisioning (WS Protocol v3) | ✅ Complete |
| LLM identity generation + template fallback | ✅ Complete |
| QuickStart flow | ✅ Complete |
| Full configuration flow | ✅ Complete |
| Stack management commands | ✅ Complete |
| Doctor / diagnostics | ✅ Complete |
| Non-interactive / CI mode | ✅ Complete |
| `reseed-agent` (non-destructive identity update) | ✅ Complete |

## Code Statistics

```
wizard.sh (entry point):    162 lines
lib/ (15 shell modules):   ~2070 lines
scripts/ (2 Python files):  ~490 lines
templates/:                   27 lines
────────────────────────────────────
Total:                      ~2750 lines
```

## Related

- **[GoClaw](https://github.com/nextlevelbuilder/goclaw)** — the gateway this wizard installs
- **[docs/design.md](./docs/design.md)** — complete technical specification
- **[docs/architecture-diagram.md](./docs/architecture-diagram.md)** — system design diagrams
- **[docs/feature-coverage.md](./docs/feature-coverage.md)** — feature compatibility matrix

## License

Same as GoClaw — see [parent repository](https://github.com/nextlevelbuilder/goclaw).

---

**Repository**: https://github.com/therichardngai-code/goclaw-wizards
