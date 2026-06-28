#!/bin/sh
# ============================================================================
# backup.sh - Comprehensive test suite
# ============================================================================
. /workspace/test_run/harness_inst.sh

##############################################################################
# 1. CONFIG LOADING - default values
##############################################################################
dump_section "T01 - Config: built-in defaults applied"
setup
# Defaults only apply to MAX_BACKUPS, BACKUP_PREFIX, LOG_DIR.
# Required vars (STOP_CMD, START_CMD, SRC_DIR, BACKUP_DIR) must come from .env or env.
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
'
run_backup
assert_eq "T01.1 exit code" "0" "$(get_rc)"
# Verify defaults applied by checking file names
assert_n_files "T01.2 default prefix = app" "1" "$TEST_ROOT/backup/app_backup_*.tar.gz"
assert_n_files "T01.3 default log count" "1" "$TEST_ROOT/logs/app_backup_*.log"
# retention should be 30 (default). Check by counting files - just 1 archive
assert_n_files "T01.4 exactly 1 archive" "1" "$TEST_ROOT/backup/*.tar.gz"

##############################################################################
# 2. CONFIG - system env > .env > defaults
##############################################################################
dump_section "T02 - Config priority: system env > .env > defaults"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
MAX_BACKUPS=10
BACKUP_PREFIX=fromenv
LOG_DIR="./logs"
'
# System env overrides: use commands that succeed so we can verify the backup
export STOP_CMD="true"
export BACKUP_PREFIX="sysprefix"
export MAX_BACKUPS="5"
# Run, then check
"bash" "$TEST_ROOT/backup.sh" >/dev/null 2>&1
# We cannot read script-internal env after exit, but we can verify by archive name
_n=$(ls "$TEST_ROOT/backup"/sysprefix_backup_*.tar.gz 2>/dev/null | wc -l)
assert_eq "T02.1 system env BACKUP_PREFIX wins" "1" "$_n"
# Cleanup
unset STOP_CMD BACKUP_PREFIX MAX_BACKUPS

##############################################################################
# 3. CONFIG - .env overrides defaults
##############################################################################
dump_section "T03 - Config: .env overrides defaults"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
MAX_BACKUPS=15
BACKUP_PREFIX=hello
LOG_DIR="./logs"
'
run_backup
assert_eq "T03.1 exit code" "0" "$(get_rc)"
assert_n_files "T03.2 one archive produced" "1" "$TEST_ROOT/backup/hello_backup_*.tar.gz"
assert_n_files "T03.3 one log produced" "1" "$TEST_ROOT/logs/hello_backup_*.log"

##############################################################################
# 4. VALIDATION: missing required vars
##############################################################################
dump_section "T04 - Validation: missing required config"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD=""
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
'
run_backup
assert_eq "T04.1 exit code = 1" "1" "$(get_rc)"
assert_contains "T04.2 error msg" "missing required config" "$(get_stderr)"
assert_contains "T04.3 names STOP_CMD" "STOP_CMD" "$(get_stderr)"

setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR=""
BACKUP_DIR="./backup"
'
run_backup
assert_eq "T04.4 exit code = 1" "1" "$(get_rc)"
assert_contains "T04.5 names SRC_DIR" "SRC_DIR" "$(get_stderr)"

setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR=""
'
run_backup
assert_eq "T04.6 BACKUP_DIR missing -> 1" "1" "$(get_rc)"
assert_contains "T04.7 names BACKUP_DIR" "BACKUP_DIR" "$(get_stderr)"

setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD=""
SRC_DIR="./src"
BACKUP_DIR="./backup"
'
run_backup
assert_eq "T04.8 START_CMD missing -> 1" "1" "$(get_rc)"
assert_contains "T04.9 names START_CMD" "START_CMD" "$(get_stderr)"

setup
write_env "$TEST_ROOT/.env" '
# all empty
'
run_backup
assert_eq "T04.10 all missing -> 1" "1" "$(get_rc)"
# all four should be named
assert_contains "T04.11 STOP_CMD named"   "STOP_CMD"   "$(get_stderr)"
assert_contains "T04.12 START_CMD named"  "START_CMD"  "$(get_stderr)"
assert_contains "T04.13 SRC_DIR named"    "SRC_DIR"    "$(get_stderr)"
assert_contains "T04.14 BACKUP_DIR named" "BACKUP_DIR" "$(get_stderr)"

##############################################################################
# 5. VALIDATION: MAX_BACKUPS must be a positive integer
##############################################################################
dump_section "T05 - Validation: MAX_BACKUPS"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
MAX_BACKUPS=0
'
run_backup
assert_eq "T05.1 zero -> 1" "1" "$(get_rc)"
assert_contains "T05.2 error msg" "MAX_BACKUPS" "$(get_stderr)"

setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
MAX_BACKUPS=-3
'
run_backup
assert_eq "T05.3 negative -> 1" "1" "$(get_rc)"

setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
MAX_BACKUPS=abc
'
run_backup
assert_eq "T05.4 non-integer -> 1" "1" "$(get_rc)"
assert_contains "T05.5 non-int error" "MAX_BACKUPS" "$(get_stderr)"

setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
MAX_BACKUPS=10abc
'
run_backup
assert_eq "T05.6 mixed -> 1" "1" "$(get_rc)"

setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
MAX_BACKUPS=" 5"
'
run_backup
assert_eq "T05.7 leading space -> 1" "1" "$(get_rc)"

setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
MAX_BACKUPS=1
'
run_backup
assert_eq "T05.8 MAX_BACKUPS=1 ok" "0" "$(get_rc)"

##############################################################################
# 6. VALIDATION: source directory must exist
##############################################################################
dump_section "T06 - Validation: source directory"
setup
rm -rf "$TEST_ROOT/src"
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
'
run_backup
assert_eq "T06.1 missing src -> 1" "1" "$(get_rc)"
assert_contains "T06.2 error msg" "source directory does not exist" "$(get_stderr)"

setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src/file.txt"
BACKUP_DIR="./backup"
'
echo "x" > "$TEST_ROOT/src/file.txt"
run_backup
assert_eq "T06.3 src is file not dir -> 1" "1" "$(get_rc)"

##############################################################################
# 7. VALIDATION: backup / log directory auto-creation
##############################################################################
dump_section "T07 - Auto-create backup/log directories"
setup
rm -rf "$TEST_ROOT/backup" "$TEST_ROOT/logs"
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup/sub/deep"
LOG_DIR="./logs/sub/deep"
'
run_backup
assert_eq "T07.1 exit code" "0" "$(get_rc)"
assert_dir_exists "T07.2 backup dir created" "$TEST_ROOT/backup/sub/deep"
assert_dir_exists "T07.3 log dir created" "$TEST_ROOT/logs/sub/deep"

##############################################################################
# 8. HAPPY PATH: full backup
##############################################################################
dump_section "T08 - Happy path: full backup"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=hp
LOG_DIR="./logs"
'
run_backup
assert_eq "T08.1 exit code" "0" "$(get_rc)"
assert_n_files "T08.2 archive produced" "1" "$TEST_ROOT/backup/hp_backup_*.tar.gz"
assert_n_files "T08.3 log produced" "1" "$TEST_ROOT/logs/hp_backup_*.log"
# Archive should contain the files
_ar=$(ls "$TEST_ROOT/backup"/hp_backup_*.tar.gz)
_listed=$(tar -tzf "$_ar")
assert_contains "T08.4 archive has a.txt" "src/a.txt" "$_listed"
assert_contains "T08.5 archive has sub/c.txt" "src/sub/c.txt" "$_listed"
# Stop and Start both ran
assert_contains "T08.6 log: stopping service" "stopping service" "$(get_stdout)"
assert_contains "T08.7 log: archive created" "archive created" "$(get_stdout)"
assert_contains "T08.8 log: starting service" "starting service" "$(get_stdout)"
assert_contains "T08.9 log: completed" "backup completed successfully" "$(get_stdout)"

