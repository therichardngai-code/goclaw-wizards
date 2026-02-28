# GoClaw Wizard — Architecture Diagrams

## 1. Component Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│  wizard.sh  (single entry point)                                         │
│                                                                          │
│  Commands:  install | add-agent | remove-agent | start | stop            │
│             restart | upgrade | status | logs | uninstall                │
│  Options:   --name STACK  --mode MODE  --features LIST                   │
└────────────────────────┬─────────────────────────────────────────────────┘
                         │ sources
        ┌────────────────┴────────────────────────┐
        │                lib/                      │
        │  colors.sh    detect.sh    deps.sh       │
        │  wizard-ui.sh secrets.sh  ports.sh       │
        │  compose.sh   stack.sh    bootstrap.sh   │
        └────────────────┬────────────────────────┘
                         │ calls
        ┌────────────────┴────────────────────────┐
        │              scripts/                    │
        │  identity-wizard.py   provision-agent.py │
        └─────────────────────────────────────────┘
```

---

## 2. Install Flow

```
wizard.sh install
       │
       ├─ 1. Preflight
       │       check deps (docker, git, openssl, python3, curl)
       │       detect OS / arch
       │       check if stack exists → reinstall? add-agent? cancel?
       │
       ├─ 2. Interactive Configuration
       │       mode: managed | standalone
       │       features: ui, otel, sandbox, tailscale (multi-select)
       │       provider: 10 choices → API key
       │       channels: telegram, discord, lark, zalo, whatsapp (multi-select)
       │         └─ per-channel: credentials + owner_ids
       │
       ├─ 3. Port Allocation
       │       scan used ports → assign free block
       │       API=18790+(N×10), UI=3000+(N×10), PG=5432+(N×10)
       │
       ├─ 4. Secret Generation
       │       GATEWAY_TOKEN, ENCRYPTION_KEY, POSTGRES_PASSWORD
       │       reuse on reinstall → preserves DB
       │       store: macOS Keychain | secret-tool | .secrets file
       │
       ├─ 5. Fetch GoClaw Source
       │       git clone --depth 1 github.com/nextlevelbuilder/goclaw
       │       git pull on update
       │       build sandbox image (if feature enabled)
       │
       ├─ 6. Generate .env
       │       all secrets + port overrides + feature flags
       │       ephemeral (deleted after compose up)
       │
       ├─ 7. Launch Stack
       │       docker compose --project-name goclaw-{stack}
       │         -f docker-compose.yml
       │         -f docker-compose.managed.yml        ← if managed
       │         -f docker-compose.selfservice.yml    ← if ui
       │         -f docker-compose.otel.yml           ← if otel
       │         -f docker-compose.sandbox.yml        ← if sandbox
       │         -f docker-compose.tailscale.yml      ← if tailscale
       │         up -d --build
       │
       ├─ 8. Health Check
       │       GET http://127.0.0.1:{API_PORT}/health
       │       20 retries × 5s
       │
       ├─ 9. LLM Warmup
       │       POST /v1/chat/completions ("Say OK", 5 tokens)
       │       5 retries × 10s → fallback if fails
       │
       ├─ 10. Identity Wizard  (scripts/identity-wizard.py)
       │       ask owner: name, language, notes
       │       ask agent: name, purpose, personality
       │       LLM generate → SOUL.md + IDENTITY.md + USER.md
       │       fallback template if LLM unavailable
       │
       ├─ 11. Bootstrap Agent  (lib/bootstrap.sh)
       │       provision-agent.py --action create
       │         → agents.create (predefined type)
       │         → agents.files.set × 3 (SOUL, IDENTITY, USER)
       │         → channels.instances.create × N
       │       docker restart goclaw-{stack}-goclaw-1
       │       health check
       │       send welcome message on each channel
       │
       ├─ 12. Write State
       │       state.json: stack, mode, features, ports, agents, version
       │
       └─ 13. Print Summary Banner
