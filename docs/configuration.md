# Configuration

The `cleaner.conf` format: which targets ship by default, the row fields, predefined actions, wildcard paths, `protect` lines, and validation.

## Shipped targets

See [`cleaner.conf`](../cleaner.conf) for the authoritative list of targets, age thresholds, and exclusions, or run `cleaner --list-targets` to inspect the active inventory. The shipped configuration covers:

- **Developer & language caches (`safe`, `medium` for Cargo)**: npm, Yarn, Bun (files older than 30 days), pnpm (`pnpm store prune`), pip, uv (`uv cache prune`), Hugging Face hub (`hf cache prune --yes`), Aurman, Go build cache, clangd, TypeScript, Prettier, VSCode C++ extension cache, and Cargo registry cache.
- **GPU & desktop caches (`safe`, `medium` for Trash)**: NVIDIA compute cache, Mesa shader cache, legacy and modern desktop thumbnails, and desktop Trash (>30 days).
- **Web browser caches (`medium`)**: Chromium, Firefox, and Google Chrome caches under `$HOME/.cache`.
- **AI assistant & editor caches, logs, and transcripts (`safe` for caches/logs, `medium` for transcripts/media/VM image)**: Gemini Temp, Cursor, Antigravity, Claude Desktop, Codex CLI/Desktop, Grok CLI, and Hermes caches/logs/sessions, plus per-project AI debug/log directories under `/opt` (`.gemini/model_debug_logs`, `.codex/logs`, `.remember/logs`). Durable configuration, rules, memory stores, SQLite state databases, and `$HOME/.claude/projects` are deliberately excluded.
- **Idle C/C++ build directories (`safe`)**: `/opt/**/build*` and `/opt/**/cmake-build*` verified by `filter:cxx_build` and idle for more than 14 days.
- **System package-manager caches (`medium`)**: `/var/cache/pacman/pkg` (`action:paccache_keep1`), plus optional commented rows for `pacman_clean`, `apt_clean`, `dnf_clean`, `zypper_clean`, and `apk_clean`. Because an action whose package manager is not installed is skipped cleanly without failing the run, the same `cleaner.conf` is portable across distributions.

## Row format

Each active target row in `cleaner.conf` has **5 to 7 pipe-delimited fields** (`RISK_LEVEL`, `NAME`, `PATH_EXPRESSION`, `DESCRIPTION`, and `MIN_AGE_DAYS` are required; `CHECK_PROCESSES` and `CUSTOM_ACTION` are optional):

```text
RISK_LEVEL|NAME|PATH_EXPRESSION|DESCRIPTION|MIN_AGE_DAYS|CHECK_PROCESSES|CUSTOM_ACTION
```

- **`RISK_LEVEL`**: `safe`, `medium`, or `danger`.
- **`NAME`**: Non-empty human-readable target name (e.g. `NPM Cache`).
- **`PATH_EXPRESSION`**: Non-empty path to clean. Supports `$HOME`, leading `~`, `$USER`, `$XDG_CACHE_HOME` (default `$HOME/.cache`), `$XDG_CONFIG_HOME` (default `$HOME/.config`), `$XDG_DATA_HOME` (default `$HOME/.local/share`), and `$XDG_STATE_HOME` (default `$HOME/.local/state`) whole-token expansion (unset or relative XDG values fall back to the spec default), plus `*`, `?`, and `**` directory wildcards.
- **`DESCRIPTION`**: Brief explanation of what the target cleans.
- **`MIN_AGE_DAYS`**: Numeric minimum age in days (`find -mtime +N`), or `0`/empty to clean the target regardless of age. When paired with `filter:cxx_build`, `MIN_AGE_DAYS > 0` is an idle threshold for the directory as a whole.
- **`CHECK_PROCESSES`**: (Optional) Comma-separated process names (`pgrep -x`, comparing the first 15 characters for longer plain names) or `cmdline:<pattern>` tokens matching the full command line. Use `cmdline:<install-path>` (e.g. `cmdline:/usr/share/cursor`) for Electron or Node apps that do not run under their own binary name. The cleaner excludes its own process ancestry, descendants, and exited PIDs so its own invocation never self-blocks.
- **`CUSTOM_ACTION`**: (Optional) Holds at most **one** token — a predefined action, a build filter, or a per-row exclusion list (they cannot be combined):
  - `action:paccache_keep1` (`sudo paccache -rk1`), `action:paccache_keep2` (`sudo paccache -rk2`), `action:paccache_keep3` (`sudo paccache -rk3`)
  - `action:pacman_clean` (`sudo pacman -Sc --noconfirm`)
  - `action:apt_clean` (`sudo apt-get clean`)
  - `action:dnf_clean` (`sudo dnf clean all`)
  - `action:zypper_clean` (`sudo zypper clean -a`)
  - `action:apk_clean` (`sudo apk cache clean`)
  - `action:uv_cache_prune` (`uv cache prune`), `action:pnpm_store_prune` (`pnpm store prune`), `action:hf_cache_prune` (`hf cache prune --yes`)
  - `filter:cxx_build`: Keeps a literal path or wildcard match only if it contains a C/C++ build-system marker (`CMakeCache.txt`, `CMakeFiles`, `build.ninja`, `meson-info`, `compile_commands.json`, or `.qmake.stash`) directly or one level below.
  - `exclude:NAME[,NAME...]`: Adds comma-separated `find` glob/path exclusions for this row only (merging with `-e/--exclude` / `LINUX_CLEANER_EXCLUDE`). Preserves matching files and directories during dry-run sizing, deletion, quarantine, and empty-directory pruning, and processes files individually even when `MIN_AGE_DAYS` is `0`.

