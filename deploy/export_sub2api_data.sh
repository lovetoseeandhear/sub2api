#!/usr/bin/env bash
set -euo pipefail

# Export local sub2api data for migration to production.
# Includes:
# 1) PostgreSQL dump of sub2api database from existing postgres container
# 2) /app/data files from sub2api container
# 3) import instructions

# Configurable env vars
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-postgres}"
SUB2API_CONTAINER="${SUB2API_CONTAINER:-sub2api}"
DB_NAME="${DB_NAME:-sub2api}"
DB_USER="${DB_USER:-root}"
EXPORT_ROOT="${EXPORT_ROOT:-$(pwd)/exports}"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
EXPORT_DIR="${EXPORT_ROOT}/sub2api_export_${TIMESTAMP}"

mkdir -p "${EXPORT_DIR}"

echo "[1/5] Checking docker containers..."
docker ps --format '{{.Names}}' | grep -qx "${POSTGRES_CONTAINER}" || {
  echo "ERROR: postgres container not found: ${POSTGRES_CONTAINER}" >&2
  exit 1
}
docker ps --format '{{.Names}}' | grep -qx "${SUB2API_CONTAINER}" || {
  echo "ERROR: sub2api container not found: ${SUB2API_CONTAINER}" >&2
  exit 1
}

echo "[2/5] Exporting PostgreSQL database: ${DB_NAME}"
docker exec -i "${POSTGRES_CONTAINER}" pg_dump -U "${DB_USER}" -d "${DB_NAME}" -Fc > "${EXPORT_DIR}/sub2api_db.dump"

echo "[3/5] Exporting sub2api app data directory (/app/data)"
docker cp "${SUB2API_CONTAINER}:/app/data" "${EXPORT_DIR}/app_data"

echo "[4/5] Writing import guide"
cat > "${EXPORT_DIR}/IMPORT_ON_SERVER.md" <<'GUIDE'
# Import sub2api data on target server

## 1) Upload package
Copy this export folder (or .tar.gz) to target server.

## 2) Restore PostgreSQL database
Assume target postgres container name: postgres

```bash
# create db if not exists
docker exec -i postgres psql -U root -d postgres -c 'CREATE DATABASE "sub2api";' || true

# restore
docker exec -i postgres pg_restore -U root -d sub2api --clean --if-exists --no-owner --no-privileges < sub2api_db.dump
```

## 3) Restore /app/data
Assume target sub2api container name: sub2api

```bash
# optional backup before overwrite
docker exec -i sub2api sh -lc 'cp -a /app/data /app/data.bak.$(date +%Y%m%d_%H%M%S)'

# copy exported data back
docker cp app_data/data/. sub2api:/app/data/
```

## 4) Restart sub2api
```bash
docker restart sub2api
```

## 5) Verify
- Login admin panel
- Check accounts/channels/settings
- Check `/health`
GUIDE

echo "[5/5] Creating compressed archive"
(
  cd "${EXPORT_ROOT}"
  tar czf "sub2api_export_${TIMESTAMP}.tar.gz" "sub2api_export_${TIMESTAMP}"
)

echo ""
echo "Export completed:"
echo "- Folder : ${EXPORT_DIR}"
echo "- Archive: ${EXPORT_ROOT}/sub2api_export_${TIMESTAMP}.tar.gz"
echo ""
echo "Files:"
ls -lh "${EXPORT_DIR}"
