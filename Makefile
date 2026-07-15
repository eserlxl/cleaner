# Makefile for the Linux Cache and Temp File Cleaner.
# Install paths derive from PREFIX and honor DESTDIR (see README "Installation").

PREFIX     ?= /usr/local
DESTDIR    ?=
BINDIR     ?= $(PREFIX)/bin
SYSCONFDIR ?= /etc
MANDIR     ?= $(PREFIX)/share/man
DATADIR    ?= $(PREFIX)/share

# Installed command name (the source script is cleaner.sh) and package namespace.
BINNAME    ?= cleaner
PKGNAME    ?= linux-cleaner

.PHONY: all help install uninstall install-man check clean pre-release check-aur-ready check-runbook-examples

all: help

help:
	@echo "Targets: install, uninstall, install-man, check, clean"
	@echo "Vars: PREFIX (=$(PREFIX)) DESTDIR BINDIR SYSCONFDIR (=$(SYSCONFDIR)) MANDIR DATADIR"

install: install-man
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 0755 cleaner.sh "$(DESTDIR)$(BINDIR)/$(BINNAME)"
	install -d "$(DESTDIR)$(SYSCONFDIR)/$(PKGNAME)"
	@if [ -f "$(DESTDIR)$(SYSCONFDIR)/$(PKGNAME)/cleaner.conf" ]; then \
		echo "Existing config found; installing cleaner.conf.example instead."; \
		install -m 0644 cleaner.conf "$(DESTDIR)$(SYSCONFDIR)/$(PKGNAME)/cleaner.conf.example"; \
	else \
		install -m 0644 cleaner.conf "$(DESTDIR)$(SYSCONFDIR)/$(PKGNAME)/cleaner.conf"; \
	fi
	install -d "$(DESTDIR)$(DATADIR)/licenses/$(PKGNAME)"
	install -m 0644 LICENSE "$(DESTDIR)$(DATADIR)/licenses/$(PKGNAME)/LICENSE"

install-man:
	install -d "$(DESTDIR)$(MANDIR)/man1"
	install -m 0644 cleaner.1 "$(DESTDIR)$(MANDIR)/man1/$(BINNAME).1"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/$(BINNAME)"
	rm -f "$(DESTDIR)$(MANDIR)/man1/$(BINNAME).1"
	rm -f "$(DESTDIR)$(DATADIR)/licenses/$(PKGNAME)/LICENSE"
	-rmdir "$(DESTDIR)$(DATADIR)/licenses/$(PKGNAME)" 2>/dev/null
	@echo "Note: the system config $(DESTDIR)$(SYSCONFDIR)/$(PKGNAME)/cleaner.conf is preserved (it may hold user edits)."

check-runbook-examples:
	bash scripts/validate-runbook-examples.sh

check: check-runbook-examples
	bash test_cleaner.sh

clean:
	@echo "Nothing to clean."

pre-release:
	shellcheck cleaner.sh test_cleaner.sh install.sh release-notes.sh
	bash test_cleaner.sh

check-aur-ready:
	@test "$${AUR_PREP:-0}" != 1 || grep -vq "SKIP" PKGBUILD
