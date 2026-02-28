# GoClaw Wizard — System Design

**Version:** 2.0
**Date:** 2026-03-01
**Target:** `goclaw-wizards/` — Self-contained one-command installer for GoClaw

---

## 1. Overview

The GoClaw Wizard is a single-command installer that provisions a fully functional GoClaw AI gateway stack on any Linux or macOS host with Docker. It wraps GoClaw's official Docker Compose overlays with an opinionated, interactive setup flow that handles secrets, stack orchestration, agent identity, channel wiring, and multi-stack port management automatically.

**Install command (target UX):**
```bash
curl -fsSL https://raw.githubusercontent.com/nextlevelbuilder/goclaw/main/goclaw-wizards/wizard.sh | bash
```

Or from a cloned repo:
```bash
bash goclaw-wizards/wizard.sh
```

**Key design principles:**
- Zero manual compose file editing — wizard generates all configuration
- Uses GoClaw's **official compose overlays** directly (no reimplementation)
- Two modes: **QuickStart** (sensible defaults, 3 inputs) and **Full** (every option exposed)
- Fully **scriptable** via flags + env vars (`--non-interactive`)
- Named stacks for multiple isolated deployments on one host
- All optional features (OTel, Sandbox, Tailscale, UI) selectable at install time
- **`wizard.sh doctor`** for post-install diagnostics and repair
- Inline **help notes** per channel/provider — no tab-switching required
- Cross-platform secrets storage (macOS Keychain / Linux secret-tool / `.secrets` fallback)
- Full upgrade support via GoClaw's native `upgrade` command

---

## 2. Repository Structure

```
goclaw-wizards/
├── wizard.sh                        # SINGLE ENTRY POINT — all operations
├── lib/
│   ├── colors.sh                    # ANSI color output + banner + spinner + note box
│   ├── detect.sh                    # OS, arch, distro, Docker group detection
│   ├── deps.sh                      # Dependency checks (docker, git, openssl, python3, curl, ss)
│   ├── secrets.sh                   # Cross-platform secret read/write (keychain/secret-tool/.secrets)
│   ├── wizard-ui.sh                 # Interactive prompts: ask, ask_secret, ask_choice,
│   │                                #   multiselect, confirm, note, progress, cancel-trap
│   ├── ports.sh                     # Port discovery, block allocation, conflict detection
│   ├── compose.sh                   # Overlay list builder + docker compose up/down/restart/logs
│   ├── stack.sh                     # Stack lifecycle: install, start, stop, status, upgrade, uninstall
│   ├── bootstrap.sh                 # Agent provisioning + channel config post-start
│   └── doctor.sh                    # Health checks, config validation, security audit, repair
├── scripts/
│   ├── identity-wizard.py           # LLM-powered identity generator (SOUL.md + IDENTITY.md)
│   └── provision-agent.py           # GoClaw WS RPC: create/delete agents + channel instances
├── templates/
│   ├── soul-default.md.tpl          # Fallback SOUL.md template (used if LLM unavailable)
│   └── identity-default.md.tpl      # Fallback IDENTITY.md template
└── docs/
    ├── design.md                    # This document
    ├── architecture-diagram.md      # Visual diagrams
    └── feature-coverage.md          # Full GoClaw feature matrix
```

---

## 3. Command Interface

