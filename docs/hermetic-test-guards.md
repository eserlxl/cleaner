# Hermetic test guards

Drift guards run after mock `$HOME` setup with stubbed `sudo`, `pgrep`, `paccache`, `pacman`, `apt-get`, `dnf`, and `zypper` binaries. Guards must not require root or network.

Execution order: drift guards run after `setup_mock_env` and are interleaved with the feature test cases rather than grouped at the end; find them by heading in the guard catalog.

See `docs/test-coverage-matrix.md` for the guard catalog.
