# Makefile for the Linux Cache and Temp File Cleaner.
# Install paths derive from PREFIX and honor DESTDIR (see docs/installation.md).

PREFIX             ?= /usr/local
DESTDIR            ?=
BINDIR             ?= $(PREFIX)/bin
SYSCONFDIR         ?= /etc
MANDIR             ?= $(PREFIX)/share/man
DATADIR            ?= $(PREFIX)/share
SYSTEMDUSERUNITDIR ?= $(PREFIX)/lib/systemd/user

# Installed command name (the source script is cleaner.sh) and package namespace.
BINNAME    ?= cleaner
PKGNAME    ?= linux-cleaner

# Every tracked shell file; make lint, the pre-release gate and CI read only this list.
SHELLCHECK_FILES = cleaner.sh test_cleaner.sh install.sh release-notes.sh \
	scripts/validate-runbook-examples.sh completions/cleaner.bash

.PHONY: all help install uninstall install-man check-binname check check-package lint clean pre-release check-runbook-examples

all: help

help:
	@echo "Targets: install, uninstall, install-man, check, check-package, lint, clean, pre-release, check-runbook-examples"
	@echo "Vars: PREFIX (=$(PREFIX)) DESTDIR BINDIR SYSCONFDIR (=$(SYSCONFDIR)) MANDIR DATADIR SYSTEMDUSERUNITDIR (=$(SYSTEMDUSERUNITDIR))"

# BINNAME becomes a file name and a completion registration: a plain basename only.
check-binname:
	@case "$(BINNAME)" in ''|.|..|-*|*[![:alnum:]._-]*) \
	  echo "Error: BINNAME '$(BINNAME)' must be a plain name of letters, digits, '.', '_' or '-'." >&2; exit 1 ;; esac

