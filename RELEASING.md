# Releasing

This project ships as a single script; releases are cut from `main` as annotated
`v*` git tags. Follow this runbook for every release.

## Prerequisites

- The working tree is clean and on `main`.
- You have push access to the repository.

## Release steps

1. **Pick the version** `X.Y.Z` per the [bump policy](CHANGELOG.md#versioning)
   (major = config/CLI break, minor = feature / safety-guard / new action,
   patch = fix / docs).
2. **Bump the version everywhere it is carried** — `cleaner.sh` and `cleaner.1`.
   The pre-release gate (below) checks both against the changelog,
   so a partial bump fails it:
   ```sh
   sed -i 's/^readonly VERSION=.*/readonly VERSION="X.Y.Z"/' cleaner.sh
   sed -i '1s/"linux-cleaner [^"]*"/"linux-cleaner X.Y.Z"/' cleaner.1
   ```
   Confirm `./cleaner.sh --version` prints the new version. The AUR `pkgver` is not
   edited here: `aurgen aur` takes it from the `vX.Y.Z` tag after the release is cut.
3. **Roll the changelog**: `./release-notes.sh roll X.Y.Z` moves the `[Unreleased]`
   entries under a new `## [X.Y.Z] - <YYYY-MM-DD>` heading (today's date, or pass it as a
   third argument) and rewrites the compare/tag links at the bottom. It refuses an
   existing section, an empty `[Unreleased]`, or a missing `[Unreleased]` compare link,
   leaving `CHANGELOG.md` untouched.
4. **Run the pre-release gate** (below) — it must be green.
5. **Commit** the version bump and changelog roll.
6. **Tag** an annotated release and push it:
   ```sh
   git tag -a vX.Y.Z -m "Release vX.Y.Z"
   git push origin main --follow-tags
   ```
7. **Publish the GitHub Release** for the `vX.Y.Z` tag with the changelog section
   as the release notes and the source tarball attached. The release workflow can
   do this automatically on the tag push; live publication stays human-gated.

## Pre-release gate

A release must never be cut on a failing safety suite. Before tagging, confirm all of:

- `make lint` is clean;
- `bash test_cleaner.sh` (or `make check`) passes;
- `bash scripts/validate-runbook-examples.sh` (`make check-runbook-examples`, which `make pre-release` runs first) passes;
- the version-consistency check passes (the CHANGELOG top version equals
  `cleaner.sh --version` and `cleaner.1`'s `.TH` version matches);
- the **stranded-entries guard** passes: once HEAD is tagged, `bash test_cleaner.sh`
  fails if `## [Unreleased]` still holds entries. The release workflow builds its notes
  by extracting only the tagged version's changelog section, so anything left under
  `[Unreleased]` would be **silently dropped from the published notes** — and a pushed
  tag is never deleted (see below). Roll the entries into the version's section first
  (step 3). The guard's assertion is exercised against fixtures on every test run, so it
  cannot rot while the repository sits untagged.

## Yanking or patching a bad release

If a released version is broken, do **not** delete the tag. Cut a new patch release
(`X.Y.Z+1`) with the fix, note the regression in the changelog, and add a prominent
warning to the bad GitHub Release's notes (or mark it a pre-release).

## Packaging (AUR)

[AURGen](https://github.com/eserlxl/aurgen) generates the Arch packaging files. The only
tracked packaging file is `aur/aurgen.install.yaml` (`aur/.gitignore` keeps generated
output out of git). Edit that file: `package.install_messages` (`post_install` /
`pre_remove`) is the pacman install scriptlet text, printed verbatim. `aurgen aur`
writes the release `PKGBUILD` (`pkgver` comes from the `v<version>` git tag), `.SRCINFO`
and the install scriptlet; `aurgen git` writes the `-git` package. The generated
`package()` runs `make install DESTDIR="$pkgdir" PREFIX=/usr`; `check()` runs
`make check-package` (`package.check` in the YAML), a seconds-long smoke test that needs no
git, network or home directory, so it passes inside an AUR helper's clone. `make check`
stays the full developer suite. Test with `aurgen local`
(build and install a local package) or `aurgen test` (dry-run every mode).
`aurgen --dry-run <mode>` writes only under `aur/dry-run/`.

The steps below need the pushed tag, so they run only after the release is cut.

### Release workflow permissions (fail-closed)

The tag-push workflow (`.github/workflows/release.yml`) uses the minimum GitHub token scope
needed to create a **draft** release:

| Setting | Value | Rationale |
|---------|-------|-----------|
| `permissions.contents` | `write` | Required for `gh release create` on the tag |
| `id-token` | absent | Not needed; no OIDC publishing |
| Empty-notes fallback | **none** | `release-notes.sh extract` must succeed or the job fails |

There is no fallback path that publishes empty release notes if changelog extraction fails.
See `docs/release-workflow-audit.md` for the step-by-step cross-walk.

### Ordered AUR packaging checklist

1. Edit `aur/aurgen.install.yaml` when package metadata or install messages change.
2. Confirm the `vX.Y.Z` tag exists on the remote (`git ls-remote --tags origin`).
3. `aurgen aur` — generate the release `PKGBUILD`, `.SRCINFO` and install scriptlet (`pkgver` from the tag).
4. `aurgen local` or `aurgen test` — install a local test package, or dry-run every mode.
5. `aurgen aur-deploy` — copy `PKGBUILD`, `.SRCINFO` and the install scriptlet into the AUR clone and push.

- Documentation review: walk `docs/DOC_REVIEW_CHECKLIST.md` before tagging.

## Post-tag local verification

After the tag is pushed:

```sh
git fetch --tags
git checkout vX.Y.Z
make check    # exercises Version/Tag/Changelog Consistency on real tagged HEAD
```

## Remote sync and external gates

Push `main` only after a green local `make pre-release`; the local suite is the gate, not a hosted CI status check.

Maintainer checklist (GitHub):

- [ ] Draft release workflow tested on a prior tag (see [Release workflow permissions](#release-workflow-permissions-fail-closed); do not duplicate full release validation here).
