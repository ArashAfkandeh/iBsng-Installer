#!/bin/bash

# ============================= #
# IBSng Database Restore Script #
# ============================= #

# --- Settings ---
CONTAINER_NAME="ibsng"
DB_USER="ibs"
DB_NAME="IBSng"
DB_SUPERUSER="postgres"
# -----------------

# Check if the input parameter (backup file path) is provided
if [ -z "$1" ]; then
    echo -e "\033[1;31mError: Please provide the full path to the backup file as the first argument.\033[0m"
    echo "Example: $0 /root/iBsng_02_08_2025.bak"
    exit 1
fi

BACKUP_FILE_HOST_PATH="$1"
BACKUP_FILENAME=$(basename "${BACKUP_FILE_HOST_PATH}")
BACKUP_FILE_CONTAINER_PATH="/tmp/${BACKUP_FILENAME}"

# --- Helper Functions ---
run_as_postgres() {
    docker exec -i "${CONTAINER_NAME}" su - "${DB_SUPERUSER}" -c "$1"
}

prepare_database() {
    echo -e "\n2. Preparing for restore..."
    echo "   - Stopping IBSng service..."
    docker exec "${CONTAINER_NAME}" service IBSng stop >/dev/null 2>&1
    echo "   - Forcibly terminating all connections..."
    TERMINATE_QUERY="SELECT pg_terminate_backend(procpid) FROM pg_stat_activity WHERE datname = '${DB_NAME}';"
    run_as_postgres "psql -d postgres -c \"${TERMINATE_QUERY}\"" >/dev/null 2>&1
    echo "   - Dropping and recreating the '${DB_NAME}' database..."
    run_as_postgres "dropdb ${DB_NAME}" >/dev/null 2>&1
    run_as_postgres "createdb -O ${DB_USER} ${DB_NAME}" || { echo "❌ Error creating the new database!"; exit 1; }
    echo "✅ Database successfully recreated."
}

finalize_restore() {
    echo -e "\n4. Checking status and restarting..."
    echo "   - Restarting IBSng service..."
    docker exec "${CONTAINER_NAME}" service IBSng start

    sleep 5
    docker exec "${CONTAINER_NAME}" service IBSng status >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "\n\033[1;32m✅ Restore operation completed successfully, and the IBSng service is running.\033[0m"
    else
        echo -e "\n\033[1;31m❌ Error: The IBSng service did not start after the restore. Please check the logs.\033[0m"
    fi

    echo "   - Cleaning up the temporary backup file from inside the container..."
    docker exec "${CONTAINER_NAME}" rm -f "${BACKUP_FILE_CONTAINER_PATH}" "${BACKUP_FILE_CONTAINER_PATH}.uncompressed" >/dev/null 2>&1
    echo -e "\n--- End of operation ---"
}

# --- Script Start ---

# 1. Warning and Confirmation
echo -e "\n\033[1;31m*** CRITICAL WARNING ***\033[0m"
read -p "Are you sure you want to continue? (Type 'y' to confirm): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Operation cancelled."
    exit 1
fi

# Copy the backup file
echo -e "\n1. Copying the backup file into the container..."
docker cp "${BACKUP_FILE_HOST_PATH}" "${CONTAINER_NAME}:${BACKUP_FILE_CONTAINER_PATH}" || { echo "❌ Error copying the file!"; exit 1; }
echo "✅ File copied successfully."

# Detect file type and run the appropriate method
echo -e "\n3. Detecting backup file type and starting the restore..."
UNCOMPRESSED_PATH="${BACKUP_FILE_CONTAINER_PATH}"

if docker exec "${CONTAINER_NAME}" file "${BACKUP_FILE_CONTAINER_PATH}" | grep -q "gzip compressed data"; then
    echo "   - Compressed (gzip) file detected. Uncompressing..."
    UNCOMPRESSED_PATH="${BACKUP_FILE_CONTAINER_PATH}.uncompressed"
    docker exec "${CONTAINER_NAME}" bash -c "gunzip -c '${BACKUP_FILE_CONTAINER_PATH}' > '${UNCOMPRESSED_PATH}'"
fi

FILE_SIGNATURE=$(docker exec "${CONTAINER_NAME}" head -c 5 "${UNCOMPRESSED_PATH}")

if [[ "$FILE_SIGNATURE" == "PGDMP" ]]; then
    # --- Restore method for custom format (pg_restore) ---
    echo "   - Backup Type: PostgreSQL custom format (pg_dump -Fc) detected."
    prepare_database
    # *** Key change: The --clean option is removed ***
    # Since the database is already empty, no internal cleanup is needed.
    echo "   - Restoring using pg_restore..."
    run_as_postgres "pg_restore -U ${DB_USER} -d ${DB_NAME} '${UNCOMPRESSED_PATH}'"
    if [ $? -ne 0 ]; then
        echo -e "\033[1;31m❌ Error during pg_restore. Please check the output.\033[0m"
        exit 1
    fi
    finalize_restore

elif [[ "$FILE_SIGNATURE" == *"--"* || "$FILE_SIGNATURE" == *"SET"* ]]; then
    # --- Restore method for plain text format (psql) ---
    echo "   - Backup Type: SQL plain text file detected."
    prepare_database
    echo "   - Installing 'plpgsql' language..."
    run_as_postgres "createlang plpgsql ${DB_NAME}" >/dev/null 2>&1
    echo "   - Starting two-pass restore..."
    run_as_postgres "psql -U ${DB_USER} -d ${DB_NAME} -f '${UNCOMPRESSED_PATH}'" > /tmp/restore_pass1.log 2>&1
    run_as_postgres "psql -U ${DB_USER} -d ${DB_NAME} -f '${UNCOMPRESSED_PATH}'" > /tmp/restore_pass2.log 2>&1
    echo "✅ Two-pass restore completed."
    finalize_restore

else
    echo -e "\033[1;31m❌ Error: Backup file type is not recognizable.\033[0m"
    exit 1
fi
