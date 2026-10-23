# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Bash tab completion for cleaner / cleaner.sh.

_cleaner() {
  local cur prev idx
  COMPREPLY=()
  idx=$COMP_CWORD
  cur="${COMP_WORDS[idx]:-}"
  prev=""
  if (( idx > 0 )); then
    prev="${COMP_WORDS[idx - 1]}"
  fi

  # Rejoin "prefix:val" when COMP_WORDBREAKS splits on ':' (e.g. older-than:7 or max-size:5G).
  if [[ "$cur" == ":" && $idx -ge 2 ]]; then
    cur="${COMP_WORDS[idx - 1]}:"
    prev="${COMP_WORDS[idx - 2]}"
  elif [[ "$prev" == ":" && $idx -ge 3 ]]; then
    cur="${COMP_WORDS[idx - 2]}:$cur"
    prev="${COMP_WORDS[idx - 3]}"
  fi

  local -a sessions=()
  if [[ "$prev" == --restore || "$prev" == --purge-sessions || "$prev" == --hold-session || "$prev" == --release-session ]]; then
    local session
    while IFS= read -r session; do
      [[ -d "$session" && ! -L "$session" ]] || continue
      session="${session##*/}"
      [[ "$session" == "." || "$session" == ".." ]] && continue
      [[ "$session" == "$cur"* ]] && sessions+=("$session")
    done < <(compgen -d -- "$HOME/.cache/linux-cleaner/quarantine/$cur")
  fi

  case "$prev" in
    -r|--risk)
      mapfile -t COMPREPLY < <(compgen -W "safe medium danger" -- "$cur")
      return 0
      ;;
    --restore|--hold-session|--release-session)
      mapfile -t COMPREPLY < <(compgen -W "latest" -- "$cur")
      COMPREPLY+=("${sessions[@]}")
      return 0
      ;;
    --purge-sessions)
      mapfile -t COMPREPLY < <(compgen -W "latest all older-than: max-size: keep-latest:" -- "$cur")
      COMPREPLY+=("${sessions[@]}")
      if [[ ${#COMPREPLY[@]} -eq 1 && "${COMPREPLY[0]}" == *: ]]; then
        compopt -o nospace 2>/dev/null || true
      fi
      if [[ "${COMP_WORDBREAKS:-}" == *:* && "$cur" == *:* ]]; then
        local colon_prefix="${cur%"${cur##*:}"}"
        local i
        for i in "${!COMPREPLY[@]}"; do
          COMPREPLY[i]="${COMPREPLY[i]#"$colon_prefix"}"
          # An empty reply would replace the typed ':' with nothing.
          [[ -z "${COMPREPLY[i]}" ]] && unset 'COMPREPLY[i]'
        done
      fi
      return 0
      ;;
    --log)
      # The FILE argument is optional, so an option may follow directly.
      if [[ "$cur" != -* ]]; then
        compopt -o filenames 2>/dev/null || true
        mapfile -t COMPREPLY < <(compgen -f -- "$cur")
        return 0
      fi
      ;;
    -c|--config)
      compopt -o filenames 2>/dev/null || true
      mapfile -t COMPREPLY < <(compgen -f -- "$cur")
      return 0
      ;;
    --only-path|--exclude-path|--min-free-path)
      compopt -o filenames 2>/dev/null || true
      mapfile -t COMPREPLY < <(compgen -f -- "$cur")
      return 0
      ;;
    -e|--exclude|--only|--only-exact|--only-target|--exclude-target|--lock-wait|--check-health|--min-reclaim|--min-free|--trash-keep-days|--min-age|--action-timeout)
      return 0
      ;;
  esac

  local opts="
    -c --config
    -d --dry-run
    --clean
    -i --interactive
    -f --force
    --yes-danger
    -t --trash
    -r --risk
    -e --exclude
    --list-sessions
    --report
    --check-health
    --list-targets
    --check-config
    --init-config
    --doctor
    --restore
    --hold-session
    --release-session
    --only
    --only-exact
    --only-target
    --exclude-target
    --only-path
    --exclude-path
    --lock-wait
    --min-reclaim
    --min-free
    --min-free-path
    --min-age
    --action-timeout
    --trash-keep-days
    --purge-sessions
    --allow-outside-home
    --log
    -q --quiet
    --debug
    --show-matches
    --exit-code
    --notify
    --fail-fast
    --json
    -h --help
    -V --version
  "

  mapfile -t COMPREPLY < <(compgen -W "$opts" -- "$cur")
}

complete -F _cleaner cleaner cleaner.sh
