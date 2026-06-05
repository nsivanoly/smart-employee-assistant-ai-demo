#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

MASTER_TEMPLATE="$ROOT_DIR/config/master.env.template"
MASTER_ENV="$ROOT_DIR/config/master.env"
ORCH_ENV="$ROOT_DIR/apps/orchestrator/.env"
HR_AGENT_ENV="$ROOT_DIR/apps/hr_agent/.env"
IT_AGENT_ENV="$ROOT_DIR/apps/it_agent/.env"

IS_ADMIN_USER="${IS_ADMIN_USER:-admin}"
IS_ADMIN_PASS="${IS_ADMIN_PASS:-admin}"

COMPOSE_CMD=()

detect_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
  else
    echo "docker compose or docker-compose is required" >&2
    exit 1
  fi
}

compose_cmd() {
  "${COMPOSE_CMD[@]}" "$@"
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed or not on PATH" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  if command -v colima >/dev/null 2>&1; then
    echo "docker daemon is not reachable. Starting colima..."
    colima start
  else
    echo "docker daemon is not reachable. Start your Docker runtime and retry." >&2
    exit 1
  fi
fi

detect_compose_cmd

upsert_env_value() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  if grep -qE "^${key}=" "$env_file"; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$env_file" && rm -f "${env_file}.bak"
  else
    echo "${key}=${value}" >> "$env_file"
  fi
}

read_env_value() {
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
  [[ -n "$value" ]] || return 1
  echo "$value"
}

prompt_value() {
  local key="$1"
  local prompt_text="$2"
  local current default answer
  current="$(read_env_value "$key" "$MASTER_ENV" || true)"
  default="${current}"
  read -r -p "$prompt_text [${default:-empty}]: " answer
  if [[ -z "$answer" ]]; then
    answer="$default"
  fi
  upsert_env_value "$MASTER_ENV" "$key" "$answer"
}

ensure_required_value() {
  local key="$1"
  local prompt_text="$2"
  local current answer
  current="$(read_env_value "$key" "$MASTER_ENV" || true)"
  while [[ -z "$current" ]]; do
    read -r -p "$prompt_text [required]: " answer
    answer="${answer//$'\r'/}"
    if [[ -z "$answer" ]]; then
      echo "$key is required." >&2
      continue
    fi
    upsert_env_value "$MASTER_ENV" "$key" "$answer"
    current="$answer"
  done
}

wait_for_wso2() {
  local max_wait=300
  local deadline=$((SECONDS + max_wait))
  echo "Waiting for WSO2 IS readiness (JWKS + bootstrap marker) ..."
  while (( SECONDS < deadline )); do
    if curl -skf https://localhost:9443/oauth2/jwks >/dev/null 2>&1 \
      && [[ -f "$ROOT_DIR/.bootstrap/wso2is.ready" ]]; then
      echo "WSO2 IS is ready."
      return 0
    fi
    sleep 2
  done
  echo "WSO2 IS did not become ready in time." >&2
  return 1
}

start_wso2_only() {
  local build_mode="$1"
  # Clear stale marker so readiness reflects the current startup/bootstrap cycle.
  rm -f "$ROOT_DIR/.bootstrap/wso2is.ready"
  case "$build_mode" in
    cache)
      compose_cmd up -d --build wso2is
      ;;
    no-cache)
      compose_cmd build --no-cache wso2is
      compose_cmd up -d --force-recreate wso2is
      ;;
    skip)
      compose_cmd up -d wso2is
      ;;
  esac
}

start_full_stack() {
  local build_mode="$1"
  local app_services=(orchestrator hr_agent it_agent hr_server it_server)
  case "$build_mode" in
    cache)
      # Phase 2: build app images after envs are rendered.
      compose_cmd build "${app_services[@]}"
      # Start from built images and force container recreation so env_file is re-read.
      compose_cmd up -d --force-recreate --no-build "${app_services[@]}"
      ;;
    no-cache)
      # Phase 2: no-cache app builds after envs are rendered.
      compose_cmd build --no-cache "${app_services[@]}"
      compose_cmd up -d --force-recreate --no-build "${app_services[@]}"
      ;;
    skip)
      # Skip image builds but still recreate app services to pick up new env values.
      compose_cmd up -d --force-recreate --no-build "${app_services[@]}"
      ;;
  esac
}

env_file_value() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 1
  grep -E "^${key}=" "$file" | tail -n1 | cut -d'=' -f2-
}

container_env_value() {
  local service="$1"
  local key="$2"
  compose_cmd exec -T "$service" /bin/sh -lc "printenv $key 2>/dev/null || true"
}

