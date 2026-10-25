# Config field governance

Rules for evolving the pipe-delimited config contract:
`RISK_LEVEL|NAME|PATH_EXPRESSION|DESCRIPTION|MIN_AGE_DAYS|CHECK_PROCESSES|CUSTOM_ACTION`

## Field evolution rules

1. **Optional trailing additions (MINOR)** — New optional fields may only be appended after existing fields, and the new parser must still accept existing configs. Current parsers reject more than seven fields; configs using a new column require a parser version that supports it. Older parsers do not ignore unknown trailing columns.

2. **Required field count or semantics change (MAJOR)** — Changing which fields are required, reordering fields, or altering the meaning of an existing required field is a breaking change.

3. **Tightening validation (MINOR)** — Rejecting values previously accepted (e.g. non-numeric `MIN_AGE_DAYS`, empty `NAME`) is a safety-guard tightening and warrants a **minor** bump per CHANGELOG policy.

4. **Line-numbered error format (preserved)** — Config validation errors include the file and line. Field-count and field-value errors use `Error: <config-file>:<lineno>: ...`; unknown-action and unknown-risk errors use `<config-file>:<lineno>: Error: ...`. Preserve these existing layouts; changing them is **MAJOR**.

5. **Shipped `cleaner.conf` updates** — Update the shipped default config only when adding new **shipped** targets or documenting new optional fields for end users. Experimental fields stay in contributor docs only.

## Parser touch points

- Field count validation: `cleaner.sh` config parser
- Value validation: risk level, numeric age, non-empty name/path
- Tests: `Malformed Too Few Fields`, `Malformed Too Many Fields`, `Positive Control Valid Config`, `Shipped Config Self-Validates`

## SemVer classification

Use [contract-semver-taxonomy.md](contract-semver-taxonomy.md) before merging.

## CUSTOM_ACTION: actions, filters, and exclusions

The seventh field holds one token, and there are three kinds:

- `action:*` — runs a predefined command *instead of* deleting the path. Irreversible;
  bypasses quarantine.
- `filter:*` — constrains which literal paths or expanded wildcard matches become targets. It only ever
  narrows the match set, so it can never introduce a target the pattern alone would
  not have produced, and it never replaces deletion.
- `exclude:NAME[,NAME...]` — adds exclusions for this target only; it never
  replaces deletion or runs a command.

A target carries exactly one of these tokens; exclusions cannot be combined with
an action or filter. Actions and filters are validated against their enumeration;
exclusion lists reject empty/blank elements, pipes, and newlines. Invalid tokens
are rejected with a line-numbered error, including by `--check-config`.

`filter:cxx_build` keeps a match only when it holds a build-system marker
(`CMakeCache.txt`, `CMakeFiles`, `build.ninja`, `meson-info`, `compile_commands.json`,
`.qmake.stash`) directly or one level below — the one-level allowance covers a qmake
per-kit layout such as `build/Desktop-Debug`. Selecting by contents is what separates
real build output from a source directory whose name merely begins with "build".
Surrounding field whitespace is trimmed before applying the filter, for both
wildcard and literal paths. When paired with a positive `MIN_AGE_DAYS`, the age is an
idle threshold for the whole directory rather than a per-file filter: if anything under
the directory (other than files a global exclusion matches) was modified within `MIN_AGE_DAYS` days, the target is reported clean
(`active within N days`) and untouched; otherwise the entire build tree is sized and
removed as a whole, or file by file when a global exclusion applies (`(idle > N days)` in the plan report), while JSON dry-run preserves
the configured `min_age_days`.

`exclude:notes` protects matching `notes` directories and everything beneath
them, including old files. Other old session logs remain eligible. Row patterns merge with the global
`--exclude` / `LINUX_CLEANER_EXCLUDE` patterns using the same `find` glob/path
builder, and never carry over to the next target. Size reporting, age checks,
deletion, quarantine, and empty-directory cleanup all use the merged set.
An exclusion forces file-by-file cleanup even at age `0`, preserving the target
directory. Wildcard expansion passes the token through unchanged and keeps normal
ancestor pruning; `filter:cxx_build` and `**` patterns disable that pruning, but a match
nested inside an already accepted match is still not emitted again.

## CHECK_PROCESSES: name tokens and cmdline tokens

A bare token matches the kernel `comm` field exactly (`pgrep -x`). The kernel keeps only
the first 15 characters of that name, so a plain name longer than 15 characters is
compared on its first 15. That works only when the tool runs under its own name. It does not for a tool launched through a shared
runtime: `/usr/bin/cursor` execs `/usr/lib/electron42/electron`, and `cursor-agent` runs
`exec -a "$0" node index.js` — measured to leave `comm` as `node-MainThread`, which
matches neither `cursor-agent` nor `node`. An exact-name guard there fails **silently**,
which is the dangerous direction: the target is cleaned while the tool is writing to it.

A token written `cmdline:<pattern>` matches the full command line instead. Because that
is far broader, three exclusions keep it from matching the cleaner itself — which would
otherwise block every target forever while nothing is running:

- the run's **whole process ancestry**, not just its own PID: an invoking shell, wrapper
  script or scheduler carries the cleaner's arguments in its own command line;
- its **descendants**, since a subshell or helper inherits the arguments;
- any **already-exited PID**, which cannot be an application still running.

Prefer an installation path (`cmdline:/usr/share/cursor`) over a bare word: a path cannot
collide with an unrelated process the way a common word can. An empty pattern after the
prefix would match every process and is rejected at config-validation time.

## `protect|PATH` directive lines

Alongside 5–7 field target rows, the config accepts a two-field directive:
`protect|PATH` (first field literally `protect`, case-sensitive).

- **Validation**: Must have exactly 2 fields. `PATH` expands `$HOME`, `$USER`, leading `~`, `$XDG_CACHE_HOME`, `$XDG_CONFIG_HOME`, `$XDG_DATA_HOME`, and `$XDG_STATE_HOME` (`expand_path_safe`, falling back to XDG spec defaults when unset or relative); an empty `PATH`, a non-absolute `PATH` after expansion, a `PATH` containing glob characters (`*`, `?`, `[`), or extra fields is rejected by `validate_config_file` with `Error: <config-file>:<lineno>: ...`. `PATH` need not exist on disk.
- **Non-target semantics**: `protect` lines are skipped by `expand_config_globs` and every target-row consumer (`--list-targets`, `--list-targets --json`, and the cleanup loop), and are not counted in `--check-config`'s `OK: N targets` total.
- **Protection rules**: Before target analysis, each `protect|PATH` is canonicalized (`canonicalize_physical` after `strip_trailing_slashes`). Any target whose canonical path equals a protected path, lies under one, or contains one (whole path components only) gets `target_status=protected`, reason `"protected by config"`, and is never sized or cleaned.

