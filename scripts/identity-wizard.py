#!/usr/bin/env python3
# GoClaw identity wizard — LLM-powered SOUL.md / IDENTITY.md / USER.md generator.
# Python 3.8+, stdlib only. Calls local gateway /v1/chat/completions.
# On LLM failure: 3 retries (5s/10s backoff) then template fallback.
import argparse, json, os, sys, time
from urllib.request import Request, urlopen
from urllib.error import URLError

SOUL_START  = "SOUL_START"
SOUL_END    = "SOUL_END"
IDENT_START = "IDENTITY_START"
IDENT_END   = "IDENTITY_END"


def build_prompt(agent_name, agent_purpose, agent_personality="",
                 agent_language="English", owner_name="", owner_language="English"):
    """Build chat messages that instruct the LLM to generate delimited identity files."""
    system = (
        "You are an AI identity generator. Output exactly what is requested "
        "using the specified delimiters. No extra commentary."
    )
    parts = [
        f"Generate identity files for an AI agent named '{agent_name}'.",
        f"Purpose: {agent_purpose}",
    ]
    if agent_personality:
        parts.append(f"Personality/tone: {agent_personality}")
    parts.append(f"Response language: {agent_language}")
    if owner_name:
        parts.append(
            f"Owner profile: name='{owner_name}', language='{owner_language}'. "
            f"Include an ## Owner section in SOUL.md. Always address the owner by name."
        )

    # Owner section embedded in SOUL.md (agent-level file — always loaded by predefined agents).
    # USER.md is written to agent_context_files but is overridden at runtime by the per-user
    # user_context_files blank template seeded on first chat (GoClaw SeedUserFiles behaviour).
    # Embedding owner profile in SOUL.md ensures the agent always sees it regardless of
    # user_context_files priority.
    owner_section = (
        f"\n## Owner\n**Name:** {owner_name}\n**Language:** {owner_language}\n"
        if owner_name else ""
    )

    parts.append(f"""
Output format — use these exact delimiter lines with no extra text around them:

{SOUL_START}
# SOUL.md -- {agent_name}

## Identity
**Name:** {agent_name}
**Role:** [5-8 word role based on purpose]
**Emoji:** [single fitting emoji]
**Language:** {agent_language}

## Purpose
[2-3 sentences describing the agent's purpose]

## Personality
- [trait 1]
- [trait 2]
- [trait 3]
- [trait 4]

## Operating Principles
1. [principle]
2. [principle]
3. [principle]{owner_section}
{SOUL_END}

{IDENT_START}
# IDENTITY.md
- **Name:** {agent_name}
- **Role:** [same role as above]
- **Emoji:** [same emoji]
{IDENT_END}
""")
    return [
        {"role": "system", "content": system},
        {"role": "user",   "content": "\n".join(parts)},
    ]


def call_llm(host, port, token, model, messages, timeout=60):
    """POST /v1/chat/completions and return the assistant message content."""
    url  = f"http://{host}:{port}/v1/chat/completions"
    body = json.dumps({
        "model": model,
        "messages": messages,
        "max_tokens": 1000,
        "temperature": 0.7,
    }).encode("utf-8")
    req = Request(url, data=body, headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "X-GoClaw-User-Id": "wizard",  # required in managed mode
    })
    with urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read())
    return data["choices"][0]["message"]["content"]


def parse_delimiters(text):
    """Extract SOUL and IDENTITY blocks from LLM output.
    Returns (soul_str, identity_str) or raises ValueError on missing delimiters.
    """
    def extract(src, start_tag, end_tag):
        s = src.find(start_tag)
        e = src.find(end_tag)
        if s == -1 or e == -1 or e <= s:
            raise ValueError(f"Missing delimiter {start_tag}/{end_tag}")
        return src[s + len(start_tag):e].strip()

    soul     = extract(text, SOUL_START,  SOUL_END)
    identity = extract(text, IDENT_START, IDENT_END)
    return soul, identity


