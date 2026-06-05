# srt-emp — Smart Employee Agent Demo

An agentic **employee self-service** assistant built on **WSO2 Identity Server 7.3**.
Employees and HR admins chat with an orchestrator that routes requests to specialist
**HR** and **IT** agents. Every action an agent performs on the user's behalf is
gated by **per-action consent (CIBA)**, and every data call is authorized by
**scoped OAuth tokens** validated at the resource server.

It demonstrates a modern agentic-identity pattern:

```
Browser SPA ──(BFF login, Pattern C)──► Orchestrator ──A2A──► HR / IT Agent ──CIBA──► WSO2 IS
                                              │                      │
                                              └── serves SPA         └── MCP tool call ──► HR / IT Server (token-B)
```

- **Backend-for-Frontend (BFF)** login — the browser holds only a session cookie; tokens live server-side.
- **A2A** (Agent-to-Agent, JSON-RPC) between orchestrator and specialists.
- **CIBA** (Client-Initiated Backchannel Authentication) for out-of-band, per-action user consent.
- **MCP** (Model Context Protocol) tools at the resource servers, behind F-04 token validation.
- **UAEPass** federated login (staging) with JIT → local-account role mapping.

---

## Table of contents

- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Services & ports](#services--ports)
- [Demo users](#demo-users)
- [Try it (test scenarios)](#try-it-test-scenarios)
- [Configuration](#configuration)
- [Development workflow](#development-workflow)
- [Observability / tracing](#observability--tracing)
- [UAEPass federated login](#uaepass-federated-login)
- [Project layout](#project-layout)
- [Troubleshooting](#troubleshooting)
- [Further docs](#further-docs)

---

## Prerequisites

| Requirement | Notes |
|---|---|
| **Docker** | Docker Desktop, **Colima**, or any Docker engine. |
| **Memory** | The container VM needs **≥ 8 GB** — WSO2 IS alone needs ~1.5–2 GB. On Colima: `colima start --memory 8 --cpu 4`. |
| **`docker compose`** or **`docker-compose`** | `start.sh` auto-detects either. |
| **Outbound internet** | Required for image pulls, LLM calls, and (optionally) UAEPass staging. |
| **The WSO2 IS pack** | You must **download** the IS distribution zip and place it in `wso2-is-pack/` — see below. It is **git-ignored** (~400 MB, too large to commit). |

Optional (only if `LLM_FALLBACK_MODE=llm`): an OpenAI-compatible API key. The default
mode is `keyword`, which needs no LLM.

### Download the WSO2 Identity Server pack (required)

The build needs the IS distribution zip. **Version must be 7.3.0 or newer.**

1. Download `wso2is-<version>.zip` from one of:
   - https://wso2.com/identity-server/
   - https://github.com/wso2/product-is/releases
2. Place it **inside `wso2-is-pack/`** keeping the original filename, e.g.:
   ```
   wso2-is-pack/wso2is-7.3.0.zip      # default
   wso2-is-pack/wso2is-7.4.0.zip      # a newer release
   ```
3. **If you use a version other than 7.3.0**, set the version so the build picks the
   right file — either:
   - **env override (no edits):** `WSO2IS_VERSION=7.4.0 ./start.sh`, or
   - **edit the Dockerfile directly:** change the one line in
     `wso2-is-pack/Dockerfile`:
     ```dockerfile
     ARG WSO2IS_VERSION=7.4.0
     ```
   That single value drives both the `COPY wso2is-<version>.zip` and the unpack step —
   nothing else to change.

```bash
# verify the pack is in place before starting
ls wso2-is-pack/wso2is-*.zip
```

> The UAEPass connector in this repo is recompiled for IS 7.3 / Nimbus 10. If a much
> newer IS ships a different Nimbus major, the connector may need re-compiling — see
> [docs/UAEPASS.md](docs/UAEPASS.md#connector-compatibility-is-73--nimbus-10).

---

## Quick start

```bash
# 1. Download the WSO2 IS pack (>= 7.3.0) into wso2-is-pack/ — see
#    "Download the WSO2 Identity Server pack" above. Verify:
ls wso2-is-pack/wso2is-*.zip

# 2. Start everything (builds images, boots WSO2 IS, runs bootstrap,
#    generates env files, then starts the full stack)
./start.sh
#    (for a non-default IS version: WSO2IS_VERSION=7.4.0 ./start.sh)

# 3. Open the app
open http://localhost:8090
```

`start.sh`:
1. Starts the Docker runtime (auto-`colima start` if needed).
2. Builds + boots **WSO2 IS**, which runs the **bootstrap** (`scripts/bootstrap-wso2is-entrypoint.sh`) to create OAuth apps, API resources, scopes, roles, demo users, the UAEPass IdP, and branding.
3. Generates `config/master.env` from the live IS, prompts for `OPENAI_API_KEY` / `AMP_AGENT_API_KEY` (press Enter to skip), and renders per-service `.env` files.
4. Builds + starts the five application services.

**Stop / clean up:**

```bash
./stop.sh        # interactive: graceful stop / remove volumes / full cleanup
```

---

## Services & ports

| Service | URL / port | Role |
|---|---|---|
| **wso2is** | `https://localhost:9443` (Console + OAuth), `9763` | Identity Server — OAuth/OIDC, CIBA, federation. Admin: `admin` / `admin`. |
| **orchestrator** | `http://localhost:8090` | Serves the SPA **and** the chat/reports API. BFF login, A2A client, chat router. |
| **hr_agent** | `127.0.0.1:8001` (loopback) | HR specialist — A2A inbound, CIBA, calls hr_server via MCP. |
| **it_agent** | `127.0.0.1:8002` (loopback) | IT specialist — A2A inbound, CIBA, calls it_server via MCP. |
| **hr_server** | `127.0.0.1:8000` (loopback) | HR resource server — MCP tools + REST (`/api/me/*`, `/api/reports/*`). |
| **it_server** | `127.0.0.1:8004` (loopback) | IT resource server — MCP tools + REST. |

Only the orchestrator (`:8090`) and WSO2 IS (`:9443`) are exposed to the host; the
agents and resource servers bind to loopback (defense-in-depth).

Check health: `docker compose ps` (all should be `healthy`).

---

## Demo users

| Username (= email) | Password | Role | Login path |
|---|---|---|---|
| `employee@example.com` | `NewsMax@1234` | employee | local (Basic) |
| `hradmin@example.com` | `NewsMax@1234` | HR Admin | local (Basic) |
| `sivanoly@wso2.com` | (UAEPass) | HR Admin | UAEPass federated (JIT) |
| `ramith@wso2.com` | (UAEPass) | employee | UAEPass federated (JIT) |

Roles drive scopes: **employee** → `hr_basic_rest`, `hr_self_rest`, `it_assets_self_rest`;
**HR Admin** → all of employee's plus `hr_read_rest`, `hr_approve_rest`,
`hr_assets_write_rest`, `it_assets_read_rest`, `it_assets_write_rest`.

---

## Try it (test scenarios)

Sign in at `http://localhost:8090` (local Basic or "Sign in with UAEPass"), then chat:

**Reads (scope-checked, may prompt CIBA consent the first time):**
- `what laptops are available`
- `show my leave balance`
- `where is my cubicle`

**Writes (each triggers a CIBA consent widget → Approve):**
- `apply 5 days annual from 20th june 2026`
- `on board employee@example.com and allocate cubical and laptop and phone`
  → guided flow: pick a floor → pick a seat (e.g. `C-012`) ; HR agent also fetches the
  standard IT kit from the IT agent (A2A coordination).

**HR Admin only — the Reports tab (`:8090` → Reports):**
- **Pending Leaves** — approve / reject (CIBA-driven)
- **Cubicles** — current seat assignments
- **Devices** — issued IT assets

**Sidebar** (all users): My Leaves, My Cubicle, My IT Assets.

> **Consent caching (UC-06):** after you approve once, the agent caches the token
> for ~1 hour, so repeat actions are silent. To force the consent UX again, restart
> the agents: `docker compose restart hr_agent it_agent`.

---

## Configuration

Config is layered:

| File | Purpose | Committed? |
|---|---|---|
| `config/master.env.template` | Template with safe blanks | ✅ |
| `config/master.env` | Generated, holds live client IDs/secrets | ❌ (gitignored) |
| `apps/<svc>/.env.example` | Per-service template | ✅ |
| `apps/<svc>/.env` | Per-service runtime config (rendered) | ❌ (gitignored) |
| `docker-compose.yml` | Base stack (production-style) | ✅ |
| `docker-compose.override.yml` | **Dev** override: source mounts + `--reload` (auto-merged by `docker compose`) | ✅ |

Key env vars:
- `LLM_FALLBACK_MODE` — `keyword` (default, no LLM) or `llm` (needs `OPENAI_API_KEY`).
- `ENABLE_API_TRACES` — `0`/`1`, per service `.env` (see [tracing](#observability--tracing)).
- `*_EXPECTED_AUD`, `*_REST_VALID_AUDIENCES` — token audience wiring (auto-derived by the render script).

The bootstrap is **idempotent** — re-running it (or restarting `wso2is`) reconciles
config without duplicating apps.

---

## Development workflow

The committed `docker-compose.override.yml` mounts source into the containers and runs
the apps under `uvicorn --reload`, so most Python edits hot-reload.

```bash
docker compose up -d                 # base + override (dev)
docker compose -f docker-compose.yml up -d   # base only (no dev mounts)
```

**Caveats (macOS + Colima/VirtioFS):**
- File-watch reload can miss changes in mounted dirs; if an edit doesn't take,
  `docker compose restart <service>`.
- Changes to `libs/common` (shared) reliably need a restart of the consuming services.
- `requirements.txt` changes need a rebuild: `docker compose build <svc> && docker compose up -d <svc>`.

**Image builds are optimized** (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#build--image-optimization)):
- `wso2is` has its own build context, so the 400 MB pack is kept out of the Python
  services' build context (~2.6 MB).
- Dockerfiles install deps before copying code, so editing app code rebuilds in ~2 s.

---

## Observability / tracing

Spans export to the WSO2 AMP OpenTelemetry endpoint via Traceloop (the
`amp-instrument` wrapper). Business spans (`chat_fan_out.workflow`, `llm_router.task`,
agent dispatch/CIBA) are always on.

**API/HTTP request tracing is OFF by default** (it's noisy — `/events` SSE, `/healthz`,
proxy calls). Toggle per service in `apps/<svc>/.env`:

```
ENABLE_API_TRACES=0   # off (quiet): only business spans
ENABLE_API_TRACES=1   # on: + FastAPI server spans + httpx client spans + cross-service nesting
```

Set on `orchestrator`, `hr_agent`, `it_agent`, then
`docker compose up -d orchestrator hr_agent it_agent`.

---

## UAEPass federated login

The stack ships the UAEPass OIDC connector (recompiled for IS 7.3 / Nimbus 10) and the
bootstrap configures a **staging** UAEPass IdP with **JIT provisioning** that maps the
federated user to a local account by email, so federated users inherit local roles/scopes.
Branding (logo, colours, uaepass.ae links) is applied **only to the client app's login
page**, not the whole IS Console.

Full details and the design rationale: **[docs/UAEPASS.md](docs/UAEPASS.md)**.

---

## Project layout

```
srt-emp/
├── apps/
│   ├── orchestrator/     # BFF login, chat router/composer, A2A client, SSE, reports proxy
│   ├── hr_agent/         # HR specialist: A2A handler, CIBA orchestrator, MCP client, it-peer client
│   ├── it_agent/         # IT specialist: A2A handler, CIBA orchestrator, MCP client, peer endpoint
│   ├── hr_server/        # HR resource server: MCP tools + REST, F-04 JWT validator, in-memory store
│   ├── it_server/        # IT resource server: MCP tools + REST, F-04 JWT validator, in-memory store
│   └── client/           # SPA source (app.js/index.html/styles.css) — served BY the orchestrator
├── libs/common/          # Shared: a2a/, auth/ (CIBA, JWT, actor tokens, peer trust), logging, revocation
├── wso2-is-pack/         # IS Dockerfile (ARG WSO2IS_VERSION), entrypoint, UAEPass connector + assets
│                         #   ↳ download wso2is-<version>.zip here (>= 7.3.0; gitignored)
├── scripts/              # bootstrap-wso2is-entrypoint.sh, render-envs / generate-master-env
├── config/               # master.env(.template)
├── docs/                 # architecture, UAEPass, troubleshooting
├── docker-compose.yml    # base stack
├── docker-compose.override.yml  # dev override (committed; auto-merged in dev)
├── start.sh / stop.sh
└── README.md
```

---

## Troubleshooting

Common issues and fixes are in **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**.
Highlights:

- **WSO2 IS `Killed` / OOM** → raise the Docker VM memory (Colima: `colima start --memory 8`).
- **Reports show "Sign in to view reports."** → stale session cookie; hard-refresh / re-login.
- **403 `insufficient_scope`** → token-A lacks role scopes; re-login (esp. after a clean start).
- **Consent window shows a login page** → the agent app needs the federated session; covered in docs.
- **Build is slow** → ensure `wso2-is-pack/` is excluded from the Python build context (it is, via `.dockerignore`).

---

## Further docs

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — services, auth flows (Pattern C, CIBA, MCP/F-04), A2A chain, identity model, build optimization.
- **[docs/UAEPASS.md](docs/UAEPASS.md)** — UAEPass federation setup, JIT role mapping, connector compatibility, branding.
- **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** — symptom → cause → fix.
