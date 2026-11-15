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

  # Rejoin "prefix:val" when COMP_WORDBREAKS splits on ':' (e.g. older-than:7 or /dir:1/file).
  if [[ "${COMP_WORDBREAKS:-}" == *:* ]]; then
    if [[ "$cur" =~ ^:+$ && $idx -ge 2 ]]; then
      case "${COMP_WORDS[idx - 1]}" in
        -c|--config|-r|--risk|-e|--exclude|--exclude-from|--restore|--hold-session|--release-session|--purge-sessions|--only|--only-exact|--only-target|--only-target-exact|--exclude-target|--exclude-target-exact|--only-path|--exclude-path|--lock-wait|--check-health|--min-reclaim|--min-free|--min-free-path|--min-age|--action-timeout|--trash-keep-days|--log)
          if (( idx > 2 )) && [[ "${COMP_WORDS[idx - 2]}" =~ ^:+$ ]]; then
            cur="${COMP_WORDS[idx - 1]}${cur}"
            idx=$((idx - 1))
          fi
          ;;
        *)
          cur="${COMP_WORDS[idx - 1]}${cur}"
          idx=$((idx - 1))
          ;;
      esac
    fi
    while (( idx >= 2 )) && [[ "${COMP_WORDS[idx - 1]}" =~ ^:+$ ]]; do
      cur="${COMP_WORDS[idx - 1]}${cur}"
      idx=$((idx - 1))
      if (( idx >= 2 )); then
        case "${COMP_WORDS[idx - 1]}" in
          -c|--config|-r|--risk|-e|--exclude|--exclude-from|--restore|--hold-session|--release-session|--purge-sessions|--only|--only-exact|--only-target|--only-target-exact|--exclude-target|--exclude-target-exact|--only-path|--exclude-path|--lock-wait|--check-health|--min-reclaim|--min-free|--min-free-path|--min-age|--action-timeout|--trash-keep-days|--log)
            if (( idx == 2 )) || [[ ! "${COMP_WORDS[idx - 2]}" =~ ^:+$ ]]; then
              break
            fi
            ;;
        esac
        cur="${COMP_WORDS[idx - 1]}${cur}"
        idx=$((idx - 1))
      fi
    done
    prev=""
    if (( idx > 0 )); then
      prev="${COMP_WORDS[idx - 1]}"
    fi
  fi

  local -a sessions=()
  if [[ "$prev" == --restore || "$prev" == --purge-sessions || "$prev" == --hold-session || "$prev" == --release-session ]]; then
    local quarantine_dir="${HOME:-}/.cache/linux-cleaner/quarantine"
    if [[ -n "${HOME:-}" && "$cur" != */* && -d "$quarantine_dir" && ! -L "$quarantine_dir" ]]; then
      local session
      while IFS= read -r session; do
        [[ -d "$session" && ! -L "$session" ]] || continue
        session="${session##*/}"
        [[ "$session" == "." || "$session" == ".." ]] && continue
        [[ "$session" == "$cur"* ]] && sessions+=("$session")
      done < <(compgen -d -- "$quarantine_dir/$cur")
    fi
  fi

  local handled=true is_file_comp=false
  case "$prev" in
    -r|--risk)
      mapfile -t COMPREPLY < <(compgen -W "safe medium danger" -- "$cur")
      ;;
    --restore|--hold-session|--release-session)
      mapfile -t COMPREPLY < <(compgen -W "latest" -- "$cur")
      COMPREPLY+=("${sessions[@]}")
      ;;
    --purge-sessions)
      mapfile -t COMPREPLY < <(compgen -W "latest all older-than: max-size: keep-latest:" -- "$cur")
      COMPREPLY+=("${sessions[@]}")
      if [[ ${#COMPREPLY[@]} -eq 1 && "${COMPREPLY[0]}" == *: ]]; then
        compopt -o nospace 2>/dev/null || true
      fi
      ;;
    --log)
      # The FILE argument is optional, so an option may follow directly.
      if [[ "$cur" != -* ]]; then
        is_file_comp=true
        compopt -o filenames 2>/dev/null || true
        mapfile -t COMPREPLY < <(compgen -f -- "$cur")
      else
        handled=false
      fi
      ;;
    -c|--config|--exclude-from|--only-path|--exclude-path|--min-free-path)
      is_file_comp=true
      compopt -o filenames 2>/dev/null || true
      mapfile -t COMPREPLY < <(compgen -f -- "$cur")
      ;;
    -e|--exclude|--only|--only-exact|--only-target|--only-target-exact|--exclude-target|--exclude-target-exact|--lock-wait|--check-health|--min-reclaim|--min-free|--trash-keep-days|--min-age|--action-timeout)
      ;;
    *)
      handled=false
      ;;
  esac

  if [[ "$handled" != true ]]; then
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
      --exclude-from
      --list-sessions
      --report
      --check-health
      --list-targets
      --check-config
      --init-config
      --overlay
      --doctor
      --restore
      --hold-session
      --release-session
      --only
      --only-exact
      --only-target
      --only-target-exact
      --exclude-target
      --exclude-target-exact
      --only-path
      --exclude-path
      --skip-actions
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
  fi

  if [[ "${COMP_WORDBREAKS:-}" == *:* && "$cur" == *:* ]]; then
    local colon_prefix="${cur%"${cur##*:}"}"
    local i full
    for i in "${!COMPREPLY[@]}"; do
      full="${COMPREPLY[i]}"
      if [[ "$is_file_comp" == true && -d "$full" && "$full" != */ ]]; then
        full="${full}/"
      fi
      COMPREPLY[i]="${full#"$colon_prefix"}"
      # An empty reply would replace the typed ':' with nothing.
      [[ -z "${COMPREPLY[i]}" ]] && unset 'COMPREPLY[i]'
    done
    if [[ "$is_file_comp" == true && ${#COMPREPLY[@]} -eq 1 && "${COMPREPLY[*]}" == */ ]]; then
      compopt -o nospace 2>/dev/null || true
    fi
  fi
}

complete -F _cleaner cleaner cleaner.sh
