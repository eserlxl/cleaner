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
2. **Bump the version everywhere it is carried** — `cleaner.sh`, `cleaner.1`, `PKGBUILD`, and
   `.SRCINFO`. The pre-release gate (below) checks all three against the changelog,
   so a partial bump fails it:
   ```sh
   sed -i 's/^readonly VERSION=.*/readonly VERSION="X.Y.Z"/' cleaner.sh
   sed -i '1s/"linux-cleaner [^"]*"/"linux-cleaner X.Y.Z"/' cleaner.1
   sed -i -e 's/^pkgver=.*/pkgver=X.Y.Z/' -e 's/^pkgrel=.*/pkgrel=1/' PKGBUILD
   makepkg --printsrcinfo > .SRCINFO   # rewrites .SRCINFO's pkgver and source line
   ```
   Confirm `./cleaner.sh --version` prints the new version. (The tarball checksum
   cannot be computed yet — it needs the pushed tag, so it stays in *Packaging (AUR)*.)
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

- `shellcheck cleaner.sh test_cleaner.sh install.sh release-notes.sh` is clean;
- `bash test_cleaner.sh` (or `make check`) passes;
- `bash scripts/validate-runbook-examples.sh` (`make check-runbook-examples`, which `make pre-release` runs first) passes;
- the version-consistency check passes (the CHANGELOG top version equals
  `cleaner.sh --version`, `cleaner.1`'s `.TH` version matches, and `PKGBUILD`/`.SRCINFO`
  carry the same `pkgver`);
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

The repository ships an Arch `PKGBUILD` and `.SRCINFO` whose `package()` delegates to
`make install DESTDIR="$pkgdir" PREFIX=/usr`. To build and publish a package for a release:

`pkgver` was already bumped by release step 2; everything below needs the pushed tag,
so it runs only after the release is cut. The `source` URL in `PKGBUILD` points at
`$url/archive/refs/tags/v$pkgver.tar.gz` — **`updpkgsums` cannot succeed until that tag
exists on the remote.** Never publish with `sha256sums=('SKIP')`.

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

1. Confirm the `vX.Y.Z` tag exists on the remote (`git ls-remote --tags origin`).
2. Run `updpkgsums` — rewrites the previous release's sha256 for the new release tarball.
3. `AUR_PREP=1 make check-aur-ready` — verify `sha256sums` is one 64-hex digest, e.g. `sha256sums=("<64-hex>")` — **never publish with SKIP**.
4. `makepkg -f` — build the package locally.
5. `namcap PKGBUILD` — lint the recipe.
6. `namcap *.pkg.tar.zst` — lint the built package.
7. `makepkg --printsrcinfo > .SRCINFO` — regenerate metadata.
8. Commit `PKGBUILD` and `.SRCINFO`.
9. Human AUR push (never automated): copy `PKGBUILD`, `.SRCINFO` and `linux-cleaner.install` (the `install=` scriptlet) into the AUR repo.

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
