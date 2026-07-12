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
2. **Bump the version constant** in `cleaner.sh`:
   ```sh
   sed -i 's/^readonly VERSION=.*/readonly VERSION="X.Y.Z"/' cleaner.sh
   ```
   Confirm `./cleaner.sh --version` prints the new version.
3. **Roll the changelog**: move the `[Unreleased]` entries under a new
   `## [X.Y.Z] - <YYYY-MM-DD>` heading in `CHANGELOG.md`, and update the
   compare/tag links at the bottom.
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

- `shellcheck cleaner.sh test_cleaner.sh install.sh` is clean;
- `bash test_cleaner.sh` (or `make check`) passes;
- the version-consistency check passes (the CHANGELOG top version equals
  `cleaner.sh --version`).

## Yanking or patching a bad release

If a released version is broken, do **not** delete the tag. Cut a new patch release
(`X.Y.Z+1`) with the fix, note the regression in the changelog, and add a prominent
warning to the bad GitHub Release's notes (or mark it a pre-release).

## Packaging (AUR)

The repository ships an Arch `PKGBUILD` and `.SRCINFO` whose `package()` delegates to
`make install DESTDIR="$pkgdir" PREFIX=/usr`. To build and publish a package for a release:

1. Bump `pkgver` in `PKGBUILD` to the release version and reset `pkgrel=1`.
2. Replace the placeholder checksum with the real one against the release tarball:
   ```sh
   updpkgsums                       # rewrites the SKIP sha256 for the v<pkgver> tarball
   ```
3. Build and lint locally:
   ```sh
   makepkg -f                       # builds the package
   namcap PKGBUILD                  # lint the PKGBUILD
   namcap *.pkg.tar.zst             # lint the built package
   ```
4. Regenerate and commit the metadata alongside the PKGBUILD:
   ```sh
   makepkg --printsrcinfo > .SRCINFO
   ```
5. **Submit to the AUR** — a deliberate, human-gated maintainer action: push the
   updated `PKGBUILD` and `.SRCINFO` to the package's AUR git remote. This is never
   automated.
