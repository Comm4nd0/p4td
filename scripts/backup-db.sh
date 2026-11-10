#!/usr/bin/env bash
# =============================================================================
# p4td backup: database, vaccination certificates, media
# =============================================================================
# One run takes, into $BACKUP_DIR (default <repo>/backups):
#
#   p4td-<stamp>.dump                  pg_dump, custom format (pg_restore reads it)
#   p4td-private-media-<stamp>.tar.gz  vaccination certificates (private-media/)
#   media-snapshots/<stamp>/           every file under media/, as hard links
#
# and keeps the newest $BACKUP_RETENTION of each (default 7).
#
# Every artefact is written under a ".partial" name and renamed only once it is
# complete, so a run that dies halfway never leaves something that looks like a
# backup — and never counts towards retention, where a week of truncated dumps
# used to be able to push out the last good one.
#
# media/ is a hard-link snapshot, not a tarball: dog gallery photos are medical
# records that cannot be re-taken, but the directory is far too big to copy
# nightly on this disk. A snapshot costs no space for files that haven't
# changed, and keeps a file that was deleted or swept by mistake for
# $BACKUP_RETENTION days. It needs $BACKUP_DIR on the same filesystem as media/.
#
# NONE OF THIS SURVIVES THE SERVER. Everything above is on the same disk as the
# thing it backs up. Set BACKUP_OFFBOX_CMD (in .env or the environment) to a
# command that copies it somewhere else; it runs after a successful backup with
# these exported:
#
#   BACKUP_DIR  BACKUP_DB_DUMP  BACKUP_PRIVATE_MEDIA_ARCHIVE
#   MEDIA_DIR   PRIVATE_MEDIA_DIR
#
# e.g. (rclone remote configured on the host out-of-band):
#
#   BACKUP_OFFBOX_CMD='rclone copy "$BACKUP_DB_DUMP" box:p4td/db && rclone copy "$BACKUP_PRIVATE_MEDIA_ARCHIVE" box:p4td/private && rclone copy "$MEDIA_DIR" box:p4td/media'
#
# Copy media from $MEDIA_DIR, not from media-snapshots/: the snapshots are hard
# links, and a tool that doesn't know that uploads every file once per night.
# Unset = no off-box copy, and the script says so every run.
#
# Monitoring: on full success it pings BACKUP_HEARTBEAT_URL, or
# "$P4TD_CRON_HEARTBEAT_URL/backup" when only that is set. Any failure — the
# dump, an archive, the snapshot, the off-box copy — exits non-zero and pings
# nothing, so a dead-man's-switch notices.
#
# Scheduled by scripts/install-cron.sh (which deploy.sh runs): nightly, 02:30
# UK time. Reads connection settings from RDS_* env vars (falls back to ./.env).
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
RETENTION="${BACKUP_RETENTION:-7}"   # how many of each artefact to keep
MEDIA_DIR="${MEDIA_DIR:-$REPO_ROOT/media}"
PRIVATE_MEDIA_DIR="${PRIVATE_MEDIA_DIR:-$REPO_ROOT/private-media}"
SNAPSHOT_DIR="$BACKUP_DIR/media-snapshots"

case "$RETENTION" in
    ''|*[!0-9]*|0) echo "ERROR: BACKUP_RETENTION must be a positive number, not '$RETENTION'." >&2; exit 1 ;;
esac

mkdir -p "$BACKUP_DIR"
# Dumps hold password hashes and login tokens; the certificate archive holds
# owners' names and addresses. Root only.
chmod 700 "$BACKUP_DIR"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
failures=0
note_failure() { echo "ERROR: $*" >&2; failures=$((failures + 1)); }

