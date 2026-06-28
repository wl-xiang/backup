#!/bin/sh
# ============================================================================
# Code coverage analyzer for backup.sh
# Strategy: at the start of every test invocation, replace $TEST_ROOT/backup.sh
# with a traced copy (shebang changed to bash, set -x + PS4 added, original
# shebang dropped).  Each test thus runs a self-traced copy whose SCRIPT_DIR
# matches $TEST_ROOT (so its .env loads correctly).
# ============================================================================
set -e

SCRIPT=/workspace/backup.sh
TESTS=/workspace/test_run/test_cases.sh
HARNESS=/workspace/test_run/test_harness.sh
TRACE_DIR=/workspace/test_run/trace
RESULTS=/workspace/test_run/coverage.txt
SCRIPT_LINES=/workspace/test_run/script_total_lines.txt
HARNESS_INST=/workspace/test_run/harness_inst.sh

rm -rf "$TRACE_DIR"
mkdir -p "$TRACE_DIR"

# Build the traced template (a copy of backup.sh with bash + set -x prepended).
TRACED_TEMPLATE="$TRACE_DIR/backup_traced.sh"
{
    echo '#!/bin/bash'
    echo "PS4='+TRACE+\${LINENO}+'"
    echo 'set -x'
    tail -n +2 "$SCRIPT"
} > "$TRACED_TEMPLATE"
chmod +x "$TRACED_TEMPLATE"

# Build a per-test installer.  When sourced by the test harness (via .env
# mechanism won't work; use a different hook), it will rewrite $TEST_ROOT/backup.sh
# to the traced copy.
# We'll inject a setup hook at the top of a custom test harness.

cp "$HARNESS" "$HARNESS_INST"
# Prepend a setup override to the harness so the `setup` function installs the
# traced script in $TEST_ROOT before any test runs.
cat > "$HARNESS_INST.tmp" <<'EOF'
# Coverage harness: install the traced script in $TEST_ROOT on every setup.
TRACED_SRC=/workspace/test_run/trace/backup_traced.sh
# Wrap setup so it copies the traced script
_orig_setup=$(declare -f setup | sed -n '/^setup()/,/^}/p')
EOF

# Simpler approach: just sed the `setup` function body in the harness to copy
# TRACED_SRC instead of SCRIPT.
# Look for: cp "$SCRIPT" "$TEST_ROOT/backup.sh"
# Replace with: cp "$TRACED_SRC" "$TEST_ROOT/backup.sh"
cp "$HARNESS" "$HARNESS_INST"
# Inject variables
sed -i '1i TRACED_SRC=/workspace/test_run/trace/backup_traced.sh' "$HARNESS_INST"
# Replace the cp line.  The original line ends in "$TEST_ROOT/backup.sh" with
# no following space and args.  Use a regex that matches exactly that, with
# no other characters.  We need to avoid the sed later turning
# "$TEST_ROOT/backup.sh" into "bash $TEST_ROOT/backup.sh" inside the setup.
sed -i 's|cp "$SCRIPT" "$TEST_ROOT/backup.sh"|cp "$TRACED_SRC" "$TEST_ROOT/backup.sh"|' "$HARNESS_INST"

# Now also: the T02 inline call `"$TEST_ROOT/backup.sh" >/dev/null 2>&1` should
# be wrapped to also redirect trace.  Simpler: set BASH_XTRACEFD for the test
# runner.  But the inline call uses /dev/null.  Instead, modify the harness's
# run_backup function to also append the trace to the trace.log.
# Easiest: just append a sed to the test_cases.sh that wraps any
# "$TEST_ROOT/backup.sh" call to write a marker to trace.log first.
# Even simpler: change the harness's run_backup to set BASH_XTRACEFD before
# running the script.  bash will inherit BASH_XTRACEFD from the parent.

# Add to the harness: in run_backup and run_backup_input, set BASH_XTRACEFD=7
# and use bash explicitly.  But the script's shebang is #!/bin/bash in the
# traced version, so we can just exec it.

# For the inline call in T02, we'll do a small patch: replace it with a helper.
cp "$TESTS" "$TRACE_DIR/cases_collect.sh"
# Make the cases source the coverage harness instead of the regular harness
sed -i 's|. /workspace/test_run/test_harness.sh|. /workspace/test_run/harness_inst.sh|' "$TRACE_DIR/cases_collect.sh"
sed -i 's|"$TEST_ROOT/backup.sh"|"bash" "$TEST_ROOT/backup.sh"|g' "$TRACE_DIR/cases_collect.sh"

