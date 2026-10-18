#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# POSIX-sh installer for the Linux Cache and Temp File Cleaner.
# Mirrors the Makefile install/uninstall; honors PREFIX and DESTDIR.
set -eu

PREFIX="${PREFIX:-/usr/local}"
DESTDIR="${DESTDIR:-}"
BINDIR="${BINDIR:-$PREFIX/bin}"
SYSCONFDIR="${SYSCONFDIR:-/etc}"
MANDIR="${MANDIR:-$PREFIX/share/man}"
DATADIR="${DATADIR:-$PREFIX/share}"
SYSTEMDUSERUNITDIR="${SYSTEMDUSERUNITDIR:-$PREFIX/lib/systemd/user}"
BINNAME="${BINNAME:-cleaner}"
PKGNAME="${PKGNAME:-linux-cleaner}"
UNITS="linux-cleaner-clean.service linux-cleaner-clean.timer linux-cleaner-retention.service linux-cleaner-retention.timer linux-cleaner-monitor.service linux-cleaner-monitor.timer"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "Usage: $0 [install|uninstall]"
  echo "Vars: PREFIX (=$PREFIX) DESTDIR BINDIR SYSCONFDIR MANDIR DATADIR SYSTEMDUSERUNITDIR"
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
  install -d "$DESTDIR$DATADIR/$PKGNAME"
  install -m 0644 "$SRC_DIR/examples/linux-cleaner.env.example" "$DESTDIR$DATADIR/$PKGNAME/linux-cleaner.env.example"
  install -d "$DESTDIR$SYSTEMDUSERUNITDIR"
  for unit in $UNITS; do
    install -m 0644 "$SRC_DIR/examples/systemd/$unit" "$DESTDIR$SYSTEMDUSERUNITDIR/$unit"
  done
  install -d "$DESTDIR$DATADIR/bash-completion/completions"
  install -m 0644 "$SRC_DIR/completions/cleaner.bash" "$DESTDIR$DATADIR/bash-completion/completions/$BINNAME"
  install -d "$DESTDIR$DATADIR/zsh/site-functions"
  install -m 0644 "$SRC_DIR/completions/_cleaner" "$DESTDIR$DATADIR/zsh/site-functions/_$BINNAME"
  echo "Installed $BINNAME to $DESTDIR$BINDIR"
}

do_uninstall() {
  rm -f "$DESTDIR$BINDIR/$BINNAME"
  rm -f "$DESTDIR$MANDIR/man1/$BINNAME.1"
  rm -f "$DESTDIR$DATADIR/licenses/$PKGNAME/LICENSE"
  rmdir "$DESTDIR$DATADIR/licenses/$PKGNAME" 2>/dev/null || true
  rm -f "$DESTDIR$DATADIR/$PKGNAME/linux-cleaner.env.example"
  rmdir "$DESTDIR$DATADIR/$PKGNAME" 2>/dev/null || true
  rm -f "$DESTDIR$DATADIR/bash-completion/completions/$BINNAME"
  rmdir "$DESTDIR$DATADIR/bash-completion/completions" 2>/dev/null || true
  rmdir "$DESTDIR$DATADIR/bash-completion" 2>/dev/null || true
  rm -f "$DESTDIR$DATADIR/zsh/site-functions/_$BINNAME"
  rmdir "$DESTDIR$DATADIR/zsh/site-functions" 2>/dev/null || true
  rmdir "$DESTDIR$DATADIR/zsh" 2>/dev/null || true
  for unit in $UNITS; do
    rm -f "$DESTDIR$SYSTEMDUSERUNITDIR/$unit"
  done
  rmdir "$DESTDIR$SYSTEMDUSERUNITDIR" 2>/dev/null || true
  echo "Uninstalled $BINNAME (system config preserved)"
}

case "${1:-install}" in
  install) do_install ;;
  uninstall) do_uninstall ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