```
wizard.sh [OPTIONS] [COMMAND]

COMMANDS (default: install)
  install           First-time install (default when no command given)
  add-agent         Add a new agent / bot to an existing running stack
  remove-agent      Remove an agent and its channel instances
  channels add      Add a new channel to an existing agent
  start             Start a stopped stack
  stop              Stop a running stack (volumes preserved)
  restart           Restart stack services
  upgrade           Pull latest GoClaw + run DB migrations + rebuild
  status            Show stack health, service list, and agent summary
  logs [SERVICE]    Tail logs (goclaw | postgres | ui | jaeger; default: goclaw)
  doctor            Diagnose and optionally repair config/security issues
  uninstall         Stop stack + optionally wipe volumes and state

OPTIONS
  --name STACK      Stack name (default: "default")
                    Multiple named stacks run isolated on the same host
  --flow FLOW       Wizard flow: quickstart | full (default: quickstart)
  --mode MODE       Deployment mode: standalone | managed (default: managed)
  --features LIST   Comma-separated optional features: ui, otel, sandbox, tailscale
                    (QuickStart enables ui by default; Full prompts interactively)
  --agent-key KEY   Agent key (used with remove-agent)
  --non-interactive Run without prompts; all values from flags/env vars
  --accept-risk     Required with --non-interactive (acknowledges agent power)
  --reset           Wipe config + sessions before install (preserves secrets)
  --reset-scope S   Reset scope: config | config+sessions | full
  --yes             Accept all defaults / skip confirmations
  --help            Show usage

NON-INTERACTIVE FLAGS (used with --non-interactive)
  --provider PROV   LLM provider: anthropic|openai|gemini|openrouter|groq|deepseek|
                    minimax|mistral|xai|cohere|perplexity|custom
  --api-key KEY     Provider API key (or set GOCLAW_<PROVIDER>_API_KEY env var)
  --model MODEL     Override default model for provider
  --channels LIST   Comma-separated channels: telegram,discord,lark,zalo,whatsapp
  --telegram-token  Telegram bot token (or GOCLAW_TELEGRAM_TOKEN env var)
  --discord-token   Discord bot token (or GOCLAW_DISCORD_TOKEN env var)
  --lark-app-id     Feishu/Lark App ID
  --lark-app-secret Feishu/Lark App Secret
  --zalo-token      Zalo token
  --whatsapp-url    WhatsApp bridge URL
  --owner-ids IDS   Comma-separated owner user IDs for all channels
  --agent-name NAME Agent display name
  --agent-purpose P Agent purpose/role description
  --agent-personality P Agent personality description
  --gateway-port P  Override API port (default: auto-allocated)
  --gateway-token T Use specific gateway token (default: auto-generated)
  --encryption-key K Use specific encryption key (default: auto-generated)

EXAMPLES
  # QuickStart (interactive, recommended defaults)
  bash wizard.sh

  # Full configuration (all options exposed)
  bash wizard.sh --flow full

  # Named stack with observability enabled
  bash wizard.sh --name production --features ui,otel

  # Fully scripted (CI/CD friendly)
  GOCLAW_ANTHROPIC_API_KEY=sk-ant-... \
  GOCLAW_TELEGRAM_TOKEN=1234:abc... \
    bash wizard.sh --non-interactive --accept-risk \
      --provider anthropic \
      --channels telegram \
      --owner-ids 123456789 \
      --agent-name "Aria" \
      --agent-purpose "Personal assistant"

  # Add agent to existing stack
  bash wizard.sh --name production add-agent

  # Add channel to existing agent
  bash wizard.sh --name production channels add --agent-key aria

  # Post-install diagnostics
  bash wizard.sh doctor

  # Repair insecure config
  bash wizard.sh doctor --repair

  # Upgrade all services + DB migrations
  bash wizard.sh --name production upgrade

  # Tail gateway logs
  bash wizard.sh logs goclaw

  # Check stack health
  bash wizard.sh status

  # Uninstall (with data wipe confirmation)
  bash wizard.sh --name production uninstall
```

---

## 4. Two Wizard Flows

### 4.1 QuickStart (default `--flow quickstart`)

Goal: **working bot in under 3 minutes** with minimal decisions.

Applies sensible defaults silently:
- Mode: `managed` (PostgreSQL)
- Features: `ui` (web dashboard) enabled
- DM policy: `allowlist` (bot only responds to owner)
- Port: next available block
- Agent type: `predefined`
- Secrets: auto-generated

Only asks:
1. LLM provider + API key
2. Which channel(s) + credentials + owner ID(s)
3. Agent name + one-line purpose

Everything else is defaulted. No feature menus. No mode selection.

### 4.2 Full (`--flow full`)

Goal: **complete control** for power users.

Exposes every option interactively:
1. Mode selection (standalone / managed)
2. Feature selection (ui / otel / sandbox / tailscale)
3. LLM provider + API key + optional model override + optional base URL
4. Channel(s) selection (with help notes per channel)
5. Per-channel: credentials + optional display name + owner IDs
6. Agent identity (name / purpose / personality / language)
7. Owner profile (name / preferred language / notes)
8. Gateway port (or accept auto-allocation)
9. Confirm summary before launch

---

## 5. UX Design Patterns (from OpenClaw reference)

### 5.1 Terminal UI Structure

Every interactive session is framed:
```
┌  GoClaw Wizard — QuickStart
│
◇  Model/auth provider
│  ❯ Anthropic (Claude)
│    OpenAI (GPT)
│    Google (Gemini)
│    OpenRouter  hint: 100+ models via one key
│    Groq
│    ...
│
◇  Anthropic API key
│  sk-ant-...
│
◇  Which channels?  (space to select, enter to confirm)
│  ◉ Telegram
│  ○ Discord
│  ○ Feishu/Lark
│  ○ Zalo
│  ○ WhatsApp
│
■  Note: Telegram bot token
│
│  1) Open Telegram → chat with @BotFather
│  2) /newbot → follow prompts
│  3) Copy token (looks like: 123456789:ABC...)
│  Tip: or set GOCLAW_TELEGRAM_TOKEN=... in env
│  Docs: https://docs.goclaw.ai/channels/telegram
│
◇  Telegram bot token
│  1234567890:AAF...
│
◇  Your Telegram user ID  hint: DM @userinfobot
│  123456789
│
◇  Agent name?
│  Nova
│
◇  What does Nova do?
│  Personal assistant for daily tasks and research
│
  Generating Nova's identity...  ✔
  Launching stack...             ✔
  Health check...                ✔
  Provisioning agent...          ✔
  Sending welcome message...     ✔
│
└  ✓ Nova is live on Telegram (@nova_bot)
```

### 5.2 Prompt Primitives (`lib/wizard-ui.sh`)

| Primitive | Usage |
|-----------|-------|
| `prompt_select` | Single-choice menu with arrow keys |
| `prompt_multiselect` | Multi-choice with spacebar, optional filter-by-type |
| `prompt_text` | Free text with optional validation function |
| `prompt_secret` | Hidden input (no echo) |
| `prompt_confirm` | y/N boolean with default |
| `prompt_note` | Boxed info block (help text, links, tips) |
| `prompt_progress` | Spinner with update/stop messages |
| `prompt_intro` | Session opener (`┌` framing) |
| `prompt_outro` | Session closer (`└` framing) |

