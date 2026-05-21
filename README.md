# Linux Cache and Temp File Cleaner

A safe, configuration-driven Bash utility designed to estimate and reclaim disk space by cleaning up unnecessary temporary files, caches, and logs on a Linux system.

## Features

- **Dry-run by Default**: By default, the script runs in dry-run mode, printing estimated space savings without deleting any files. Use `--clean` to execute.
- **Safety Guards**: Bypasses system folders (e.g. `/`, `/usr`, `/var`, `/etc`), rejects symlinked paths directly, and blocks paths outside the user's `$HOME` unless explicitly permitted.
- **Risk Levels**: Group targets as `safe`, `medium`, or `danger`. Filter execution via `-r, --risk <level>` (default is `safe`).
- **Confirmation Guards**: High-risk targets (`danger`) require manual confirmation even under `--force`, unless the bypass flag `--yes-danger` is provided.
- **Age Filter**: Targets can specify a minimum age in days (using `find -mtime`). Only files/symlinks older than the limit are cleaned.
- **Running-Process Checks**: Skip targets if their associated applications/processes are running (e.g., skip chromium cache if Chrome is open).
- **Trash Quarantine**: Move deleted files to a quarantine folder (`~/.cache/linux-cleaner/quarantine/`) with collision prevention and path sanitization instead of deleting permanently.

---

## Configuration

By default, the script reads target definitions from `./cleaner.conf`. The format is a plain text file where each line defines a target with fields separated by pipe `|` characters:

```text
RISK_LEVEL|NAME|PATH_EXPRESSION|DESCRIPTION|MIN_AGE_DAYS|CHECK_PROCESSES
```

- **`RISK_LEVEL`**: The category of danger if cleaned: `safe`, `medium`, or `danger`.
- **`NAME`**: A human-readable identifier for the target (e.g. `NPM Cache`).
- **`PATH_EXPRESSION`**: The absolute or relative path to clean. Supports safe placeholder expansion for `$HOME`, `~`, and `$USER`.
- **`DESCRIPTION`**: A brief explanation of the files being cleaned.
- **`MIN_AGE_DAYS`**: (Optional) Only delete files/symlinks older than N days. Set to `0` or leave empty to clean immediately.
- **`CHECK_PROCESSES`**: (Optional) Comma-separated process names. If any process in the list is running, the target is skipped.

### Example `cleaner.conf`
```text
safe|NPM Cache|$HOME/.npm/_cacache|NPM dependency cache files|0|node,npm
safe|Gemini Temp|$HOME/.gemini/tmp|Gemini temporary/scratch files|7|gemini
medium|Chromium Cache|$HOME/.cache/chromium|Chromium browser cache files|3|chromium
danger|Chromium IndexedDB|$HOME/.config/chromium/Default/IndexedDB|Site-specific database storage|30|chromium
```

---

## Usage

Run the script directly from the project directory:

```bash
./cleaner.sh [OPTIONS]
```

### Options

- **`--clean`**: Execute the cleanup. Without this flag, the script runs in dry-run mode.
- **`-c, --config FILE`**: Use a custom configuration file instead of `./cleaner.conf`.
- **`-d, --dry-run`**: Run in preview/dry-run mode (default).
- **`-i, --interactive`**: Prompt for confirmation before deleting each target individually.
- **`-f, --force`**: Skip all normal confirmation prompts (except danger level).
- **`--yes-danger`**: Bypass manual confirmation prompt for danger risk targets.
- **`-t, --trash`**: Move files to quarantine instead of permanent deletion.
- **`-r, --risk LEVEL`**: Max risk level to clean: `safe`, `medium`, or `danger` (default: `safe`).
- **`-e, --exclude PATTERNS`**: Comma-separated list of glob patterns to exclude from cleanup (e.g. `.git,*.log`).
  > [!WARNING]
  > Exclusion patterns are matched using standard `find` glob/path expressions. This is powerful but can be dangerous; incorrect patterns can accidentally exclude everything or deeply alter deletion/cleanup semantics. Always verify your exclusion patterns with `--dry-run` first.
- **`--restore SESSION`**: Restore files from a quarantine session (`latest` or a specific timestamp).
- **`--allow-outside-home`**: Explicitly allow cleaning targets outside the user's `$HOME` directory.
- **`-h, --help`**: Display usage details.

---

## Safety Features

1. **Root Block**: Paths that resolve to root (`/`), system directories (`/etc`, `/boot`, `/usr`, `/sys`, etc.), or `/home` itself will be flagged as `UNSAFE` and skipped automatically.
2. **HOME Boundary**: Targets outside the user's `$HOME` directory are blocked unless `--allow-outside-home` is active.
3. **Symlink Guard**: If a target path is a symlink, the script refuses to delete it to prevent deletion bugs.
4. **No Wildcard Eval**: Path expansion only resolves explicit placeholders (`$HOME`, `~`, and `$USER`) to avoid unintended wildcard expansion accidents.