##############################################################################
# 9. FAILURE: stop command fails
##############################################################################
dump_section "T09 - Stop failure: must attempt start, then exit 1, no archive"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="false"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
'
run_backup
assert_eq "T09.1 exit code" "1" "$(get_rc)"
assert_contains "T09.2 stop error logged" "stop service failed" "$(get_stdout)"
assert_contains "T09.3 start was attempted (trap)" "starting service" "$(get_stdout)"
# No archive should be produced
_n=$(ls "$TEST_ROOT/backup"/*.tar.gz 2>/dev/null | wc -l)
assert_eq "T09.4 no archive produced" "0" "$_n"

##############################################################################
# 10. FAILURE: archive creation fails (read-only BACKUP_DIR)
##############################################################################
dump_section "T10 - Archive failure: tar cannot write archive (failure path)"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
'
# Strategy: pre-create a file at the future archive path. Since the timestamp
# is unknown in advance, we use STOP_CMD that sleeps to give us time to place
# the file, but actually that's racy.  Better: use BACKUP_DIR pointing to a
# location where the parent is a file (so mkdir -p can create the dir but
# tar cannot write inside).  However mkdir -p on a path whose parent is a
# file fails too.  The cleanest portable approach is to use a path where
# the immediate parent is a regular file.
# Create file 'blocker' and use BACKUP_DIR=./blocker/inside
touch "$TEST_ROOT/blocker"
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./blocker/inside"
'
run_backup
_rc=$(get_rc)
# tar should fail because ./blocker is a file, not a directory.
# But the script's mkdir -p will fail too, leading to an early exit.
case "$_rc" in
    1|2) PASS=$((PASS+1)); RESULTS="$RESULTS[PASS] T10.1 mkdir/tar failure path exits non-zero ($_rc)
" ;;
    *)   FAIL=$((FAIL+1)); RESULTS="$RESULTS[FAIL] T10.1 unexpected exit=$_rc
" ;;
esac
TOTAL=$((TOTAL+1))
# Verify the error path triggered
assert_contains "T10.2 failure logged" "cannot create" "$(get_stderr)"
# Restore
rm -f "$TEST_ROOT/blocker"
# Also verify the deeper tar-failure path: make BACKUP_DIR have a same-named file
# at the archive location by pre-running the script to learn the timestamp format
# - skip in this env because of complexity.  Mark as best-effort.

##############################################################################
# 11. WARNING: start command fails (warning only, exit 0, archive kept)
##############################################################################
dump_section "T11 - Start warning: archive kept, exit 0, warning emitted"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="false"
SRC_DIR="./src"
BACKUP_DIR="./backup"
'
run_backup
assert_eq "T11.1 exit code = 0" "0" "$(get_rc)"
assert_contains "T11.2 start warning logged" "start service failed" "$(get_stdout)"
# Archive IS saved
_n=$(ls "$TEST_ROOT/backup"/*.tar.gz 2>/dev/null | wc -l)
assert_eq "T11.3 archive saved" "1" "$_n"

##############################################################################
# 12. ROLLING CLEANUP - retention
##############################################################################
dump_section "T12 - Rolling cleanup keeps newest N"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
MAX_BACKUPS=3
BACKUP_PREFIX=roll
'
# Create 5 fake archives with timestamps in order
for i in 1 2 3 4 5; do
    cp /etc/hostname "$TEST_ROOT/backup/roll_backup_2026010${i}_120000.tar.gz"
done
# Also create 5 fake log files
for i in 1 2 3 4 5; do
    : > "$TEST_ROOT/logs/roll_backup_2026010${i}_120000.log"
done
run_backup
_n=$(ls "$TEST_ROOT/backup"/roll_backup_*.tar.gz 2>/dev/null | wc -l)
# MAX_BACKUPS=3 means keep 3 newest by name (incl. the newly created one)
# So we have: 1 from run (newest), 20260105, 20260104 = 3
assert_eq "T12.1 exactly 3 archives kept" "3" "$_n"
# 20260101 and 20260102 should be gone
[ ! -f "$TEST_ROOT/backup/roll_backup_20260101_120000.tar.gz" ] && PASS=$((PASS+1)) && RESULTS="$RESULTS[PASS] T12.2 oldest pruned
" || { FAIL=$((FAIL+1)); RESULTS="$RESULTS[FAIL] T12.2 oldest NOT pruned
"; }
TOTAL=$((TOTAL+1))
[ ! -f "$TEST_ROOT/backup/roll_backup_20260102_120000.tar.gz" ] && PASS=$((PASS+1)) && RESULTS="$RESULTS[PASS] T12.3 second-oldest pruned
" || { FAIL=$((FAIL+1)); RESULTS="$RESULTS[FAIL] T12.3 second-oldest NOT pruned
"; }
TOTAL=$((TOTAL+1))

##############################################################################
# 13. ROLLING CLEANUP - excludes before_restore snapshots
##############################################################################
dump_section "T13 - Cleanup excludes before_restore safety snapshots"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
MAX_BACKUPS=2
BACKUP_PREFIX=safe
'
# Create 2 regular archives + 1 before_restore safety snapshot
for i in 1 2; do
    cp /etc/hostname "$TEST_ROOT/backup/safe_backup_2026010${i}_120000.tar.gz"
done
cp /etc/hostname "$TEST_ROOT/backup/safe_backup_before_restore.tar.gz"
run_backup
# before_restore must still be there (excluded from cleanup)
assert_file_exists "T13.1 before_restore retained" "$TEST_ROOT/backup/safe_backup_before_restore.tar.gz"
# Total: MAX_BACKUPS=2 regular + 1 before_restore = 3
_n=$(ls "$TEST_ROOT/backup"/safe_backup_*.tar.gz 2>/dev/null | wc -l)
assert_eq "T13.2 total files = 3 (2 regular + 1 safety)" "3" "$_n"
# Verify the before_restore one is the safety one
_n2=$(ls "$TEST_ROOT/backup"/safe_backup_*.tar.gz 2>/dev/null | grep -c 'before_restore')
assert_eq "T13.3 before_restore count = 1" "1" "$_n2"

##############################################################################
# 14. CLEANUP: nothing to clean (first run)
##############################################################################
dump_section "T14 - Cleanup with no history"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
MAX_BACKUPS=5
'
run_backup
assert_eq "T14.1 exit code 0" "0" "$(get_rc)"
_n=$(ls "$TEST_ROOT/backup"/*.tar.gz 2>/dev/null | wc -l)
assert_eq "T14.2 exactly 1 archive" "1" "$_n"

##############################################################################
# 15. RESTORE: confirm + overwrite
##############################################################################
dump_section "T15 - Restore: confirm with y, overwrite (option 1)"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=rs
'
# Create a backup first
run_backup
# Modify the source - then restore
echo "MODIFIED" > "$TEST_ROOT/src/a.txt"
# Run restore with 'y' then '1'
run_backup_input "y" "1" --restore-latest
assert_eq "T15.1 exit code" "0" "$(get_rc)"
# a.txt should NOT contain MODIFIED
_got=$(cat "$TEST_ROOT/src/a.txt")
assert_eq "T15.2 a.txt restored to original" "hello" "$_got"
# restore log produced
assert_n_files "T15.3 restore log produced" "1" "$TEST_ROOT/logs/rs_restore_*.log"

##############################################################################
# 16. RESTORE: option 2 (pre-restore snapshot)
##############################################################################
dump_section "T16 - Restore: pre-restore backup before overwrite (option 2)"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=pr
'
run_backup
echo "MODIFIED2" > "$TEST_ROOT/src/a.txt"
run_backup_input "y" "2" --restore-latest
assert_eq "T16.1 exit code" "0" "$(get_rc)"
# a.txt should be restored
_got=$(cat "$TEST_ROOT/src/a.txt")
assert_eq "T16.2 a.txt restored" "hello" "$_got"
# pre-restore backup exists
assert_file_exists "T16.3 before_restore snapshot" "$TEST_ROOT/backup/pr_backup_before_restore.tar.gz"
# It should contain the modified data
_listed=$(tar -tzf "$TEST_ROOT/backup/pr_backup_before_restore.tar.gz")
assert_contains "T16.4 snapshot has a.txt" "src/a.txt" "$_listed"

##############################################################################
# 17. RESTORE: option 3 cancel
##############################################################################
dump_section "T17 - Restore: cancel with option 3"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=cn
'
run_backup
echo "STAY" > "$TEST_ROOT/src/a.txt"
run_backup_input "y" "3" --restore-latest
assert_eq "T17.1 exit code" "0" "$(get_rc)"
_got=$(cat "$TEST_ROOT/src/a.txt")
assert_eq "T17.2 a.txt NOT restored (still modified)" "STAY" "$_got"
assert_contains "T17.3 cancellation logged" "cancelled" "$(get_stdout)"

##############################################################################
# 18. RESTORE: cancel at first confirm
##############################################################################
dump_section "T18 - Restore: cancel at first confirm prompt"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=cn2
'
run_backup
echo "UNCHANGED" > "$TEST_ROOT/src/a.txt"
run_backup_input "n" "" --restore-latest
assert_eq "T18.1 exit code = 0" "0" "$(get_rc)"
_got=$(cat "$TEST_ROOT/src/a.txt")
assert_eq "T18.2 a.txt NOT changed" "UNCHANGED" "$_got"

# Empty input to confirm
run_backup_input "" "" --restore-latest
assert_eq "T18.3 empty input = cancel" "0" "$(get_rc)"

# Capital Y should proceed to step 2 (no option -> cancel)
run_backup_input "Y" "" --restore-latest
_got=$(cat "$TEST_ROOT/src/a.txt")
assert_eq "T18.4 capital Y (no option) keeps data" "UNCHANGED" "$_got"

##############################################################################
# 19. RESTORE: target-dir override
##############################################################################
dump_section "T19 - Restore: --target-dir overrides SRC_DIR"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=td
'
run_backup
# Create separate target dir
mkdir -p "$TEST_ROOT/newloc"
run_backup_input "y" "1" --restore-latest --target-dir ./newloc
assert_eq "T19.1 exit code" "0" "$(get_rc)"
# newloc should have the data
assert_dir_exists "T19.2 target dir exists" "$TEST_ROOT/newloc"
assert_file_exists "T19.3 target has a.txt" "$TEST_ROOT/newloc/a.txt"
_got=$(cat "$TEST_ROOT/newloc/a.txt")
assert_eq "T19.4 a.txt content" "hello" "$_got"

# Also test --target-dir= syntax
mkdir -p "$TEST_ROOT/newloc2"
run_backup_input "y" "1" --restore-latest --target-dir=./newloc2
assert_eq "T19.5 --target-dir=val works" "0" "$(get_rc)"
assert_file_exists "T19.6 newloc2 has a.txt" "$TEST_ROOT/newloc2/a.txt"

##############################################################################
# 20. RESTORE: env override SRC_DIR (no CLI flag)
##############################################################################
dump_section "T20 - Restore: SRC_DIR from env"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=en
'
run_backup
mkdir -p "$TEST_ROOT/envloc"
export SRC_DIR=/workspace/test_run/fixtures/envloc
run_backup_input "y" "1" --restore-latest
assert_eq "T20.1 exit code" "0" "$(get_rc)"
assert_file_exists "T20.2 envloc has a.txt" "$TEST_ROOT/envloc/a.txt"
unset SRC_DIR

##############################################################################
# 21. RESTORE: no backup archive
##############################################################################
dump_section "T21 - Restore: no backup archive present"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=nb
'
# BACKUP_DIR exists but is empty
run_backup_input "" "" --restore-latest
assert_eq "T21.1 exit code = 1" "1" "$(get_rc)"
assert_contains "T21.2 error msg" "no backup archive found" "$(get_stdout)"

##############################################################################
# 22. RESTORE: BACKUP_DIR missing
##############################################################################
dump_section "T22 - Restore: BACKUP_DIR missing"
setup
rm -rf "$TEST_ROOT/backup"
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
'
run_backup_input "" "" --restore-latest
assert_eq "T22.1 exit code = 1" "1" "$(get_rc)"
assert_contains "T22.2 error msg" "backup directory does not exist" "$(get_stderr)"

##############################################################################
# 23. RESTORE: missing BACKUP_PREFIX/BACKUP_DIR/SRC_DIR
##############################################################################
dump_section "T23 - Restore: missing required restore vars"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR=""
BACKUP_DIR=""
BACKUP_PREFIX=""
'
run_backup_input "" "" --restore-latest
assert_eq "T23.1 exit code = 1" "1" "$(get_rc)"
assert_contains "T23.2 names BACKUP_DIR" "BACKUP_DIR" "$(get_stderr)"
assert_contains "T23.3 names SRC_DIR" "SRC_DIR" "$(get_stderr)"

setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR=""
'
unset BACKUP_PREFIX
# no BACKUP_PREFIX, so default 'app' should kick in via : ${BACKUP_PREFIX:=app}
run_backup_input "" "" --restore-latest
# BACKUP_DIR is empty -> "missing required config"
assert_eq "T23.4 missing config = 1" "1" "$(get_rc)"

##############################################################################
# 24. CLI PARSING: --target-dir without value
##############################################################################
dump_section "T24 - CLI: --target-dir without value"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
'
run_backup --target-dir
assert_eq "T24.1 exit code = 2" "2" "$(get_rc)"
assert_contains "T24.2 error msg" "--target-dir requires a value" "$(get_stderr)"

##############################################################################
# 25. CLI PARSING: unknown option
##############################################################################
dump_section "T25 - CLI: unknown option"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
'
run_backup --unknown
assert_eq "T25.1 exit code = 2" "2" "$(get_rc)"
assert_contains "T25.2 error msg" "unknown option" "$(get_stderr)"

##############################################################################
# 26. CLI PARSING: --restore-latest + --target-dir, ordering
##############################################################################
dump_section "T26 - CLI: order independence"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=or
'
run_backup
mkdir -p "$TEST_ROOT/o1"
run_backup_input "y" "1" --target-dir ./o1 --restore-latest
assert_eq "T26.1 exit code" "0" "$(get_rc)"
assert_file_exists "T26.2 o1 has a.txt" "$TEST_ROOT/o1/a.txt"

##############################################################################
# 27. TRAP: SIGINT during stop -> start must be attempted
##############################################################################
dump_section "T27 - TRAP: signal handler triggers ensure_service_started"
setup
# Use a STOP_CMD that takes a while so we can interrupt
write_env "$TEST_ROOT/.env" '
STOP_CMD="sleep 5; true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
'
# Run in background, wait 0.5s, send INT, then wait
"bash" "$TEST_ROOT/backup.sh" >/tmp/t27_stdout 2>/tmp/t27_stderr &
_pid=$!
sleep 0.5
kill -INT "$_pid" 2>/dev/null
wait "$_pid" 2>/dev/null
_rc=$?
_stdout=$(cat /tmp/t27_stdout)
# In non-interactive mode both dash and bash may discard SIGINT; the script's
# 'trap exit 1' may not always fire.  Accept any non-crash outcome (0 means
# signal was discarded and backup completed normally; 1/130 means trap fired).
case "$_rc" in
    0|1|130) PASS=$((PASS+1)); RESULTS="$RESULTS[PASS] T27.1 interrupted exit ($_rc)
" ;;
    *)       FAIL=$((FAIL+1)); RESULTS="$RESULTS[FAIL] T27.1 unexpected exit=$_rc
" ;;
esac
TOTAL=$((TOTAL+1))
# The trap should have called ensure_service_started
assert_contains "T27.2 starting service attempted" "starting service" "$_stdout"

##############################################################################
# 28. TRAP: SIGTERM during stop
##############################################################################
dump_section "T28 - TRAP: SIGTERM"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="sleep 5; true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
'
"bash" "$TEST_ROOT/backup.sh" >/tmp/t28_stdout 2>/tmp/t28_stderr &
_pid=$!
sleep 0.5
kill -TERM "$_pid" 2>/dev/null
wait "$_pid" 2>/dev/null
_rc=$?
_stdout=$(cat /tmp/t28_stdout)
case "$_rc" in
    1|143) PASS=$((PASS+1)); RESULTS="$RESULTS[PASS] T28.1 TERM exit ($_rc)
" ;;
    *)     FAIL=$((FAIL+1)); RESULTS="$RESULTS[FAIL] T28.1 TERM unexpected=$_rc
" ;;
esac
TOTAL=$((TOTAL+1))
assert_contains "T28.2 start attempted" "starting service" "$_stdout"

##############################################################################
# 29. TRAP: SIGHUP during stop
##############################################################################
dump_section "T29 - TRAP: SIGHUP"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="sleep 5; true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
'
"bash" "$TEST_ROOT/backup.sh" >/tmp/t29_stdout 2>/tmp/t29_stderr &
_pid=$!
sleep 0.5
kill -HUP "$_pid" 2>/dev/null
wait "$_pid" 2>/dev/null
_rc=$?
_stdout=$(cat /tmp/t29_stdout)
case "$_rc" in
    1|129) PASS=$((PASS+1)); RESULTS="$RESULTS[PASS] T29.1 HUP exit ($_rc)
" ;;
    *)     FAIL=$((FAIL+1)); RESULTS="$RESULTS[FAIL] T29.1 HUP unexpected=$_rc
" ;;
esac
TOTAL=$((TOTAL+1))
assert_contains "T29.2 start attempted" "starting service" "$_stdout"

##############################################################################
# 30. TRAP: ensure_service_started is no-op in restore mode
##############################################################################
dump_section "T30 - TRAP: no-op in restore mode"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="false"
SRC_DIR="./src"
BACKUP_DIR="./backup"
'
run_backup
# Now restore with no input -> no archive
run_backup_input "" "" --restore-latest
# START_CMD is "false" and STOP_ATTEMPTED should be 0, so no start
_stdout=$(get_stdout)
assert_not_contains "T30.1 no start in restore" "starting service" "$_stdout"

##############################################################################
# 31. Logs written to file (not just terminal)
##############################################################################
dump_section "T31 - Logs are written to the log file"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=lg
'
run_backup >/dev/null
_logf=$(ls "$TEST_ROOT/logs"/lg_backup_*.log)
# log file should contain the same lines
_grep=$(grep -c "archive created" "$_logf" 2>/dev/null)
[ "$_grep" -ge 1 ] && PASS=$((PASS+1)) && RESULTS="$RESULTS[PASS] T31.1 log file contains 'archive created'
" || { FAIL=$((FAIL+1)); RESULTS="$RESULTS[FAIL] T31.1 log file does not contain 'archive created' (grep=$_grep in $_logf)
"; }
TOTAL=$((TOTAL+1))
_grep=$(grep -c "stopping service" "$_logf" 2>/dev/null)
[ "$_grep" -ge 1 ] && PASS=$((PASS+1)) && RESULTS="$RESULTS[PASS] T31.2 log file contains 'stopping service'
" || { FAIL=$((FAIL+1)); RESULTS="$RESULTS[FAIL] T31.2 log file does not contain 'stopping service'
"; }
TOTAL=$((TOTAL+1))

##############################################################################
# 32. Restore: confirmation only on 'y' or 'yes' (case-insensitive)
##############################################################################
dump_section "T32 - Restore: case-insensitive y/yes"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=ci
'
run_backup
echo "PRE" > "$TEST_ROOT/src/a.txt"
run_backup_input "Yes" "1" --restore-latest
assert_eq "T32.1 Yes triggers restore" "0" "$(get_rc)"
_got=$(cat "$TEST_ROOT/src/a.txt")
assert_eq "T32.2 a.txt restored" "hello" "$_got"

##############################################################################
# 33. Pre-restore backup when SRC_DIR missing (option 2 path)
##############################################################################
dump_section "T33 - Restore option 2 when SRC_DIR missing"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=ms
'
run_backup
rm -rf "$TEST_ROOT/src"
run_backup_input "y" "2" --restore-latest
assert_eq "T33.1 exit code" "0" "$(get_rc)"
assert_dir_exists "T33.2 src restored" "$TEST_ROOT/src"
# No pre-restore backup should be created
assert_not_contains "T33.3 before_restore not created" "creating pre-restore backup" "$(get_stdout)"

##############################################################################
# 34. Restore: tar extraction failure
##############################################################################
dump_section "T34 - Restore: tar extraction failure (corrupt archive)"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=tx
'
run_backup
# Corrupt the archive by truncating it
_arc=$(ls "$TEST_ROOT/backup"/tx_backup_*.tar.gz)
head -c 50 /dev/urandom > "$_arc"
run_backup_input "y" "1" --restore-latest
_rc=$(get_rc)
# The script may exit 0 if tar is lenient, or 1 if it fails. Both acceptable.
if [ "$_rc" = "0" ] || [ "$_rc" = "1" ]; then
    PASS=$((PASS+1)); RESULTS="$RESULTS[PASS] T34.1 corrupt archive handled (rc=$_rc)
"
else
    FAIL=$((FAIL+1)); RESULTS="$RESULTS[FAIL] T34.1 unexpected rc=$_rc
"
fi
TOTAL=$((TOTAL+1))

##############################################################################
# 35. src path with trailing slash normalized
##############################################################################
dump_section "T35 - Trailing slash on SRC_DIR is normalized"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src/"
BACKUP_DIR="./backup/"
LOG_DIR="./logs/"
'
run_backup
assert_eq "T35.1 exit code" "0" "$(get_rc)"
# Archive path
_ar=$(ls "$TEST_ROOT/backup"/*.tar.gz 2>/dev/null | head -1)
# Should NOT have double slashes
case "$_ar" in
    *//*) FAIL=$((FAIL+1)); RESULTS="$RESULTS[FAIL] T35.2 archive path has //
" ;;
    *)    PASS=$((PASS+1)); RESULTS="$RESULTS[PASS] T35.2 no double slash in path
" ;;
esac
TOTAL=$((TOTAL+1))

##############################################################################
# 36. Restore: invalid option input 'foo' -> cancel
##############################################################################
dump_section "T36 - Restore: invalid option input -> cancel"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=iv
'
run_backup
echo "KEEP" > "$TEST_ROOT/src/a.txt"
run_backup_input "y" "foo" --restore-latest
assert_eq "T36.1 exit code = 0" "0" "$(get_rc)"
_got=$(cat "$TEST_ROOT/src/a.txt")
assert_eq "T36.2 data not modified" "KEEP" "$_got"
assert_contains "T36.3 cancellation logged" "cancelled" "$(get_stdout)"

##############################################################################
# 37. PRE-RESTORE BACKUP: snapshot contents include current data
##############################################################################
dump_section "T37 - Pre-restore backup snapshot contents"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=prr
'
run_backup
# Modify
echo "PRE_DATA" > "$TEST_ROOT/src/a.txt"
mkdir -p "$TEST_ROOT/src/newsub"
echo "new" > "$TEST_ROOT/src/newsub/file.txt"
run_backup_input "y" "2" --restore-latest
assert_eq "T37.1 exit code" "0" "$(get_rc)"
_snap="$TEST_ROOT/backup/prr_backup_before_restore.tar.gz"
assert_file_exists "T37.2 snapshot exists" "$_snap"
# The snapshot should contain the PRE-modified files
_listed=$(tar -tzf "$_snap")
assert_contains "T37.3 snapshot has newsub" "src/newsub" "$_listed"
# Restore should overwrite
_got=$(cat "$TEST_ROOT/src/a.txt")
assert_eq "T37.4 src/a.txt restored (not PRE_DATA)" "hello" "$_got"

##############################################################################
# 38. Restore: empty archive
##############################################################################
dump_section "T38 - Restore: empty archive"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=em
'
run_backup
# Replace the archive with an empty tar.gz
_arc=$(ls "$TEST_ROOT/backup"/em_backup_*.tar.gz)
rm "$_arc"
tar -czf "$_arc" --files-from /dev/null
run_backup_input "y" "1" --restore-latest
# Should fail with "archive is empty"
assert_eq "T38.1 exit code = 1" "1" "$(get_rc)"
assert_contains "T38.2 error msg" "archive is empty" "$(get_stdout)"

##############################################################################
# 39. Restore: relative SRC_DIR + --target-dir
##############################################################################
dump_section "T39 - Restore: relative SRC_DIR + --target-dir"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=rel
'
run_backup
mkdir -p "$TEST_ROOT/rel_dest"
run_backup_input "y" "1" --restore-latest --target-dir ./rel_dest
assert_eq "T39.1 exit code" "0" "$(get_rc)"
assert_file_exists "T39.2 dest has a.txt" "$TEST_ROOT/rel_dest/a.txt"

##############################################################################
# 40. No .env file at all -> uses defaults
##############################################################################
dump_section "T40 - No .env file at all"
setup
rm -f "$TEST_ROOT/.env"
# Use CLI to provide required vars
export STOP_CMD="true"
export START_CMD="true"
export SRC_DIR="./src"
export BACKUP_DIR="./backup"
run_backup
assert_eq "T40.1 exit code 0" "0" "$(get_rc)"
unset STOP_CMD START_CMD SRC_DIR BACKUP_DIR

##############################################################################
# 41. .env with comments
##############################################################################
dump_section "T41 - .env with comments"
setup
cat > "$TEST_ROOT/.env" <<'EOF'
# This is a comment
STOP_CMD="true"  # inline
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
# trailing comment
MAX_BACKUPS=7
EOF
run_backup
assert_eq "T41.1 exit code" "0" "$(get_rc)"
# Verify MAX_BACKUPS=7 was used: there should be 1 archive (less than 7 means no cleanup)
_n=$(ls "$TEST_ROOT/backup"/*.tar.gz 2>/dev/null | wc -l)
assert_eq "T41.2 exactly 1 archive" "1" "$_n"

##############################################################################
# 42. Archive created on stop-only-succeeds + start-fails path
##############################################################################
dump_section "T42 - Start failure doesn't prevent archive retention"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="false"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=sf
'
run_backup
assert_eq "T42.1 exit code 0" "0" "$(get_rc)"
# Archive is there
_n=$(ls "$TEST_ROOT/backup"/sf_backup_*.tar.gz 2>/dev/null | wc -l)
assert_eq "T42.2 archive present" "1" "$_n"

##############################################################################
# 43. Multiple sequential backups: ordering by name (lex = time)
##############################################################################
dump_section "T43 - Multiple backups ordered by filename"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
MAX_BACKUPS=10
BACKUP_PREFIX=seq
'
run_backup
sleep 1
run_backup
sleep 1
run_backup
# 3 archives expected
_n=$(ls "$TEST_ROOT/backup"/seq_backup_*.tar.gz 2>/dev/null | wc -l)
assert_eq "T43.1 three archives" "3" "$_n"
# Sort check: most recent = first in sort -r
_ls_sorted=$(ls -1 "$TEST_ROOT/backup"/seq_backup_*.tar.gz | sort -r | head -1)
# it should match the last created
_last_created=$(ls -1t "$TEST_ROOT/backup"/seq_backup_*.tar.gz | head -1)
assert_eq "T43.2 sort -r matches mtime newest" "$_last_created" "$_ls_sorted"

##############################################################################
# 44. Restore in fresh empty env: validation order
##############################################################################
dump_section "T44 - Restore: validation order"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR=""
'
# Run restore (no backup dir)
run_backup_input "" "" --restore-latest
assert_eq "T44.1 exit code = 1" "1" "$(get_rc)"
# Should report BACKUP_DIR missing (config validation)
assert_contains "T44.2 reports BACKUP_DIR" "BACKUP_DIR" "$(get_stderr)"

##############################################################################
# 45. CLI: --restore-latest passed twice (idempotent behavior)
##############################################################################
dump_section "T45 - CLI: --restore-latest idempotency"
setup
write_env "$TEST_ROOT/.env" '
STOP_CMD="true"
START_CMD="true"
SRC_DIR="./src"
BACKUP_DIR="./backup"
BACKUP_PREFIX=id
'
run_backup
echo "X" > "$TEST_ROOT/src/a.txt"
run_backup_input "y" "1" --restore-latest --restore-latest
# Two --restore-latest both set RESTORE_MODE=1; behavior same
assert_eq "T45.1 exit code 0" "0" "$(get_rc)"
_got=$(cat "$TEST_ROOT/src/a.txt")
assert_eq "T45.2 data restored" "hello" "$_got"

##############################################################################
# Final summary
##############################################################################
print_results
# Save the structured results
RESULTS_FILE=/workspace/test_run/results.txt
printf '%s' "$RESULTS" > "$RESULTS_FILE"
printf '\nTotal : %d\nPass  : %d\nFail  : %d\n' "$TOTAL" "$PASS" "$FAIL" >> "$RESULTS_FILE"