On `Ctrl+C`: print `  Setup cancelled.` + cleanup + exit 0 (no stack trace).

### 5.3 Help Notes per Channel

Before collecting credentials, display a `prompt_note` box for each channel:

**Telegram:**
```
■  Note: Telegram bot token
│  1) Open Telegram → chat with @BotFather
│  2) Send /newbot → give your bot a name
│  3) Copy the token: 123456789:ABCdef...
│  Tip: or export GOCLAW_TELEGRAM_TOKEN=<token>
│  Docs: https://core.telegram.org/bots#botfather
```

**Discord:**
```
■  Note: Discord bot token
│  1) https://discord.com/developers/applications
│  2) New Application → Bot → Reset Token → Copy
│  3) Enable MESSAGE_CONTENT intent under Privileged Intents
│  4) Invite bot to your server with applications.commands scope
```

**Feishu/Lark:**
```
■  Note: Feishu/Lark credentials
│  1) https://open.feishu.cn/app → Create App
│  2) Copy App ID + App Secret from Credentials tab
│  3) (Optional) Enable Event encryption key
│  4) Add bot to workspace and grant messaging permissions
```

**Zalo:**
```
■  Note: Zalo OA token
│  1) Register at https://oa.zalo.me/
│  2) Create Official Account → Settings → API Access
│  3) Copy the access token
```

**WhatsApp:**
```
■  Note: WhatsApp bridge URL
│  WhatsApp requires a bridge service (e.g. Baileys-based).
│  1) Deploy a Baileys bridge or use a compatible provider
│  2) Enter the bridge HTTP endpoint URL
│  Example: http://localhost:3001
```

### 5.4 Owner ID Resolution

For Telegram: after collecting the bot token, offer to resolve Telegram `@username` to numeric ID:

```bash
resolve_telegram_id() {
  local token="$1" username="$2"
  # Strips @ prefix, calls https://api.telegram.org/bot{token}/getChat?chat_id=@{username}
  # Returns numeric id if successful, echoes input unchanged on failure
}
```

Display after resolution:
```
◇  Telegram owner ID  hint: @username resolves to numeric id
│  @myusername
│  ✓ Resolved to: 123456789
```

### 5.5 Searchable Multiselect

For provider and channel selection, support type-to-filter:

```
◇  Which channels?  (type to filter, space to select)
│  Filter: te
│  ◉ Telegram    hint: Bot token from @BotFather
│  ○ Microsoft Teams
```

### 5.6 Progress Spinners

All async operations show a named spinner:

```
  Cloning GoClaw source...          ✔  (2.1s)
  Building Docker images...         ●  (running...)
  Waiting for health check...       ✔  attempt 3/20
  Warming up LLM gateway...         ✔
  Generating Nova's identity...     ✔  (LLM)
  Provisioning agent...             ✔
  Sending Telegram welcome...       ✔
```

On failure: spinner stops with `✗` + error message + hint for next step.

---

## 6. State & Path Layout

```
~/.goclaw-wizard/
├── stacks/
│   ├── default/
│   │   ├── .secrets          # Stack secrets (chmod 600)
│   │   ├── state.json        # Stack metadata
│   │   ├── agents/
│   │   │   ├── nova/         # First agent
│   │   │   │   ├── SOUL.md
│   │   │   │   ├── IDENTITY.md
│   │   │   │   └── USER.md
│   │   │   └── aria/         # Additional agents
│   │   └── goclaw/           # Shallow GoClaw clone (official repo)
│   └── {stack-name}/
│       └── ...               # Same layout per named stack
└── wizard.log                # Last wizard run log (for doctor/debug)
```

**`.secrets` format** (chmod 600):
```bash
GOCLAW_GATEWAY_TOKEN=<hex32>
GOCLAW_ENCRYPTION_KEY=<hex64>
POSTGRES_PASSWORD=<hex24>
GOCLAW_OWNER_IDS=<comma-separated>
GOCLAW_PROVIDER=anthropic
GOCLAW_MODEL=claude-sonnet-4-5-20250929
GOCLAW_ANTHROPIC_API_KEY=sk-ant-...
GOCLAW_TELEGRAM_TOKEN=<bot-token>
# GOCLAW_DISCORD_TOKEN=
# GOCLAW_LARK_APP_ID=
# GOCLAW_LARK_APP_SECRET=
# GOCLAW_ZALO_TOKEN=
# GOCLAW_WHATSAPP_BRIDGE_URL=
```

**`state.json`:**
```json
{
  "stack":        "default",
  "installed_at": "2026-03-01T10:00:00Z",
  "version":      "2.13.0",
  "flow":         "quickstart",
  "mode":         "managed",
  "features":     ["ui"],
  "ports": {
    "api":      18790,
    "ui":       3000,
    "postgres": 5432,
    "jaeger":   16686
  },
  "agents": [
    {
      "key":      "nova",
      "name":     "Nova",
      "type":     "predefined",
      "channels": ["telegram"],
      "created_at": "2026-03-01T10:05:00Z"
    }
  ],
  "owner_ids": ["123456789"]
}
```

---

## 7. Port Allocation

