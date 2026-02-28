# GoClaw Feature Coverage — Wizard vs GoClaw Capabilities

This document maps every GoClaw feature to its wizard coverage. No gaps.

---

## LLM Providers (13+)

| Provider | Env Var | Wizard Support | Notes |
|---------|---------|:---:|-------|
| Anthropic | `GOCLAW_ANTHROPIC_API_KEY` | ✅ | Menu option 1 |
| OpenAI | `GOCLAW_OPENAI_API_KEY` | ✅ | Menu option 2 |
| Google Gemini | `GOCLAW_GEMINI_API_KEY` | ✅ | Menu option 3 |
| OpenRouter | `GOCLAW_OPENROUTER_API_KEY` | ✅ | Menu option 4 |
| Groq | `GOCLAW_GROQ_API_KEY` | ✅ | Menu option 5 |
| DeepSeek | `GOCLAW_DEEPSEEK_API_KEY` | ✅ | Menu option 6 |
| MiniMax | `GOCLAW_MINIMAX_API_KEY` | ✅ | Menu option 7 |
| Mistral | `GOCLAW_MISTRAL_API_KEY` | ✅ | Menu option 8 |
| xAI (Grok) | `GOCLAW_XAI_API_KEY` | ✅ | Menu option 9 |
| Cohere | `GOCLAW_COHERE_API_KEY` | ✅ | "Other" option |
| Perplexity | `GOCLAW_PERPLEXITY_API_KEY` | ✅ | "Other" option |
| DashScope (Qwen) | — | ✅ | "Other" option |
| Bailian Coding | — | ✅ | "Other" option |
| Custom base URL | `GOCLAW_ANTHROPIC_BASE_URL` | ✅ | Advanced prompt |
| Model override | `GOCLAW_MODEL` | ✅ | Optional in provider step |

---

## Messaging Channels (5)

| Channel | Credentials Needed | Wizard Support | Notes |
|---------|-------------------|:---:|-------|
| Telegram | `GOCLAW_TELEGRAM_TOKEN` + owner IDs | ✅ | Primary channel |
| Discord | `GOCLAW_DISCORD_TOKEN` + owner IDs | ✅ | Multi-select |
| Feishu/Lark | `GOCLAW_LARK_APP_ID`, `GOCLAW_LARK_APP_SECRET` (+ optional encrypt/verify) | ✅ | Multi-select |
| Zalo | `GOCLAW_ZALO_TOKEN` | ✅ | Multi-select |
| WhatsApp | `GOCLAW_WHATSAPP_BRIDGE_URL` | ✅ | Multi-select |
| Multiple channels per agent | via channels.instances.create | ✅ | Provision creates one instance per channel |
| `dm_policy: allowlist` | config at instance creation | ✅ | Always set — no pairing required |

---

## Deployment Modes

| Mode | Wizard Support | Notes |
|------|:---:|-------|
| Standalone (file-based) | ✅ | `--mode standalone` or interactive selection |
| Managed (PostgreSQL 18 + pgvector) | ✅ | Default recommended mode |
| Mode selectable per stack | ✅ | Each `--name` stack has its own mode |

---

## Docker Compose Overlays

| Overlay File | Feature | Wizard Support | Notes |
|-------------|---------|:---:|-------|
| `docker-compose.yml` | Base gateway | ✅ | Always included |
| `docker-compose.managed.yml` | PostgreSQL | ✅ | Managed mode |
| `docker-compose.standalone.yml` | File storage | ✅ | Standalone mode |
| `docker-compose.selfservice.yml` | Web Dashboard | ✅ | `--features ui` |
| `docker-compose.otel.yml` | OpenTelemetry + Jaeger | ✅ | `--features otel` |
| `docker-compose.sandbox.yml` | Docker code execution | ✅ | `--features sandbox` |
| `docker-compose.tailscale.yml` | Tailscale VPN | ✅ | `--features tailscale` |
| `docker-compose.upgrade.yml` | DB migrations | ✅ | `wizard.sh upgrade` |

---

## Optional Features

| Feature | Wizard Support | What Wizard Does |
|---------|:---:|-------|
| Web Dashboard (port 3000+) | ✅ | Adds selfservice overlay, sets `GOCLAW_UI_PORT` |
| OpenTelemetry / Jaeger | ✅ | Adds otel overlay, sets telemetry env vars |
| Docker Sandbox | ✅ | Adds sandbox overlay, builds `openclaw-sandbox:bookworm-slim` image, sets sandbox env vars |
| Tailscale VPN | ✅ | Adds tailscale overlay, prompts for auth key + hostname |

---

## Gateway Configuration

| Config | Env Var | Wizard Support | Notes |
|--------|---------|:---:|-------|
| Port | `GOCLAW_PORT` | ✅ | Auto-allocated per stack block |
| Host | `GOCLAW_HOST` | ✅ | Always `0.0.0.0` |
| Mode | `GOCLAW_MODE` | ✅ | Set from mode selection |
| Gateway token | `GOCLAW_GATEWAY_TOKEN` | ✅ | Auto-generated + stored |
| Encryption key | `GOCLAW_ENCRYPTION_KEY` | ✅ | Auto-generated + stored |
| Owner IDs | `GOCLAW_OWNER_IDS` | ✅ | Collected per channel |
| Verbose tracing | `GOCLAW_TRACE_VERBOSE` | ✅ | Default 0; advanced option |

---

## Database Configuration (Managed)