verify_runtime_env_sync() {
  local expected actual

  expected="$(env_file_value "$ORCH_ENV" "ORCHESTRATOR_MCP_CLIENT_SECRET" || true)"
  actual="$(container_env_value orchestrator "ORCHESTRATOR_MCP_CLIENT_SECRET")"
  if [[ -n "$expected" && "$expected" != "$actual" ]]; then
    echo "runtime env mismatch: orchestrator ORCHESTRATOR_MCP_CLIENT_SECRET" >&2
    return 1
  fi

  expected="$(env_file_value "$ORCH_ENV" "ORCHESTRATOR_AGENT_OAUTH_CLIENT_SECRET" || true)"
  actual="$(container_env_value orchestrator "ORCHESTRATOR_AGENT_OAUTH_CLIENT_SECRET")"
  if [[ -n "$expected" && "$expected" != "$actual" ]]; then
    echo "runtime env mismatch: orchestrator ORCHESTRATOR_AGENT_OAUTH_CLIENT_SECRET" >&2
    return 1
  fi

  expected="$(env_file_value "$HR_AGENT_ENV" "HR_AGENT_OAUTH_CLIENT_SECRET" || true)"
  actual="$(container_env_value hr_agent "HR_AGENT_OAUTH_CLIENT_SECRET")"
  if [[ -n "$expected" && "$expected" != "$actual" ]]; then
    echo "runtime env mismatch: hr_agent HR_AGENT_OAUTH_CLIENT_SECRET" >&2
    return 1
  fi

  expected="$(env_file_value "$IT_AGENT_ENV" "IT_AGENT_OAUTH_CLIENT_SECRET" || true)"
  actual="$(container_env_value it_agent "IT_AGENT_OAUTH_CLIENT_SECRET")"
  if [[ -n "$expected" && "$expected" != "$actual" ]]; then
    echo "runtime env mismatch: it_agent IT_AGENT_OAUTH_CLIENT_SECRET" >&2
    return 1
  fi

  return 0
}

echo "⚙️  Choose build option:"
echo "  1) Build with cache   (default)"
echo "  2) Build without cache"
echo "  3) Skip build"
read -r -p "Select build option [1-3] (Enter = 1): " build_choice

BUILD_MODE="cache"
case "$build_choice" in
  1|"") BUILD_MODE="cache" ;;
  2) BUILD_MODE="no-cache" ;;
  3) BUILD_MODE="skip" ;;
  *) echo "Invalid build option" >&2; exit 1 ;;
esac

echo "🧹 Choose cleanup option before starting:"
echo "  1) Clean start (stop and remove all existing containers, volumes)   (default)"
echo "  2) Keep existing (start alongside running containers)"
echo "  3) Exit"
read -r -p "Select cleanup option [1-3] (Enter = 1): " cleanup_choice

case "$cleanup_choice" in
  1|"")
    compose_cmd down --volumes --remove-orphans || true
    ;;
  2)
    ;;
  3)
    echo "Exiting."
    exit 0
    ;;
  *)
    echo "Invalid cleanup option" >&2
    exit 1
    ;;
esac

if [[ ! -f "$MASTER_TEMPLATE" ]]; then
  echo "Missing master template: $MASTER_TEMPLATE" >&2
  exit 1
fi

echo "Preparing WSO2 baseline (startup + bootstrap + env generation)..."
start_wso2_only "$BUILD_MODE"
wait_for_wso2
# WSO2 container entrypoint already runs bootstrap on startup.
# To force an extra manual bootstrap, run with RUN_MANUAL_BOOTSTRAP=1 ./start.sh
if [[ "${RUN_MANUAL_BOOTSTRAP:-0}" == "1" ]]; then
  echo "RUN_MANUAL_BOOTSTRAP=1 -> running manual bootstrap pass..."
  "$ROOT_DIR/scripts/bootstrap-wso2is-entrypoint.sh"
else
  echo "Skipping manual bootstrap (entrypoint bootstrap already completed)."
fi
"$ROOT_DIR/scripts/generate-master-env.sh" "$MASTER_ENV"

echo
echo "Enter external configuration values (press Enter to keep current/default)."
prompt_value OPENAI_API_KEY "OPENAI_API_KEY (LLM key)"
prompt_value AMP_AGENT_API_KEY "AMP_AGENT_API_KEY"

"$ROOT_DIR/scripts/render-envs-from-master.sh" "$MASTER_ENV"

echo "Starting full stack..."
start_full_stack "$BUILD_MODE"

echo "Verifying runtime env sync..."
verify_runtime_env_sync || {
  echo "runtime env sync verification failed; refusing to continue." >&2
  exit 1
}

echo
echo "Stack started."
echo "WSO2 bootstrap: automatic via wso2is custom entrypoint."
