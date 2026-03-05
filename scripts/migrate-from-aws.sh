#!/bin/bash
# Migrate data from AWS (RDS + S3) to local files for Hetzner transfer
# Prerequisites: aws CLI configured, pg_dump available
#
# Usage: ./scripts/migrate-from-aws.sh
# Output: migration-data/db-dump.sql and migration-data/media/

set -e

# Load AWS config
if [ -f "aws-config.env" ]; then
    source aws-config.env
else
    echo "Error: aws-config.env not found."
    echo "This file should contain RDS_HOSTNAME, RDS_DB_NAME, RDS_USERNAME, RDS_PASSWORD, AWS_STORAGE_BUCKET_NAME"
    exit 1
fi

MIGRATION_DIR="migration-data"
mkdir -p "$MIGRATION_DIR"

echo "=== P4TD: Migrate data from AWS ==="
echo ""

# ============================================================================
# 1. Check S3 bucket size
# ============================================================================
echo "1. Checking S3 bucket size..."
if [ -n "$AWS_STORAGE_BUCKET_NAME" ]; then
    BUCKET_SIZE=$(aws s3 ls "s3://${AWS_STORAGE_BUCKET_NAME}" --recursive --summarize | grep "Total Size" || echo "Could not determine size")
    BUCKET_COUNT=$(aws s3 ls "s3://${AWS_STORAGE_BUCKET_NAME}" --recursive --summarize | grep "Total Objects" || echo "Could not determine count")
    echo "   $BUCKET_SIZE"
    echo "   $BUCKET_COUNT"
    echo ""
else
    echo "   No S3 bucket configured, skipping media sync."
    echo ""
fi

# ============================================================================
# 2. Dump PostgreSQL database from RDS
# ============================================================================
echo "2. Dumping PostgreSQL database from RDS..."
echo "   Host: $RDS_HOSTNAME"
echo "   Database: $RDS_DB_NAME"

PGPASSWORD="$RDS_PASSWORD" pg_dump \
    -h "$RDS_HOSTNAME" \
    -U "$RDS_USERNAME" \
    -d "$RDS_DB_NAME" \
    -p "${RDS_PORT:-5432}" \
    --no-owner \
    --no-privileges \
    -F c \
    -f "$MIGRATION_DIR/db-dump.sql"

echo "   Database dump saved to: $MIGRATION_DIR/db-dump.sql"
echo "   Size: $(du -h "$MIGRATION_DIR/db-dump.sql" | cut -f1)"
echo ""

# ============================================================================
# 3. Sync S3 media files
# ============================================================================
if [ -n "$AWS_STORAGE_BUCKET_NAME" ]; then
    echo "3. Syncing S3 media files..."
    aws s3 sync "s3://${AWS_STORAGE_BUCKET_NAME}" "$MIGRATION_DIR/media/" --no-progress
    echo "   Media files saved to: $MIGRATION_DIR/media/"
    echo "   Size: $(du -sh "$MIGRATION_DIR/media/" | cut -f1)"
    echo ""
fi

# ============================================================================
# 4. Summary
# ============================================================================
echo "=== Migration data ready ==="
echo ""
echo "Total size: $(du -sh "$MIGRATION_DIR" | cut -f1)"
echo ""
echo "Next steps:"
echo "  1. Transfer to Hetzner:  scp -r $MIGRATION_DIR root@YOUR_HETZNER_IP:/root/"
echo "  2. Run setup-hetzner.sh on the server to import the data"
