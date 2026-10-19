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
  if [[ "$prev" == --restore || "$prev" == --purge-sessions ]]; then
    local session
    for session in "$HOME/.cache/linux-cleaner/quarantine/"{*,.[!.]*,..?*}; do
      [[ -d "$session" && ! -L "$session" ]] || continue
      session="${session##*/}"
      [[ "$session" == "$cur"* ]] && sessions+=("$session")
    done
  fi

  case "$prev" in
    -r|--risk)
      mapfile -t COMPREPLY < <(compgen -W "safe medium danger" -- "$cur")
      return 0
      ;;
    --restore)
      mapfile -t COMPREPLY < <(compgen -W "latest" -- "$cur")
      COMPREPLY+=("${sessions[@]}")
      return 0
      ;;
    --purge-sessions)
      mapfile -t COMPREPLY < <(compgen -W "latest all older-than: max-size:" -- "$cur")
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
        mapfile -t COMPREPLY < <(compgen -f -- "$cur")
        return 0
      fi
      ;;
    -c|--config)
      mapfile -t COMPREPLY < <(compgen -f -- "$cur")
      return 0
      ;;
    --only-path)
      mapfile -t COMPREPLY < <(compgen -f -- "$cur")
      return 0
      ;;
    -e|--exclude|--only|--only-exact|--only-target|--exclude-target|--lock-wait|--min-reclaim|--min-free|--trash-keep-days|--min-age)
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
    --list-targets
    --check-config
    --init-config
    --restore
    --only
    --only-exact
    --only-target
    --exclude-target
    --only-path
    --lock-wait
    --min-reclaim
    --min-free
    --min-age
    --trash-keep-days
    --purge-sessions
    --allow-outside-home
    --log
    -q --quiet
    --debug
    --notify
    --json
    -h --help
    -V --version
  "

  mapfile -t COMPREPLY < <(compgen -W "$opts" -- "$cur")
}

complete -F _cleaner cleaner cleaner.sh
