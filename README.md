# GoClaw Wizard

**One-command installer for GoClaw AI gateway** — provisions a fully functional GoClaw stack on any Linux or macOS host with Docker.

## Quick Start

```bash
# Clone the repo
git clone https://github.com/nextlevelbuilder/goclaw-wizards.git
cd goclaw-wizards

# Run wizard (coming soon)
bash wizard.sh
```

## What is GoClaw Wizard?

The GoClaw Wizard simplifies deploying GoClaw, a multi-channel AI gateway, by:

- **Zero manual config** — Interactive wizard generates all Docker Compose files
- **Multi-stack support** — Run isolated GoClaw instances on the same host
- **All channels built-in** — Telegram, Discord, Feishu/Lark, Zalo, WhatsApp
- **Optional features** — Web dashboard, observability (Jaeger), Docker sandbox, Tailscale VPN
- **Scriptable mode** — CI/CD friendly `--non-interactive` flag
- **Post-install diagnostics** — Built-in `doctor` command for health checks

## Repository Structure

```
goclaw-wizards/
├── README.md                    # This file
├── wizard.sh                    # Entry point (coming soon)
├── lib/
│   ├── colors.sh               # ANSI colors, spinner, banner UI
│   ├── detect.sh               # OS & Docker detection
│   ├── deps.sh                 # Dependency validation
│   ├── ports.sh                # Port allocation & conflict detection
│   ├── secrets.sh              # Cross-platform secrets storage
│   └── wizard-ui.sh            # Interactive prompts
├── scripts/                     # Python utilities (coming soon)
│   ├── identity-wizard.py       # LLM-based agent identity generator
│   └── provision-agent.py       # GoClaw WebSocket RPC provisioning
├── templates/                   # Template files (coming soon)
│   ├── soul-default.md.tpl
│   └── identity-default.md.tpl
└── docs/
    ├── design.md               # Full technical design (v2.0)
    ├── architecture-diagram.md # System architecture
    └── feature-coverage.md     # Feature compatibility matrix
```

## Features

### Core
- ✅ Interactive QuickStart (3 inputs, working bot in <3 min)
- ✅ Full configuration flow (all options exposed)
- ✅ Named multi-stack deployments
- ✅ Automatic port allocation & conflict detection
- ✅ Cross-platform secret storage (macOS Keychain / Linux secret-tool / fallback)

### Stack Management
- ✅ Start, stop, restart, upgrade, uninstall
- ✅ Add/remove agents post-deployment
- ✅ Add channels to existing agents
- ✅ Stack health diagnostics (`doctor` command)

### Messaging Channels
- Telegram
- Discord
- Feishu / Lark
- Zalo
- WhatsApp

### Optional Features
- Web dashboard (port 3000+)
- Observability / Jaeger tracing
- Docker sandbox for code execution
- Tailscale VPN remote access

### LLM Providers
- Anthropic (Claude)
- OpenAI (GPT)
- Google (Gemini)
- OpenRouter (100+ models)
- Groq, DeepSeek, MiniMax, Mistral, xAI, Cohere, Perplexity, Custom

## Usage

### QuickStart (Interactive, Recommended)

```bash
bash wizard.sh
```

Only asks:
1. LLM provider + API key
2. Messaging channel(s) + credentials
3. Agent name + purpose

Sensible defaults for everything else.

### Full Configuration

```bash
bash wizard.sh --flow full
```

Exposes every option: mode, features, owner profile, custom ports, etc.

### Named Stack

```bash
bash wizard.sh --name production --features ui,otel
```

Run multiple isolated GoClaw instances on one host.

### Scripted / CI-CD

```bash
GOCLAW_ANTHROPIC_API_KEY=sk-ant-... \
GOCLAW_TELEGRAM_TOKEN=123:abc... \
  bash wizard.sh --non-interactive --accept-risk \
    --provider anthropic \
    --channels telegram \
    --owner-ids 123456789 \
    --agent-name "Aria"
```

### Stack Management

```bash
# Add another agent to running stack
bash wizard.sh --name production add-agent

# Add new channel to existing agent
bash wizard.sh --name production channels add --agent-key aria

# Check health / diagnose issues
bash wizard.sh doctor
bash wizard.sh doctor --repair

# View logs
bash wizard.sh logs goclaw
bash wizard.sh logs postgres

# Upgrade all services
bash wizard.sh --name production upgrade

# Uninstall stack
bash wizard.sh --name production uninstall
```

## Requirements

- **Docker**: v20.10+ (with Compose v2 plugin)
- **Git**: 2.x
- **OpenSSL**: 1.1+
- **Python3**: 3.8+
- **curl**, **ss** or **netstat**

The wizard will check all dependencies and provide OS-specific install commands if any are missing.

## State & Configuration

All state stored in `~/.goclaw-wizard/`:

```
~/.goclaw-wizard/
├── stacks/
│   ├── default/
│   │   ├── .secrets              # Encrypted credentials (chmod 600)
│   │   ├── state.json            # Stack metadata
│   │   ├── agents/               # Agent SOUL.md, IDENTITY.md
│   │   └── goclaw/               # Shallow GoClaw source clone
│   └── {stack-name}/             # Additional stacks
└── wizard.log                     # Diagnostic log
```

## Documentation

- **[design.md](./docs/design.md)** — Complete technical specification (v2.0)
- **[architecture-diagram.md](./docs/architecture-diagram.md)** — System design diagrams
- **[feature-coverage.md](./docs/feature-coverage.md)** — Feature compatibility matrix

## Implementation Status

| Phase | Status |
|-------|--------|
| Phase 1 — Core QuickStart (MVP) | 🔨 In Progress |
| Phase 2 — Full Flow + All Channels | ⏳ Planned |
| Phase 3 — Optional Features | ⏳ Planned |
| Phase 4 — Stack Management | ⏳ Planned |
| Phase 5 — Doctor + Non-Interactive | ⏳ Planned |
| Phase 6 — Upgrade + Polish | ⏳ Planned |

## Contributing

This is part of the [GoClaw](https://github.com/nextlevelbuilder/goclaw) project.

## License

Same as GoClaw (see parent repo).

---

**Status**: Actively developed  
**Latest Design**: v2.0 (2026-03-01)
