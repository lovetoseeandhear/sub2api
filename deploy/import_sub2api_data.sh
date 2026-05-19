#!/usr/bin/env bash
set -euo pipefail

# Import sub2api data package on target server.
# Supports:
# 1) export directory: sub2api_export_YYYYmmdd_HHMMSS/
# 2) tar.gz package:   sub2api_export_YYYYmmdd_HHMMSS.tar.gz

# Usage:
#   ./import_sub2api_data.sh /path/to/sub2api_export_*.tar.gz
#   ./import_sub2api_data.sh /path/to/sub2api_export_*
#
# Optional env vars:
#   POSTGRES_CONTAINER=postgres
#   SUB2API_CONTAINER=sub2api
#   DB_USER=root
#   DB_NAME=sub2api
#   WORKDIR=/tmp/sub2api_import

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-postgres}"
SUB2API_CONTAINER="${SUB2API_CONTAINER:-sub2api}"
DB_USER="${DB_USER:-root}"
DB_NAME="${DB_NAME:-sub2api}"
WORKDIR="${WORKDIR:-/tmp/sub2api_import}"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <export_dir_or_tar.gz>" >&2
  exit 1
fi

SRC_PATH="$1"
mkdir -p "$WORKDIR"

resolve_export_dir() {
  local src="$1"
  if [[ -d "$src" ]]; then
    echo "$src"
    return 0
  fi

  if [[ -f "$src" && "$src" == *.tar.gz ]]; then
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    local dest="$WORKDIR/unpack_$ts"
    mkdir -p "$dest"
    tar xzf "$src" -C "$dest"

    # Expect a single top-level export folder.
    local found
    found="$(find "$dest" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
    if [[ -z "$found" ]]; then
      echo "ERROR: invalid tar.gz, no export directory found" >&2
      exit 1
    fi
    echo "$found"
    return 0
  fi

  echo "ERROR: input must be export directory or .tar.gz file: $src" >&2
  exit 1
}

check_prerequisites() {
  docker ps --format '{{.Names}}' | grep -qx "$POSTGRES_CONTAINER" || {
    echo "ERROR: postgres container not running: $POSTGRES_CONTAINER" >&2
    exit 1
  }
  docker ps --format '{{.Names}}' | grep -qx "$SUB2API_CONTAINER" || {
    echo "ERROR: sub2api container not running: $SUB2API_CONTAINER" >&2
    exit 1
  }
}

restore_db() {
  local export_dir="$1"
  local dump_file="$export_dir/sub2api_db.dump"
  [[ -f "$dump_file" ]] || { echo "ERROR: dump file not found: $dump_file" >&2; exit 1; }

  echo "[1/4] Ensure target database exists: $DB_NAME"
  docker exec -i "$POSTGRES_CONTAINER" psql -U "$DB_USER" -d postgres -c "CREATE DATABASE \"$DB_NAME\";" >/dev/null 2>&1 || true

  echo "[2/4] Restoring database dump"
  docker exec -i "$POSTGRES_CONTAINER" pg_restore -U "$DB_USER" -d "$DB_NAME" --clean --if-exists --no-owner --no-privileges < "$dump_file"
}

restore_app_data() {
  local export_dir="$1"
  local app_data_dir="$export_dir/app_data/data"
  [[ -d "$app_data_dir" ]] || { echo "ERROR: app data directory not found: $app_data_dir" >&2; exit 1; }

  echo "[3/4] Backing up current /app/data in container"
  docker exec -i "$SUB2API_CONTAINER" sh -lc 'cp -a /app/data /app/data.bak.$(date +%Y%m%d_%H%M%S)'

  echo "[3/4] Restoring /app/data"
  docker cp "$app_data_dir/." "$SUB2API_CONTAINER:/app/data/"
}

restart_and_verify() {
  echo "[4/4] Restarting sub2api"
  docker restart "$SUB2API_CONTAINER" >/dev/null

  echo "Waiting for container status..."
  sleep 2
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E "^${SUB2API_CONTAINER}[[:space:]]" || true

  echo "Recent logs:"
  docker logs --tail 80 "$SUB2API_CONTAINER" || true
}

main() {
  check_prerequisites
  local export_dir
  export_dir="$(resolve_export_dir "$SRC_PATH")"

  echo "Using export directory: $export_dir"
  restore_db "$export_dir"
  restore_app_data "$export_dir"
  restart_and_verify

  echo ""
  echo "Import completed."
}

main
