#!/usr/bin/env bash
# vole completion - shell completion for bash, zsh, fish

VOLE_COMMANDS="clean uninstall optimize analyze status purge installer history completion update remove help version"

completion_bash() {
cat <<'EOF'
_vole_complete() {
    local cur prev; cur="${COMP_WORDS[COMP_CWORD]}"; prev="${COMP_WORDS[1]}"
    if (( COMP_CWORD == 1 )); then
        COMPREPLY=( $(compgen -W "clean uninstall optimize analyze status purge installer history completion update remove help version --help --version" -- "$cur") ); return
    fi
    case "$prev" in
        clean) COMPREPLY=( $(compgen -W "--dry-run --debug --user-only --docker --whitelist" -- "$cur") ) ;;
        uninstall) COMPREPLY=( $(compgen -W "--dry-run --list --yes" -- "$cur") ) ;;
        optimize) COMPREPLY=( $(compgen -W "--dry-run --whitelist" -- "$cur") ) ;;
        purge) COMPREPLY=( $(compgen -W "--dry-run --yes --paths" -- "$cur") ) ;;
        installer) COMPREPLY=( $(compgen -W "--dry-run --yes" -- "$cur") ) ;;
        history) COMPREPLY=( $(compgen -W "--json --all" -- "$cur") ) ;;
        status) COMPREPLY=( $(compgen -W "--json --watch --interval" -- "$cur") ) ;;
        analyze|analyse) COMPREPLY=( $(compgen -d -- "$cur") $(compgen -W "--json" -- "$cur") ) ;;
        completion) COMPREPLY=( $(compgen -W "bash zsh fish" -- "$cur") ) ;;
    esac
}
complete -F _vole_complete vole vo
EOF
}

completion_zsh() {
cat <<'EOF'
#compdef vole vo
_vole() {
  local -a cmds
  cmds=(clean:'Deep cleanup' uninstall:'Remove apps + leftovers' optimize:'Refresh caches & services' analyze:'Disk explorer' status:'Live system dashboard' purge:'Clean project artifacts' installer:'Remove installer files' history:'Cleanup history' completion:'Shell completion' update:'Update Vole' remove:'Remove Vole')
  if (( CURRENT == 2 )); then _describe 'command' cmds; return; fi
  case $words[2] in
    clean) _values 'option' --dry-run --debug --user-only --docker --whitelist ;;
    uninstall) _values 'option' --dry-run --list --yes ;;
    optimize) _values 'option' --dry-run --whitelist ;;
    purge) _values 'option' --dry-run --yes --paths ;;
    installer) _values 'option' --dry-run --yes ;;
    history) _values 'option' --json --all ;;
    status) _values 'option' --json --watch --interval ;;
    analyze|analyse) _files -/ ;;
    completion) _values 'shell' bash zsh fish ;;
  esac
}
compdef _vole vole vo
EOF
}

completion_fish() {
cat <<'EOF'
for c in vole vo
  complete -c $c -f -n '__fish_use_subcommand' -a 'clean uninstall optimize analyze status purge installer history completion update remove'
  complete -c $c -n '__fish_seen_subcommand_from clean uninstall optimize purge installer' -l dry-run
  complete -c $c -n '__fish_seen_subcommand_from clean optimize' -l whitelist
  complete -c $c -n '__fish_seen_subcommand_from clean' -l user-only
  complete -c $c -n '__fish_seen_subcommand_from purge' -l paths
  complete -c $c -n '__fish_seen_subcommand_from status history analyze' -l json
  complete -c $c -n '__fish_seen_subcommand_from completion' -a 'bash zsh fish'
end
EOF
}

cmd_completion() {
    local sh="${1:-}"
    if [[ -z "$sh" ]]; then
        sh=$(basename "${SHELL:-bash}")
        local file
        case "$sh" in
            bash) file="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions/vole"; mkdir -p "$(dirname "$file")"; completion_bash > "$file"; ln -sf vole "$(dirname "$file")/vo"
                  ok "Installed bash completion: ${file/#$HOME/\~} (open a new shell)" ;;
            zsh)  file="$HOME/.zsh/completions/_vole"; mkdir -p "$(dirname "$file")"; completion_zsh > "$file"
                  grep -q '.zsh/completions' "$HOME/.zshrc" 2>/dev/null || printf '\nfpath=(~/.zsh/completions $fpath)\nautoload -Uz compinit && compinit\n' >> "$HOME/.zshrc"
                  ok "Installed zsh completion: ${file/#$HOME/\~}" ;;
            fish) file="${XDG_CONFIG_HOME:-$HOME/.config}/fish/completions/vole.fish"; mkdir -p "$(dirname "$file")"; completion_fish > "$file"; cp "$file" "$(dirname "$file")/vo.fish"
                  ok "Installed fish completion: ${file/#$HOME/\~}" ;;
            *) die "Unsupported shell: $sh (use: vo completion bash|zsh|fish)" ;;
        esac
        return
    fi
    case "$sh" in bash) completion_bash ;; zsh) completion_zsh ;; fish) completion_fish ;; *) die "Unsupported shell: $sh" ;; esac
}