Each stack gets a 10-port block. Auto-detected from existing stacks + live port scan.

| Block | Stack | API | UI | PG | Jaeger UI |
|-------|-------|-----|----|----|-----------|
| 0 | default | 18790 | 3000 | 5432 | 16686 |
| 1 | second | 18800 | 3010 | 5442 | 16696 |
| 2 | third | 18810 | 3020 | 5452 | 16706 |
| N | name-N | 18790+N×10 | 3000+N×10 | 5432+N×10 | 16686+N×10 |

On reinstall: read existing assignment from `state.json` — never re-allocate.

---

## 8. Docker Compose Strategy

The wizard **never writes its own docker-compose.yml**. Instead:

1. Shallow-clone `https://github.com/nextlevelbuilder/goclaw.git` into `~/.goclaw-wizard/stacks/{name}/goclaw/`
2. Build overlay list from selected mode + features
3. Run `docker compose --project-name goclaw-{stack} --env-file .env {overlays} up -d --build`

**Overlay builder** (`lib/compose.sh`):
```bash
build_overlay_args() {
  local goclaw_dir="$1" mode="$2" features="$3"
  local -a args=("-f" "${goclaw_dir}/docker-compose.yml")

  [[ "$mode" == "managed"    ]] && args+=("-f" "${goclaw_dir}/docker-compose.managed.yml")
  [[ "$mode" == "standalone" ]] && args+=("-f" "${goclaw_dir}/docker-compose.standalone.yml")
  [[ "$features" == *"ui"*        ]] && args+=("-f" "${goclaw_dir}/docker-compose.selfservice.yml")
  [[ "$features" == *"otel"*      ]] && args+=("-f" "${goclaw_dir}/docker-compose.otel.yml")
  [[ "$features" == *"sandbox"*   ]] && args+=("-f" "${goclaw_dir}/docker-compose.sandbox.yml")
  [[ "$features" == *"tailscale"* ]] && args+=("-f" "${goclaw_dir}/docker-compose.tailscale.yml")
  echo "${args[@]}"
}
```

**Container names** (via compose project):
```
goclaw-{stack}-goclaw-1
goclaw-{stack}-postgres-1     (managed)
goclaw-{stack}-goclaw-ui-1    (ui feature)
goclaw-{stack}-jaeger-1       (otel feature)
```

All ports bound to `127.0.0.1:{allocated_port}` — no public exposure.

---

## 9. Install Flow — Full Detail

### 9.1 QuickStart (`--flow quickstart`)

```
PREFLIGHT
  ├── check OS, deps (docker v2, git, openssl, python3, curl, ss)
  ├── detect existing stack → if running: offer [reinstall] [add-agent] [cancel]
  └── detect existing secrets → reuse GATEWAY_TOKEN, ENCRYPTION_KEY, POSTGRES_PASSWORD

STEP 1: Provider
  prompt_select "Model/auth provider"
    [Anthropic] [OpenAI] [Gemini] [OpenRouter] [Groq] [DeepSeek]
    [MiniMax] [Mistral] [xAI] [Cohere] [Perplexity] [Custom]
  If provider has multiple auth methods → sub-select (API key / OAuth / token)
  prompt_secret "{provider} API key"
  [optional] prompt_text "Model override" initialValue={provider_default}

STEP 2: Channels
  prompt_multiselect "Which channels?" (searchable)
    [Telegram] [Discord] [Feishu/Lark] [Zalo] [WhatsApp]
  For each selected channel:
    prompt_note {channel_help_text}
    collect credentials (token, app_id+secret, bridge_url)
    [Telegram only] resolve @username → numeric ID via bot API
    prompt_text "Your {channel} user ID (allowlist)"

STEP 3: Agent Identity
  prompt_text "Agent name?"
  prompt_text "What does {name} do?"  (one-line purpose)
  [QuickStart skips personality/language — uses defaults]

PORT ALLOCATION (silent)
  find_free_port_block → assign API/UI/PG ports

SECRET GENERATION (silent)
  openssl rand -hex 16  → GATEWAY_TOKEN
  openssl rand -hex 32  → ENCRYPTION_KEY
  openssl rand -hex 24  → POSTGRES_PASSWORD
  write to .secrets (chmod 600)

CONFIRM SUMMARY
  ┌────────────────────────────────────┐
  │  Stack:    default (managed + ui)  │
  │  Provider: Anthropic / Claude      │
  │  Channel:  Telegram                │
  │  Agent:    Nova                    │
  │  Ports:    API=18790  UI=3000      │
  └────────────────────────────────────┘
  prompt_confirm "Deploy?" initialValue=true

LAUNCH
  progress "Cloning GoClaw source..."       git clone --depth 1
  progress "Starting Docker stack..."       docker compose up -d --build
  progress "Health check..."                poll /health 20×5s
  progress "Warming up LLM gateway..."      POST /v1/chat/completions 5×10s
  progress "Generating {name}'s identity..." identity-wizard.py (LLM + fallback)
  progress "Provisioning agent..."          provision-agent.py --action create
  progress "Sending welcome message..."     Telegram/Discord/etc. API

WRITE STATE
  state.json, update .secrets

OUTRO
  └  ✓ Nova is live!

  Gateway: http://127.0.0.1:18790
  Dashboard: http://127.0.0.1:3000

  Add another agent:  bash wizard.sh add-agent
  Check health:       bash wizard.sh doctor
  View logs:          bash wizard.sh logs
```

