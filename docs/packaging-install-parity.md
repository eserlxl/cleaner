# Install path parity

| installation.md row | Makefile | install.sh | PKGBUILD package() |
|------------|----------|------------|---------------------|
| bin/cleaner | BINDIR | install | make install |
| man | MANDIR | install | make install |
| config | SYSCONFDIR | install | make install |
| license | DATADIR | install | make install |
| environment template (`$DATADIR/$PKGNAME/linux-cleaner.env.example`, mode 0644; user copies preserved on uninstall) | DATADIR, PKGNAME | install | make install |
| bash completion (`$DATADIR/bash-completion/completions/$BINNAME`, mode 0644) | DATADIR, BINNAME | install | make install |
| zsh completion (`$DATADIR/zsh/site-functions/_$BINNAME`, mode 0644) | DATADIR, BINNAME | install | make install |
| systemd user units (`linux-cleaner-clean`, `linux-cleaner-retention`, and `linux-cleaner-monitor` `.service` and `.timer` under `/usr/lib/systemd/user` when `PREFIX=/usr`, mode 0644, not enabled) | SYSTEMDUSERUNITDIR | install | make install |

Aligned on HEAD.
