# Makefile for the Linux Cache and Temp File Cleaner.
# Install paths derive from PREFIX and honor DESTDIR (see README "Installation").

PREFIX     ?= /usr/local
DESTDIR    ?=
BINDIR     ?= $(PREFIX)/bin
SYSCONFDIR ?= /etc
MANDIR     ?= $(PREFIX)/share/man
DATADIR    ?= $(PREFIX)/share

# Installed command name (the source script is cleaner.sh) and package namespace.
BINNAME    ?= cleaner.sh
PKGNAME    ?= linux-cleaner

.PHONY: all help install uninstall install-man check clean

all: help

help:
	@echo "Targets: install, uninstall, install-man, check, clean"
	@echo "Vars: PREFIX (=$(PREFIX)) DESTDIR BINDIR SYSCONFDIR (=$(SYSCONFDIR)) MANDIR DATADIR"

install:
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
	@echo "install-man: no man page yet (added in a later step)."

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/$(BINNAME)"
	rm -f "$(DESTDIR)$(DATADIR)/licenses/$(PKGNAME)/LICENSE"
	-rmdir "$(DESTDIR)$(DATADIR)/licenses/$(PKGNAME)" 2>/dev/null
	@echo "Note: the system config $(DESTDIR)$(SYSCONFDIR)/$(PKGNAME)/cleaner.conf is preserved (it may hold user edits)."

check:
	bash test_cleaner.sh

clean:
	@echo "Nothing to clean."
