#!/usr/bin/env bash
# lib/flow-data.sh — Provider + channel arrays, CHANNEL_HELP notes, and lookup utilities
# Sourced by flows.sh. No side effects — pure data declarations.

# ── LLM Provider data (parallel arrays, index-aligned) ───────────────────────
PROVIDERS=(anthropic openai gemini openrouter groq deepseek minimax mistral xai cohere perplexity dashscope custom)

PROVIDER_LABELS=(
  "Anthropic (Claude)" "OpenAI (GPT)" "Google (Gemini)"
  "OpenRouter" "Groq" "DeepSeek" "MiniMax" "Mistral"
  "xAI (Grok)" "Cohere" "Perplexity" "DashScope (Qwen)" "Custom endpoint"
)

PROVIDER_HINTS=(
  "claude-sonnet-4-5" "gpt-4o" "gemini-2.0-flash"
  "100+ models via 1 key" "llama-3.3-70b" "deepseek-chat" "minimax-01" "mistral-large"
  "grok-2" "command-r-plus" "llama-3.1-sonar" "qwen-max" "OpenAI-compatible API"
)

# Maps provider index → env var prefix used in GOCLAW_{ENV}_API_KEY
PROVIDER_ENV=(
  ANTHROPIC OPENAI GEMINI OPENROUTER GROQ DEEPSEEK MINIMAX MISTRAL
  XAI COHERE PERPLEXITY DASHSCOPE CUSTOM
)

# Default model for each provider (empty = user must specify)
PROVIDER_MODELS=(
  claude-sonnet-4-5-20250929 gpt-4o gemini-2.0-flash
  "anthropic/claude-sonnet-4-5-20250929" llama-3.3-70b-versatile deepseek-chat
  minimax-01 mistral-large-latest grok-2 command-r-plus
  llama-3.1-sonar-large-128k-online qwen-max ""
)

# ── Messaging Channel data ────────────────────────────────────────────────────
CHANNEL_TYPES=(telegram discord lark zalo whatsapp)

CHANNEL_LABELS=("Telegram" "Discord" "Feishu/Lark" "Zalo" "WhatsApp")

CHANNEL_HINTS=(
  "Bot token from @BotFather"
  "Bot token from Dev Portal"
  "App ID + Secret from open.feishu.cn"
  "OA token from oa.zalo.me"
  "Baileys bridge URL"
)

# Per-channel inline help shown before credential prompts ($'...' = literal \n support)
declare -A CHANNEL_HELP=(
  [telegram]=$'1) Telegram → @BotFather → /newbot → follow prompts → copy token\n2) Get your numeric user ID via @userinfobot\nDocs: https://core.telegram.org/bots#botfather'
  [discord]=$'1) discord.com/developers → New Application → Bot → Reset Token → copy\n2) OAuth2 → bot scope → invite bot to your server\n3) User Settings → Advanced → Developer Mode → copy your user ID'
  [lark]=$'1) open.feishu.cn → Create App → copy App ID and App Secret\n2) Enable "Messenger Bot" capability → publish the app'
  [zalo]=$'1) oa.zalo.me → Create OA → Settings → OA Information\n2) Copy Access Token and your Zalo numeric user ID'
  [whatsapp]=$'1) Deploy Baileys WS bridge: https://github.com/WhiskeySockets/Baileys\n2) Scan QR code with WhatsApp mobile → note bridge HTTP URL (e.g. http://localhost:3001)'
)

# ── Utilities ─────────────────────────────────────────────────────────────────

# index_of <value> <array_name> → prints 0-based index, fallback 0
index_of() {
  local val="$1"; local -n _io_arr="$2"
  local i; for (( i=0; i<${#_io_arr[@]}; i++ )); do
    [[ "${_io_arr[$i]}" == "$val" ]] && echo "$i" && return
  done
  echo "0"
}

# derive_agent_key <name> → lowercase slug (a-z0-9 and dashes only)
derive_agent_key() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//'
}
