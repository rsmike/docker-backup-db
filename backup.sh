#!/bin/bash
set -euo pipefail

##########################
# CONFIGURATION
##########################

NOWDATE=$(date +%Y-%m-%d)
DAYOFWEEK=$(date +"%u")
MONTHDAY=$(date +"%d")

# S3 bucket info
BUCKET="${BUCKET:?BUCKET must be set}"
BUCKET_DIR="${BUCKET_DIR:-database}"

# RDS info
RDS_INSTANCE="${RDS_INSTANCE:?RDS_INSTANCE must be set}"
TMP_RDS_INSTANCE="${RDS_INSTANCE}-tmp-backup"

# Kuma (optional)
STATUS_URL="${STATUS_URL:?STATUS_URL must be set}"

# Retention policy
DAILY_KEEP=14
WEEKLY_KEEP=52

##########################
# FUNCTIONS
##########################

notify_ok() {
    local msg="${1:-OK}"
    curl -s --get --data-urlencode "status=up" --data-urlencode "msg=$msg" "$STATUS_URL" >/dev/null || true
}

notify_fail() {
    local msg="${1:-FAILED}"
    curl -s --get --data-urlencode "status=down" --data-urlencode "msg=$msg" "$STATUS_URL" >/dev/null || true
}

cleanup_old_backups() {
    local prefix="$1"
    local keep="$2"

    local files
    files=$(aws s3 ls "$prefix/" | awk '{print $4}' | grep '\.sql\.gz$' || true)

    local count
    count=$(echo "$files" | grep -c . || echo "0")

    if [ "$count" -gt "$keep" ]; then
        echo "$files" | head -n -"$keep" | while read -r f; do
            [ -n "$f" ] && aws s3 rm "$prefix/$f"
        done
    fi
}

cleanup_temp_instance() {
  if aws rds describe-db-instances --db-instance-identifier "$TMP_RDS_INSTANCE" >/dev/null 2>&1; then
        echo "[INFO] Deleting temporary RDS instance $TMP_RDS_INSTANCE..."
        aws rds delete-db-instance \
            --db-instance-identifier "$TMP_RDS_INSTANCE" \
            --skip-final-snapshot >/dev/null

        aws rds wait db-instance-deleted --db-instance-identifier "$TMP_RDS_INSTANCE"

        echo "[INFO] Temporary RDS instance deleted."
    fi
}


##########################
# MAIN
##########################

echo "[INFO] Starting backup at $NOWDATE"

EXIT_STATUS=0
trap 'echo "[ERROR] Backup failed!"; notify_fail "Backup script error"; cleanup_temp_instance; exit 1' ERR INT TERM

# ------------------ RDS TEMP INSTANCE ------------------

cleanup_temp_instance

echo "[INFO] Getting the latest snapshot..."
LATEST_SNAP=$(aws rds describe-db-snapshots \
  --db-instance-identifier "$RDS_INSTANCE" \
  --snapshot-type automated \
  --query "DBSnapshots | sort_by(@,&SnapshotCreateTime)[-1].DBSnapshotIdentifier" \
  --output text)

if [ "$LATEST_SNAP" = "None" ]; then
    echo "[ERROR] No snapshots found"
    exit 1
fi

echo "[INFO] Getting security groups from main RDS instance..."
MAIN_SGS=$(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE" \
  --query 'DBInstances[0].VpcSecurityGroups[*].VpcSecurityGroupId' \
  --output text)

echo "[INFO] Creating temporary RDS instance from latest snapshot..."
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier "$TMP_RDS_INSTANCE" \
  --db-snapshot-identifier "$LATEST_SNAP" \
  --no-multi-az \
  --no-auto-minor-version-upgrade \
  --db-instance-class db.t3.small \
  --publicly-accessible \
  --tags Key=backup,Value=temporary \
  --vpc-security-group-ids $MAIN_SGS \
  --query 'DBInstance.DBInstanceIdentifier' \
  --output text

echo "[INFO] Waiting for temporary RDS instance to become available..."
aws rds wait db-instance-available --db-instance-identifier "$TMP_RDS_INSTANCE"

# ------------------ MYSQL CREDS ------------------

MYSQL_HOST=$(aws rds describe-db-instances \
  --db-instance-identifier "$TMP_RDS_INSTANCE" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
MYSQL_PORT=3306
MYSQL_USER="${MYSQL_USER:?MYSQL_USER must be set}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:?MYSQL_PASSWORD must be set}"

# ------------------ DUMP DATABASES ------------------

DBS=$(mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -BNe 'show databases' \
      | grep -Ev 'mysql|information_schema|performance_schema|sys|innodb|tmp|test_')

for DB in $DBS; do
    echo "[INFO] Dumping $DB..."

    # Paths
    S3_BASE="s3://$BUCKET/$BUCKET_DIR/${RDS_INSTANCE}-${DB}"
    DAILY_PATH="$S3_BASE/daily/${DB}-$NOWDATE.sql.gz"
    WEEKLY_PATH="$S3_BASE/weekly/${DB}-$NOWDATE.sql.gz"
    MONTHLY_PATH="$S3_BASE/monthly/${DB}-$NOWDATE.sql.gz"

    # Daily (main) backup
    set +e

    mysqldump -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
        --quote-names --set-gtid-purged=OFF --single-transaction --max_allowed_packet=1G \
        --quick --opt --create-options "$DB" \
        | gzip -9 \
        | aws s3 cp - "$DAILY_PATH" --storage-class STANDARD_IA --no-progress

    status=$?
    set -e

    if [ $status -ne 0 ]; then
        echo "[ERROR] Failed backup for $DB"
        notify_fail "Backup failed for $DB"
        EXIT_STATUS=1
        continue
    fi

    echo "[INFO] Daily backup uploaded: $DAILY_PATH"
    cleanup_old_backups "$S3_BASE/daily" $DAILY_KEEP

	# Weekly backup - copy over
    if [ "$DAYOFWEEK" -eq 7 ]; then
        aws s3 cp "$DAILY_PATH" "$WEEKLY_PATH" --storage-class STANDARD_IA --no-progress
        echo "[INFO] Weekly backup uploaded: $WEEKLY_PATH"
        cleanup_old_backups "$S3_BASE/weekly" $WEEKLY_KEEP
    fi

    # Monthly backup - copy over
    if [ "$MONTHDAY" == "01" ]; then
        aws s3 cp "$DAILY_PATH" "$MONTHLY_PATH" --storage-class STANDARD_IA --no-progress
        echo "[INFO] Monthly backup uploaded: $MONTHLY_PATH"
    fi

    echo "[INFO] Finished $DB"
done

# Cleanup temp RDS instance
cleanup_temp_instance

if [ "$EXIT_STATUS" -eq 0 ]; then
    notify_ok "All databases backed up successfully."
fi

exit $EXIT_STATUS
