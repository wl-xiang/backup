# backup

> **English** / [简体中文](README_zh.md)

Linux server generic backup & restore script. POSIX compliant, runs under both `sh` and `bash`, and adapts to new and old Linux distributions. Configurable via `.env` file or environment variables — no script edits needed to adapt to different services.

## Features

- **POSIX compliant**: standard syntax and basic commands only; no bash-only features. Works under `sh` / `bash`.
- **Config / logic separation**: all variable parameters injected via `.env` / env vars; the script body is reusable as-is.
- **Pre-validation**: required vars, paths, and dependencies are validated up front; the script fails fast before touching anything.
- **Failure fallback**: `trap` catches every exit path; if a service stop was attempted, a start is forced on exit so the service is never left stopped.
- **Rolling retention**: keeps the newest N backups and logs; older ones are pruned automatically.
- **Restore support**: `--restore-latest` restores the newest backup, with an optional pre-restore safety snapshot.
- **Minimal output**: only key milestones are printed; errors carry a return code.

## Project structure

```
.
├── backup.sh        # core backup / restore script (POSIX)
├── .env.example     # configuration template (copy to .env and edit)
├── .gitignore       # ignores .env and logs/
└── README.md
```

After a run, the script produces archives and logs at the configured locations:

```
{BACKUP_DIR}/{PREFIX}_backup_{YYYYMMDD_HHMMSS}.tar.gz   # backup archive
{LOG_DIR}/{PREFIX}_backup_{YYYYMMDD_HHMMSS}.log         # backup run log
{LOG_DIR}/{PREFIX}_restore.log                        # restore run log (overwritten each run)
```

## Quick start

1. Copy the config template and fill in the required values:

   ```sh
   cp .env.example .env
   vi .env
   ```

2. Edit `.env` and fill in at least the 4 required variables (stop command, source dir, backup dir, start command):

   ```sh
   STOP_CMD="systemctl stop myapp"
   START_CMD="systemctl start myapp"
   SRC_DIR="/opt/myapp/data"
   BACKUP_DIR="/var/backups/myapp"
   ```

3. Make the script executable and run a backup:

   ```sh
   chmod +x backup.sh
   ./backup.sh
   ```

4. (Optional) Schedule a daily backup, e.g. at 02:30:

   ```sh
   crontab -e
   # add:
   30 2 * * * /path/to/backup.sh
   ```

## Usage

```
./backup.sh                                  # run a backup
./backup.sh --restore-latest                 # restore the latest backup
./backup.sh --restore-latest --target-dir /new/path
                                             # restore to a different directory
```

| Option | Description |
| --- | --- |
| `--restore-latest` | Restore the newest backup archive to `SRC_DIR` (interactive). |
| `--target-dir <dir>` | Override `SRC_DIR` for this run (highest priority). Usable with backup or restore. |

## Configuration

All variables follow the priority: **system environment > `.env` file > built-in defaults**. Existing system env vars are never overwritten by `.env`, so you can override any value at runtime.

| Variable | Required | Default | Description |
| --- | :---: | --- | --- |
| `STOP_CMD` | yes | — | Command to stop the service before backup |
| `START_CMD` | yes | — | Command to start the service after backup |
| `SRC_DIR` | yes | — | Source data directory to back up (relative or absolute) |
| `BACKUP_DIR` | yes | — | Directory for backup archives (auto-created if missing) |
| `MAX_BACKUPS` | no | `30` | Max archives and logs to keep, shared (positive integer) |
| `BACKUP_PREFIX` | no | `app` | Filename prefix for archives and logs |
| `LOG_DIR` | no | `./logs/` | Directory for log files (auto-created if missing) |

## Backup workflow

The script runs in strict order: **validate → stop → backup → start → cleanup**. Any failed step takes its dedicated fallback branch.

1. **Pre-validation**: load config → check required vars → validate `MAX_BACKUPS` is a positive integer → verify source dir exists → auto-create backup/log dirs → generate the run timestamp.
2. **Stop service**: run `STOP_CMD` and check the return code. On failure: attempt to start the service, then exit with an error — no backup is taken.
3. **Backup data**: `tar -zcf` archives the source directory (by its basename, so the archive is portable). On failure: delete the partial archive, start the service, exit with an error — no cleanup runs.
4. **Start service**: run `START_CMD`. On failure: emit a warning only; the backup is already saved and the script ends normally.
5. **Rolling cleanup**: runs only after a successful backup; prunes archives and logs to the newest `MAX_BACKUPS` each.

