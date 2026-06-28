#!/bin/sh
# ============================================================================
#  Linux Server Generic Backup Script
#  POSIX compliant - runs under sh / bash on any Linux distribution.
#  Configurable via environment variables or a .env file next to this script.
# ============================================================================

# ----------------------------------------------------------------------------
# Module 1: Configuration loading & validation
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
if [ -f "$SCRIPT_DIR/.env" ]; then
    . "$SCRIPT_DIR/.env"
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
: "${BACKUP_PREFIX:=APP}"
: "${LOG_DIR:=./logs/}"

# Normalize paths: strip a single trailing slash for clean concatenation
SRC_DIR="${SRC_DIR%/}"
BACKUP_DIR="${BACKUP_DIR%/}"
LOG_DIR="${LOG_DIR%/}"

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
cleanup_old_files() {
    _cdir="$1"; _cpat="$2"; _ckeep="$3"; _ccount=0
    _clist=$(ls -1 "$_cdir"/$_cpat 2>/dev/null | sort -r)
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
# Pre-validation (fail fast before touching the service)
# ----------------------------------------------------------------------------

# Required variables must be non-empty
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

# MAX_BACKUPS must be a positive integer
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

# Source data directory must exist
if [ ! -d "$SRC_DIR" ]; then
    printf '[%s] [ERROR] source directory does not exist: %s\n' \
        "$(date +%Y%m%d_%H%M%S)" "$SRC_DIR" >&2
    exit 1
fi

# Auto-create backup and log directories
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

# Unified timestamp for this run (shared by archive and log filenames)
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

# Step 2: backup data
log_info "creating archive..."
if ! tar -zcf "$BACKUP_FILE" "$SRC_DIR" 2>>"$LOG_FILE"; then
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