def generate_user_md(owner_name, owner_language, owner_notes=""):
    """Build USER.md content from owner profile (no LLM call needed)."""
    notes_line = owner_notes.strip() if owner_notes.strip() else "None"
    return (
        f"# USER.md -- Owner Profile\n"
        f"- **Name:** {owner_name}\n"
        f"- **Language:** {owner_language}\n"
        f"- **Notes:** {notes_line}\n\n"
        f"## Communication\n"
        f"Always address the owner as {owner_name}. "
        f"Default response language: {owner_language}.\n"
    )


def load_template(template_path, replacements):
    """Load a .tpl file and substitute {{KEY}} placeholders."""
    with open(template_path, "r") as f:
        content = f.read()
    for key, val in replacements.items():
        content = content.replace("{{" + key + "}}", val)
    return content


def main():
    p = argparse.ArgumentParser(description="GoClaw LLM identity generator")
    p.add_argument("--mode",              required=True, choices=["install", "add-agent"])
    p.add_argument("--host",              default="127.0.0.1")
    p.add_argument("--port",              type=int, required=True)
    p.add_argument("--token",             required=True)
    p.add_argument("--model",             default="default")
    p.add_argument("--agent-name",        required=True)
    p.add_argument("--agent-purpose",     required=True)
    p.add_argument("--agent-personality", default="")
    p.add_argument("--agent-language",    default="English")
    p.add_argument("--owner-name",        default="")
    p.add_argument("--owner-language",    default="English")
    p.add_argument("--owner-notes",       default="")
    p.add_argument("--output-dir",        required=True)
    p.add_argument("--templates-dir",     required=True)
    args = p.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    messages = build_prompt(
        agent_name=args.agent_name,
        agent_purpose=args.agent_purpose,
        agent_personality=args.agent_personality,
        agent_language=args.agent_language,
        owner_name=args.owner_name,
        owner_language=args.owner_language,
    )

    # --- LLM generation with retry + exponential backoff ---
    soul = identity = None
    for attempt in range(3):
        try:
            raw = call_llm(args.host, args.port, args.token, args.model, messages)
            soul, identity = parse_delimiters(raw)
            break  # success
        except (ValueError, URLError, KeyError, Exception) as exc:
            print(f"[identity-wizard] attempt {attempt + 1}/3 failed: {exc}", file=sys.stderr)
            if attempt < 2:
                time.sleep(5 * (attempt + 1))  # 5s then 10s backoff

    # --- Template fallback ---
    if soul is None or identity is None:
        print("[identity-wizard] LLM unavailable — using template fallback", file=sys.stderr)
        replacements = {
            "NAME":          args.agent_name,
            "PURPOSE":       args.agent_purpose,
            "PURPOSE_LOWER": args.agent_purpose.lower(),
            "LANGUAGE":      args.agent_language,
        }
        soul = load_template(
            os.path.join(args.templates_dir, "soul-default.md.tpl"), replacements)
        # Append owner section so template fallback also carries owner profile in SOUL.md
        if args.owner_name:
            soul += (
                f"\n## Owner\n**Name:** {args.owner_name}\n"
                f"**Language:** {args.owner_language}\n"
            )
        identity = load_template(
            os.path.join(args.templates_dir, "identity-default.md.tpl"), replacements)

    # --- Write output files ---
    with open(os.path.join(args.output_dir, "SOUL.md"), "w")     as f: f.write(soul)
    with open(os.path.join(args.output_dir, "IDENTITY.md"), "w") as f: f.write(identity)

    files_written = ["SOUL.md", "IDENTITY.md"]

    # USER.md only in install mode when owner name is provided
    if args.mode == "install" and args.owner_name:
        user_md = generate_user_md(args.owner_name, args.owner_language, args.owner_notes)
        with open(os.path.join(args.output_dir, "USER.md"), "w") as f:
            f.write(user_md)
        files_written.append("USER.md")

    print(json.dumps({"ok": True, "files": files_written}))


if __name__ == "__main__":
    main()