> [!WARNING]
> Predefined `action:*` commands bypass quarantine (`--trash`) and run directly, resulting in irreversible deletion. System package-cache actions run via `sudo`; user-level prune actions (`action:uv_cache_prune`, `action:pnpm_store_prune`, `action:hf_cache_prune`) run as the invoking user without `sudo` and measure their freed size on disk at run time. See [docs/action-registry-governance.md](action-registry-governance.md).

## Action cross-walk

| `action:*` | `cleaner.sh` command | `cleaner.conf` target | `cleaner.1` |
|------------|---------------------|------------------------|-------------|
| `action:paccache_keep1` | `sudo paccache -rk1` | `Pacman Cache (Keep 1)` | CONFIGURATION |
| `action:paccache_keep2` | `sudo paccache -rk2` | (supported) | CONFIGURATION |
| `action:paccache_keep3` | `sudo paccache -rk3` | header comment example | CONFIGURATION |
| `action:pacman_clean` | `sudo pacman -Sc --noconfirm` | `Pacman Cache (Purge All)` (commented) | CONFIGURATION |
| `action:apt_clean` | `sudo apt-get clean` | `APT Cache Clean` (commented) | CONFIGURATION |
| `action:dnf_clean` | `sudo dnf clean all` | `DNF Cache Clean` (commented) | CONFIGURATION |
| `action:zypper_clean` | `sudo zypper clean -a` | `Zypper Cache Clean` (commented) | CONFIGURATION |
| `action:apk_clean` | `sudo apk cache clean` | `APK Cache Clean` (commented) | CONFIGURATION |
| `action:uv_cache_prune` | `uv cache prune --cache-dir PATH` | `UV Cache` | CONFIGURATION |
| `action:pnpm_store_prune` | `pnpm store prune --store-dir PATH` | `PNPM Store` | CONFIGURATION |
| `action:hf_cache_prune` | `hf cache prune --yes --cache-dir PATH` | `Hugging Face Cache` | CONFIGURATION |

User-level prune actions (`action:uv_cache_prune`, `action:pnpm_store_prune`, `action:hf_cache_prune`) run as the invoking user without `sudo` against the target's configured PATH (`uv --cache-dir`, `pnpm --store-dir`, `hf --cache-dir`), and their freed size is measured on disk from the filesystem free-space change rather than directory `du`.

## Wildcard paths

A `PATH_EXPRESSION` containing `*` or `?` expands into **one independent target per matching directory**, each checked individually by the safety pipeline:

- **Fixed depth by default**: Matches must sit at the exact depth after the literal prefix (e.g. `$HOME/src/*/build*` matches `~/src/app/build` but not `~/src/a/b/build`).
- **`**` spans nesting levels**: A `**` component matches one or more directory levels, bounded at **10 levels** (`GLOB_RECURSION_MAX_DEPTH=10`) below the literal prefix.
- **Directories only**: Wildcard expansion matches directories (`-type d`), never individual files.
- **Safe path identity**: A wildcard in the first path component (`/*/build`) is refused with a warning; matches containing newlines, `|`, leading/trailing whitespace, or literal `$HOME`/`~`/`$USER`/`$XDG_CACHE_HOME`/`$XDG_CONFIG_HOME`/`$XDG_DATA_HOME`/`$XDG_STATE_HOME` tokens are skipped with a warning; a pattern with no matches is not an error.

