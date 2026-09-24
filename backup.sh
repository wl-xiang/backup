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
#    ./backup.sh --help                           # show full usage
# ============================================================================

# ----------------------------------------------------------------------------
# Parse CLI arguments
# ----------------------------------------------------------------------------

# Print full usage: modes, options, configuration, files, examples, exit codes.
print_usage() {
    cat <<'EOF'
Linux Server Generic Backup / Restore Script

Usage:
  ./backup.sh [OPTIONS]

Modes (mutually exclusive; default when no mode option is given is backup):
  (none)                 Run a backup of SRC_DIR.
  --restore-latest       Restore the latest backup archive into SRC_DIR.

Options:
  --target-dir DIR       Override SRC_DIR for this run (applies to both modes).
                         A relative DIR resolves against the current working
                         directory.
  -h, --help             Show this help and exit.

Configuration (system env > .env file > built-in defaults):
  STOP_CMD        Command to stop the service before backup/restore.  (required)
  START_CMD       Command to start the service after backup/restore.  (required)
  SRC_DIR         Directory to back up / restore into.                (required)
  BACKUP_DIR      Directory where archives are written.               (required)
  MAX_BACKUPS     Newest N archives and logs to keep. Default: 30
  BACKUP_PREFIX   Prefix for archive / log file names. Default: app
  LOG_DIR         Directory for logs and the run lock. Default: ./logs/

Files:
  .env                                                   Optional, next to this script
  <BACKUP_DIR>/<BACKUP_PREFIX>_backup_<timestamp>.tar.gz           Backup archive
  <BACKUP_DIR>/<BACKUP_PREFIX>_backup_before_restore.tar.gz        Pre-restore safety snapshot
  <LOG_DIR>/<BACKUP_PREFIX>_backup_<timestamp>.log                 Backup log
  <LOG_DIR>/<BACKUP_PREFIX>_restore.log                            Restore log

Examples:
  ./backup.sh
  ./backup.sh --target-dir /srv/app/data
  ./backup.sh --restore-latest
  ./backup.sh --restore-latest --target-dir /srv/app/newdata

Exit codes:
  0  success, or restore cancelled by the user
  1  runtime failure
  2  invalid command-line usage
EOF
}

RESTORE_MODE=0
TARGET_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            print_usage; exit 0 ;;
        --restore-latest)
            RESTORE_MODE=1; shift ;;
        --target-dir)
            [ $# -lt 2 ] && { printf 'error: --target-dir requires a value\n' >&2; exit 2; }
            TARGET_DIR="$2"; shift 2 ;;
        --target-dir=*)
            TARGET_DIR="${1#--target-dir=}"; shift ;;
        *)
            printf 'error: unknown option: %s\n' "$1" >&2
            printf 'try: %s --help\n' "$0" >&2
            exit 2 ;;
    esac
done

# ----------------------------------------------------------------------------
# Module 1: Configuration loading
# ----------------------------------------------------------------------------

# Resolve this script's directory (used to locate .env and to anchor relative paths)
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

