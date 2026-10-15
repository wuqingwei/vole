#!/usr/bin/env bash
# vole installer - find and remove installer files (.deb .rpm .iso .run .pkg.tar.zst ...).

INSTALLER_PATTERNS=( '*.deb' '*.rpm' '*.iso' '*.img.xz' '*.run' '*.pkg.tar.zst' '*.pkg.tar.xz' '*.flatpakref' '*.snap' '*.apk' '*.msi' '*.exe' '*.dmg' '*.xpi' '*-installer*.tar.gz' '*-installer*.zip' '*_Setup*.zip' '*Installer*.bin' )

installer_sources() {
    local s=(
        "$HOME/Downloads|Downloads" "$HOME/下载|Downloads" "$HOME/Desktop|Desktop" "$HOME/桌面|Desktop"
        "$HOME/Downloads/Telegram Desktop|Telegram" "$HOME/.local/share/TelegramDesktop/tdata/temp|Telegram"
        "$HOME/.cache/yay|yay (AUR)" "$HOME/.cache/paru/clone|paru (AUR)" "$HOME/Documents/WeChat Files|WeChat"
        "$HOME/.local/share/Steam/steamapps/downloading|Steam"
    )
    printf '%s\n' "${s[@]}"
}

installer_scan() {
    local src dir label p expr=() first=1 seen=""
    for p in "${INSTALLER_PATTERNS[@]}"; do (( first )) || expr+=(-o); first=0; expr+=(-iname "$p"); done
    declare -A visited=()
    while IFS='|' read -r dir label; do
        [[ -d "$dir" ]] || continue
        local real; real=$(cd "$dir" && pwd -P)
        [[ -n "${visited[$real]:-}" ]] && continue; visited[$real]=1
        local depth=2; [[ "$label" == *AUR* ]] && depth=3
        while IFS= read -r -d '' p; do
            [[ -L "$p" ]] && continue
            is_whitelisted "$p" && continue
            # Skip .exe / .zip files that live inside an extracted program folder
            if [[ "$p" == *.exe && -n "$(find "$(dirname "$p")" -maxdepth 1 -iname '*.dll' -print -quit)" ]]; then continue; fi
            printf '%s|%s|%s\n' "$(stat -c %s -- "$p")" "$label" "$p"
        done < <(find "$real" -maxdepth "$depth" -type f \( "${expr[@]}" \) -print0 2>/dev/null)
    done < <(installer_sources)
}

cmd_installer() {
    VOLE_COMMAND=installer
    local a
    for a in "$@"; do
        case "$a" in
            --dry-run|-n) VOLE_DRY_RUN=1 ;; --debug) VOLE_DEBUG=1 ;; -y|--yes) VOLE_YES=1 ;;
            -h|--help) echo "Usage: vo installer [--dry-run] [--yes]"; return ;;
            *) die "Unknown option: $a" ;;
        esac
    done
    load_whitelist
    title "Installer Files"
    local rows=()
    mapfile -t rows < <(installer_scan | sort -t'|' -k1,1nr)
    (( ${#rows[@]} )) || { say "No installer files found."; return 0; }
    VOLE_MENU_LABELS=(); VOLE_MENU_SELECTED=()
    local r total=0
    for r in "${rows[@]}"; do
        IFS='|' read -r b l p <<<"$r"
        VOLE_MENU_LABELS+=("$(printf '%-36.36s %9s | %s' "$(basename "$p")" "$(human "$b")" "$l")")
        # Pre-select installers older than 3 days
        if [[ -n "$(find "$p" -mtime +3 -print 2>/dev/null)" ]]; then VOLE_MENU_SELECTED+=(1); else VOLE_MENU_SELECTED+=(0); fi
    done
    if [[ -t 0 && "$VOLE_YES" != "1" ]]; then
        select_multi "Select Installers to Remove" || { say "Cancelled."; return 0; }
    elif [[ "$VOLE_DRY_RUN" != "1" && "$VOLE_YES" != "1" ]]; then
        die "Non-interactive run needs --yes (or --dry-run)."
    fi
    local chosen=() i
    for i in "${!rows[@]}"; do [[ ${VOLE_MENU_SELECTED[$i]} == 1 ]] && chosen+=("${rows[$i]}"); done
    (( ${#chosen[@]} )) || { say "Nothing selected."; return 0; }
    local n=0 freed=0 got
    for r in "${chosen[@]}"; do
        IFS='|' read -r b l p <<<"$r"
        # re-verify identity at deletion time
        [[ -f "$p" && ! -L "$p" && "$(stat -c %s -- "$p" 2>/dev/null)" == "$b" ]] || { skip "$(basename "$p") · changed since scan"; continue; }
        if [[ "$VOLE_DRY_RUN" == "1" ]]; then step "Would remove $(basename "$p") ($(human "$b"))"; n=$((n+1)); freed=$((freed+b)); continue; fi
        got=$(safe_remove "$p") || true
        n=$((n+1)); freed=$((freed + ${got:-0}))
    done
    echo; rule
    say "${C_BOLD}Installers $( [[ $VOLE_DRY_RUN == 1 ]] && echo "(dry run)" || echo cleaned)${C_RESET}"
    say "Removed $n installer$( ((n==1)) || echo s), freed $(human "$freed")"
    rule
}