install: check-binname install-man
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
	install -d "$(DESTDIR)$(DATADIR)/$(PKGNAME)"
	install -m 0644 examples/linux-cleaner.env.example "$(DESTDIR)$(DATADIR)/$(PKGNAME)/linux-cleaner.env.example"
	install -d "$(DESTDIR)$(SYSTEMDUSERUNITDIR)"
	install -m 0644 examples/systemd/*.service examples/systemd/*.timer "$(DESTDIR)$(SYSTEMDUSERUNITDIR)/"
	install -d "$(DESTDIR)$(DATADIR)/bash-completion/completions"
	install -m 0644 completions/cleaner.bash "$(DESTDIR)$(DATADIR)/bash-completion/completions/$(BINNAME)"
	install -d "$(DESTDIR)$(DATADIR)/zsh/site-functions"
	install -m 0644 completions/_cleaner "$(DESTDIR)$(DATADIR)/zsh/site-functions/_$(BINNAME)"
	install -d "$(DESTDIR)$(DATADIR)/fish/vendor_completions.d"
	install -m 0644 completions/cleaner.fish "$(DESTDIR)$(DATADIR)/fish/vendor_completions.d/$(BINNAME).fish"
	@# The shipped completions register cleaner and cleaner.sh; a renamed command needs its own.
	@if [ "$(BINNAME)" != cleaner ]; then \
	  printf 'complete -F _cleaner %s\n' "$(BINNAME)" >> "$(DESTDIR)$(DATADIR)/bash-completion/completions/$(BINNAME)"; \
	  { printf '#compdef %s cleaner cleaner.sh\n' "$(BINNAME)"; tail -n +2 completions/_cleaner; } \
	    > "$(DESTDIR)$(DATADIR)/zsh/site-functions/_$(BINNAME)"; \
	  printf 'complete -c %s -w cleaner\n' "$(BINNAME)" >> "$(DESTDIR)$(DATADIR)/fish/vendor_completions.d/$(BINNAME).fish"; \
	  sed -i "s|^ExecStart=/usr/bin/env cleaner |ExecStart=/usr/bin/env $(BINNAME) |" "$(DESTDIR)$(SYSTEMDUSERUNITDIR)"/linux-cleaner-*.service; \
	fi

install-man: check-binname
	install -d "$(DESTDIR)$(MANDIR)/man1"
	install -m 0644 cleaner.1 "$(DESTDIR)$(MANDIR)/man1/$(BINNAME).1"

uninstall: check-binname
	rm -f "$(DESTDIR)$(BINDIR)/$(BINNAME)"
	rm -f "$(DESTDIR)$(MANDIR)/man1/$(BINNAME).1"
	rm -f "$(DESTDIR)$(SYSCONFDIR)/$(PKGNAME)/cleaner.conf.example"
	rm -f "$(DESTDIR)$(DATADIR)/licenses/$(PKGNAME)/LICENSE"
	-rmdir "$(DESTDIR)$(DATADIR)/licenses/$(PKGNAME)" 2>/dev/null
	rm -f "$(DESTDIR)$(DATADIR)/$(PKGNAME)/linux-cleaner.env.example"
	-rmdir "$(DESTDIR)$(DATADIR)/$(PKGNAME)" 2>/dev/null
	rm -f "$(DESTDIR)$(DATADIR)/bash-completion/completions/$(BINNAME)"
	-rmdir "$(DESTDIR)$(DATADIR)/bash-completion/completions" 2>/dev/null
	-rmdir "$(DESTDIR)$(DATADIR)/bash-completion" 2>/dev/null
	rm -f "$(DESTDIR)$(DATADIR)/zsh/site-functions/_$(BINNAME)"
	-rmdir "$(DESTDIR)$(DATADIR)/zsh/site-functions" 2>/dev/null
	-rmdir "$(DESTDIR)$(DATADIR)/zsh" 2>/dev/null
	rm -f "$(DESTDIR)$(DATADIR)/fish/vendor_completions.d/$(BINNAME).fish"
	-rmdir "$(DESTDIR)$(DATADIR)/fish/vendor_completions.d" 2>/dev/null
	-rmdir "$(DESTDIR)$(DATADIR)/fish" 2>/dev/null
	rm -f "$(DESTDIR)$(SYSTEMDUSERUNITDIR)"/linux-cleaner-clean.service \
		"$(DESTDIR)$(SYSTEMDUSERUNITDIR)"/linux-cleaner-clean.timer \
		"$(DESTDIR)$(SYSTEMDUSERUNITDIR)"/linux-cleaner-retention.service \
		"$(DESTDIR)$(SYSTEMDUSERUNITDIR)"/linux-cleaner-retention.timer \
		"$(DESTDIR)$(SYSTEMDUSERUNITDIR)"/linux-cleaner-monitor.service \
		"$(DESTDIR)$(SYSTEMDUSERUNITDIR)"/linux-cleaner-monitor.timer
	-rmdir "$(DESTDIR)$(SYSTEMDUSERUNITDIR)" 2>/dev/null
	@echo "Note: the system config $(DESTDIR)$(SYSCONFDIR)/$(PKGNAME)/cleaner.conf is preserved (it may hold user edits)."

check-runbook-examples:
	bash scripts/validate-runbook-examples.sh

check: check-runbook-examples
	bash test_cleaner.sh

# Package-time smoke test (the AUR check()): seconds, from an unpacked tarball, with
# no git, network, root, user environment or home writes. make check is the full suite.
check-package:
	bash -n cleaner.sh
	bash -n completions/cleaner.bash
	@tmp=$$(mktemp -d) && trap 'rm -r "$$tmp"' EXIT && \
	for args in --version --help '--check-config --config cleaner.conf'; do \
		env -i PATH="$$PATH" HOME="$$tmp" LC_ALL=C bash cleaner.sh $$args > /dev/null || exit 1; \
	done && echo "check-package: OK"

clean:
	@echo "Nothing to clean."

lint:
	shellcheck $(SHELLCHECK_FILES)

pre-release: check-runbook-examples lint
	bash test_cleaner.sh
