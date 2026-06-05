# Architecture

## Components

| Component | Tech | Responsibility |
|---|---|---|
| **WSO2 IS 7.3+** | Java/OSGi | OAuth2/OIDC provider, CIBA grant, federation (UAEPass), roles→scopes, branding. Version set via `ARG WSO2IS_VERSION` in `wso2-is-pack/Dockerfile` (the `wso2is-<version>.zip` is downloaded into `wso2-is-pack/`). |
| **orchestrator** | FastAPI | Serves the SPA; BFF login (Pattern C); chat router + composer; A2A client; SSE to the browser; reports proxy. Confidential OAuth client `orchestrator-mcp-client`. |
| **hr_agent / it_agent** | FastAPI | Specialist agents. Receive A2A calls, run **CIBA** to obtain on-behalf-of tokens, call their resource server via **MCP**. Each is its own OAuth client (`hr-agent-oauth` / `it-agent-oauth`) + WSO2 "Agent" identity. |
| **hr_server / it_server** | FastAPI | Resource servers. Expose **MCP tools** (`/mcp/tools/*`) and **REST** (`/api/me/*`, `/api/reports/*`). Enforce the F-04 six-step token validation. In-memory data stores. |
| **client** | static JS | The SPA (`app.js`/`index.html`/`styles.css`), served by the orchestrator at `/`. No tokens in the browser — only the `orch_sid` session cookie. |
| **libs/common** | Python | Shared `a2a/` (JSON-RPC client/server/models), `auth/` (CIBA client, JWT validator, actor-token provider, peer trust), `logging/`, `revocation/`. |

## Request flow (chat → action)

```
1. Browser → orchestrator  POST /api/chat            (session cookie)
2. orchestrator router decides tool calls (keyword or LLM)
3. orchestrator → agent    POST /a2a/message/send     (token-A, Bearer)
4. agent initiates CIBA at IS (login_hint = user, actor_token = agent's I4 token)
5. IS returns auth_req_id + auth_url
6. orchestrator pushes the consent widget to the SPA over SSE
7. user approves at IS (the consent window)
8. agent polls /oauth2/token → receives token-B (sub=user, act.sub=agent, scope=...)
9. agent → resource server POST /mcp/tools/<tool>    (token-B, Bearer)
10. resource server runs F-04 validation, executes, returns the result
11. orchestrator composes the reply, pushes chat_message over SSE
```

## Authentication patterns

### Pattern C — BFF login (token-A)
The browser never sees tokens. The orchestrator (confidential client
`orchestrator-mcp-client`) runs the auth-code + PKCE flow **server-side**:
`/authorize` → IS → `/agent-callback` (orchestrator backend) → code exchange →
**token-A** stored in the server-side session. The browser gets only the `orch_sid`
cookie. See `apps/orchestrator/auth/pattern_c.py`.

token-A carries the user's role-derived scopes (e.g. `hr_read_rest`) and an `act`
claim naming the orchestrator agent. The resource servers' REST endpoints accept
token-A (its `aud` = `orchestrator-mcp-client`, allowed via `*_REST_VALID_AUDIENCES`).

### CIBA — per-action consent (token-B / OBO)
For any agent action, the agent calls IS `/oauth2/ciba` with `login_hint` = the user
and its own **actor token**. IS returns an `auth_url` the SPA opens; the user approves;
the agent polls `/oauth2/token` for **token-B** (on-behalf-of: `sub`=user,
`act.sub`=agent, `aud`=agent, `scope`=the tool's scope). Token-B is cached per
`(user, scope)` for ~1 h (UC-06). See `libs/common/auth/ciba_client.py` and
`apps/*/ciba/orchestrator.py`.

### MCP token validation — F-04 (six steps)
Every MCP tool call validates token-B:
1. JWT signature (JWKS)  2. `iss`  3. `exp`  4. `aud` == this server's agent
5. `act.sub` ∈ trusted peer agents (depth-1)  6. required scope ⊆ token scopes
Plus step 7: a JTI **denylist** (revocation). See `apps/*/auth/validators.py`.

## A2A and the hr→it chain

The orchestrator talks to agents over **A2A** (JSON-RPC, two-phase: `message/send`
then long-poll `await`). For **onboarding**, the orchestrator fans out to both HR and
IT agents (each drives its own consent). Additionally, `hr_agent` makes a **peer A2A
call** to `it_agent`'s consent-free `/a2a/peer/onboard-kit` endpoint to fetch the
standard new-hire IT kit — a real hr→it chain that needs no extra consent (static
policy data). See `apps/hr_agent/peer/` and `apps/it_agent/peer/`.

## Identity model

Since S5.12 every OAuth app asserts **email as the OIDC subject**, so a user's `sub`
== their email across token-A, token-B, and federated logins. In-memory stores key on
that email. The shared `JWTClaims.effective_sub` returns the email when present so
store lookups are stable regardless of the issuing app's subject config.

Federated (UAEPass) users carry the UAEPass UUID as their raw subject; the IdP claim
mapping (`email` → user-id) plus `useMappedLocalSubject=true` on the apps resolves
them to the matching local account, so their **local roles drive OAuth scopes** and
the CIBA `login_hint` matches the consent-window user. See [UAEPASS.md](UAEPASS.md).

## Build & image optimization

- **wso2is** uses build context `./wso2-is-pack` (not the repo root), so the ~400 MB
  IS zip stays out of the five Python services' build context. With `.dockerignore`
  excluding `wso2-is-pack/`, `tempz/`, `docs/`, etc., the Python build context is ~2.6 MB.
- Python Dockerfiles copy `requirements.txt` and `pip install` **before** copying
  `libs/common` and app code, so editing code never busts the dependency layer
  (code-change rebuilds ~2 s).
- Env hygiene: `PYTHONDONTWRITEBYTECODE`, `PYTHONUNBUFFERED`, `--no-cache-dir`.
- Boot time is dominated by the WSO2 IS JVM (~40–60 s); the Python services boot in seconds.