# Anything still called .partial belongs to a run that died (or to this one, if
# it is about to): clear them on the way in and on the way out.
clean_partials() {
    rm -f "$BACKUP_DIR"/*.partial 2>/dev/null || true
    if [ -d "$SNAPSHOT_DIR" ]; then
        find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -name '*.partial' -exec rm -rf {} + 2>/dev/null || true
    fi
}
clean_partials
trap clean_partials EXIT

# --- 1. Database --------------------------------------------------------------
BACKUP_DB_DUMP="$BACKUP_DIR/p4td-${TIMESTAMP}.dump"
echo ">>> [$TIMESTAMP] Backing up database '$DB_NAME' to $BACKUP_DB_DUMP"

# Run pg_dump inside the db container so we don't need a client on the host.
# Custom format (-Fc) is compressed and restorable with pg_restore. The dump is
# the one artefact nothing else can stand in for, so its failure ends the run.
if ! PGPASSWORD="$DB_PASSWORD" docker compose -f "$REPO_ROOT/$COMPOSE_FILE" exec -T \
        -e PGPASSWORD="$DB_PASSWORD" db \
        pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$BACKUP_DB_DUMP.partial"; then
    echo "ERROR: pg_dump failed — no dump was kept." >&2
    exit 1
fi
# Guard against a silently-empty dump (e.g. auth failure that still exits 0).
if [ ! -s "$BACKUP_DB_DUMP.partial" ]; then
    echo "ERROR: backup file is empty — aborting." >&2
    exit 1
fi
mv "$BACKUP_DB_DUMP.partial" "$BACKUP_DB_DUMP"
echo ">>> Database dump complete: $(du -h "$BACKUP_DB_DUMP" | cut -f1)"

# --- 2. Vaccination certificates ----------------------------------------------
# private-media/ is never in the database and never under media/ — see
# api/certificates.py. It is the vet's paperwork and cannot be recreated, and it
# is small, so a full archive travels with every dump.
BACKUP_PRIVATE_MEDIA_ARCHIVE=""
if [ -d "$PRIVATE_MEDIA_DIR" ]; then
    archive="$BACKUP_DIR/p4td-private-media-${TIMESTAMP}.tar.gz"
    echo ">>> Archiving private-media/ to $archive"
    if tar -czf "$archive.partial" -C "$(dirname "$PRIVATE_MEDIA_DIR")" "$(basename "$PRIVATE_MEDIA_DIR")"; then
        mv "$archive.partial" "$archive"
        BACKUP_PRIVATE_MEDIA_ARCHIVE="$archive"
        echo ">>> Archive complete: $(du -h "$archive" | cut -f1)"
    else
        rm -f "$archive.partial"
        note_failure "could not archive private-media/."
    fi
else
    echo ">>> No private-media/ directory; nothing to archive."
fi

# --- 3. Media snapshot --------------------------------------------------------
if [ "${BACKUP_MEDIA_SNAPSHOT:-1}" = "0" ]; then
    echo ">>> Media snapshot skipped (BACKUP_MEDIA_SNAPSHOT=0)."
elif [ -d "$MEDIA_DIR" ]; then
    mkdir -p "$SNAPSHOT_DIR"
    snapshot="$SNAPSHOT_DIR/$TIMESTAMP"
    echo ">>> Snapshotting media/ to $snapshot (hard links)"
    # cp -al: directories are real, files are links to the same data. Fails
    # (rather than quietly copying gigabytes) when $BACKUP_DIR is on another
    # filesystem.
    if cp -al "$MEDIA_DIR" "$snapshot.partial"; then
        mv "$snapshot.partial" "$snapshot"
        echo ">>> Snapshot complete: $(find "$snapshot" -type f | wc -l) file(s)"
    else
        rm -rf "$snapshot.partial"
        note_failure "could not snapshot media/ (is $BACKUP_DIR on the same filesystem as $MEDIA_DIR?)."
    fi
else
    echo ">>> No media/ directory; nothing to snapshot."
fi

# --- 4. Retention -------------------------------------------------------------
# Newest $RETENTION of each kind stay. Only complete artefacts carry these
# names, so this can never trade a good backup for a truncated one.
echo ">>> Pruning old backups (keeping $RETENTION of each)..."
prune_files() {
    # shellcheck disable=SC2012  # names are ours: timestamps, no whitespace
    { ls -1t "$@" 2>/dev/null || true; } | tail -n +$((RETENTION + 1)) | while read -r old; do
        echo "    removing $old"
        rm -f "$old"
    done
}
prune_files "$BACKUP_DIR"/p4td-*.dump
prune_files "$BACKUP_DIR"/p4td-private-media-*.tar.gz
if [ -d "$SNAPSHOT_DIR" ]; then
    # Snapshot names are UTC timestamps, so name order is age order.
    find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' | sort -r \
        | tail -n +$((RETENTION + 1)) | while read -r old; do
            echo "    removing $old"
            rm -rf "$old"
        done
fi

# --- 5. Off-box copy ----------------------------------------------------------
export BACKUP_DIR BACKUP_DB_DUMP BACKUP_PRIVATE_MEDIA_ARCHIVE MEDIA_DIR PRIVATE_MEDIA_DIR
if [ -n "${BACKUP_OFFBOX_CMD:-}" ]; then
    echo ">>> Copying off-box (BACKUP_OFFBOX_CMD)..."
    if bash -c "$BACKUP_OFFBOX_CMD"; then
        echo ">>> Off-box copy complete."
    else
        note_failure "the off-box copy failed — tonight's backup exists only on this server."
    fi
else
    echo ">>> WARNING: BACKUP_OFFBOX_CMD is not set. This backup exists only on this"
    echo ">>> server and dies with it. See the header of $0."
fi

# --- 6. Report ----------------------------------------------------------------
if [ "$failures" -gt 0 ]; then
    echo ">>> Backup finished with $failures problem(s); heartbeat not pinged." >&2
    exit 1
fi

heartbeat="${BACKUP_HEARTBEAT_URL:-}"
if [ -z "$heartbeat" ] && [ -n "${P4TD_CRON_HEARTBEAT_URL:-}" ]; then
    heartbeat="${P4TD_CRON_HEARTBEAT_URL%/}/backup"
fi
if [ -n "$heartbeat" ]; then
    # Best effort: monitoring must never fail the backup it reports on.
    if command -v curl >/dev/null 2>&1; then
        curl -fsS -m 10 -o /dev/null "$heartbeat" || echo ">>> Heartbeat ping failed (backup itself is fine)."
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 10 -O /dev/null "$heartbeat" || echo ">>> Heartbeat ping failed (backup itself is fine)."
    fi
fi

echo ">>> Done."
