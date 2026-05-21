# Linux Cache and Temp File Cleaner

A safe, configuration-driven Bash utility designed to estimate and reclaim disk space by cleaning up unnecessary temporary files, caches, and logs on a Linux system.

## Features

- **Safety Guards**: Prevents deleting critical root directories or system folders (e.g., `/`, `/usr`, `/var`, etc.) and warns when targeting paths outside your home directory.
- **Dry-run Mode**: Preview potential disk space savings without making any modifications.
- **Interactive Summaries**: Shows a preview of what will be deleted and prompts for confirmation by default before executing the cleanup.
- **Configurable**: Define custom cleanup targets easily inside a simple configuration file.
- **Visual Output**: Color-coded CLI terminal outputs detailing found, cleaned, and skipped targets.

---

## Configuration

By default, the script reads target definitions from `./cleaner.conf`. You can define custom targets by adding entries to the `TARGETS` array in the following format:

```bash
TARGETS=(
  "NAME;PATH_EXPRESSION;DESCRIPTION"
)
```

- **`NAME`**: A human-readable identifier for the target (e.g., `"NPM Cache"`).
- **`PATH_EXPRESSION`**: The absolute or relative path to clean. You can use standard shell variables like `$HOME` or `~` and `$USER`, which will expand safely at runtime.
- **`DESCRIPTION`**: A brief explanation of the files being cleaned.

### Example `cleaner.conf`
```bash
TARGETS=(
  "NPM Cache;$HOME/.npm/_cacache;NPM dependency cache files"
  "Gemini Temp;$HOME/.gemini/tmp;Gemini temporary/scratch files"
  "Aurman Cache;$HOME/.cache/aurman;Aurman package manager cache"
  "Yarn Cache;$HOME/.cache/yarn;Yarn package manager cache files"
)
```

---

## Usage

Run the script directly from the project directory:

```bash
./cleaner.sh [OPTIONS]
```

### Options

- **`-c, --config FILE`**: Use a custom configuration file instead of the default `./cleaner.conf`.
- **`-d, --dry-run`**: Print the list of targets, their current sizes, and estimate the total potential space reclaimed without deleting any files.
- **`-i, --interactive`**: Prompt for confirmation before deleting each target individually.
- **`-f, --force`**: Perform the cleanup immediately without prompting for confirmation.
- **`-h, --help`**: Display usage details.

---

## Safety Features

1. **Root Block**: Paths that resolve to root (`/`), system directories (`/etc`, `/boot`, `/usr`, `/sys`, etc.), or `/home` itself will be flagged as `UNSAFE` and skipped automatically.
2. **HOME Boundary**: If a configured target resolves to a path outside the current user's `$HOME` directory, it prints a warning. In default summary mode, it prompts for extra confirmation before deleting it.
3. **No Wildcard Eval**: Path expansion only resolves explicit placeholders (`$HOME`, `~`, and `$USER`) to avoid unintended wildcard expansion accidents.
