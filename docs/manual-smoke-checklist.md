# Manual smoke checklist

## Hermetic test boundaries

The hermetic suite stubs `sudo`, `pgrep`, `paccache`, and `pacman` under mock `$HOME`. It does not cover live `/etc/linux-cleaner/cleaner.conf` resolution, real sudo prompts, or race-sensitive TOCTOU.

## Hermetic boundaries

Suite stubs sudo/pgrep/PM; not hermetically testable: /etc resolution, live sudo, TOCTOU races.