### 9.2 Full Flow (`--flow full`)

Same as QuickStart plus:

```
After PREFLIGHT, before STEP 1:
  prompt_select "Deployment mode"
    [managed — PostgreSQL, all features] [standalone — file storage, eval only]

  If managed:
    prompt_multiselect "Optional features"
      [x] Web Dashboard (port {UI_PORT})
      [ ] Observability / Jaeger (port {JAEGER_PORT})
      [ ] Docker Sandbox (code execution isolation)
      [ ] Tailscale VPN (remote access)
    If tailscale: prompt_secret "Tailscale auth key"
                  prompt_text "Tailscale hostname" initialValue="goclaw-{stack}"
    If sandbox:   inform "Will build openclaw-sandbox:bookworm-slim image (~3 min)"

After STEP 1 (Provider):
  prompt_text "Custom base URL?" (for proxies/custom endpoints) [optional, skip=enter]

After STEP 2 (Channels), for each channel:
  prompt_text "Display name for this account?" [optional]

STEP 3 Full: Agent Identity (all fields)
  prompt_text "Agent name?"
  prompt_text "What does {name} do?"
  prompt_text "How should {name} communicate? (personality/tone)"
  prompt_text "Preferred response language?" initialValue="English"

STEP 4 (Full only): Owner Profile
  prompt_text "Your name? (agent will address you as this)"
  prompt_text "Anything your agent should know about you?" [optional]

After PORT ALLOCATION:
  prompt_confirm "API port: {auto_port} — override?" initialValue=false
  If yes: prompt_text "API port" validate=is_free_port
```

---

## 10. Add Agent Flow

```
wizard.sh [--name STACK] add-agent

PREFLIGHT
  ├── load state.json, verify stack running (GET /health)
  └── load secrets (for gateway token + model)

LLM WARMUP
  progress "Warming up LLM gateway..."   POST /v1/chat/completions

CHANNEL CREDENTIALS FOR NEW AGENT
  Note: Each agent needs its OWN bot tokens (different bot per agent)
  prompt_multiselect "Channels for new agent?" (pre-filtered to installed channels)
  For each channel:
    prompt_note {channel_help_text}
    collect NEW credentials (new bot token, etc.)
    collect owner IDs (reuse existing or add new)

AGENT IDENTITY WIZARD
  [no owner profile — already stored]
  prompt_text "Agent name?"
  prompt_text "What does {name} do?"
  prompt_text "How should {name} communicate?"
  LLM generate → SOUL.md + IDENTITY.md

PROVISION
  progress "Provisioning {name}..."   provision-agent.py --action create
  docker restart goclaw-{stack}-goclaw-1
  health check
  send welcome message

UPDATE STATE
  append agent to state.json agents[]

OUTRO
  └  ✓ {name} is live!
  Manage agents: bash wizard.sh status --name {stack}
```

---

## 11. `channels add` Flow

```
wizard.sh [--name STACK] channels add [--agent-key KEY]

PREFLIGHT
  ├── load state + verify running
  └── if no --agent-key: prompt_select "Which agent?" (list from state.json)

SELECT CHANNEL
  prompt_select "Which channel to add?"  (show only channels NOT already on this agent)

COLLECT CREDENTIALS
  prompt_note {channel_help_text}
  collect credentials + owner IDs

PROVISION
  provision-agent.py --action add-channel \
    --agent-key {key} --channel {type} \
    --credentials {json} --owner-ids {ids}
  docker restart (to flush cache)

OUTRO
  └  ✓ {channel} added to {agent_name}
```

---

## 12. `doctor` Command

Inspired by OpenClaw's `openclaw doctor`. Runs a suite of checks and optionally repairs.

```
wizard.sh [--name STACK] doctor [--repair] [--yes]

CHECKS:
  ┌ Config & Secrets
  │  ✓ .secrets file exists
  │  ✓ .secrets permissions = 600
  │  ✓ GATEWAY_TOKEN length = 32 chars
  │  ✓ ENCRYPTION_KEY length = 64 chars
  │  ✗ POSTGRES_PASSWORD missing  → hint: re-run wizard.sh install

  ┌ Services
  │  ✓ goclaw-default-goclaw-1   running (healthy)
  │  ✓ goclaw-default-postgres-1 running (healthy)
  │  ✗ goclaw-default-goclaw-ui-1 not found
  │    → hint: enable ui feature: wizard.sh install --features ui

  ┌ Gateway Health
  │  ✓ GET /health → 200 OK  (latency: 12ms)
  │  ✓ LLM gateway reachable  (POST /v1/chat/completions → 200)
  │  ✓ WebSocket connectable  (ws://127.0.0.1:{port}/ws)

  ┌ Security
  │  ✓ DM policy = allowlist on all channel instances
  │  ✓ No BOOTSTRAP.md in user_context_files
  │  ✗ state.json permissions = 644  → should be 600
  │    [repair] chmod 600 ~/.goclaw-wizard/stacks/default/state.json

  ┌ Agents
  │  ✓ Agent "nova" (predefined) — Telegram channel active
  │  ✓ SOUL.md seeded (agent_context_files)
  │  ✓ IDENTITY.md seeded
  │  ✓ USER.md seeded

  ┌ Versions
  │  ✓ GoClaw: 2.13.0 (up to date)
  │  ✓ Docker: 27.3.1
  │  ✓ Python: 3.11.2
  │  ℹ GoClaw source: last pulled 3 days ago
  │    [repair] git pull → upgrade available (2.14.0)

  ┌ Ports
  │  ✓ API port 18790 — bound to goclaw-default-goclaw-1
  │  ✓ No port conflicts with other stacks

  Summary: 2 warnings, 1 error
  Run `wizard.sh doctor --repair` to apply fixes
```