# Patch run_backup_input too - but only the function calls, not the setup()
# line that copies the script.
# Use a marker comment to identify function-call sites.
sed -i '/^run_backup() {/a\    export BASH_XTRACEFD=7' "$HARNESS_INST"
sed -i 's|"$TEST_ROOT/backup.sh" "$@" 2>/tmp/|"bash" "$TEST_ROOT/backup.sh" "$@" 2>/tmp/|g' "$HARNESS_INST"
# Now patch the run_backup_input's pipe form (uses a different temp file suffix)
sed -i 's|"$TEST_ROOT/backup.sh" 2>/tmp/_stderr|"bash" "$TEST_ROOT/backup.sh" 2>/tmp/_stderr|g' "$HARNESS_INST"

# Clean up tmp
rm -f "$HARNESS_INST.tmp"

# Count executable lines
TOTAL=0; EXECUTABLE=0; SKIPPED=0
while IFS= read -r line; do
    TOTAL=$((TOTAL+1))
    trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
    if [ -z "$trimmed" ] || [ "${trimmed#\#}" != "$trimmed" ]; then
        SKIPPED=$((SKIPPED+1))
    else
        EXECUTABLE=$((EXECUTABLE+1))
    fi
done < "$SCRIPT"

# Build the test driver that sources our coverage harness and runs cases
DRIVER="$TRACE_DIR/driver.sh"
cat > "$DRIVER" <<EOF
#!/bin/bash
exec 7>>/workspace/test_run/trace/trace.log
export BASH_XTRACEFD=7
. $HARNESS_INST
. $TRACE_DIR/cases_collect.sh
EOF
chmod +x "$DRIVER"

# Run
TRACE_LOG="$TRACE_DIR/trace.log"
set +e
: > "$TRACE_LOG"
( cd /workspace/test_run && bash "$DRIVER" >/dev/null 2>&1 ) || true

# Stats
TRACE_LINES=$(wc -l < "$TRACE_LOG")
echo "Trace log size: $TRACE_LINES lines"

echo "---trace log first 5 lines---"
head -5 "$TRACE_LOG" 2>/dev/null
echo "---trace log last 5 lines---"
tail -5 "$TRACE_LOG" 2>/dev/null
echo "---trace line count---"
wc -l "$TRACE_LOG" 2>/dev/null

# Compute coverage
HIT_FILE="$TRACE_DIR/lines_hit.txt"
NOT_HIT_FILE="$TRACE_DIR/lines_not_hit.txt"
NOT_HIT_BRANCHES="$TRACE_DIR/branches_not_hit.txt"

# Extract unique line numbers from trace
grep -oE '\+TRACE\+[0-9]+' "$TRACE_LOG" | sed 's/+TRACE+//' | sort -un > "$HIT_FILE"
LINES_HIT=$(wc -l < "$HIT_FILE")
echo "Unique lines hit: $LINES_HIT" > "$RESULTS"

# Generate the list of not-hit executable lines
: > "$NOT_HIT_FILE"
: > "$NOT_HIT_BRANCHES"
lineno=0
while IFS= read -r line; do
    lineno=$((lineno+1))
    trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
    # Skip shebang
    if [ "$lineno" -eq 1 ]; then continue; fi
    # Skip blank and comment lines
    if [ -z "$trimmed" ] || [ "${trimmed#\#}" != "$trimmed" ]; then
        continue
    fi
    if ! grep -qx "$lineno" "$HIT_FILE" 2>/dev/null; then
        # Classify
        case "$trimmed" in
            *'if '*|*'elif '*|*'else'*|*'fi'*) echo "L${lineno} (branch): $trimmed" >> "$NOT_HIT_BRANCHES" ;;
            *) echo "L${lineno}: $trimmed" >> "$NOT_HIT_FILE" ;;
        esac
    fi
done < "$SCRIPT"

NOT_HIT=$(wc -l < "$NOT_HIT_FILE")
BRANCH_NOT_HIT=$(wc -l < "$NOT_HIT_BRANCHES")
HIT_PCT=$(awk "BEGIN { printf \"%.1f\", ($LINES_HIT * 100.0) / $EXECUTABLE }")
echo "Executable lines : $EXECUTABLE" >> "$RESULTS"
echo "Lines hit        : $LINES_HIT" >> "$RESULTS"
echo "Lines not hit    : $NOT_HIT" >> "$RESULTS"
echo "Branch lines not hit: $BRANCH_NOT_HIT" >> "$RESULTS"
echo "Coverage (exec)  : ${HIT_PCT}%" >> "$RESULTS"
cat "$RESULTS"
echo "---"
echo "=== Executable lines NOT hit ($NOT_HIT) ==="
cat "$NOT_HIT_FILE"
echo "=== Branch lines NOT hit ($BRANCH_NOT_HIT) ==="
cat "$NOT_HIT_BRANCHES"

