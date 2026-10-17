# Hermetic test guards

Drift guards run after mock `$HOME` setup with stubbed binaries. `setup_mock_env` in `test_cleaner.sh` stubs `sudo`, `pgrep`, `paccache`, `pacman`, the package managers `apt`, `apt-get`, `dnf`, `zypper`, and `apk`, and the user-level prune tools `uv`, `pnpm`, and `hf`; this is the one list of them, so update it when a stub is added. Guards must not require root or network.

Execution order: drift guards run after `setup_mock_env` and are interleaved with the feature test cases rather than grouped at the end; find them by heading in the guard catalog.

See `docs/test-coverage-matrix.md` for the guard catalog.
