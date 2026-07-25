#!/usr/bin/env bash

set -uo pipefail

# ------------------------------------------------------------
# Transfer local backups to an external destination via SMB
# ------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

if [[ ! -r "$CONFIG_FILE" ]]; then
    printf 'ERROR: The configuration file does not exist or cannot be read: %s\n' \
        "$CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=backup.conf
source "$CONFIG_FILE"

REQUIRED_CONFIG_VALUES=(
    BACKUP_DIR
    REMOTE_SHARE
    MOUNT_POINT
    CREDENTIALS_FILE
    RETENTION_COUNT
    LOG_DIR
    DATA_DIR
    TRANSFER_LOCK_FILE
    MOUNT_OPTIONS
)

for config_value in "${REQUIRED_CONFIG_VALUES[@]}"; do
    if [[ -z "${!config_value:-}" ]]; then
        printf 'ERROR: The required configuration value is missing: %s\n' \
            "$config_value" >&2
        exit 1
    fi
done

if [[ ! "$RETENTION_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    printf 'ERROR: RETENTION_COUNT must be a positive integer greater than zero.\n' >&2
    exit 1
fi

LOCAL_BACKUP_DIR="$BACKUP_DIR"

LOG_FILE="${LOG_DIR}/transfer-$(date '+%Y-%m-%d').log"

STATUS_UPDATER="${SCRIPT_DIR}/update-status.py"
STATUS_FILE="${DATA_DIR}/backup_status.json"

LOCK_FILE="$TRANSFER_LOCK_FILE"

export STATUS_FILE

MOUNTED_BY_SCRIPT=false
UPLOAD_SUCCEEDED=false


log() {
    local message="$1"

    mkdir -p "$LOG_DIR"

    printf '%s %s\n' \
        "$(date '+%d-%m-%Y %H:%M:%S')" \
        "$message" | tee -a "$LOG_FILE"
}


cleanup() {
    if [[ "$MOUNTED_BY_SCRIPT" == true ]] && mountpoint -q "$MOUNT_POINT"; then
        log "Unmounting the SMB share."

        if ! umount "$MOUNT_POINT"; then
            log "WARNING: The SMB share could not be unmounted."
        fi
    fi
}

set_failed_status() {
    "$STATUS_UPDATER" \
        overall_status=failed \
        last_backup_result="Transfer to the SMB destination failed" \
        pending_transfer=true \
        updated="$(date '+%Y-%m-%d %H:%M')"
}


trap cleanup EXIT
trap 'log "The transfer script was interrupted."; exit 1' INT TERM


# Prevent multiple copies of the script from running at the same time.
exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    log "The transfer script is already running. Exiting."
    exit 0
fi


if [[ $EUID -ne 0 ]]; then
    log "ERROR: The script must be run as root."
    set_failed_status
    exit 1
fi


if [[ ! -d "$LOCAL_BACKUP_DIR" ]]; then
    log "ERROR: The local backup directory does not exist: $LOCAL_BACKUP_DIR"
    set_failed_status
    exit 1
fi


mapfile -d '' BACKUP_FILES < <(
    find "$LOCAL_BACKUP_DIR" \
        -maxdepth 1 \
        -type f \
        -name '*.tar.gz' \
        -print0 |
    sort -z
)


if (( ${#BACKUP_FILES[@]} == 0 )); then
    log "No local backups are awaiting transfer."
    exit 0
fi

"$STATUS_UPDATER" \
    overall_status=running \
    last_backup_result="Backup is being transferred to the SMB destination" \
    pending_transfer=true \
    updated="$(date '+%Y-%m-%d %H:%M')"


mkdir -p "$MOUNT_POINT"


if mountpoint -q "$MOUNT_POINT"; then
    log "The SMB share is already mounted."
else
    log "Mounting ${REMOTE_SHARE} at ${MOUNT_POINT}."

    if ! mount -t cifs \
        "$REMOTE_SHARE" \
        "$MOUNT_POINT" \
        -o "$MOUNT_OPTIONS"
    then
        log "ERROR: The SMB share could not be mounted."
        set_failed_status
        exit 1
    fi

    MOUNTED_BY_SCRIPT=true
fi


if [[ ! -w "$MOUNT_POINT" ]]; then
    log "ERROR: The mount point is not writable."
    set_failed_status
    exit 1
fi


for source_file in "${BACKUP_FILES[@]}"; do
    filename="$(basename "$source_file")"
    destination_file="${MOUNT_POINT}/${filename}"
    temporary_file="${destination_file}.nosync"

    log "Transferring ${filename}."

    rm -f "$temporary_file"

    if ! cp --preserve=timestamps "$source_file" "$temporary_file"; then
        log "ERROR: Copying ${filename} failed."
        rm -f "$temporary_file"
        continue
    fi

    local_checksum="$(sha256sum "$source_file" | awk '{print $1}')"
    remote_checksum="$(sha256sum "$temporary_file" | awk '{print $1}')"

    if [[ "$local_checksum" != "$remote_checksum" ]]; then
        log "ERROR: Checksum mismatch for ${filename}."
        rm -f "$temporary_file"
        continue
    fi

    if ! mv "$temporary_file" "$destination_file"; then
        log "ERROR: Could not finalize ${filename} at the SMB destination."
        rm -f "$temporary_file"
        continue
    fi

    if ! rm -f "$source_file"; then
        log "WARNING: The backup was transferred, but the local file could not be deleted: ${filename}"
        continue
    fi

    UPLOAD_SUCCEEDED=true
    log "Transfer verified. Local copy deleted: ${filename}"
done


# Remove old remote backups only if at least one new backup
# was transferred and verified during this run.
if [[ "$UPLOAD_SUCCEEDED" == true ]]; then
    log "Keeping the latest ${RETENTION_COUNT} remote backups."

    mapfile -d '' REMOTE_BACKUPS < <(
        find "$MOUNT_POINT" \
            -maxdepth 1 \
            -type f \
            -name '*.tar.gz' \
            -printf '%T@ %p\0' |
        sort -z -nr |
        cut -z -d ' ' -f 2-
    )

    if (( ${#REMOTE_BACKUPS[@]} > RETENTION_COUNT )); then
        for ((i = RETENTION_COUNT; i < ${#REMOTE_BACKUPS[@]}; i++)); do
            old_backup="${REMOTE_BACKUPS[$i]}"
            old_filename="$(basename "$old_backup")"

            if rm -f "$old_backup"; then
                log "Deleted old remote backup: ${old_filename}"
            else
                log "WARNING: Could not delete old remote backup: ${old_filename}"
            fi
        done
    else
        log "There are ${#REMOTE_BACKUPS[@]} remote backups. No cleanup is required."
    fi
else
    log "No new backups were transferred. Skipping remote cleanup."
    exit 1
fi

"$STATUS_UPDATER" \
    overall_status=success \
    last_backup_result="Backup transferred to the SMB destination" \
    pending_transfer=false \
    updated="$(date '+%Y-%m-%d %H:%M')"

log "The transfer script has finished."
