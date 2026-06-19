#!/usr/bin/env bash
# =============================================================================
# p4td PostgreSQL backup
# =============================================================================
# Takes a compressed custom-format pg_dump of the production database and prunes
# to a rolling retention window (default: keep the 7 most recent dumps).
#
# MANUAL DEPLOY STEPS (not automated by this script):
#   1. Wire to host cron, e.g. daily at 02:30:
#        30 2 * * * cd /home/<user>/p4td && ./scripts/backup-db.sh >> /var/log/p4td-backup.log 2>&1
#   2. SHIP THE DUMP OFF-BOX. Local dumps die with the server — they are NOT a
#      real backup until copied off the host. After this script runs, push the
#      backups dir to remote storage, e.g.:
#        rclone copy "$BACKUP_DIR" hetzner-storagebox:p4td-backups   # Storage Box
#        restic backup "$BACKUP_DIR"                                 # restic repo
#        aws s3 sync "$BACKUP_DIR" s3://your-bucket/p4td-backups/    # S3
#      Configure rclone/restic/aws credentials on the host out-of-band.
#
# Reads connection settings from RDS_* env vars (falls back to ./.env).
# =============================================================================

set -euo pipefail

# Resolve repo root from this script's location so cron can call it by path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env if present (does not override already-exported env vars).
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$REPO_ROOT/.env"
    set +a
fi

DB_NAME="${RDS_DB_NAME:-p4td}"
DB_USER="${RDS_USERNAME:-postgres}"
DB_PASSWORD="${RDS_PASSWORD:-}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.prod.yml}"

BACKUP_DIR="${BACKUP_DIR:-$REPO_ROOT/backups}"
RETENTION="${BACKUP_RETENTION:-7}"   # number of dumps to keep

mkdir -p "$BACKUP_DIR"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTFILE="$BACKUP_DIR/p4td-${TIMESTAMP}.dump"

echo ">>> Backing up database '$DB_NAME' to $OUTFILE"

# Run pg_dump inside the db container so we don't need a client on the host.
# Custom format (-Fc) is compressed and restorable with pg_restore.
PGPASSWORD="$DB_PASSWORD" docker compose -f "$REPO_ROOT/$COMPOSE_FILE" exec -T \
    -e PGPASSWORD="$DB_PASSWORD" db \
    pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$OUTFILE"

# Guard against a silently-empty dump (e.g. auth failure that still exits 0).
if [ ! -s "$OUTFILE" ]; then
    echo "ERROR: backup file is empty — aborting." >&2
    rm -f "$OUTFILE"
    exit 1
fi

echo ">>> Backup complete: $(du -h "$OUTFILE" | cut -f1)"

# Prune: keep the newest $RETENTION dumps, delete the rest.
echo ">>> Pruning old backups (keeping $RETENTION)..."
ls -1t "$BACKUP_DIR"/p4td-*.dump 2>/dev/null | tail -n +$((RETENTION + 1)) | while read -r old; do
    echo "    removing $old"
    rm -f "$old"
done

echo ">>> Done. REMEMBER: ship $BACKUP_DIR off-box (see header)."
