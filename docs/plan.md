---
title: "GoClaw Wizard Implementation"
description: "One-command bash installer for GoClaw AI gateway stacks with Docker Compose orchestration"
status: pending
priority: P1
effort: 80h
branch: feat/goclaw-wizard
tags: [installer, bash, python, docker, wizard]
created: 2026-03-01
---

# GoClaw Wizard — Implementation Plan

## Tech Stack
- **Shell:** Bash 4+ (all lib/ files, wizard.sh entry point)
- **Python:** 3.8+ (identity-wizard.py, provision-agent.py)
- **Orchestration:** Docker Compose v2 plugin with official GoClaw overlays
- **State:** JSON (state.json) + flat secrets files (.secrets)

## Dependency Map
```
Phase 1 (core shell lib)  ──┐
Phase 2 (docker/compose)  ──┤── can build in parallel
Phase 3 (agent provision) ──┤
Phase 4 (identity wizard) ──┘
         │
Phase 5 (quickstart flow) ← depends on 1-4
         │
Phase 6 (full flow)       ← depends on 5
Phase 7 (stack mgmt cmds) ← depends on 5
         │
Phase 8 (doctor command)  ← depends on 1-4
Phase 9 (non-interactive) ← depends on 5-7
```

## Phases

| # | Phase | Status | File |
|---|-------|--------|------|
| 1 | Core Shell Library | ✅ Complete | [phase-01](phase-01-core-shell-library.md) |
| 2 | Docker Compose Orchestration | ✅ Complete | [phase-02](phase-02-docker-compose-orchestration.md) |
| 3 | Agent Provisioning | ✅ Complete | [phase-03](phase-03-agent-provisioning.md) |
| 4 | Identity Wizard | ✅ Complete | [phase-04](phase-04-identity-wizard.md) |
| 5 | QuickStart Flow | ✅ Complete | [phase-05](phase-05-quickstart-flow.md) |
| 6 | Full Flow | ✅ Complete | [phase-06](phase-06-full-flow.md) |
| 7 | Stack Management Commands | ✅ Complete | [phase-07](phase-07-stack-management-commands.md) |
| 8 | Doctor Command | ✅ Complete | [phase-08](phase-08-doctor-command.md) |
| 9 | Non-Interactive & Lifecycle | ✅ Complete | [phase-09](phase-09-non-interactive-and-upgrade.md) |

## Critical Constraints
1. Never write custom docker-compose.yml -- use official overlays only
2. Always `predefined` agent type (never `open`) -- avoids BOOTSTRAP.md trap
3. BOOTSTRAP.md must NEVER be seeded into user_context_files
4. `docker restart` after provisioning (5-min ContextFileInterceptor cache)
5. .env is ephemeral -- shell trap deletes after `docker compose up`
6. Docker Compose v2 plugin required -- reject v1 hyphen binary
7. All ports bound to 127.0.0.1
8. Reinstall reuses GATEWAY_TOKEN + ENCRYPTION_KEY + POSTGRES_PASSWORD
9. PG18 volume: `/var/lib/postgresql` (official overlay handles it)
10. `dm_policy=allowlist` set at `channels.instances.create` time

## Output Structure
```
goclaw-wizards/
  wizard.sh
  lib/  (colors|detect|deps|wizard-ui|secrets|ports|compose|stack|bootstrap|doctor).sh
  scripts/  identity-wizard.py  provision-agent.py
  templates/  soul-default.md.tpl  identity-default.md.tpl
```