## Restore workflow (`--restore-latest`)

Restores the newest backup archive from `BACKUP_DIR` into `SRC_DIR` (backup dir → source dir). The flow is interactive; the service is NOT touched (restore only handles data, per design).

1. **Confirm restore**: prints the latest archive path and the restore target, then asks for confirmation. Enter `y` or `yes` to proceed; anything else cancels.
2. **Choose how to handle existing data**:
   - `1` — Overwrite the existing data folder directly.
   - `2` — Back up the current data folder first as `{PREFIX}_backup_before_restore.tar.gz`, then overwrite. This safety snapshot uses a fixed filename (overwritten each restore) and does **not** count against `MAX_BACKUPS`.
   - `3` — Cancel.
   - Any value other than `1` or `2` is treated as `3` (cancel).
3. **Execute**: extracts the archive to a temp dir and moves the data into `SRC_DIR`.

Restore reads `SRC_DIR` and `BACKUP_DIR` from the config by default. To restore to a different location:

```sh
# via CLI flag (highest priority)
./backup.sh --restore-latest --target-dir /opt/myapp/data_restored

# via system env var
SRC_DIR=/opt/myapp/data_restored ./backup.sh --restore-latest
```

## Exception handling & fallback

`trap ... EXIT` catches normal exits, errors, and interrupt signals (`INT` / `HUP` / `TERM`). Whenever a service stop was actually attempted (`STOP_CMD` ran), the script forces one attempt at `START_CMD` on exit — preventing the service from being left stopped. In restore mode no stop is attempted, so the trap is a no-op.

Graded failure strategy (backup mode):

| Scenario | Behavior |
| --- | --- |
| Stop fails | No backup; attempt start; exit with error |
| Archive fails | Delete partial archive; start service; exit with error; no cleanup |
| Start fails | Warning only; backup is saved; script ends normally |
| Cleanup fails | Does not affect the main flow; warning logged |

## Rolling cleanup

- **Matching**: archives match `{PREFIX}_backup_*.tar.gz`; logs match `{PREFIX}_backup_*.log`. Files containing `before_restore` are excluded so the restore safety snapshot is never pruned or counted.
- **Ordering**: sorted by filename descending (the timestamp in the name makes lexical order equal to time order), independent of file mtime.
- **Timing**: runs only after a successful backup, so a failed backup never deletes prior usable backups.

## Logging

- Each run's log filename corresponds one-to-one with its archive (backup) or run (restore), sharing the same timestamp.
- All output is written to both the terminal and the log file; key milestones (stop, backup done, start, cleanup done) are also printed to the terminal.
- Errors carry an `[ERROR]` tag and the return code.
- Backup logs and archives share the `MAX_BACKUPS` retention; the cleanup logic is identical for both.

## Examples

**Override parameters at runtime** (without editing `.env`):

```sh
MAX_BACKUPS=10 BACKUP_PREFIX=db ./backup.sh
```

**View the latest log**:

```sh
ls -t logs/*.log | head -1 | xargs less
```

**Restore the latest backup interactively**:

```sh
./backup.sh --restore-latest
```

## Compatibility

- Syntax: POSIX only (`[ ]` tests, `.` sourcing, no arrays / associative arrays / bash string slicing).
- Commands: `date +%Y%m%d_%H%M%S`, `tar -zcf`/`-zxf` with `-C`, `ls` + `sort`, all standard parameters — no GNU-only extensions.
- Verified with `sh` and `bash` syntax checks, plus scenario tests covering success, missing config, stop failure, archive failure, retention, env override, signal-interrupt fallback, defaults, validation errors, missing source dir, and the full restore flow (overwrite, pre-restore backup, cancel, target-dir override, env override, no-archive, non-1/2 default).

## FAQ

- **"missing required config"**: a required variable in `.env` is empty — fill it in as the message indicates.
- **"source directory does not exist"**: `SRC_DIR` does not exist or is not a directory.
- **"MAX_BACKUPS must be a positive integer"**: `MAX_BACKUPS` must be an integer ≥ 1.
- **"backup directory does not exist"** (restore): `BACKUP_DIR` must already contain archives for restore.
- **Backup/log directory missing**: the script auto-creates them recursively — no manual setup needed.
- **First run**: archives and logs are created normally; cleanup is skipped when there is no history.
- **Start warning but backup succeeded**: check that `START_CMD` is correct; the archive is already valid.
- **Restore cancelled**: re-run and answer `y`/`yes` at the confirm prompt and `1` or `2` at the action prompt.
