#!/bin/bash

# ========================================== #
# IBSng Database Backup Script (Bash Module) #
# ========================================== #

# --- Settings (Read from environment variables) ---
CONTAINER_NAME=${CONTAINER_NAME:-"ibsng"}
BACKUP_DIR=${BACKUP_DIR:-"/tmp/ibsng_backup_files"}
DB_USER=${DB_USER:-"ibs"}
DB_NAME=${DB_NAME:-"IBSng"}
# -----------------

# Create the backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Backup file name with date and time
DATE_FORMAT=$(date "+%Y-%m-%d_%H-%M-%S")
BACKUP_FILE_NAME="IBSng_backup_${DATE_FORMAT}.dump.gz"
BACKUP_FILE_PATH="${BACKUP_DIR}/${BACKUP_FILE_NAME}"

echo "Starting the backup process for the IBSng database..."

# --- Main command, modified for older pg_dump syntax ---
# Change: The -d flag is removed from pg_dump, and the database name is passed as the last argument.
COMMAND_TO_EXEC="su - postgres -c 'pg_dump -U ${DB_USER} -Fc ${DB_NAME}'"
echo "Executing command in the container: ${COMMAND_TO_EXEC}"

# Execute the command and pipe its output to gzip
docker exec -i "${CONTAINER_NAME}" bash -c "${COMMAND_TO_EXEC}" | gzip > "${BACKUP_FILE_PATH}"

# Check if the backup was successful
# ${PIPESTATUS[0]} returns the exit status of the first command in the pipe.
if [ ${PIPESTATUS[0]} -eq 0 ] && [ -s "${BACKUP_FILE_PATH}" ]; then
  echo "✅ Backup successfully created and compressed at the following path:"
  ls -lh "${BACKUP_FILE_PATH}"
  # Send the backup file path to standard output for the Python script to use
  echo "BACKUP_FILE_PATH=${BACKUP_FILE_PATH}"
  exit 0
else
  echo "❌ Error: The backup process failed."
  echo "Please check for any errors displayed above."
  # On failure, remove the incomplete or empty file
  rm -f "${BACKUP_FILE_PATH}"
  exit 1
fi
