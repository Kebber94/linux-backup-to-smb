#!/usr/bin/env bash

set -uo pipefail

# ============================================================
# Lokal backup
# ============================================================

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
    HOST_NAME
    BACKUP_DIR
    LOG_DIR
    DATA_DIR
    BACKUP_LOCK_FILE
)

for config_value in "${REQUIRED_CONFIG_VALUES[@]}"; do
    if [[ -z "${!config_value:-}" ]]; then
        printf 'FEJL: Den krævede konfigurationsværdi mangler: %s\n' \
            "$config_value" >&2
        exit 1
    fi
done

if ! declare -p SOURCE_DIRS >/dev/null 2>&1 ||
    (( ${#SOURCE_DIRS[@]} == 0 )); then
    printf 'FEJL: Den krævede konfigurationsværdi mangler: SOURCE_DIRS\n' >&2
    exit 1
fi

LOG_FILE="${LOG_DIR}/backup.log"
STATUS_FILE="${DATA_DIR}/backup_status.json"
STATUS_UPDATER="${SCRIPT_DIR}/update-status.py"
LOCK_FILE="$BACKUP_LOCK_FILE"

export STATUS_FILE

DATE_NAME="$(date '+%Y-%m-%d')"
BACKUP_NAME="${DATE_NAME} - Backup of ${HOST_NAME}.tar.gz"
BACKUP_FILE="${BACKUP_DIR}/${BACKUP_NAME}"
PARTIAL_FILE="${BACKUP_FILE}.partial"

BACKUP_STARTED="$(date '+%Y-%m-%d %H:%M')"
START_SECONDS="$(date +%s)"

RUNNING_CONTAINERS=()
DOCKER_STOPPED=false
BACKUP_SUCCESS=false

mkdir -p "$BACKUP_DIR" "$LOG_DIR"

# ------------------------------------------------------------
# Funktioner
# ------------------------------------------------------------

log() {
    local level="$1"
    shift

    local message="$*"
    local timestamp

    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    printf '%s %-7s %s\n' "$timestamp" "$level" "$message" \
        | tee -a "$LOG_FILE"
}

human_size() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        printf '0 B'
        return
    fi

    local size
    size="$(du -h "$file" | awk '{print $1}')"

    case "$size" in
        *K) printf '%s KB' "${size%K}" ;;
        *M) printf '%s MB' "${size%M}" ;;
        *G) printf '%s GB' "${size%G}" ;;
        *T) printf '%s TB' "${size%T}" ;;
        *)  printf '%s' "$size" ;;
    esac
}

 write_status() {
    local overall_status="$1"
    local result="$2"
    local backup_size="${3:-0 B}"
    local docker_downtime="${4:-0}"
    local finished_at

    finished_at="$(date '+%Y-%m-%d %H:%M')"

    "$STATUS_UPDATER" \
        overall_status="$overall_status" \
        last_backup_started="$BACKUP_STARTED" \
        last_backup_finished="$finished_at" \
        last_backup_result="$result" \
        last_backup_file="$BACKUP_NAME" \
        last_backup_size="$backup_size" \
        docker_downtime_seconds="$docker_downtime" \
        pending_transfer="$BACKUP_SUCCESS" \
        updated="$finished_at"
}