**`--repair` mode:** Applies all safe auto-fixes (file permissions, stale cache clear).
**`--repair --yes`:** Applies all fixes without per-fix confirmation.
**Logged to:** `~/.goclaw-wizard/wizard.log` with timestamp.

---

## 13. Agent Provisioning (`scripts/provision-agent.py`)

### Agent Type: Always `predefined`

- `predefined` agents use `agent_context_files` — written via `agents.files.set` WS API
- No direct SQL / docker exec into postgres required
- Avoids BOOTSTRAP.md seeding trap (only applies to `open` agent type)
- All wizard-provisioned agents use this path consistently

### WS RPC Sequence (create)

```python
# 1. Auth
connect({token: GATEWAY_TOKEN, user_id: "system"})

# 2. Create agent
agents.create({
  name: agent_name,
  agent_key: agent_key,       # derived: lowercase, non-alphanum → dash
  agent_type: "predefined"
}) → {id: agent_id}

# 3. Seed identity files
agents.files.set({agentId: agent_key, name: "SOUL.md",     content})
agents.files.set({agentId: agent_key, name: "IDENTITY.md", content})
agents.files.set({agentId: agent_key, name: "USER.md",     content})

# 4. Create channel instances (one per configured channel)
channels.instances.create({
  name:         "{agent_key}-{channel_type}",
  display_name: "{Agent Name} ({channel_label})",
  channel_type: "telegram" | "discord" | "lark" | "zalo" | "whatsapp",
  agent_id:     agent_id,
  credentials:  {token: ...}          # channel-specific
  config: {
    dm_policy:  "allowlist",
    allow_from: [owner_id_1, owner_id_2, ...]
  },
  enabled: true
})
```

### Channel Credential Mapping

| Channel | `credentials` fields | `config` extra fields |
|---------|---------------------|----------------------|
| `telegram` | `{token}` | `{dm_policy, allow_from}` |
| `discord` | `{token}` | `{dm_policy, allow_from}` |
| `lark` | `{app_id, app_secret, encrypt_key?, verification_token?}` | `{dm_policy, allow_from}` |
| `zalo` | `{token}` | `{dm_policy, allow_from}` |
| `whatsapp` | `{bridge_url}` | `{dm_policy, allow_from}` |

### WS RPC Sequence (delete)

```python
connect({token: GATEWAY_TOKEN, user_id: "system"})
channels.instances.list({}) → filter by name prefix "{agent_key}-"
channels.instances.delete({id}) × N
agents.delete({agentKey: agent_key})
```

### WS RPC Sequence (add-channel)

```python
connect({token: GATEWAY_TOKEN, user_id: "system"})
# Fetch agent_id from agents.list or agents.get
channels.instances.create({...})   # same as create step 4
```

---

## 14. Identity Wizard (`scripts/identity-wizard.py`)

### LLM Generation Flow

```
1. Load GATEWAY_TOKEN + GOCLAW_MODEL from .secrets
2. POST /v1/chat/completions (runs against user's own LLM provider)
   System: "AI identity generator. Output exactly what is requested."
   Prompt: structured template with SOUL_START/END and IDENTITY_START/END delimiters
3. Parse delimiters → SOUL.md + IDENTITY.md
4. Retry 3× with 5s backoff on parse failure
5. Fallback to templates/ on all failures
```

### Generated Files

**SOUL.md** (seeded to `agent_context_files` via WS):
```markdown
# SOUL.md — {name}

## Identity
**Name:** {name}
**Role:** {5-8 word role}
**Emoji:** {emoji}
**Language:** {language}

## Purpose
{2-3 sentence purpose description}

## Personality
- {trait 1}
- {trait 2}
- {trait 3}
- {trait 4}

## Operating Principles
1. {principle}
2. {principle}
3. {principle}
```

**IDENTITY.md:**
```markdown
# IDENTITY.md
- **Name:** {name}
- **Role:** {role}
- **Emoji:** {emoji}
```

**USER.md** (install mode only):
```markdown
# USER.md — Owner Profile
- **Name:** {owner_name}
- **Language:** {owner_lang}
- **Notes:** {owner_notes or "None"}

## Communication
Always address the owner as {owner_name}. Default language: {owner_lang}.
```

### Modes

| Mode | Owner Profile | Bot Token | Output Files |
|------|:---:|:---:|------|
| `install` | ✅ asked | No (collected earlier) | SOUL.md, IDENTITY.md, USER.md |
| `add-agent` | ❌ reused | ✅ asked first | SOUL.md, IDENTITY.md |

---

## 15. Secrets Management (`lib/secrets.sh`)

