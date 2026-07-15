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
make check                            # full safety suite (same as bash test_cleaner.sh)
```

The suite is hermetic: it builds a mock `$HOME` and stubs `sudo`, `pgrep`,
`paccache`, and `pacman`, so it needs no root, network, or Arch tooling.

## Safety invariants (do not break)

A change to `cleaner.sh` must preserve all of these:

1. **Every deletion routes through `check_path_safety`.** No path is removed,
   trashed, or acted on without first being classified by that function (defined
   in `cleaner.sh`). Do not add a deletion path that bypasses it.
2. **No `eval`, no wildcard evaluation.** Path expansion resolves only the
   explicit `$HOME`, `~`, and `$USER` placeholders. Never introduce `eval` or
   unquoted glob expansion of config-supplied strings.
3. **Privileged actions only via the whitelisted registry.** Predefined
   `action:*` commands run from a fixed, enumerated whitelist — never a
   config-supplied command string. Extend the whitelist by adding a new
   enumerated arm; never open a general command channel.
4. **Dry-run stays the default.** The tool must never delete unless the user
   explicitly passes `--clean` (or `--trash`); `danger` targets require
   confirmation even under `--force`.

## Design constraints

- **Single file.** The tool is one self-contained `cleaner.sh`. Keep it that
  way — no splitting into sourced libraries.
- **Config contract.** Targets are pipe-delimited lines:
  `RISK_LEVEL|NAME|PATH_EXPRESSION|DESCRIPTION|MIN_AGE_DAYS|CHECK_PROCESSES|CUSTOM_ACTION`.
  The first five fields are required; the last two are optional.

## Adding tests

New behavior needs a test. Follow the existing `run_test_case` pattern in
`test_cleaner.sh`: write a target into a config heredoc, run the tool against a
mock `$HOME`, and assert on the exit code and the captured log. Never target a
real absolute system path from a test.

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
