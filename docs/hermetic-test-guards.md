# Hermetic test guards

Drift guards run after mock `$HOME` setup with stubbed `sudo`, `pgrep`, `paccache`, `pacman`, `apt-get`, `dnf`, and `zypper` binaries. Guards must not require root or network.

Execution order: mock env setup → individual test cases → drift guards near suite end.

See `docs/test-coverage-matrix.md` for the guard catalog.
