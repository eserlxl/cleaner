# Config field governance

Rules for evolving the pipe-delimited config contract:
`RISK_LEVEL|NAME|PATH_EXPRESSION|DESCRIPTION|MIN_AGE_DAYS|CHECK_PROCESSES|CUSTOM_ACTION`

## Field evolution rules

1. **Optional trailing additions (MINOR)** — New optional fields may only be appended after existing fields. Old parsers ignore unknown trailing columns until upgraded.

2. **Required field count or semantics change (MAJOR)** — Changing which fields are required, reordering fields, or altering the meaning of an existing required field is a breaking change.

3. **Tightening validation (MINOR)** — Rejecting values previously accepted (e.g. non-numeric `MIN_AGE_DAYS`, empty `NAME`) is a safety-guard tightening and warrants a **minor** bump per CHANGELOG policy.

4. **Line-numbered error format (preserved)** — All validation errors must keep the form `Error: <config-file>:<lineno>: ...`. Changing this format is **MAJOR**.

5. **Shipped `cleaner.conf` updates** — Update the shipped default config only when adding new **shipped** targets or documenting new optional fields for end users. Experimental fields stay in contributor docs only.

## Parser touch points

- Field count validation: `cleaner.sh` config parser
- Value validation: risk level, numeric age, non-empty name/path
- Tests: `Malformed Too Few Fields`, `Malformed Too Many Fields`, `Positive Control Valid Config`, `Shipped Config Self-Validates`

## SemVer classification

Use [contract-semver-taxonomy.md](contract-semver-taxonomy.md) before merging.

## CUSTOM_ACTION: actions and filters

The seventh field holds one enumerated token, and there are two kinds:

- `action:*` — runs a predefined command *instead of* deleting the path. Irreversible;
  bypasses quarantine.
- `filter:*` — constrains which expanded wildcard matches become targets. It only ever
  narrows the match set, so it can never introduce a target the pattern alone would
  not have produced, and it never replaces deletion.

A target carries one or the other, never both. Both are validated against the same
enumeration, so an unknown token of either kind is rejected with the same
line-numbered error.

`filter:cxx_build` keeps a match only when it holds a build-system marker
(`CMakeCache.txt`, `CMakeFiles`, `build.ninja`, `meson-info`, `compile_commands.json`,
`.qmake.stash`) directly or one level below — the one-level allowance covers a qmake
per-kit layout such as `build/Desktop-Debug`. Selecting by contents is what separates
real build output from a source directory whose name merely begins with "build".
