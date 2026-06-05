#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed or not on PATH" >&2
  exit 1
fi

COMPOSE_CMD=()
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
else
  echo "docker compose or docker-compose is required" >&2
  exit 1
fi

compose_cmd() {
  "${COMPOSE_CMD[@]}" "$@"
}

echo "Select cleanup level:"
echo "  1) Graceful stop only (preserve everything)"
echo "  2) Stop and remove volumes"
echo "  3) Full cleanup (remove all images and networks)"
echo "  4) Exit"
read -r -p "Choose [1-4]: " choice

case "$choice" in
  1|"")
    compose_cmd stop
    echo "Services stopped (containers/volumes/images preserved)."
    ;;
  2)
    compose_cmd down --volumes --remove-orphans
    echo "Services stopped and project volumes removed."
    ;;
  3)
    compose_cmd down --volumes --remove-orphans --rmi all
    docker network prune -f >/dev/null 2>&1 || true
    echo "Full cleanup completed (project images removed; unused networks pruned)."
    ;;
  4)
    echo "Exit."
    ;;
  *)
    echo "Invalid option." >&2
    exit 1
    ;;
esac
