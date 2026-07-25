#!/usr/bin/env bash

set -uo pipefail

# ------------------------------------------------------------
# Overfør lokale backups til en ekstern destination via SMB
# ------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

if [[ ! -r "$CONFIG_FILE" ]]; then
    printf 'FEJL: Konfigurationsfilen findes ikke eller kan ikke læses: %s\n' \
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
        printf 'FEJL: Den krævede konfigurationsværdi mangler: %s\n' \
            "$config_value" >&2
        exit 1
    fi
done

if [[ ! "$RETENTION_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    printf 'FEJL: RETENTION_COUNT skal være et positivt heltal større end nul.\n' >&2
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
        log "Afmonterer SMB-sharet."

        if ! umount "$MOUNT_POINT"; then
            log "ADVARSEL: SMB-sharet kunne ikke afmonteres."
        fi
    fi
}

set_failed_status() {
    "$STATUS_UPDATER" \
        overall_status=failed \
        last_backup_result="Overførsel til SMB-destinationen fejlede" \
        pending_transfer=true \
        updated="$(date '+%Y-%m-%d %H:%M')"
}


trap cleanup EXIT
trap 'log "Transfer-scriptet blev afbrudt."; exit 1' INT TERM


# Undgå at flere kopier af scriptet kører samtidig.
exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    log "Transfer-scriptet kører allerede. Afslutter."
    exit 0
fi


if [[ $EUID -ne 0 ]]; then
    log "FEJL: Scriptet skal køres som root."
    set_failed_status
    exit 1
fi


if [[ ! -d "$LOCAL_BACKUP_DIR" ]]; then
    log "FEJL: Den lokale backupmappe findes ikke: $LOCAL_BACKUP_DIR"
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
    log "Ingen lokale backups venter på overførsel."
    exit 0
fi

"$STATUS_UPDATER" \
    overall_status=running \
    last_backup_result="Backup overføres til SMB-destinationen" \
    pending_transfer=true \
    updated="$(date '+%Y-%m-%d %H:%M')"


mkdir -p "$MOUNT_POINT"


if mountpoint -q "$MOUNT_POINT"; then
    log "SMB-sharet er allerede monteret."
else
    log "Monterer ${REMOTE_SHARE} på ${MOUNT_POINT}."

    if ! mount -t cifs \
        "$REMOTE_SHARE" \
        "$MOUNT_POINT" \
        -o "$MOUNT_OPTIONS"
    then
        log "FEJL: SMB-sharet kunne ikke monteres."
        set_failed_status
        exit 1
    fi

    MOUNTED_BY_SCRIPT=true
fi


if [[ ! -w "$MOUNT_POINT" ]]; then
    log "FEJL: Mountpunktet er ikke skrivbart."
    set_failed_status
    exit 1
fi


for source_file in "${BACKUP_FILES[@]}"; do
    filename="$(basename "$source_file")"
    destination_file="${MOUNT_POINT}/${filename}"
    temporary_file="${destination_file}.nosync"

    log "Overfører ${filename}."

    rm -f "$temporary_file"

    if ! cp --preserve=timestamps "$source_file" "$temporary_file"; then
        log "FEJL: Kopiering af ${filename} mislykkedes."
        rm -f "$temporary_file"
        continue
    fi

    local_checksum="$(sha256sum "$source_file" | awk '{print $1}')"
    remote_checksum="$(sha256sum "$temporary_file" | awk '{print $1}')"

    if [[ "$local_checksum" != "$remote_checksum" ]]; then
        log "FEJL: Checksum stemmer ikke for ${filename}."
        rm -f "$temporary_file"
        continue
    fi

    if ! mv "$temporary_file" "$destination_file"; then
        log "FEJL: Kunne ikke færdiggøre ${filename} på SMB-destinationen."
        rm -f "$temporary_file"
        continue
    fi

    if ! rm -f "$source_file"; then
        log "ADVARSEL: Backupen blev overført, men den lokale fil kunne ikke slettes: ${filename}"
        continue
    fi

    UPLOAD_SUCCEEDED=true
    log "Overførsel verificeret. Lokal kopi slettet: ${filename}"
done


# Fjern kun gamle eksterne backups, hvis mindst én ny backup
# blev overført og verificeret under denne kørsel.
if [[ "$UPLOAD_SUCCEEDED" == true ]]; then
    log "Beholder de seneste ${RETENTION_COUNT} eksterne backups."

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
                log "Slettede gammel ekstern backup: ${old_filename}"
            else
                log "ADVARSEL: Kunne ikke slette gammel ekstern backup: ${old_filename}"
            fi
        done
    else
        log "Der er ${#REMOTE_BACKUPS[@]} eksterne backups. Ingen oprydning nødvendig."
    fi
else
    log "Ingen nye backups blev overført. Ekstern oprydning springes over."
    exit 1
fi

"$STATUS_UPDATER" \
    overall_status=success \
    last_backup_result="Backup overført til SMB-destinationen" \
    pending_transfer=false \
    updated="$(date '+%Y-%m-%d %H:%M')"

log "Transfer-scriptet er færdigt."
