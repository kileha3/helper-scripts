#!/bin/bash
set -e

# Usage:
# ./mongo-migrate.sh --source "mongodb://user:pass@host:port" --target "mongodb://user:pass@host:port" --dbs "db1,db2,db3"

# --- Parse named parameters ---
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --source) SOURCE_URI="$2"; shift ;;
    --target) TARGET_URI="$2"; shift ;;
    --dbs) DBS="$2"; shift ;;
    *) echo "Unknown parameter $1"; exit 1 ;;
  esac
  shift
done

if [[ -z "$SOURCE_URI" || -z "$TARGET_URI" || -z "$DBS" ]]; then
  echo "Missing required parameters."
  echo "Usage: ./mongo-migrate.sh --source <source-uri> --target <target-uri> --dbs <db1,db2,...>"
  exit 1
fi

# --- Prepare temp directory ---
TMP_DIR=$(mktemp -d)
echo "Using temporary directory: $TMP_DIR"

# --- Convert comma-separated DBs to array ---
IFS=',' read -r -a DB_ARRAY <<< "$DBS"

declare -A SOURCE_COUNTS
declare -A TARGET_COUNTS

for DB in "${DB_ARRAY[@]}"; do
  echo "Migrating database: $DB"

  DB_DUMP_DIR="$TMP_DIR/$DB"

  # --- Count documents in source before dumping ---
  COLLECTIONS=$(mongosh "$SOURCE_URI" --quiet --eval "db.getSiblingDB('$DB').getCollectionNames().join(',')")
  IFS=',' read -r -a COLL_ARRAY <<< "$COLLECTIONS"
  for COLL in "${COLL_ARRAY[@]}"; do
    COUNT=$(mongosh "$SOURCE_URI" --quiet --eval "db.getSiblingDB('$DB').getCollection('$COLL').countDocuments()")
    SOURCE_COUNTS["$DB.$COLL"]=$COUNT
  done

  # --- Dump the database silently (all collections + users/roles) ---
  mongodump --uri="$SOURCE_URI" --db="$DB" --dumpDbUsersAndRoles --quiet --out="$TMP_DIR"

  # Show dump size
  DUMP_SIZE=$(du -sh "$DB_DUMP_DIR" | awk '{print $1}')
  echo "Database $DB dumped to $DB_DUMP_DIR ($DUMP_SIZE)"

  # --- Restore to target database silently ---
  mongorestore --uri="$TARGET_URI" --db="$DB" --drop --quiet "$DB_DUMP_DIR"

  # --- Count documents in target after restore ---
  for COLL in "${COLL_ARRAY[@]}"; do
    COUNT=$(mongosh "$TARGET_URI" --quiet --eval "db.getSiblingDB('$DB').getCollection('$COLL').countDocuments()")
    TARGET_COUNTS["$DB.$COLL"]=$COUNT
  done
done

# --- Cleanup ---
rm -rf "$TMP_DIR"

# --- Output comparison ---
echo ""
echo "=== Migration Document Count Comparison ==="
for KEY in "${!SOURCE_COUNTS[@]}"; do
  echo "$KEY: source=${SOURCE_COUNTS[$KEY]}, target=${TARGET_COUNTS[$KEY]}"
done

echo "Database $DBS migrated successfully"
