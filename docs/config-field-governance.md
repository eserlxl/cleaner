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
