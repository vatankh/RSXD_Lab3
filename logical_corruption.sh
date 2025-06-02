#!/bin/bash
set -euo pipefail
set -x              
# --- Adjustables -------------------------------------------------------------
HOST="127.0.0.1"
PORT="9787"

DB_USER="postgres7"
DB_NAME="somedb"

RESERVE_HOST="postgres8@pg199"
REMOTE_BACKUP_DIR="~/backups"
LOCAL_BACKUP_DIR="$HOME/backups"

TIMESTAMP=$(date "+%Y-%m-%d_%H-%M-%S")
DUMP_REMOTE="logical_backup_${TIMESTAMP}.dump"   # will be created on pg199
DUMP_LOCAL="${LOCAL_BACKUP_DIR}/${DUMP_REMOTE}"  # full path after scp

LOG_FILE="$HOME/logical_recovery.log"
exec >>"$LOG_FILE" 2>&1

echo "==================================================================="
echo "[$TIMESTAMP]  🔧  Step 4 – logical corruption / recovery begins"

###############################################################################
# 1. Add 2-3 new rows to *every* user table
###############################################################################
echo "→ Adding demo rows to each user table in $DB_NAME …"

psql -h "$HOST" -p "$PORT" -U "$DB_USER" -d "$DB_NAME" -At \
     -c "SELECT quote_ident(schemaname)||'.'||quote_ident(relname)
           FROM pg_stat_user_tables" |
while read -r FULL_TABLE; do
  echo "   • inserting into $FULL_TABLE"
  for i in {1..3}; do
    psql -h "$HOST" -p "$PORT" -U "$DB_USER" -d "$DB_NAME" -c \
      "INSERT INTO $FULL_TABLE DEFAULT VALUES;" 2>/dev/null \
    || echo "      Skipped insert $i – table may require non-default values"
  done
done 



###############################################################################
# 2. Simulate a logical failure – scramble one FK column
###############################################################################
TABLE_WITH_FK="test_schema.test_table"
FK_COLUMN="related_id"
echo "→ Corrupting foreign keys in $TABLE_WITH_FK.$FK_COLUMN …"

psql -h "$HOST" -p "$PORT" -U "$DB_USER" -d "$DB_NAME" -c \
  "UPDATE $TABLE_WITH_FK
      SET $FK_COLUMN = (SELECT id FROM test_schema.related_table
                        ORDER BY random() LIMIT 1)
    WHERE $FK_COLUMN IS NOT NULL
    RETURNING id, $FK_COLUMN;"

###############################################################################
# 3. Generate a logical dump (custom format) on the RESERVE host
###############################################################################
echo "→ Taking pg_dump -Fc on reserve host pg199 …"

ssh "$RESERVE_HOST" \
  "pg_dump -Fc -h $HOST -p $PORT -U $DB_USER -d $DB_NAME \
           -f $REMOTE_BACKUP_DIR/$DUMP_REMOTE"

###############################################################################
# 4. Copy the dump back to the primary
###############################################################################
echo "→ Copying dump back to primary …"
mkdir -p "$LOCAL_BACKUP_DIR"
scp "$RESERVE_HOST:$REMOTE_BACKUP_DIR/$DUMP_REMOTE" "$LOCAL_BACKUP_DIR/"

###############################################################################
# 5. Restore, wiping corrupted objects first
###############################################################################
echo "→ Restoring dump – this DROPs and recreates objects!"
pg_restore --clean --if-exists \
           -h "$HOST" -p "$PORT" -U "$DB_USER" -d "$DB_NAME" \
           "$DUMP_LOCAL"

###############################################################################
# 6. Post-restore validation
###############################################################################
echo "→ Validation queries …"
psql -h "$HOST" -p "$PORT" -U "$DB_USER" -d "$DB_NAME" -c "
  SELECT 'broken fkeys'        AS check,
         COUNT(*)              AS rows
  FROM   $TABLE_WITH_FK t
  WHERE  NOT EXISTS (SELECT 1
                     FROM test_schema.related_table r
                     WHERE r.id = t.$FK_COLUMN);" 

echo "[$TIMESTAMP]  ✅  Step 4 completed successfully"
