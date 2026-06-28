#!/bin/sh
# ============================================================================
#  Linux Server Generic Backup / Restore Script
#  POSIX compliant - runs under sh / bash on any Linux distribution.
#  Configurable via environment variables or a .env file next to this script.
#
#  Usage:
#    ./backup.sh                                  # run a backup
#    ./backup.sh --restore-latest                 # restore the latest backup
#    ./backup.sh --restore-latest --target-dir /new/path
#                                                 # restore to a different dir
# ============================================================================

# ----------------------------------------------------------------------------
# Parse CLI arguments
# ----------------------------------------------------------------------------
RESTORE_MODE=0
TARGET_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --restore-latest)
            RESTORE_MODE=1; shift ;;
        --target-dir)
            [ $# -lt 2 ] && { printf 'error: --target-dir requires a value\n' >&2; exit 2; }
            TARGET_DIR="$2"; shift 2 ;;
        --target-dir=*)
            TARGET_DIR="${1#--target-dir=}"; shift ;;
        *)
            printf 'error: unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# ----------------------------------------------------------------------------
# Module 1: Configuration loading
# ----------------------------------------------------------------------------

# Resolve this script's directory (used to locate .env)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Registry of all recognized configuration variables
CONFIG_VARS="STOP_CMD SRC_DIR BACKUP_DIR START_CMD MAX_BACKUPS BACKUP_PREFIX LOG_DIR"

# Snapshot system environment (highest priority) before sourcing .env, so that
# runtime env vars are never overwritten by the .env file.
for _v in $CONFIG_VARS; do
    eval "_sysset_${_v}=\${${_v}+set}"
    eval "_sysval_${_v}=\${${_v}-}"
done

# Load .env file (file config, lower priority than system env)
# Use set -e while sourcing so any syntax/command error in .env is fatal.
if [ -f "$SCRIPT_DIR/.env" ]; then
    _restore_set_e=0
    case "$-" in *e*) _restore_set_e=1 ;; esac
    set -e
    . "$SCRIPT_DIR/.env"
    [ "$_restore_set_e" -eq 0 ] && set +e
    unset _restore_set_e
fi

# Restore system env values (override .env)
for _v in $CONFIG_VARS; do
    if eval "[ \"\${_sysset_${_v}}\" = set ]"; then
        eval "${_v}=\${_sysval_${_v}}"
    fi
    unset "_sysset_${_v}" "_sysval_${_v}"
done
unset _v

# Apply built-in defaults (lowest priority) for optional variables
: "${MAX_BACKUPS:=30}"
: "${BACKUP_PREFIX:=app}"
: "${LOG_DIR:=./logs/}"

# --target-dir overrides SRC_DIR (highest priority, applies to both modes)
if [ -n "$TARGET_DIR" ]; then
    SRC_DIR="$TARGET_DIR"
fi

# Normalize paths: strip a single trailing slash for clean concatenation.
# Preserve the root path "/" so it remains detectable for safety checks.
[ "$SRC_DIR" != "/" ] && SRC_DIR="${SRC_DIR%/}"
[ "$BACKUP_DIR" != "/" ] && BACKUP_DIR="${BACKUP_DIR%/}"
[ "$LOG_DIR" != "/" ] && LOG_DIR="${LOG_DIR%/}"

# ----------------------------------------------------------------------------
# Module 2: Utility functions
# ----------------------------------------------------------------------------

# Unified log output: writes to both terminal and the current log file (when
# available), with a consistent timestamped format.
_log() {
    _level="$1"; shift
    _msg="[$(date +%Y%m%d_%H%M%S)] [$_level] $*"
    if [ -n "${LOG_FILE:-}" ] && [ -d "${LOG_DIR:-}" ]; then
        printf '%s\n' "$_msg" | tee -a "$LOG_FILE"
    else
        printf '%s\n' "$_msg"
    fi
    unset _level _msg
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }

# Rolling cleanup: keep the newest N files matching a pattern in a directory.
# Args: 1=directory  2=glob pattern  3=keep count
# Files are sorted by name descending (timestamp in name => newest first), so
# that ordering does not depend on file mtime.
# Files whose name contains "before_restore" are excluded: they are safety
# snapshots created by the restore flow and do not count against MAX_BACKUPS.
cleanup_old_files() {
    _cdir="$1"; _cpat="$2"; _ckeep="$3"; _ccount=0
    _clist=$(ls -1 "$_cdir"/$_cpat 2>/dev/null | grep -v 'before_restore' | sort -r)
    [ -z "$_clist" ] && return 0
    printf '%s\n' "$_clist" | while IFS= read -r _cf; do
        _ccount=$((_ccount + 1))
        [ "$_ccount" -le "$_ckeep" ] && continue
        rm -f "$_cf" 2>/dev/null || log_warn "failed to delete: $_cf"
    done
}

# ----------------------------------------------------------------------------
# Module 4: Exception fallback (trap)
# ----------------------------------------------------------------------------

START_ATTEMPTED=0
STOP_ATTEMPTED=0