| Config | Env Var | Wizard Support | Notes |
|--------|---------|:---:|-------|
| PG user | `POSTGRES_USER` | ✅ | Fixed: `goclaw` |
| PG password | `POSTGRES_PASSWORD` | ✅ | Auto-generated + stored |
| PG database | `POSTGRES_DB` | ✅ | Fixed: `goclaw` |
| PG port | `POSTGRES_PORT` | ✅ | Auto-allocated per stack |
| PG image | `pgvector/pgvector:pg18` | ✅ | Official overlay handles this |
| Volume path | `/var/lib/postgresql` | ✅ | Official overlay handles this |
| Schema migrations | `goclaw upgrade` | ✅ | `wizard.sh upgrade` runs this |

---

## Security Features

| Feature | Wizard Support | Notes |
|---------|:---:|-------|
| Rate limiting | ✅ | Built into GoClaw — no config needed |
| Prompt injection detection | ✅ | Built into GoClaw — no config needed |
| SSRF protection | ✅ | Built into GoClaw — no config needed |
| Shell deny patterns | ✅ | Built into GoClaw — no config needed |
| Credential scrubbing | ✅ | Built into GoClaw — no config needed |
| AES-256-GCM API key encryption | ✅ | Requires `GOCLAW_ENCRYPTION_KEY` — wizard generates |
| Gateway bearer token | ✅ | Wizard generates + stores |
| `no-new-privileges` container | ✅ | Official compose file handles this |
| Read-only rootfs | ✅ | Official compose file handles this |
| `dm_policy: allowlist` | ✅ | Wizard sets at channel instance creation |
| Browser pairing (optional) | ℹ️ | Available in web dashboard — wizard informs |

---

## Multi-Stack & Multi-Agent

| Capability | Wizard Support | Notes |
|-----------|:---:|-------|
| Named stacks (`--name`) | ✅ | Isolated containers, volumes, ports, secrets |
| Auto port allocation | ✅ | Next free 10-port block |
| Multiple stacks on one host | ✅ | Unlimited (port limited) |
| Add agent to existing stack | ✅ | `wizard.sh add-agent --name STACK` |
| Remove agent | ✅ | `wizard.sh remove-agent --name STACK --agent-key KEY` |
| Multiple agents per stack | ✅ | Each has own context + channel instances |
| Agent identity via LLM | ✅ | `scripts/identity-wizard.py` |
| Fallback template identity | ✅ | No LLM required |

---

## Stack Lifecycle

| Operation | Wizard Support | Command |
|-----------|:---:|---------|
| Install | ✅ | `wizard.sh install` |
| Start | ✅ | `wizard.sh start --name STACK` |
| Stop | ✅ | `wizard.sh stop --name STACK` |
| Restart | ✅ | `wizard.sh restart --name STACK` |
| Status | ✅ | `wizard.sh status --name STACK` |
| Logs | ✅ | `wizard.sh logs --name STACK` |
| Upgrade | ✅ | `wizard.sh upgrade --name STACK` |
| Uninstall | ✅ | `wizard.sh uninstall --name STACK` |
| Reinstall (preserve data) | ✅ | Re-run `wizard.sh install` on existing stack |

---

## Secrets Management

| Platform | Backend | Notes |
|---------|---------|-------|
| macOS | Keychain (`security` CLI) | Per-stack key prefix |
| Linux (GNOME) | `secret-tool` | Per-stack key prefix |
| Linux (headless) | `~/.goclaw-wizard/stacks/{name}/.secrets` | chmod 600 |
| WSL / Windows | `~/.goclaw-wizard/stacks/{name}/.secrets` | chmod 600 |
| Reinstall safety | Reuse `GATEWAY_TOKEN`, `ENCRYPTION_KEY`, `POSTGRES_PASSWORD` | Preserves DB data |

---

## Build Arguments (Compile-time Features)

| Feature | Build Arg | Wizard Support | Binary Size |
|---------|-----------|:---:|------------|
| Base binary | — | ✅ | ~25 MB |
| OpenTelemetry | `ENABLE_OTEL=true` | ✅ | ~36 MB (+11 MB) |
| Tailscale | `ENABLE_TSNET=true` | ✅ | ~54 MB (+29 MB) |
| Docker Sandbox | `ENABLE_SANDBOX=true` | ✅ | (image adds docker-cli) |

The wizard selects the correct compose build args based on chosen features. GoClaw's official overlays handle setting `args: ENABLE_OTEL: "true"` etc. at compose build time.

---

## GoClaw Advanced Features (Available Post-Install, No Wizard Config Needed)

These features are available in the deployed stack without wizard configuration:

| Feature | Mode | Access |
|---------|------|--------|
| Agent delegation (sync/async) | Managed | Via web dashboard or WS API |
| Agent teams + task board | Managed | Via web dashboard or WS API |
| Agent handoff | Managed | Via web dashboard or WS API |
| Evaluate loops (generator/evaluator) | Managed | Via web dashboard or WS API |
| Quality gates | Managed | Via web dashboard or WS API |
| MCP server integration | Managed | Via web dashboard or HTTP API |
| Custom runtime tools | Managed | Via HTTP API `/v1/tools/custom` |
| Skills (BM25 + vector search) | Managed | Via web dashboard |
| Cron scheduling | Both | Via agent or dashboard |
| 30+ built-in tools | Both | Available to all agents |
| Session history | Both | Automatic |
| Browser pairing | Managed | Via web dashboard |
| LLM prompt caching | Both | Automatic (Anthropic, OpenAI) |
| Trace viewer | Managed + OTel | Jaeger UI on port 16686+ |