```

---

## 3. Docker Stack Architecture (Managed + All Features)

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Host (VPS / Mac / Linux)                                               │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  Docker network: goclaw-{stack}_agentfleet_net                    │  │
│  │                                                                   │  │
│  │  ┌─────────────────────┐   ┌──────────────────────────────────┐  │  │
│  │  │  goclaw-{stack}     │   │  goclaw-{stack}                  │  │  │
│  │  │  -goclaw-1          │   │  -goclaw-ui-1                    │  │  │
│  │  │                     │   │  (React SPA + nginx)             │  │  │
│  │  │  Go binary ~25 MB   │   │  127.0.0.1:{UI_PORT}:80          │  │  │
│  │  │  127.0.0.1:{API}    │   └──────────────────────────────────┘  │  │
│  │  │  :18790             │                                          │  │
│  │  │                     │   ┌──────────────────────────────────┐  │  │
│  │  │  Providers:         │   │  goclaw-{stack}                  │  │  │
│  │  │  13+ LLM APIs       │   │  -jaeger-1                       │  │  │
│  │  │                     │   │  (Jaeger all-in-one)             │  │  │
│  │  │  Channels:          │   │  UI:  127.0.0.1:{J_UI}:16686     │  │  │
│  │  │  Telegram, Discord  │   │  gRPC:127.0.0.1:4317             │  │  │
│  │  │  Lark, Zalo,        │   └──────────────────────────────────┘  │  │
│  │  │  WhatsApp           │                                          │  │
│  │  │                     │   ┌──────────────────────────────────┐  │  │
│  │  │  Tools: 30+         │   │  goclaw-{stack}                  │  │  │
│  │  └──────────┬──────────┘   │  -postgres-1                     │  │  │
│  │             │              │  (pgvector/pgvector:pg18)         │  │  │
│  │             │              │  127.0.0.1:{PG_PORT}:5432         │  │  │
│  │             └─────────────▶│  vol: /var/lib/postgresql         │  │  │
│  │                            └──────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ~/.goclaw-wizard/stacks/{stack}/                                       │
│    ├── .secrets         (chmod 600)                                     │
│    ├── state.json       (stack metadata)                                │
│    ├── agents/{key}/    (SOUL.md, IDENTITY.md, USER.md)                 │
│    └── goclaw/          (official repo, shallow clone)                  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Multi-Stack on Single Host

```
Host
├── Stack "default"   API=18790  UI=3000  PG=5432  Jaeger=16686
│     ├── goclaw-default-goclaw-1
│     ├── goclaw-default-postgres-1
│     └── goclaw-default-goclaw-ui-1
│
├── Stack "client-a"  API=18800  UI=3010  PG=5442  Jaeger=16696
│     ├── goclaw-client-a-goclaw-1
│     ├── goclaw-client-a-postgres-1
│     └── goclaw-client-a-goclaw-ui-1
│
└── Stack "client-b"  API=18810  UI=3020  PG=5452
      ├── goclaw-client-b-goclaw-1
      └── goclaw-client-b-postgres-1    (standalone: no postgres)

~/.goclaw-wizard/stacks/
  ├── default/  .secrets  state.json  agents/  goclaw/
  ├── client-a/ .secrets  state.json  agents/  goclaw/
  └── client-b/ .secrets  state.json  agents/  goclaw/
```

---

## 5. Multi-Agent per Stack

```
Stack "default"
  │
  ├── Agent: "nova" (key: nova)
  │     type: predefined
  │     channels:
  │       ├── nova-telegram  (dm_policy: allowlist, allow_from: [123456])
  │       └── nova-discord
  │     context files: SOUL.md, IDENTITY.md, USER.md
  │
  └── Agent: "aria" (key: aria)
        type: predefined
        channels:
          └── aria-telegram  (dm_policy: allowlist, allow_from: [123456])
        context files: SOUL.md, IDENTITY.md, USER.md

wizard.sh add-agent --name default   ← adds next agent
wizard.sh remove-agent --name default --agent-key aria  ← removes agent
```

---

## 6. Provision Agent WS Flow

```
provision-agent.py  ──WS──▶  goclaw-{stack}-goclaw-1

  connect({token, user_id:"system"})
  ────────────────────────────────────────────────────▶
                              ◀──────  {ok: true}

  agents.create({name, agent_key, agent_type:"predefined"})
  ────────────────────────────────────────────────────▶
                              ◀──────  {ok: true, payload: {id: "abc123"}}

  agents.files.set({agentId: key, name: "SOUL.md", content})
  ────────────────────────────────────────────────────▶
                              ◀──────  {ok: true}

  agents.files.set({agentId: key, name: "IDENTITY.md", content})
  ────────────────────────────────────────────────────▶
                              ◀──────  {ok: true}

  agents.files.set({agentId: key, name: "USER.md", content})
  ────────────────────────────────────────────────────▶
                              ◀──────  {ok: true}

  channels.instances.create({  ← repeat per configured channel
    name: "{key}-telegram",
    channel_type: "telegram",
    agent_id: "abc123",
    credentials: {token: BOT_TOKEN},
    config: {dm_policy: "allowlist", allow_from: [OWNER_IDS]},
    enabled: true
  })
  ────────────────────────────────────────────────────▶
                              ◀──────  {ok: true}
```

---

## 7. Upgrade Flow

```
wizard.sh upgrade --name {stack}

  1. git -C ~/.goclaw-wizard/stacks/{stack}/goclaw pull --ff-only
         (get latest compose files + migrations)

  2. docker compose --project-name goclaw-{stack}
       {overlays} -f docker-compose.upgrade.yml
       run --rm upgrade
         (runs: /app/goclaw upgrade → applies DB migrations)

  3. docker compose --project-name goclaw-{stack}
       {overlays} up -d --build
         (rebuilds + restarts with new image)

  4. Health check

  5. Update version in state.json
```
