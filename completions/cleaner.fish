# SPDX-License-Identifier: GPL-3.0-or-later
# Fish tab completion for cleaner / cleaner.sh.

function __cleaner_sessions
  for session in "$HOME/.cache/linux-cleaner/quarantine/"*/ "$HOME/.cache/linux-cleaner/quarantine/".*/
    if not test -L (string replace -r '/$' '' -- $session)
      string replace -r '^.*/([^/]+)/$' '$1' -- $session
    end
  end
end

complete -c cleaner -s c -l config -r -F -d 'Path to a configuration file (default search order: XDG user config, then /etc/linux-cleaner/cleaner.conf, then cleaner.conf beside the script)'
complete -c cleaner -s d -l dry-run -d 'Calculate and display potential space savings without deleting anything (default)'
complete -c cleaner -l clean -d 'Perform cleanup with a summary confirmation prompt'
complete -c cleaner -s i -l interactive -d 'Prompt for confirmation before cleaning each target'
complete -c cleaner -s f -l force -d 'Perform cleaning immediately without any confirmation prompts (except danger level)'
complete -c cleaner -l yes-danger -d 'Bypass manual confirmation prompt for danger risk targets'
complete -c cleaner -s t -l trash -d 'Move files to quarantine instead of permanent deletion'
complete -c cleaner -s r -l risk -x -a 'safe medium danger' -d 'Max risk level to clean: safe, medium, danger (default: safe)'
complete -c cleaner -s e -l exclude -x -d 'Comma-separated glob patterns to exclude (Warning: Incorrect patterns can affect deletion semantics or exclude everything)'
complete -c cleaner -l list-sessions -d 'List quarantine sessions (read-only) and exit'
complete -c cleaner -l report -d 'Print the saved last cleanup report and exit'
complete -c cleaner -l list-targets -d 'List configured cleanup targets (read-only) and exit'
complete -c cleaner -l check-config -d 'Validate the configuration file and exit (no disk analysis)'
complete -c cleaner -l init-config -d 'Copy the active config to your user config path (never overwrites)'
complete -c cleaner -l doctor -d 'Check the runtime environment a cleanup depends on (read-only) and exit'
complete -c cleaner -l restore -x -a 'latest (__cleaner_sessions)' -d 'Restore files from quarantine session (latest or timestamp)'
complete -c cleaner -l only -x -d 'With --restore: restore only targets whose original path contains PATTERN; the rest stay quarantined'
complete -c cleaner -l only-exact -x -d 'With --restore: match a literal original path from session inventory; excludes --only'
complete -c cleaner -l only-target -x -d 'With cleanup or --list-targets: select config targets whose NAME contains PATTERN'
complete -c cleaner -l exclude-target -x -d 'With cleanup or --list-targets: skip config targets whose NAME contains PATTERN'
complete -c cleaner -l only-path -r -F -d 'With cleanup or --list-targets: select ordinary targets at/below an existing absolute path; excludes action:* rows (env: LINUX_CLEANER_ONLY_PATH)'
complete -c cleaner -l exclude-path -r -F -d 'With cleanup or --list-targets: skip targets at, below, or containing an existing absolute path (env: LINUX_CLEANER_EXCLUDE_PATH)'
complete -c cleaner -l lock-wait -x -d 'With mutating runs: wait up to 0..2147483647 seconds for the lock (default: 0; env: LINUX_CLEANER_LOCK_WAIT)'
complete -c cleaner -l min-reclaim -x -d 'With cleanup: skip the run when the planned reclaim is below SIZE (e.g. 500M, 2G)'
complete -c cleaner -l min-free -x -d 'With cleanup: skip the run when the home filesystem already has at least SIZE free (e.g. 10G)'
complete -c cleaner -l min-age -x -d "With cleanup: raise every ordinary target's age threshold to at least DAYS days; skips action:* rows (env: LINUX_CLEANER_MIN_AGE)"
complete -c cleaner -l trash-keep-days -x -d 'With cleanup: purge quarantine sessions older than DAYS days after cleaning'
complete -c cleaner -l purge-sessions -x -a 'latest all older-than: max-size: keep-latest: (__cleaner_sessions)' -d 'Permanently delete quarantine session(s) to reclaim space (latest, all, older-than:DAYS, max-size:SIZE, keep-latest:N, or timestamp). Irreversible'
complete -c cleaner -l allow-outside-home -d 'Deprecated no-op; targets outside HOME are always allowed'
complete -c cleaner -l log -F -d 'Append an operation log (opt-in, off by default; kept under your HOME)'
complete -c cleaner -s q -l quiet -d 'Suppress per-target status lines; keep errors, totals, and final summary'
complete -c cleaner -l debug -d 'Show per-target FOUND, CLEAN and PROTECTED lines (suppressed by default; overridden by --quiet)'
complete -c cleaner -l notify -d 'With cleanup: send a desktop notification summarizing the result (no-op on dry-run; env: LINUX_CLEANER_NOTIFY)'
complete -c cleaner -l json -d 'Emit machine-readable JSON (--dry-run summary, --list-targets inventory, --list-sessions inventory, or --report summary)'
complete -c cleaner -s h -l help -d 'Display this help message and exit'
complete -c cleaner -s V -l version -d 'Print the tool version and exit'

complete -c cleaner.sh -w cleaner
