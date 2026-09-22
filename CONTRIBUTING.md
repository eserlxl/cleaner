# Contributing

Thanks for helping improve the Linux Cache and Temp File Cleaner. This is a
**safety-critical, data-deleting tool**, so contributions are held to a strict
bar: preserve the safety invariants below, keep the design small, and never let
a change ship without both gates green.

## Development gates

Every change must pass both gate commands before it is merged (they also run in
CI on push and pull request):

```bash
shellcheck cleaner.sh test_cleaner.sh install.sh release-notes.sh   # lint — must be clean
make check                            # runbook example validation + full safety suite
```

The suite is hermetic: it builds a mock `$HOME` and stubs `sudo`, `pgrep`,
`paccache`, and `pacman`, so it needs no root, network, or Arch tooling.

## Safety invariants (do not break)

A change to `cleaner.sh` must preserve all of these:

1. **Every deletion routes through `check_path_safety`.** No path is removed,
   trashed, or acted on without first being classified by that function (defined
   in `cleaner.sh`). Do not add a deletion path that bypasses it.
2. **No `eval` or shell glob expansion.** Placeholder expansion resolves only
   `$HOME`, `~`, and `$USER`; bounded wildcard discovery uses `find`. Never
   introduce `eval` or unquoted glob expansion of config-supplied strings.
3. **Privileged actions only via the whitelisted registry.** Predefined
   `action:*` commands run from a fixed, enumerated whitelist — never a
   config-supplied command string. Extend the whitelist by adding a new
   enumerated arm; never open a general command channel.
4. **Dry-run stays the cleanup default.** Cleanup executes only when enabled by
   `--clean`, `--force`, `--interactive`, or a truthy `LINUX_CLEANER_FORCE`;
   the last CLI execution/preview flag wins. `--trash` only selects quarantine.
   `danger` targets still require confirmation unless `--yes-danger` is set.
   Restore and purge are separate explicit operations and reject active
   explicit `--dry-run`.


Threat model: [docs/threat-model.md](docs/threat-model.md) (maps invariants to scenarios).

## Design constraints

- **Single file.** The tool is one self-contained `cleaner.sh`. Keep it that
  way — no splitting into sourced libraries.

## Config contract

Field-change checklist (see [config-field-governance.md](docs/config-field-governance.md)):

1. Update parser and line-numbered errors in `cleaner.sh`.
2. Add malformed and positive `run_test_case` entries in `test_cleaner.sh`.
3. Update README field table and shipped `cleaner.conf` if user-facing.
4. Classify SemVer bump via [contract-semver-taxonomy.md](docs/contract-semver-taxonomy.md).
5. Roll CHANGELOG `[Unreleased]` under the correct heading.

- **Config contract.** Targets are pipe-delimited lines:
  `RISK_LEVEL|NAME|PATH_EXPRESSION|DESCRIPTION|MIN_AGE_DAYS|CHECK_PROCESSES|CUSTOM_ACTION`.
  The first five fields are required; the last two are optional.


## Worked example: add a safe cache target and test

1. Choose a mock path under `$HOME/.cache/my-tool` in the test config.
2. Write the config line: `safe|My Tool Cache|$HOME/.cache/my-tool|desc|0||`
3. Extend `setup_mock_env` (or local test setup) with a dummy file in that path.
4. Add `run_test_case "My Tool Cache Dry Run" 0 "mytool.log" --config ... --dry-run` expecting exit 0 and a log substring.
5. Optional: add a `--force` clean case once dry-run passes.
6. Run `make check`.

## Adding tests

New behavior needs a test. Follow the existing `run_test_case` pattern in
`test_cleaner.sh`: write a target into a config heredoc, run the tool against a
mock `$HOME`, and assert on the exit code and the captured log. Never target a
real absolute system path from a test.


## Contract evolution

Unified checklist — branch to the doc that matches the change:

- [ ] **(A) Config field change** → [config-field-governance.md](docs/config-field-governance.md)
- [ ] **(B) New `action:*`** → [action-registry-governance.md](docs/action-registry-governance.md)
- [ ] **(C) CLI / env / JSON** → [cli-env-json-governance.md](docs/cli-env-json-governance.md)
- [ ] **(D) Classify SemVer** → [contract-semver-taxonomy.md](docs/contract-semver-taxonomy.md)
- [ ] **(E) CHANGELOG** → `[Unreleased]` entry under correct heading
- [ ] **(F) Gates** → `make check` + ShellCheck green
- [ ] **(G) Safety invariants** → unchanged (see above)

## License

By contributing you agree that your contributions are licensed under the
project's **GNU General Public License v3.0 or later** (`GPL-3.0-or-later`); see
[LICENSE](LICENSE).

User-facing doc changes should follow `docs/DOC_REVIEW_CHECKLIST.md`.

Check `docs/test-coverage-matrix.md` before adding duplicate coverage.

Non-hermetic validation: `docs/manual-smoke-checklist.md`.

### Test governance

1. New behavior requires a named `run_test_case`.
2. Do not re-test drift guards.
3. Titles must match log output.
4. Use mock `$HOME` paths only.
5. Update coverage matrix for new `[Unreleased]` bullets.

### Reviewer checklist

- ShellCheck clean
- `make check` green
- Named test for new behavior
- Matrix row added
- No real system paths
- Danger tests use mock configs
- Irreversible actions keep WARNING assertions

## Test documentation map

- `docs/test-coverage-matrix.md`
- `docs/manual-smoke-checklist.md`

Hermetic suite is the merge gate; manual smoke is release/ops optional.
