#!/bin/sh
# Test harness for backup.sh
# Each test is a self-contained scenario. Each test prints PASS/FAIL with details.

# Run under bash to be safe; the script under test itself stays POSIX
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
# note: not using `set -u` or `set -e` so we can examine env vars and tolerate script failures

# Set up isolated workspace
TEST_ROOT=/workspace/test_run/fixtures
rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT"
cd "$TEST_ROOT"

SCRIPT=/workspace/backup.sh

# Color helpers (tolerate non-tty)
if [ -t 1 ]; then
    C_PASS="\033[32m"; C_FAIL="\033[31m"; C_INFO="\033[36m"; C_RST="\033[0m"
else
    C_PASS=""; C_FAIL=""; C_INFO=""; C_RST=""
fi

PASS=0; FAIL=0; TOTAL=0
RESULTS=""

# assert_eq <name> <expected> <actual>
assert_eq() {
    TOTAL=$((TOTAL+1))
    if [ "$2" = "$3" ]; then
        PASS=$((PASS+1))
        RESULTS="$RESULTS[PASS] $1
"
    else
        FAIL=$((FAIL+1))
        RESULTS="$RESULTS[FAIL] $1
  expected: $2
  actual  : $3
"
    fi
}

# assert_contains <name> <needle> <haystack>
assert_contains() {
    TOTAL=$((TOTAL+1))
    case "$3" in
        *"$2"*) PASS=$((PASS+1)); RESULTS="$RESULTS[PASS] $1
" ;;
        *)       FAIL=$((FAIL+1)); RESULTS="$RESULTS[FAIL] $1
  expected to contain: $2
  actual           : $3
" ;;
    esac
}

# assert_not_contains <name> <needle> <haystack>
assert_not_contains() {
    TOTAL=$((TOTAL+1))
    case "$3" in
        *"$2"*) FAIL=$((FAIL+1)); RESULTS="$RESULTS[FAIL] $1
  expected NOT to contain: $2
  actual              : $3
" ;;
        *)       PASS=$((PASS+1)); RESULTS="$RESULTS[PASS] $1
" ;;
    esac
}

# assert_dir_exists <name> <path>
assert_dir_exists() {
    TOTAL=$((TOTAL+1))
    if [ -d "$2" ]; then PASS=$((PASS+1)); RESULTS="$RESULTS[PASS] $1
"
    else FAIL=$((FAIL+1)); RESULTS="$RESULTS[FAIL] $1
  dir missing: $2
"; fi
}

# assert_file_exists <name> <path>
assert_file_exists() {
    TOTAL=$((TOTAL+1))
    if [ -f "$2" ]; then PASS=$((PASS+1)); RESULTS="$RESULTS[PASS] $1
"
    else FAIL=$((FAIL+1)); RESULTS="$RESULTS[FAIL] $1
  file missing: $2
"; fi
}

# assert_n_files <name> <expected_count> <glob>
assert_n_files() {
    _n=$(ls -1 $3 2>/dev/null | wc -l)
    assert_eq "$1" "$2" "$_n"
}

# Setup fresh fixture: copies script, clears .env, prepares src/backup/log dirs
setup() {
    rm -rf "$TEST_ROOT"/*
    mkdir -p "$TEST_ROOT" "$TEST_ROOT/src" "$TEST_ROOT/backup" "$TEST_ROOT/logs"
    cp "$SCRIPT" "$TEST_ROOT/backup.sh"
    # Create some data
    echo "hello" > "$TEST_ROOT/src/a.txt"
    echo "world" > "$TEST_ROOT/src/b.txt"
    mkdir -p "$TEST_ROOT/src/sub"
    echo "deep"  > "$TEST_ROOT/src/sub/c.txt"
}

# write_env <file> <content>
write_env() {
    cat > "$1" <<EOF
$2
EOF
}

# Run backup.sh with optional extra args; captures stdout, stderr, exit code
run_backup() {
    _stdout=""
    _stderr=""
    _rc=0
    _stdout=$("$TEST_ROOT/backup.sh" "$@" 2>/tmp/_stderr.$$)
    _rc=$?
    _stderr=$(cat /tmp/_stderr.$$)
    rm -f /tmp/_stderr.$$
}

# get stdout (after a run_backup call)
get_stdout() { printf '%s' "$_stdout"; }
get_stderr() { printf '%s' "$_stderr"; }
get_rc()     { printf '%s' "$_rc"; }

# Run with stdin input (for interactive restore)
# Args: $1=confirm line, $2=option line, ${@:3}=script args
run_backup_input() {
    _confirm="$1"; _option="$2"; shift 2
    _stdin=$(printf '%s\n%s\n' "$_confirm" "$_option")
    _stdout=$(printf '%s' "$_stdin" | "$TEST_ROOT/backup.sh" "$@" 2>/tmp/_stderr.$$)
    _rc=$?
    _stderr=$(cat /tmp/_stderr.$$)
    rm -f /tmp/_stderr.$$
    unset _stdin _confirm _option
}

dump_section() {
    printf '\n%s== %s ==%s\n' "$C_INFO" "$1" "$C_RST"
}

print_results() {
    printf '%s' "$RESULTS"
    printf '\n%s=== Summary ===%s\n' "$C_INFO" "$C_RST"
    printf 'Total : %d\nPass  : %d\nFail  : %d\n' "$TOTAL" "$PASS" "$FAIL"
}

export PASS FAIL TOTAL RESULTS TEST_ROOT SCRIPT
export -f assert_eq assert_contains assert_not_contains
export -f assert_dir_exists assert_file_exists assert_n_files
export -f setup write_env run_backup run_backup_input get_stdout get_stderr get_rc dump_section