| OS | Primary Backend | Fallback |
|----|----------------|---------|
| macOS | Keychain (`security add-generic-password`) | `.secrets` file |
| Linux (GNOME) | `secret-tool` (libsecret) | `.secrets` file |
| Linux headless / WSL | — | `.secrets` file (chmod 600) |

**Key naming:** `goclaw-{stack}:{KEY_NAME}` in keychain.

**Reinstall safety** — these keys are always reused (preserves DB + decryption):
- `GOCLAW_GATEWAY_TOKEN`
- `GOCLAW_ENCRYPTION_KEY`
- `POSTGRES_PASSWORD`

All other credentials re-collected from user.

---

## 16. Non-Interactive Mode

For CI/CD pipelines and automated deployments (`--non-interactive --accept-risk`):

**Environment variables override all prompts:**
```bash
GOCLAW_ANTHROPIC_API_KEY=sk-ant-...
GOCLAW_TELEGRAM_TOKEN=12345:abc...
```

**CLI flags provide the rest:**
```bash
bash wizard.sh install \
  --non-interactive --accept-risk \
  --provider anthropic \
  --channels telegram \
  --owner-ids 123456789 \
  --agent-name "Aria" \
  --agent-purpose "Personal assistant for daily tasks" \
  --features ui
```

**Validation:** In `--non-interactive` mode:
- Missing required values → print error + exit 1 (never prompt)
- `--accept-risk` required → if missing, print: `Error: --accept-risk required for non-interactive mode`
- All secrets read from env vars or `--` flags; never from `.secrets` (first install)

---

## 17. Environment Variable Generation

The wizard generates an ephemeral `.env` file (deleted after `docker compose up` via `trap`):

```bash
# === GATEWAY ===
GOCLAW_HOST=0.0.0.0
GOCLAW_PORT={API_PORT}
GOCLAW_MODE={managed|standalone}
GOCLAW_GATEWAY_TOKEN={token}
GOCLAW_ENCRYPTION_KEY={key}
GOCLAW_OWNER_IDS={owner_ids}
GOCLAW_TRACE_VERBOSE=0

# === LLM PROVIDER ===
GOCLAW_PROVIDER={provider}
GOCLAW_MODEL={model}
GOCLAW_{PROVIDER_UPPER}_API_KEY={api_key}
# All other provider keys left empty

# === CHANNELS ===
GOCLAW_TELEGRAM_TOKEN={token|""}
GOCLAW_DISCORD_TOKEN={token|""}
GOCLAW_LARK_APP_ID={id|""}
GOCLAW_LARK_APP_SECRET={secret|""}
GOCLAW_LARK_ENCRYPT_KEY={key|""}
GOCLAW_LARK_VERIFICATION_TOKEN={token|""}
GOCLAW_ZALO_TOKEN={token|""}
GOCLAW_WHATSAPP_BRIDGE_URL={url|""}

# === DATABASE (managed mode) ===
POSTGRES_USER=goclaw
POSTGRES_PASSWORD={postgres_password}
POSTGRES_DB=goclaw
POSTGRES_PORT={PG_PORT}

# === UI ===
GOCLAW_UI_PORT={UI_PORT}

# === OTEL (otel feature) ===
GOCLAW_TELEMETRY_ENABLED={true|false}
GOCLAW_TELEMETRY_ENDPOINT=jaeger:4317
GOCLAW_TELEMETRY_PROTOCOL=grpc
GOCLAW_TELEMETRY_INSECURE=true
GOCLAW_TELEMETRY_SERVICE_NAME=goclaw-{stack}

# === SANDBOX (sandbox feature) ===
GOCLAW_SANDBOX_MODE={all|none}
GOCLAW_SANDBOX_IMAGE=openclaw-sandbox:bookworm-slim
GOCLAW_SANDBOX_WORKSPACE_ACCESS=rw
GOCLAW_SANDBOX_SCOPE=session
GOCLAW_SANDBOX_MEMORY_MB=512
GOCLAW_SANDBOX_CPUS=1.0
GOCLAW_SANDBOX_TIMEOUT_SEC=300
GOCLAW_SANDBOX_NETWORK=false
DOCKER_GID={docker_group_id}

# === TAILSCALE (tailscale feature) ===
GOCLAW_TSNET_AUTH_KEY={ts_key|""}
GOCLAW_TSNET_HOSTNAME=goclaw-{stack}
```

---

## 18. Dependency Requirements

| Dependency | Min Version | Purpose | Auto-install? |
|-----------|------------|---------|:---:|
| `docker` | 20.10+ | Container runtime | No — link provided |
| `docker compose` | v2 (plugin) | Multi-service orchestration | No — link provided |
| `git` | 2.x | Clone GoClaw source | No |
| `openssl` | 1.1+ | Generate secrets | No |
| `python3` | 3.8+ | Identity wizard + provision | No |
| `curl` | 7.x | Health checks + LLM warmup | No |
| `ss` or `netstat` | any | Port conflict detection | No |

Missing dep: clear error + OS-specific install command. Never silently skip.

Docker v1 `docker-compose` (hyphen) detected → print: `Docker Compose v2 plugin required. Run: apt install docker-compose-plugin`

---

## 19. Error Handling

