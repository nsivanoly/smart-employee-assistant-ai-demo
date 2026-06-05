#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE_FILE="$ROOT_DIR/config/master.env.template"
OUTPUT_FILE="${1:-$ROOT_DIR/config/master.env}"

ORCH_ENV="$ROOT_DIR/apps/orchestrator/.env"
HR_AGENT_ENV="$ROOT_DIR/apps/hr_agent/.env"
IT_AGENT_ENV="$ROOT_DIR/apps/it_agent/.env"

IS_ADMIN_USER="${IS_ADMIN_USER:-admin}"
IS_ADMIN_PASS="${IS_ADMIN_PASS:-admin}"
IS_BASE_URL="${IS_BASE_URL:-https://localhost:9443}"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Missing template: $TEMPLATE_FILE" >&2
  exit 1
fi

OLD_FILE=""
if [[ -f "$OUTPUT_FILE" ]]; then
  OLD_FILE="${OUTPUT_FILE}.bak.$$"
  cp "$OUTPUT_FILE" "$OLD_FILE"
fi

cp "$TEMPLATE_FILE" "$OUTPUT_FILE"

cleanup() {
  [[ -n "$OLD_FILE" && -f "$OLD_FILE" ]] && rm -f "$OLD_FILE"
}
trap cleanup EXIT

read_env() {
  local key="$1"
  local file="$2"
  [[ -f "$file" ]] || return 1
  local value
  value="$(grep -E "^${key}=" "$file" | tail -n1 | cut -d'=' -f2- || true)"
  value="${value%\r}"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  if [[ "$value" == '<'*'>' ]]; then
    return 1
  fi
  [[ -n "$value" ]] || return 1
  echo "$value"
}

upsert() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$file" && rm -f "$file.bak"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

set_if_present() {
  local key="$1"
  local value="$2"
  [[ -n "$value" ]] || return 0
  upsert "$OUTPUT_FILE" "$key" "$value"
}

wso2_reachable() {
  curl -skf "${IS_BASE_URL}/oauth2/jwks" >/dev/null 2>&1
}

wso2_app_client_id_by_name() {
  local app_name="$1"
  local app_id
  app_id="$(curl -sk -u "${IS_ADMIN_USER}:${IS_ADMIN_PASS}" "${IS_BASE_URL}/api/server/v1/applications?limit=500" \
    | jq -r --arg n "$app_name" '.applications[]? | select(.name==$n) | .id' | head -n1)"
  [[ -n "$app_id" ]] || return 1
  curl -sk -u "${IS_ADMIN_USER}:${IS_ADMIN_PASS}" "${IS_BASE_URL}/api/server/v1/applications/${app_id}" \
    | jq -r '.clientId // empty'
}

wso2_dcr_client_secret_by_client_id() {
  local client_id="$1"
  [[ -n "$client_id" ]] || return 1
  curl -sk -u "${IS_ADMIN_USER}:${IS_ADMIN_PASS}" \
    "${IS_BASE_URL}/api/identity/oauth2/dcr/v1.1/register/${client_id}" \
    | jq -r '.client_secret // empty'
}

wso2_agent_id_by_display_name() {
  local display_name="$1"
  curl -sk -u "${IS_ADMIN_USER}:${IS_ADMIN_PASS}" -H "Accept: application/scim+json" \
    "${IS_BASE_URL}/scim2/Agents?startIndex=1&count=500" \
    | jq -r --arg dn "$display_name" --arg schema "urn:scim:wso2:agent:schema" \
      '.Resources[]? | select((.[$schema].DisplayName // "") == $dn) | .id' \
    | head -n1
}

carry_old_value() {
  local key="$1"
  [[ -n "$OLD_FILE" && -f "$OLD_FILE" ]] || return 0
  local value
  value="$(read_env "$key" "$OLD_FILE" || true)"
  [[ -n "$value" ]] || return 0
  upsert "$OUTPUT_FILE" "$key" "$value"
}

# Carry operator-supplied values from previous master env.
for key in \
  LLM_FALLBACK_MODE OPENAI_BASE_URL OPENAI_API_HEADER OPENAI_API_KEY OPENAI_MODEL \
  AMP_OTEL_ENDPOINT AMP_AGENT_API_KEY INTERNAL_REVOKE_SHARED_SECRET \
  MASTER_WSO2_IS_BASE_URL_HOST MASTER_WSO2_IS_BASE_URL_SERVICE MASTER_ORCHESTRATOR_PUBLIC_URL MASTER_ALLOWED_ORIGINS
  do
  carry_old_value "$key"
done

ORCH_CLIENT_ID="$(read_env ORCHESTRATOR_MCP_CLIENT_ID "$ORCH_ENV" || true)"
ORCH_CLIENT_SECRET="$(read_env ORCHESTRATOR_MCP_CLIENT_SECRET "$ORCH_ENV" || true)"
ORCH_REDIRECT="$(read_env ORCHESTRATOR_MCP_CLIENT_REDIRECT_URI "$ORCH_ENV" || true)"
ORCH_POST_LOGOUT="$(read_env POST_LOGOUT_REDIRECT_URI "$ORCH_ENV" || true)"
ORCH_AGENT_ID="$(read_env ORCHESTRATOR_AGENT_ID "$ORCH_ENV" || true)"
ORCH_AGENT_SECRET="$(read_env ORCHESTRATOR_AGENT_SECRET "$ORCH_ENV" || true)"
ORCH_AGENT_OAUTH_ID="$(read_env ORCHESTRATOR_AGENT_OAUTH_CLIENT_ID "$ORCH_ENV" || true)"
ORCH_AGENT_OAUTH_SECRET="$(read_env ORCHESTRATOR_AGENT_OAUTH_CLIENT_SECRET "$ORCH_ENV" || true)"

