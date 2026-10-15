#!/usr/bin/env bash
# Vole - minimal terminal menus (pure bash, no dependencies).
# shellcheck disable=SC2034

[[ -n "${VOLE_UI_LOADED:-}" ]] && return 0
VOLE_UI_LOADED=1

# Inputs for both menus:
#   VOLE_MENU_LABELS=( "label" ... )
#   VOLE_MENU_SELECTED=( 0|1 ... )   (multi only)
# Outputs:
#   select_single -> VOLE_MENU_CHOICE (index), returns 1 on cancel
#   select_multi  -> VOLE_MENU_SELECTED updated, VOLE_MENU_KEY = enter|<extra key>, returns 1 on cancel

_ui_read_key() {
    local k rest
    IFS= read -rsn1 k </dev/tty || { echo quit; return; }
    if [[ "$k" == $'\x1b' ]]; then
        IFS= read -rsn2 -t 0.02 rest </dev/tty || rest=""
        case "$rest" in
            "[A"|"OA") echo up ;;   "[B"|"OB") echo down ;;
            "[C"|"OC") echo right ;; "[D"|"OD") echo left ;;
            "[5") IFS= read -rsn1 -t 0.02 _ </dev/tty; echo pgup ;;
            "[6") IFS= read -rsn1 -t 0.02 _ </dev/tty; echo pgdn ;;
            "") echo quit ;;
            *) echo other ;;
        esac
        return
    fi
    case "$k" in
        "") echo enter ;;
        " ") echo space ;;
        k|K) echo up ;; j|J) echo down ;;
        q|Q) echo quit ;;
        *) printf 'key:%s\n' "$k" ;;
    esac
}

_ui_rows() { local r; r=$(tput lines 2>/dev/null || echo 24); echo $(( r > 10 ? r - 8 : 5 )); }

_ui_begin() { tput civis 2>/dev/null; stty -echo 2>/dev/null </dev/tty; trap '_ui_end; exit 130' INT; }
_ui_end()   { tput cnorm 2>/dev/null; stty echo 2>/dev/null </dev/tty; trap - INT; }

_ui_clear_lines() { local n="$1" i; for ((i=0;i<n;i++)); do printf '\033[1A\033[2K'; done; }

select_single() {
    local heading="$1" cur=0 n=${#VOLE_MENU_LABELS[@]} drawn=0 i key
    (( n == 0 )) && return 1
    [[ -t 0 || -r /dev/tty ]] || return 1
    _ui_begin
    while true; do
        (( drawn > 0 )) && _ui_clear_lines "$drawn"
        drawn=0
        printf '%s%s%s\n' "$C_BOLD" "$heading" "$C_RESET" >/dev/tty; drawn=$((drawn+1))
        for ((i=0;i<n;i++)); do
            if (( i == cur )); then printf ' %s%s %s%s\n' "$C_CYAN" "$ICON_ARROW" "${VOLE_MENU_LABELS[$i]}" "$C_RESET"
            else printf '   %s\n' "${VOLE_MENU_LABELS[$i]}"; fi
            drawn=$((drawn+1))
        done >/dev/tty
        printf '%s↑/↓ move · Enter select · q quit%s\n' "$C_GRAY" "$C_RESET" >/dev/tty; drawn=$((drawn+1))
        key=$(_ui_read_key)
        case "$key" in
            up) cur=$(( (cur - 1 + n) % n )) ;;
            down) cur=$(( (cur + 1) % n )) ;;
            enter|right) _ui_end; _ui_clear_lines "$drawn"; VOLE_MENU_CHOICE=$cur; return 0 ;;
            quit) _ui_end; _ui_clear_lines "$drawn"; return 1 ;;
            key:[1-9]) local d=${key#key:}; if (( d <= n )); then cur=$((d-1)); _ui_end; _ui_clear_lines "$drawn"; VOLE_MENU_CHOICE=$cur; return 0; fi ;;
        esac
    done
}

