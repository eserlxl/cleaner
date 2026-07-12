#!/bin/sh
# POSIX-sh installer for the Linux Cache and Temp File Cleaner.
# Mirrors the Makefile install/uninstall; honors PREFIX and DESTDIR.
set -eu

PREFIX="${PREFIX:-/usr/local}"
DESTDIR="${DESTDIR:-}"
BINDIR="${BINDIR:-$PREFIX/bin}"
SYSCONFDIR="${SYSCONFDIR:-/etc}"
MANDIR="${MANDIR:-$PREFIX/share/man}"
DATADIR="${DATADIR:-$PREFIX/share}"
BINNAME="${BINNAME:-cleaner}"
PKGNAME="${PKGNAME:-linux-cleaner}"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "Usage: $0 [install|uninstall]"
  echo "Vars: PREFIX (=$PREFIX) DESTDIR BINDIR SYSCONFDIR DATADIR"
}

do_install() {
  install -d "$DESTDIR$BINDIR"
  install -m 0755 "$SRC_DIR/cleaner.sh" "$DESTDIR$BINDIR/$BINNAME"
  install -d "$DESTDIR$SYSCONFDIR/$PKGNAME"
  if [ -f "$DESTDIR$SYSCONFDIR/$PKGNAME/cleaner.conf" ]; then
    echo "Existing config found; installing cleaner.conf.example instead."
    install -m 0644 "$SRC_DIR/cleaner.conf" "$DESTDIR$SYSCONFDIR/$PKGNAME/cleaner.conf.example"
  else
    install -m 0644 "$SRC_DIR/cleaner.conf" "$DESTDIR$SYSCONFDIR/$PKGNAME/cleaner.conf"
  fi
  install -d "$DESTDIR$MANDIR/man1"
  install -m 0644 "$SRC_DIR/cleaner.1" "$DESTDIR$MANDIR/man1/$BINNAME.1"
  install -d "$DESTDIR$DATADIR/licenses/$PKGNAME"
  install -m 0644 "$SRC_DIR/LICENSE" "$DESTDIR$DATADIR/licenses/$PKGNAME/LICENSE"
  echo "Installed $BINNAME to $DESTDIR$BINDIR"
}

do_uninstall() {
  rm -f "$DESTDIR$BINDIR/$BINNAME"
  rm -f "$DESTDIR$MANDIR/man1/$BINNAME.1"
  rm -f "$DESTDIR$DATADIR/licenses/$PKGNAME/LICENSE"
  rmdir "$DESTDIR$DATADIR/licenses/$PKGNAME" 2>/dev/null || true
  echo "Uninstalled $BINNAME (system config preserved)"
}

case "${1:-install}" in
  install) do_install ;;
  uninstall) do_uninstall ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