| Failure Point | Behavior |
|--------------|---------|
| Missing dependency | Print OS-specific install command + exit |
| Docker daemon not running | "Start Docker daemon: sudo systemctl start docker" |
| Port conflict | Auto-increment to next free block (no user interaction) |
| git clone failure | Retry once, then exit with GitHub URL |
| Sandbox image build failure | Warn + disable sandbox feature + continue |
| Stack startup failure | Print last 30 log lines + `bash wizard.sh logs` hint |
| Health check timeout (20×5s) | Print logs + "Run: bash wizard.sh doctor" |
| LLM warmup failure | Warn "Using fallback identity template" + continue |
| LLM generation failure (3×) | Fallback to templates/ + inform user |
| Provision WS failure | Print WS error + exit with retry hint |
| Ctrl+C at any point | "Setup cancelled." + cleanup .env trap + exit 0 |
| Reinstall with existing data | Reuse gateway/enc/pg secrets → preserves DB |

---

## 20. Feature Compatibility Matrix

| Feature | Standalone | Managed | Overlay |
|---------|:----------:|:-------:|:-------:|
| Basic agent + 30+ tools | ✅ | ✅ | — |
| All 5 messaging channels | ✅ | ✅ | — |
| Memory (FTS5) | ✅ | ✅ | — |
| Cron scheduling | ✅ | ✅ | — |
| **Web Dashboard** | ❌ | ✅ | ui |
| **Per-user isolation** | ❌ | ✅ | — |
| **Agent teams** | ❌ | ✅ | — |
| **Agent delegation** | ❌ | ✅ | — |
| **Handoff + evaluate loops** | ❌ | ✅ | — |
| **Quality gates** | ❌ | ✅ | — |
| **MCP integration** | ❌ | ✅ | — |
| **Custom tools (runtime)** | ❌ | ✅ | — |
| **Skills (pgvector search)** | ❌ | ✅ | — |
| **Tracing / Jaeger** | ❌ | ✅ | otel |
| **Docker Sandbox** | ❌ | ✅ | sandbox |
| **Tailscale VPN** | ❌ | ✅ | tailscale |

---

## 21. Implementation Phases

### Phase 1 — Core QuickStart (MVP)
- `wizard.sh` entry point: `install` + `--flow quickstart` + `--name`
- `lib/colors.sh` — ANSI + spinner + note box + banner + intro/outro framing
- `lib/detect.sh` — OS, arch, Docker group detection
- `lib/deps.sh` — dependency check with OS-specific fix hints
- `lib/wizard-ui.sh` — select, multiselect, text, secret, confirm, note, progress, cancel-trap
- `lib/secrets.sh` — cross-platform store/load
- `lib/ports.sh` — block allocation + conflict detection
- `lib/compose.sh` — overlay builder + docker compose wrapper
- `lib/stack.sh` — clone, generate .env, up, health, warmup, write state
- `lib/bootstrap.sh` — restart + welcome dispatch
- `scripts/provision-agent.py` — WS RPC create + delete
- `scripts/identity-wizard.py` — LLM gen + fallback
- `templates/soul-default.md.tpl`
- `templates/identity-default.md.tpl`
- Channels: Telegram only (QuickStart default)
- Mode: managed only

### Phase 2 — Full Flow + All Channels
- `--flow full` path with all prompts
- All 5 channels + channel help notes
- Owner profile step
- Gateway port override
- Custom LLM base URL

### Phase 3 — Optional Features
- `ui` overlay (web dashboard)
- `otel` overlay (Jaeger)
- `sandbox` overlay + image build
- `tailscale` overlay + auth key

### Phase 4 — Stack Management Commands
- `add-agent` command
- `remove-agent` command
- `channels add` command
- `status` command (table format)
- `start` / `stop` / `restart` commands
- `logs [SERVICE]` command

### Phase 5 — Doctor + Non-Interactive
- `doctor` command (all checks + repair)
- `--non-interactive --accept-risk` mode
- All `--` flags for scripted installs
- Log file at `~/.goclaw-wizard/wizard.log`

### Phase 6 — Upgrade + Uninstall + Multi-Stack Polish
- `upgrade` command (git pull + db migrate + rebuild)
- `uninstall` command (with data wipe option)
- Multi-stack: `--name` across all commands
- `status --all` — overview of every stack on the host
- Cross-stack doctor: detect port collisions between stacks

---

## 22. Known Constraints (from GoClaw source)

| Constraint | Wizard Handling |
|-----------|----------------|
| PG18 volume path must be `/var/lib/postgresql` (not `.../data`) | Use official overlay — handles correctly |
| `agents.files.set` ignored for `open` agents | Always provision `predefined` — no SQL needed |
| BOOTSTRAP.md triggers first-run prompt | Never seeded; not referenced anywhere |
| Channel instances override global config in managed mode | Set `dm_policy` at `channels.instances.create` time |
| ContextFileInterceptor caches 5 min | `docker restart goclaw-{stack}-goclaw-1` post-provision |
| OTel binary +11 MB; Tailscale +29 MB | Compose build args set by official otel/tailscale overlays |
| Sandbox requires docker socket mount | Inform user + check docker group membership |
| `docker compose v2` required | Detect and error on v1 `docker-compose` (hyphen) |

---

*End of design — v2.0*