# --target-dir overrides SRC_DIR (highest priority, applies to both modes).
# Relative CLI paths resolve against the current working directory (intuitive
# when typed interactively).
if [ -n "$TARGET_DIR" ]; then
    case "$TARGET_DIR" in
        /*) SRC_DIR="$TARGET_DIR" ;;
        *)  SRC_DIR="$(pwd)/$TARGET_DIR" ;;
    esac
fi

# Resolve config-relative paths against the script directory so that cron /
# different CWDs cannot silently redirect SRC_DIR, BACKUP_DIR, or LOG_DIR.
resolve_config_path() {
    case "$1" in
        '')  printf '' ;;
        /*)  printf '%s' "$1" ;;
        *)
            _rp="$1"
            case "$_rp" in
                ./*) _rp="${_rp#./}" ;;
            esac
            printf '%s/%s' "$SCRIPT_DIR" "$_rp"
            ;;
    esac
}
[ -n "${SRC_DIR:-}" ]    && SRC_DIR=$(resolve_config_path "$SRC_DIR")
[ -n "${BACKUP_DIR:-}" ] && BACKUP_DIR=$(resolve_config_path "$BACKUP_DIR")
[ -n "${LOG_DIR:-}" ]    && LOG_DIR=$(resolve_config_path "$LOG_DIR")

# Normalize paths: strip ALL trailing slashes for clean concatenation and so
# root guards match ("//", "///", ... become "/"). Preserve "/" itself.
strip_trailing_slashes() {
    _st="${1:-}"
    while [ -n "$_st" ] && [ "$_st" != "/" ] && [ "${_st%/}" != "$_st" ]; do
        _st="${_st%/}"
    done
    printf '%s' "$_st"
}
if [ -n "${SRC_DIR:-}" ]; then
    SRC_DIR=$(strip_trailing_slashes "$SRC_DIR")
fi
if [ -n "${BACKUP_DIR:-}" ]; then
    BACKUP_DIR=$(strip_trailing_slashes "$BACKUP_DIR")
fi
if [ -n "${LOG_DIR:-}" ]; then
    LOG_DIR=$(strip_trailing_slashes "$LOG_DIR")
fi

# ----------------------------------------------------------------------------
# Module 2: Utility functions
# ----------------------------------------------------------------------------

# Unified log output: writes to both terminal and the current log file (when
# available), with a consistent timestamped format.
_log() {
    _level="$1"; shift
    _msg="[$(date +%Y%m%d_%H%M%S)] [$_level] $*"
    if [ -n "${LOG_FILE:-}" ] && [ -d "${LOG_DIR:-}" ]; then
        printf '%s\n' "$_msg" | tee -a "$LOG_FILE" || printf '%s\n' "$_msg"
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
# "|| true" keeps this safe under `set -e`.
cleanup_old_files() {
    _cdir="$1"; _cpat="$2"; _ckeep="$3"; _ccount=0
    _clist=$(ls -1 "$_cdir"/$_cpat 2>/dev/null | grep -v 'before_restore' | sort -r || true)
    [ -z "$_clist" ] && return 0
    printf '%s\n' "$_clist" | while IFS= read -r _cf; do
        _ccount=$((_ccount + 1))
        [ "$_ccount" -le "$_ckeep" ] && continue
        rm -f "$_cf" 2>/dev/null || log_warn "failed to delete: $_cf"
    done
    return 0
}

# ----------------------------------------------------------------------------
# Concurrency lock (mkdir-based, POSIX; stale-lock recovery via PID)
# ----------------------------------------------------------------------------
LOCK_DIR=""
acquire_lock() {
    LOCK_DIR="$LOG_DIR/.${BACKUP_PREFIX}_run.lock"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        return 0
    fi
    _opid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ -n "$_opid" ] && [ "$_opid" != "$$" ] && kill -0 "$_opid" 2>/dev/null; then
        printf '[%s] [ERROR] another instance is already running (pid %s, lock: %s)\n' \
            "$(date +%Y%m%d_%H%M%S)" "$_opid" "$LOCK_DIR" >&2
        exit 1
    fi
    log_warn "removing stale lock (owner pid ${_opid:-unknown} is not running): $LOCK_DIR"
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        return 0
    fi
    printf '[%s] [ERROR] cannot acquire lock: %s\n' \
        "$(date +%Y%m%d_%H%M%S)" "$LOCK_DIR" >&2
    exit 1
}

release_lock() {
    [ -n "${LOCK_DIR:-}" ] || return 0
    [ -d "$LOCK_DIR" ] || return 0
    _pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ "$_pid" = "$$" ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Module 4: Exception fallback (trap)
# ----------------------------------------------------------------------------

START_ATTEMPTED=0
STOP_ATTEMPTED=0

# Safety net: ensure the service is (re)started on any exit, but only if a
# stop was actually attempted and a start command is configured. Idempotent.
# Runs before lock release so a crashed restore/backup never leaves the
# service down or the lock held.
ensure_service_started() {
    [ "$START_ATTEMPTED" -eq 1 ] && return 0
    [ "${STOP_ATTEMPTED:-0}" -eq 0 ] && return 0
    [ -z "${START_CMD:-}" ] && return 0
    START_ATTEMPTED=1
    log_info "starting service: $START_CMD"
    eval "$START_CMD" >/dev/null 2>&1
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        log_warn "start service failed (exit code: $_rc)"
    fi
    return 0
}

on_exit() {
    ensure_service_started
    release_lock
}
trap 'on_exit' EXIT
trap 'exit 1' INT HUP TERM

# Stop the service once; on failure try to start it again and abort.
# Used by both backup and restore modes.
stop_service() {
    log_info "stopping service: $STOP_CMD"
    STOP_ATTEMPTED=1
    eval "$STOP_CMD" >/dev/null 2>&1
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        log_error "stop service failed (exit code: $_rc)"
        ensure_service_started
        exit 1
    fi
    return 0
}

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

    # Safety guard: refuse to overwrite the root filesystem ("//", "///" ... too).
    if [ "$SRC_DIR" = "/" ]; then
        printf '[%s] [ERROR] refusing to restore to root directory\n' \
            "$(date +%Y%m%d_%H%M%S)" >&2
        exit 1
    fi

    # Refuse stopping the service without a matching start command.
    if [ -n "${STOP_CMD:-}" ] && [ -z "${START_CMD:-}" ]; then
        printf '[%s] [ERROR] STOP_CMD is set but START_CMD is empty; refusing to stop without start\n' \
            "$(date +%Y%m%d_%H%M%S)" >&2
        exit 1
    fi

    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        printf '[%s] [ERROR] cannot create log directory: %s\n' \
            "$(date +%Y%m%d_%H%M%S)" "$LOG_DIR" >&2
        exit 1
    fi

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    LOG_FILE="$LOG_DIR/${BACKUP_PREFIX}_restore.log"
    : > "$LOG_FILE" 2>/dev/null || true

    # ---- Restore flow ------------------------------------------------------
    log_info "restore mode started (timestamp: $TIMESTAMP)"

    # Locate the latest regular backup (exclude before_restore snapshots)
    _latest=$(ls -1 "$BACKUP_DIR"/${BACKUP_PREFIX}_backup_*.tar.gz 2>/dev/null \
              | grep -v 'before_restore' | sort -r | head -1 || true)
    if [ -z "$_latest" ]; then
        log_error "no backup archive found in $BACKUP_DIR (prefix: $BACKUP_PREFIX)"
        exit 1
    fi

    # Integrity-check the archive BEFORE stopping anything or touching data.
    if ! tar -tzf "$_latest" >/dev/null 2>&1; then
        log_error "backup archive is corrupt or unreadable: $_latest"
        exit 1
    fi

    # Acquire lock before prompts so a concurrent backup cannot start mid-restore.
    acquire_lock

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
    _mode=0
    case "$_option" in
        1) _mode=1 ;;
        2) _mode=2 ;;
        *) log_info "restore cancelled by user"; exit 0 ;;
    esac

    # Step 3: stop the service (when configured) so data is not swapped under a live process
    if [ -n "${STOP_CMD:-}" ]; then
        stop_service
    else
        log_warn "STOP_CMD not set; restoring without stopping any service"
    fi

    # Step 4 (option 2): pre-restore safety snapshot of current data
    if [ "$_mode" -eq 2 ]; then
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
    fi

    # Step 5: extract to a temp dir, then swap with rollback on failure.
    # Order: validate extract -> move current data aside (rename, same FS)
    #        -> move new data into place -> delete old only after success.
    # On any failure the previous data is moved back before exiting.
    log_info "extracting archive: $_latest"
    _tmp=$(mktemp -d 2>/dev/null) || _tmp="/tmp/${BACKUP_PREFIX}_restore_$$"
    [ -d "$_tmp" ] || mkdir -p "$_tmp" || { log_error "cannot create temp dir: $_tmp"; exit 1; }
    if ! tar -zxf "$_latest" -C "$_tmp" 2>>"$LOG_FILE"; then
        log_error "extraction failed"
        rm -rf "$_tmp"
        exit 1
    fi

    _nentries=$(ls -1A "$_tmp" 2>/dev/null | wc -l | tr -d ' ')
    if [ -z "$_nentries" ] || [ "$_nentries" -eq 0 ]; then
        log_error "archive is empty"
        rm -rf "$_tmp"
        exit 1
    fi

    # Move current data aside (same-filesystem rename = atomic).
    _old_side=""
    if [ -e "$SRC_DIR" ]; then
        _old_side="${SRC_DIR}.pre_restore.$$"
        rm -rf "$_old_side" 2>/dev/null || true
        if ! mv "$SRC_DIR" "$_old_side" 2>>"$LOG_FILE"; then
            log_error "failed to move existing data aside: $SRC_DIR"
            rm -rf "$_tmp"
            exit 1
        fi
    fi

    _entries_list="${LOG_DIR:-/tmp}/.${BACKUP_PREFIX}_restore_entries.$$"
    _rollback() {
        log_error "$1"
        if [ -n "${_old_side:-}" ] && [ -e "$_old_side" ]; then
            rm -rf "$SRC_DIR" 2>/dev/null || true
            if mv "$_old_side" "$SRC_DIR" 2>>"$LOG_FILE"; then
                log_info "previous data restored to $SRC_DIR"
            else
                log_error "rollback failed; previous data left at: $_old_side"
            fi
        fi
        rm -f "${_entries_list:-}" 2>/dev/null || true
        rm -rf "$_tmp" 2>/dev/null || true
        exit 1
    }

    mkdir -p "$(dirname "$SRC_DIR")" 2>/dev/null || true

    if [ "$_nentries" -eq 1 ]; then
        _top=$(ls -1A "$_tmp" 2>/dev/null | head -1)
        if [ -d "$_tmp/$_top" ]; then
            # Normal case (our own backups): archive root is the source dir basename.
            if ! mv "$_tmp/$_top" "$SRC_DIR" 2>>"$LOG_FILE"; then
                _rollback "failed to move restored data to $SRC_DIR"
            fi
        else
            # Single non-directory entry: place it inside SRC_DIR.
            mkdir -p "$SRC_DIR" 2>/dev/null || _rollback "cannot create $SRC_DIR"
            if ! mv "$_tmp/$_top" "$SRC_DIR"/ 2>>"$LOG_FILE"; then
                _rollback "failed to move restored entry into $SRC_DIR"
            fi
        fi
    else
        # Multi-entry archive (foreign/partial): move every entry into SRC_DIR.
        # Line-based read keeps spaces/special chars intact (no word-splitting).
        mkdir -p "$SRC_DIR" 2>/dev/null || _rollback "cannot create $SRC_DIR"
        if ! ls -1A "$_tmp" > "$_entries_list" 2>/dev/null; then
            _rollback "failed to list archive entries"
        fi
        while IFS= read -r _top; do
            [ -n "$_top" ] || continue
            if ! mv "$_tmp/$_top" "$SRC_DIR"/ 2>>"$LOG_FILE"; then
                _rollback "failed to move restored entry: $_top"
            fi
        done < "$_entries_list"
    fi

    # Success: drop temp dir, entry list, and the aside-rename of old data.
    rm -f "$_entries_list" 2>/dev/null || true
    rm -rf "$_tmp" 2>/dev/null || true
    if [ -n "$_old_side" ] && [ -e "$_old_side" ]; then
        rm -rf "$_old_side" 2>/dev/null || log_warn "could not remove old data: $_old_side"
    fi

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

# Prevent concurrent runs (two crons / manual + cron) from clashing.
acquire_lock

log_info "backup run started (timestamp: $TIMESTAMP)"
log_info "source      : $SRC_DIR"
log_info "archive     : $BACKUP_FILE"
log_info "log         : $LOG_FILE"

# ----------------------------------------------------------------------------
# Module 3: Main flow control
#            (validate -> lock -> stop -> backup -> verify -> start -> cleanup)
# ----------------------------------------------------------------------------

# Step 1: stop service
stop_service

# Step 2: backup data. Archive the source dir by its basename only (-C parent),
# so the archive is portable and can be restored to any target path.
log_info "creating archive..."
_tar_rc=0
tar -zcf "$BACKUP_FILE" -C "$(dirname "$SRC_DIR")" "$(basename "$SRC_DIR")" 2>>"$LOG_FILE" || _tar_rc=$?
if [ "$_tar_rc" -ne 0 ]; then
    # GNU tar can exit 1 on non-fatal warnings (sockets, changed files, ...).
    # Only discard the archive if it does not actually verify.
    if [ -f "$BACKUP_FILE" ] && tar -tzf "$BACKUP_FILE" >/dev/null 2>&1; then
        log_warn "tar exited with code $_tar_rc but archive verified OK; keeping it"
    else
        log_error "tar archive failed (exit code: $_tar_rc)"
        rm -f "$BACKUP_FILE" 2>/dev/null || true
        ensure_service_started
        exit 1
    fi
fi

# Step 3: integrity check - never report success on an unreadable archive.
if [ ! -f "$BACKUP_FILE" ]; then
    log_error "archive was not created: $BACKUP_FILE"
    ensure_service_started
    exit 1
fi
if ! tar -tzf "$BACKUP_FILE" >/dev/null 2>&1; then
    log_error "archive failed integrity check (tar -tzf): $BACKUP_FILE"
    rm -f "$BACKUP_FILE" 2>/dev/null || true
    ensure_service_started
    exit 1
fi
log_info "archive created and verified successfully"

# Step 4: start service (failure here is a warning only; backup is already saved)
ensure_service_started

# Step 5: rolling cleanup (only after a successful backup)
log_info "retention: keeping newest $MAX_BACKUPS archives/logs"
cleanup_old_files "$BACKUP_DIR" "${BACKUP_PREFIX}_backup_*.tar.gz" "$MAX_BACKUPS"
cleanup_old_files "$LOG_DIR" "${BACKUP_PREFIX}_backup_*.log" "$MAX_BACKUPS"

log_info "backup completed successfully"
exit 0