> [!WARNING]
> One wildcard line can expand to many targets. Always preview with `cleaner --dry-run` and `cleaner --list-targets` before cleaning.

Inspect the same NAME selection used by a selective cleanup without sizing caches or
checking running processes. Inventory includes all risk levels; filters use
case-sensitive literal substrings, trim comma-separated entries, and apply exclusions
after inclusions. An unmatched inclusion or exclusions leaving no targets exits `1`.

```sh
cleaner --list-targets --only-target 'NPM,Yarn' --exclude-target Yarn
cleaner --list-targets --only-target 'NPM,Yarn' --exclude-target Yarn --json
```

For shared-NAME wildcard rows, select one existing project without editing the
configuration or excluding every sibling:

```sh
cleaner --list-targets --only-path /opt/my-project --only-target 'C++ Build'
cleaner --dry-run --only-path /opt/my-project --only-target 'C++ Build' --json
cleaner --clean --trash --only-path /opt/my-project --only-target 'C++ Build'
```

`--only-path` is CLI-only; its last occurrence wins. Supply one existing absolute
literal file or directory path, without line feeds. After NAME filtering, only
resolved ordinary targets equal to or below its physical path are selected on
whole components: ancestors, prefix siblings, and aliases resolving outside the
scope are excluded. Ordinary rows, `filter:cxx_build`, and `exclude:*` remain
eligible; every `action:*` row is excluded because its effects are not confined to
that path. Unresolved candidates and physical paths containing line feeds are
ineligible. Placeholder expansion preserves path bytes and rejects line feeds;
unsafe wildcard/filter rows are skipped with a warning, unsafe protection paths
abort, and an unsafe log path disables logging. Unscoped ordinary-target analysis
also aborts before cleanup if expansion fails. Unused environment values containing
line feeds do not invalidate an otherwise safe path. Inventory preserves configured paths and all risk levels; cleanup
still applies its risk, age, process, protection, and symlink guards. Existing
NAME-selection errors take precedence over no eligible PATH matches. Global
`--trash-keep-days` retention, including its environment mirror, cannot be combined
with a path scope.

## Protecting directories

To keep the cleaner out of a directory tree entirely, add a two-field `protect|PATH` line to `cleaner.conf`:

```text
protect|$HOME/Projects
protect|/opt/important
```

Any target whose canonical path equals `PATH`, lies inside `PATH`, or contains `PATH` (matched on whole path components, so `protect|/opt/a` does not match `/opt/ab`) is skipped as a whole. For example, `protect|/opt/work/app/build` prevents the `/opt/**/build*` row from cleaning that build directory while leaving sibling projects eligible.

- `PATH` supports `$HOME`, `$USER`, leading `~`, `$XDG_CACHE_HOME`, `$XDG_CONFIG_HOME`, `$XDG_DATA_HOME`, and `$XDG_STATE_HOME` (relative XDG values fall back to the spec default), must be absolute after expansion, cannot contain wildcards (`*`, `?`, `[`), and does not need to exist yet. Symlinks are resolved physically.
- Physical resolution rejects line feeds and failed existing-component resolution; a protection path that cannot be safely resolved aborts cleanup instead of weakening protection. Genuinely missing path tails remain supported.
- `protect` lines are not listed by `--list-targets` or counted as targets by `--check-config`.
- Skipped targets appear under `Protected (by config):` in the plan report, as `[PROTECTED]` under `--debug`, and with `"status": "protected"` in `--dry-run --json`.

## Validation (`--check-config`)

Validate a configuration file without scanning disk usage:

```sh
cleaner --check-config --config cleaner.conf
# -> OK: 45 targets in cleaner.conf
```

Malformed lines fail with a line-numbered error (`Error: <config-file>:<lineno>: ...` or `<config-file>:<lineno>: Error: ...`).

## Example `cleaner.conf`

```text
protect|$HOME/Projects
safe|NPM Cache|$HOME/.npm/_cacache|NPM dependency cache files|0|node,npm|
safe|C++ Build Dirs|/opt/**/build*|Per-project build output|14||filter:cxx_build
medium|App Sessions|$HOME/.local/share/example-app/sessions|Old session logs, keep notes|7||exclude:notes
medium|Chromium Cache|$HOME/.cache/chromium|Chromium browser cache files|3|chromium|
medium|Pacman Cache (Keep 1)|/var/cache/pacman/pkg|Retains latest version of package cache using paccache|0||action:paccache_keep1
danger|Chromium IndexedDB|$HOME/.config/chromium/Default/IndexedDB|Site-specific database storage|30|chromium|
```