# Safety net: ensure the service is (re)started on any exit, but only if a
# stop was actually attempted and a start command is configured. Idempotent.
# In restore mode STOP_ATTEMPTED stays 0, so this is a no-op.
ensure_service_started() {
    [ "$START_ATTEMPTED" -eq 1 ] && return 0
    START_ATTEMPTED=1
    [ -z "${START_CMD:-}" ] && return 0
    [ "${STOP_ATTEMPTED:-0}" -eq 0 ] && return 0
    log_info "starting service: $START_CMD"
    eval "$START_CMD" >/dev/null 2>&1
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        log_warn "start service failed (exit code: $_rc)"
    fi
    return 0
}

trap 'ensure_service_started' EXIT
trap 'exit 1' INT HUP TERM

# ----------------------------------------------------------------------------
# Mode dispatch
# ----------------------------------------------------------------------------

if [ "$RESTORE_MODE" -eq 1 ]; then
    # ---- Restore mode: validation ------------------------------------------
    _missing=""
    [ -z "${BACKUP_DIR:-}" ]    && _missing="$_missing BACKUP_DIR"
    [ -z "${SRC_DIR:-}" ]       && _missing="$_missing SRC_DIR"
    [ -z "${BACKUP_PREFIX:-}" ] && _missing="$_missing BACKUP_PREFIX"
    if [ -n "$_missing" ]; then
        printf '[%s] [ERROR] missing required config:%s\n' \
            "$(date +%Y%m%d_%H%M%S)" "$_missing" >&2
        exit 1
    fi

    if [ ! -d "$BACKUP_DIR" ]; then
        printf '[%s] [ERROR] backup directory does not exist: %s\n' \
            "$(date +%Y%m%d_%H%M%S)" "$BACKUP_DIR" >&2
        exit 1
    fi

    # Safety guard: refuse to overwrite the root filesystem.
    case "$SRC_DIR" in /|//) SRC_DIR="/" ;; esac
    if [ "$SRC_DIR" = "/" ]; then
        printf '[%s] [ERROR] refusing to restore to root directory\n' \
            "$(date +%Y%m%d_%H%M%S)" >&2
        exit 1
    fi

    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        printf '[%s] [ERROR] cannot create log directory: %s\n' \
            "$(date +%Y%m%d_%H%M%S)" "$LOG_DIR" >&2
        exit 1
    fi

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    LOG_FILE="$LOG_DIR/${BACKUP_PREFIX}_restore_${TIMESTAMP}.log"

    # ---- Restore flow ------------------------------------------------------
    log_info "restore mode started (timestamp: $TIMESTAMP)"

    # Locate the latest regular backup (exclude before_restore snapshots)
    _latest=$(ls -1 "$BACKUP_DIR"/${BACKUP_PREFIX}_backup_*.tar.gz 2>/dev/null \
              | grep -v 'before_restore' | sort -r | head -1)
    if [ -z "$_latest" ]; then
        log_error "no backup archive found in $BACKUP_DIR (prefix: $BACKUP_PREFIX)"
        exit 1
    fi

    # Step 1: confirm restore and print the archive path
    printf 'Latest backup archive: %s\n' "$_latest"
    printf 'Restore target:        %s\n' "$SRC_DIR"
    printf 'Proceed with restore? [y/yes to confirm, others to cancel]: '
    read _answer
    case "$_answer" in
        [yY]|[yY][eE][sS]) ;;
        *) log_info "restore cancelled by user"; exit 0 ;;
    esac

    # Step 2: choose how to handle the existing data folder
    printf 'How to handle the existing data folder?\n'
    printf '  1) Overwrite existing data directly\n'
    printf '  2) Back up current data first, then overwrite\n'
    printf '     (saved as: %s_backup_before_restore.tar.gz)\n' "$BACKUP_PREFIX"
    printf '  3) Cancel\n'
    printf 'Enter option [1/2/3]: '
    read _option
    case "$_option" in
        1)
            log_info "overwrite mode selected" ;;
        2)
            if [ -d "$SRC_DIR" ]; then
                _pre="$BACKUP_DIR/${BACKUP_PREFIX}_backup_before_restore.tar.gz"
                log_info "creating pre-restore backup: $_pre"
                if ! tar -zcf "$_pre" -C "$(dirname "$SRC_DIR")" "$(basename "$SRC_DIR")" 2>>"$LOG_FILE"; then
                    log_error "pre-restore backup failed"
                    exit 1
                fi
                log_info "pre-restore backup created"
            else
                log_warn "source dir does not exist, skipping pre-restore backup"
            fi
            ;;
        *)
            log_info "restore cancelled by user"; exit 0 ;;
    esac

    # Step 3: execute the restore (backup_dir -> src_dir)
    log_info "extracting archive: $_latest"
    _tmp=$(mktemp -d 2>/dev/null) || _tmp="/tmp/${BACKUP_PREFIX}_restore_$$"
    [ -d "$_tmp" ] || mkdir -p "$_tmp"
    if ! tar -zxf "$_latest" -C "$_tmp" 2>>"$LOG_FILE"; then
        log_error "extraction failed"
        rm -rf "$_tmp"
        exit 1
    fi
    # Archive stores the source dir basename as its single top-level entry.
    _top=$(ls -1A "$_tmp" 2>/dev/null | head -1)
    if [ -z "$_top" ]; then
        log_error "archive is empty"
        rm -rf "$_tmp"
        exit 1
    fi
    mkdir -p "$(dirname "$SRC_DIR")" 2>/dev/null
    rm -rf "$SRC_DIR"
    if ! mv "$_tmp/$_top" "$SRC_DIR" 2>>"$LOG_FILE"; then
        log_error "failed to move restored data to $SRC_DIR"
        rm -rf "$_tmp"
        exit 1
    fi
    rm -rf "$_tmp"
    log_info "restore completed successfully"
    log_info "restored from: $_latest"
    log_info "restored to:   $SRC_DIR"
    exit 0