# select_multi HEADING [EXTRA_KEYS] [EXTRA_HINT]
select_multi() {
    local heading="$1" extra="${2:-}" extra_hint="${3:-}"
    local cur=0 top=0 n=${#VOLE_MENU_LABELS[@]} drawn=0 i key rows count
    (( n == 0 )) && return 1
    [[ -t 0 || -r /dev/tty ]] || return 1
    _ui_begin
    while true; do
        rows=$(_ui_rows)
        (( cur < top )) && top=$cur
        (( cur >= top + rows )) && top=$(( cur - rows + 1 ))
        (( drawn > 0 )) && _ui_clear_lines "$drawn"
        drawn=0; count=0
        for ((i=0;i<n;i++)); do [[ "${VOLE_MENU_SELECTED[$i]}" == "1" ]] && count=$((count+1)); done
        {
        printf '%s%s%s  %s%d/%d selected%s\n' "$C_BOLD" "$heading" "$C_RESET" "$C_GRAY" "$count" "$n" "$C_RESET"
        printf '\n'
        } >/dev/tty
        drawn=2
        for ((i=top; i<n && i<top+rows; i++)); do
            local mark="○" col=""
            [[ "${VOLE_MENU_SELECTED[$i]}" == "1" ]] && { mark="●"; col="$C_GREEN"; }
            if (( i == cur )); then
                printf '%s%s%s %s%s %s%s\n' "$C_CYAN" "$ICON_ARROW" "$C_RESET" "$col" "$mark" "${VOLE_MENU_LABELS[$i]}" "$C_RESET"
            else
                printf '  %s%s%s %s\n' "$col" "$mark" "$C_RESET" "${VOLE_MENU_LABELS[$i]}"
            fi
            drawn=$((drawn+1))
        done >/dev/tty
        if (( n > rows )); then printf '%s  … %d-%d of %d%s\n' "$C_GRAY" $((top+1)) $(( top+rows < n ? top+rows : n )) "$n" "$C_RESET" >/dev/tty; drawn=$((drawn+1)); fi
        printf '\n%s↑/↓ move · Space toggle · a all · n none · Enter confirm · q cancel%s%s\n' "$C_GRAY" "${extra_hint:+ · $extra_hint}" "$C_RESET" >/dev/tty
        drawn=$((drawn+2))
        key=$(_ui_read_key)
        case "$key" in
            up) cur=$(( (cur - 1 + n) % n )) ;;
            down) cur=$(( (cur + 1) % n )) ;;
            pgup|left) cur=$(( cur - rows < 0 ? 0 : cur - rows )) ;;
            pgdn|right) cur=$(( cur + rows >= n ? n - 1 : cur + rows )) ;;
            space) if [[ "${VOLE_MENU_SELECTED[$cur]}" == "1" ]]; then VOLE_MENU_SELECTED[cur]=0; else VOLE_MENU_SELECTED[cur]=1; fi
                   (( cur < n - 1 )) && cur=$((cur+1)) ;;
            key:a|key:A) for ((i=0;i<n;i++)); do VOLE_MENU_SELECTED[i]=1; done ;;
            key:n|key:N) for ((i=0;i<n;i++)); do VOLE_MENU_SELECTED[i]=0; done ;;
            enter) _ui_end; _ui_clear_lines "$drawn"; VOLE_MENU_KEY=enter; return 0 ;;
            quit) _ui_end; _ui_clear_lines "$drawn"; return 1 ;;
            key:*)
                local c=${key#key:}
                if [[ -n "$extra" && "$extra" == *"$c"* ]]; then _ui_end; _ui_clear_lines "$drawn"; VOLE_MENU_KEY="$c"; VOLE_MENU_CURSOR=$cur; return 0; fi ;;
        esac
    done
}

# prompt_key "text" -> echoes the pressed key (enter|<char>|quit)
prompt_key() {
    printf '%s' "$1" >/dev/tty
    local k; k=$(_ui_read_key); printf '\n' >/dev/tty
    case "$k" in key:*) echo "${k#key:}" ;; *) echo "$k" ;; esac
}