start_containers_again() {
    if [[ "$DOCKER_STOPPED" != true ]]; then
        return 0
    fi

    if (( ${#RUNNING_CONTAINERS[@]} == 0 )); then
        DOCKER_STOPPED=false
        return 0
    fi

    log "INFO" "Starter tidligere kørende Docker-containere."

    local restart_failed=false
    local container

    for container in "${RUNNING_CONTAINERS[@]}"; do
        if ! docker start "$container" >/dev/null; then
            restart_failed=true
        fi
    done

    if [[ "$restart_failed" == false ]]; then
        log "INFO" "Docker-containerne er startet igen."
        DOCKER_STOPPED=false
        return 0
    else
        log "ERROR" "En eller flere Docker-containere kunne ikke startes."
        return 1
    fi
}

cleanup_on_exit() {
    local exit_code=$?

    trap - EXIT

    if ! start_containers_again; then
        exit_code=1
    fi

    if (( exit_code != 0 )) && [[ "$BACKUP_SUCCESS" != true ]]; then
        rm -f "$PARTIAL_FILE"
    fi

    exit "$exit_code"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ------------------------------------------------------------
# Lås
# ------------------------------------------------------------

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    log "WARN" "Backup blev ikke startet, fordi et andet backup-job allerede kører."
    exit 0
fi

log "INFO" "Backup-job startet."

write_status \
    "running" \
    "Backup er i gang" \
    "0 B" \
    "0"

# ------------------------------------------------------------
# Kontrollér om dagens backup allerede findes
# ------------------------------------------------------------

if [[ -f "$BACKUP_FILE" ]]; then
    if tar \
        --list \
        --gzip \
        --file="$BACKUP_FILE" \
        >/dev/null; then

        rm -f "$PARTIAL_FILE"
        BACKUP_SUCCESS=true
        existing_size="$(human_size "$BACKUP_FILE")"

        log "INFO" "Dagens backup findes allerede: $BACKUP_NAME"

        write_status \
            "success" \
            "Dagens backup fandtes allerede" \
            "$existing_size" \
            "0"

        exit 0
    fi

    log "ERROR" "Dagens backupfil findes, men er ugyldig: $BACKUP_NAME"

    write_status \
        "failed" \
        "Dagens backupfil er ugyldig" \
        "0 B" \
        "0"

    exit 1
fi

rm -f "$PARTIAL_FILE"

# ------------------------------------------------------------
# Kontrollér kildemapper
# ------------------------------------------------------------

VALID_SOURCES=()

for source in "${SOURCE_DIRS[@]}"; do
    if [[ -e "$source" ]]; then
        VALID_SOURCES+=("$source")
        log "INFO" "Kilde inkluderet: $source"
    else
        log "WARN" "Kilden findes ikke og springes over: $source"
    fi
done

if (( ${#VALID_SOURCES[@]} == 0 )); then
    log "ERROR" "Ingen gyldige kildemapper blev fundet."

    write_status \
        "failed" \
        "Ingen gyldige kildemapper blev fundet" \
        "0 B" \
        "0"

    exit 1
fi

# ------------------------------------------------------------
# Kontrollér ledig plads
#
# Vi kræver mindst kildernes ukomprimerede størrelse plus 1 GB.
# Det er forsigtigt, men reducerer risikoen for en fyldt disk.
# ------------------------------------------------------------

SOURCE_BYTES="$(du -sb "${VALID_SOURCES[@]}" 2>/dev/null | awk '{sum += $1} END {print sum + 0}')"
FREE_BYTES="$(df --output=avail -B1 "$BACKUP_DIR" | tail -n 1 | tr -d ' ')"
REQUIRED_BYTES=$((SOURCE_BYTES + 1073741824))

if (( FREE_BYTES < REQUIRED_BYTES )); then
    log "ERROR" "Der er ikke tilstrækkelig ledig plads i $BACKUP_DIR."

    write_status \
        "failed" \
        "Ikke tilstrækkelig ledig diskplads" \
        "0 B" \
        "0"

    exit 1
fi

# ------------------------------------------------------------
# Stop kørende Docker-containere
# ------------------------------------------------------------

mapfile -t RUNNING_CONTAINERS < <(docker ps --format '{{.ID}}')

DOCKER_STOP_START="$(date +%s)"

if (( ${#RUNNING_CONTAINERS[@]} > 0 )); then
    log "INFO" "Stopper ${#RUNNING_CONTAINERS[@]} kørende Docker-container(e)."

    # Restaurering er nødvendig, selv hvis docker stop kun lykkes
    # for nogle af containerne og derefter returnerer en fejl.
    DOCKER_STOPPED=true

    if ! docker stop "${RUNNING_CONTAINERS[@]}" >/dev/null; then
        log "ERROR" "Docker-containerne kunne ikke stoppes sikkert."

        write_status \
            "failed" \
            "Docker-containerne kunne ikke stoppes" \
            "0 B" \
            "0"

        exit 1
    fi

    log "INFO" "Docker-containerne er stoppet."
else
    log "INFO" "Ingen Docker-containere var i gang."
fi

# ------------------------------------------------------------
# Opret backup
#
# --absolute-names bruges ikke. Derfor gemmes stierne relativt:
# path/to/source/... i stedet for /path/to/source/...
# ------------------------------------------------------------

log "INFO" "Opretter backup: $BACKUP_NAME"

TAR_SOURCES=()

for source in "${VALID_SOURCES[@]}"; do
    TAR_SOURCES+=("${source#/}")
done

if tar \
    --create \
    --gzip \
    --file="$PARTIAL_FILE" \
    --directory="/" \
    --one-file-system \
    "${TAR_SOURCES[@]}"; then

    # Et hard link publicerer arkivet atomisk og fejler, hvis
    # destinationsfilen allerede findes. Et eksisterende arkiv
    # bliver derfor aldrig overskrevet.
    if ! ln "$PARTIAL_FILE" "$BACKUP_FILE"; then
        log "ERROR" "Backupfilen kunne ikke færdiggøres sikkert."

        write_status \
            "failed" \
            "Backupfilen kunne ikke færdiggøres sikkert" \
            "0 B" \
            "0"

        exit 1
    fi

    if [[ ! -f "$BACKUP_FILE" ]] || ! tar \
        --list \
        --gzip \
        --file="$BACKUP_FILE" \
        >/dev/null; then

        log "ERROR" "Den færdige backupfil kunne ikke valideres."
        rm -f "$BACKUP_FILE"

        write_status \
            "failed" \
            "Den færdige backupfil kunne ikke valideres" \
            "0 B" \
            "0"

        exit 1
    fi

    rm -f "$PARTIAL_FILE"
    BACKUP_SUCCESS=true

    log "INFO" "Backupfilen blev oprettet korrekt."
else
    log "ERROR" "Tar kunne ikke oprette backupfilen."

    write_status \
        "failed" \
        "Backupfilen kunne ikke oprettes" \
        "0 B" \
        "0"

    exit 1
fi

# ------------------------------------------------------------
# Start containerne igen
# ------------------------------------------------------------

if ! start_containers_again; then
    write_status \
        "failed" \
        "Docker-containerne kunne ikke startes" \
        "$(human_size "$BACKUP_FILE")" \
        "0"

    exit 1
fi

DOCKER_STOP_END="$(date +%s)"
DOCKER_DOWNTIME=$((DOCKER_STOP_END - DOCKER_STOP_START))

BACKUP_SIZE="$(human_size "$BACKUP_FILE")"
TOTAL_SECONDS=$(( $(date +%s) - START_SECONDS ))

log "INFO" "Backup gennemført: $BACKUP_NAME"
log "INFO" "Backupstørrelse: $BACKUP_SIZE"
log "INFO" "Docker-nedetid: ${DOCKER_DOWNTIME} sekunder"
log "INFO" "Samlet køretid: ${TOTAL_SECONDS} sekunder"
log "INFO" "Backup afventer senere overførsel til SMB-destinationen."

write_status \
    "pending" \
    "Backup oprettet og afventer overførsel" \
    "$BACKUP_SIZE" \
    "$DOCKER_DOWNTIME"

exit 0