fi

# ----------------------------------------------------------------------------
# Backup mode: pre-validation (fail fast before touching the service)
# ----------------------------------------------------------------------------

_missing=""
[ -z "${STOP_CMD:-}" ]   && _missing="$_missing STOP_CMD"
[ -z "${SRC_DIR:-}" ]    && _missing="$_missing SRC_DIR"
[ -z "${BACKUP_DIR:-}" ] && _missing="$_missing BACKUP_DIR"
[ -z "${START_CMD:-}" ]  && _missing="$_missing START_CMD"
if [ -n "$_missing" ]; then
    printf '[%s] [ERROR] missing required config:%s\n' \
        "$(date +%Y%m%d_%H%M%S)" "$_missing" >&2
    exit 1
fi

case "$MAX_BACKUPS" in
    ''|*[!0-9]*)
        printf '[%s] [ERROR] MAX_BACKUPS must be a positive integer (got: %s)\n' \
            "$(date +%Y%m%d_%H%M%S)" "$MAX_BACKUPS" >&2
        exit 1 ;;
esac
if [ "$MAX_BACKUPS" -lt 1 ]; then
    printf '[%s] [ERROR] MAX_BACKUPS must be >= 1\n' \
        "$(date +%Y%m%d_%H%M%S)" >&2
    exit 1
fi

if [ ! -d "$SRC_DIR" ]; then
    printf '[%s] [ERROR] source directory does not exist: %s\n' \
        "$(date +%Y%m%d_%H%M%S)" "$SRC_DIR" >&2
    exit 1
fi

if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
    printf '[%s] [ERROR] cannot create backup directory: %s\n' \
        "$(date +%Y%m%d_%H%M%S)" "$BACKUP_DIR" >&2
    exit 1
fi
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    printf '[%s] [ERROR] cannot create log directory: %s\n' \
        "$(date +%Y%m%d_%H%M%S)" "$LOG_DIR" >&2
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/${BACKUP_PREFIX}_backup_${TIMESTAMP}.tar.gz"
LOG_FILE="$LOG_DIR/${BACKUP_PREFIX}_backup_${TIMESTAMP}.log"

log_info "backup run started (timestamp: $TIMESTAMP)"
log_info "source      : $SRC_DIR"
log_info "archive     : $BACKUP_FILE"
log_info "log         : $LOG_FILE"

# ----------------------------------------------------------------------------
# Module 3: Main flow control
#            (validate -> stop -> backup -> start -> cleanup)
# ----------------------------------------------------------------------------

# Step 1: stop service
log_info "stopping service: $STOP_CMD"
STOP_ATTEMPTED=1
eval "$STOP_CMD" >/dev/null 2>&1
_rc=$?
if [ "$_rc" -ne 0 ]; then
    log_error "stop service failed (exit code: $_rc)"
    ensure_service_started
    exit 1
fi

# Step 2: backup data. Archive the source dir by its basename only (-C parent),
# so the archive is portable and can be restored to any target path.
log_info "creating archive..."
if ! tar -zcf "$BACKUP_FILE" -C "$(dirname "$SRC_DIR")" "$(basename "$SRC_DIR")" 2>>"$LOG_FILE"; then
    log_error "tar archive failed"
    rm -f "$BACKUP_FILE" 2>/dev/null
    ensure_service_started
    exit 1
fi
if [ ! -f "$BACKUP_FILE" ]; then
    log_error "archive was not created: $BACKUP_FILE"
    ensure_service_started
    exit 1
fi
log_info "archive created successfully"

# Step 3: start service (failure here is a warning only; backup is already saved)
ensure_service_started

# Step 4: rolling cleanup (only after a successful backup)
log_info "retention: keeping newest $MAX_BACKUPS archives/logs"
cleanup_old_files "$BACKUP_DIR" "${BACKUP_PREFIX}_backup_*.tar.gz" "$MAX_BACKUPS"
cleanup_old_files "$LOG_DIR" "${BACKUP_PREFIX}_backup_*.log" "$MAX_BACKUPS"

log_info "backup completed successfully"
exit 0