HR_AGENT_ID="$(read_env HR_AGENT_ID "$HR_AGENT_ENV" || true)"
HR_AGENT_SECRET="$(read_env HR_AGENT_SECRET "$HR_AGENT_ENV" || true)"
HR_AGENT_OAUTH_ID="$(read_env HR_AGENT_OAUTH_CLIENT_ID "$HR_AGENT_ENV" || true)"
HR_AGENT_OAUTH_SECRET="$(read_env HR_AGENT_OAUTH_CLIENT_SECRET "$HR_AGENT_ENV" || true)"
HR_AGENT_REDIRECT="$(read_env HR_AGENT_REDIRECT_URI "$HR_AGENT_ENV" || true)"

IT_AGENT_ID="$(read_env IT_AGENT_ID "$IT_AGENT_ENV" || true)"
IT_AGENT_SECRET="$(read_env IT_AGENT_SECRET "$IT_AGENT_ENV" || true)"
IT_AGENT_OAUTH_ID="$(read_env IT_AGENT_OAUTH_CLIENT_ID "$IT_AGENT_ENV" || true)"
IT_AGENT_OAUTH_SECRET="$(read_env IT_AGENT_OAUTH_CLIENT_SECRET "$IT_AGENT_ENV" || true)"
IT_AGENT_REDIRECT="$(read_env IT_AGENT_REDIRECT_URI "$IT_AGENT_ENV" || true)"


if command -v jq >/dev/null 2>&1 && wso2_reachable; then
  ORCH_CLIENT_ID="$(wso2_app_client_id_by_name "orchestrator-mcp-client" || true)"
  ORCH_AGENT_OAUTH_ID="$(wso2_app_client_id_by_name "orchestrator-agent-oauth" || true)"
  HR_AGENT_OAUTH_ID="$(wso2_app_client_id_by_name "hr-agent-oauth" || true)"
  IT_AGENT_OAUTH_ID="$(wso2_app_client_id_by_name "it-agent-oauth" || true)"

  # Keep selected IDs and secrets in lock-step to avoid first-run drift when
  # duplicate app names exist in IS and lookup order changes.
  ORCH_CLIENT_SECRET="$(wso2_dcr_client_secret_by_client_id "$ORCH_CLIENT_ID" || true)"
  ORCH_AGENT_OAUTH_SECRET="$(wso2_dcr_client_secret_by_client_id "$ORCH_AGENT_OAUTH_ID" || true)"
  HR_AGENT_OAUTH_SECRET="$(wso2_dcr_client_secret_by_client_id "$HR_AGENT_OAUTH_ID" || true)"
  IT_AGENT_OAUTH_SECRET="$(wso2_dcr_client_secret_by_client_id "$IT_AGENT_OAUTH_ID" || true)"

  ORCH_AGENT_ID="$(wso2_agent_id_by_display_name "orchestrator-agent" || true)"
  HR_AGENT_ID="$(wso2_agent_id_by_display_name "hr-agent" || true)"
  IT_AGENT_ID="$(wso2_agent_id_by_display_name "it-agent" || true)"
fi

set_if_present ORCHESTRATOR_MCP_CLIENT_ID "$ORCH_CLIENT_ID"
set_if_present ORCHESTRATOR_MCP_CLIENT_SECRET "$ORCH_CLIENT_SECRET"
set_if_present ORCHESTRATOR_MCP_CLIENT_REDIRECT_URI "$ORCH_REDIRECT"
set_if_present POST_LOGOUT_REDIRECT_URI "$ORCH_POST_LOGOUT"
set_if_present ORCHESTRATOR_AGENT_ID "$ORCH_AGENT_ID"
set_if_present ORCHESTRATOR_AGENT_SECRET "$ORCH_AGENT_SECRET"
set_if_present ORCHESTRATOR_AGENT_OAUTH_CLIENT_ID "$ORCH_AGENT_OAUTH_ID"
set_if_present ORCHESTRATOR_AGENT_OAUTH_CLIENT_SECRET "$ORCH_AGENT_OAUTH_SECRET"

set_if_present HR_AGENT_ID "$HR_AGENT_ID"
set_if_present HR_AGENT_SECRET "$HR_AGENT_SECRET"
set_if_present HR_AGENT_OAUTH_CLIENT_ID "$HR_AGENT_OAUTH_ID"
set_if_present HR_AGENT_OAUTH_CLIENT_SECRET "$HR_AGENT_OAUTH_SECRET"
set_if_present HR_AGENT_REDIRECT_URI "$HR_AGENT_REDIRECT"

set_if_present IT_AGENT_ID "$IT_AGENT_ID"
set_if_present IT_AGENT_SECRET "$IT_AGENT_SECRET"
set_if_present IT_AGENT_OAUTH_CLIENT_ID "$IT_AGENT_OAUTH_ID"
set_if_present IT_AGENT_OAUTH_CLIENT_SECRET "$IT_AGENT_OAUTH_SECRET"
set_if_present IT_AGENT_REDIRECT_URI "$IT_AGENT_REDIRECT"


if [[ -n "$HR_AGENT_ID" || -n "$IT_AGENT_ID" ]]; then
  upsert "$OUTPUT_FILE" TRUSTED_SPECIALIST_SUBS "${HR_AGENT_ID},${IT_AGENT_ID}"
fi
set_if_present HR_EXPECTED_INBOUND_AUD "$ORCH_CLIENT_ID"
set_if_present IT_EXPECTED_INBOUND_AUD "$ORCH_CLIENT_ID"
set_if_present HR_SERVER_EXPECTED_AUD "$HR_AGENT_OAUTH_ID"
set_if_present IT_SERVER_EXPECTED_AUD "$IT_AGENT_OAUTH_ID"

echo "Generated master env: $OUTPUT_FILE"
