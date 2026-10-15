#!/usr/bin/env bash
# vole uninstall - remove apps (deb/rpm/pacman packages, Flatpak, Snap, AppImage, local launchers)
# together with their caches. Personal data (config/data) is kept unless chosen with D.

# Packages Vole refuses to remove: desktop shells, core system, the package manager itself.
VOLE_UNINSTALL_DENY_RE='^(gnome-shell|gnome-session.*|gnome-control-center|nautilus|plasma-.*|kwin.*|systemsettings|dolphin|konsole|gnome-terminal|xfce4-.*|cinnamon.*|mate-.*|lxqt-.*|xorg.*|xserver-.*|wayland.*|systemd.*|dbus.*|network-manager.*|NetworkManager.*|gdm3?|sddm|lightdm|apt|dpkg|dnf|rpm|pacman|zypper|snapd|flatpak|sudo|bash|coreutils|ubuntu-desktop.*|kubuntu-desktop|fedora-release.*|linux-image.*|linux-generic.*|kernel.*|grub.*|firmware.*)$'

# App record: source|id|name|bytes|last_used_epoch|extra
_apps=()

_desktop_field() { awk -F= -v k="$2" '$1==k{ $1=""; sub(/^=/,""); print substr($0,2); exit }' "$1" 2>/dev/null; }

_atime_of() { stat -c %X -- "$1" 2>/dev/null || echo 0; }

collect_pkg_apps() {
    local pm; pm=$(detect_pkg_manager)
    local files=() f
    for f in /usr/share/applications/*.desktop /usr/local/share/applications/*.desktop; do
        [[ -f "$f" ]] || continue
        [[ "$(_desktop_field "$f" NoDisplay)" == "true" ]] && continue
        [[ "$(_desktop_field "$f" Type)" == "Application" ]] || continue
        files+=("$f")
    done
    (( ${#files[@]} )) || return 0
    declare -A owner=()
    local line pkg file
    case "$pm" in
        apt)
            while IFS= read -r line; do
                pkg=${line%%: *}; file=${line#*: }; pkg=${pkg%%,*}; pkg=${pkg%%:*}
                [[ -n "$pkg" && "$file" == /* ]] && owner["$file"]="$pkg"
            done < <(dpkg -S "${files[@]}" 2>/dev/null) ;;
        dnf|yum|zypper)
            for f in "${files[@]}"; do
                pkg=$(rpm -qf --qf '%{NAME}\n' "$f" 2>/dev/null) && [[ "$pkg" != *"not owned"* ]] && owner["$f"]="$pkg"
            done ;;
        pacman)
            while IFS= read -r line; do
                # "/usr/share/applications/x.desktop is owned by pkg 1.0-1"
                file=${line%% is owned by *}; pkg=${line#* is owned by }; pkg=${pkg%% *}
                owner["$file"]="$pkg"
            done < <(LANG=C pacman -Qo "${files[@]}" 2>/dev/null) ;;
    esac
    declare -A seen=()
    local name bytes used
    for f in "${files[@]}"; do
        pkg=${owner[$f]:-}; [[ -z "$pkg" ]] && continue
        [[ -n "${seen[$pkg]:-}" ]] && continue
        [[ "$pkg" =~ $VOLE_UNINSTALL_DENY_RE ]] && continue
        seen[$pkg]=1
        name=$(_desktop_field "$f" Name); [[ -z "$name" ]] && name="$pkg"
        case "$pm" in
            apt) bytes=$(( $(dpkg-query -W -f='${Installed-Size}' "$pkg" 2>/dev/null || echo 0) * 1024 )) ;;
            dnf|yum|zypper) bytes=$(rpm -q --qf '%{SIZE}' "$pkg" 2>/dev/null || echo 0) ;;
            pacman) bytes=$(LANG=C pacman -Qi "$pkg" 2>/dev/null | awk -F: '/^Installed Size/{gsub(/ /,"",$2); v=$2; m=1; if(v~/KiB/)m=1024; else if(v~/MiB/)m=1048576; else if(v~/GiB/)m=1073741824; gsub(/[A-Za-z]/,"",v); printf "%d", v*m}') ;;
            *) bytes=0 ;;
        esac
        local exe; exe=$(_desktop_field "$f" Exec | awk '{print $1}')
        exe=$(command -v "$exe" 2>/dev/null || echo "$f")
        used=$(_atime_of "$exe")
        _apps+=("$pm|$pkg|$name|${bytes:-0}|$used|$f")
    done
}

collect_flatpak_apps() {
    command -v flatpak >/dev/null 2>&1 || return 0
    local id name size inst bytes
    while IFS=$'\t' read -r id name size inst; do
        [[ -z "$id" ]] && continue
        bytes=$(numfmt --from=auto <<<"$(sed 's/ //g; s/B$//; s/k/K/' <<<"$size")" 2>/dev/null || echo 0)
        local used; used=$(_atime_of "$HOME/.var/app/$id")
        _apps+=("flatpak|$id|$name|$bytes|$used|$inst")
    done < <(flatpak list --app --columns=application,name,size,installation 2>/dev/null)
}

collect_snap_apps() {
    command -v snap >/dev/null 2>&1 || return 0
    local name rev bytes f
    while read -r name _ rev _; do
        [[ -z "$name" || "$name" == Name ]] && continue
        case "$name" in core|core[0-9]*|snapd|bare|gtk-common-themes|gnome-*-[0-9]*|kde-frameworks-*|mesa-*|firmware-updater|snapd-desktop-integration|snap-store) continue ;; esac
        f="/var/lib/snapd/snaps/${name}_${rev}.snap"
        bytes=$(stat -c %s "$f" 2>/dev/null || echo 0)
        _apps+=("snap|$name|$name|$bytes|$(_atime_of "$HOME/snap/$name")|")
    done < <(LANG=C snap list 2>/dev/null)
}

collect_appimages() {
    local d f
    for d in "$HOME/Applications" "$HOME/.local/bin" "$HOME/AppImages" "$HOME/Apps" "$HOME/Downloads" "/opt"; do
        [[ -d "$d" ]] || continue
        while IFS= read -r -d '' f; do
            _apps+=("appimage|$f|$(basename "${f%.*}")|$(stat -c %s "$f" 2>/dev/null || echo 0)|$(_atime_of "$f")|")
        done < <(find "$d" -maxdepth 2 -type f \( -iname '*.AppImage' \) -print0 2>/dev/null)
    done
}

collect_local_launchers() {
    # Apps installed into ~/.local or /opt via a user .desktop file (tarball installs, JetBrains Toolbox etc.)
    local f exe name dir
    for f in "$HOME/.local/share/applications"/*.desktop; do
        [[ -f "$f" ]] || continue
        [[ "$(_desktop_field "$f" NoDisplay)" == "true" ]] && continue
        exe=$(_desktop_field "$f" Exec | awk '{print $1}' | tr -d '"')
        case "$exe" in flatpak|snap|env|"") continue ;; esac
        [[ "$exe" == *.AppImage ]] && continue
        [[ "$exe" == "$HOME"/* || "$exe" == /opt/* ]] || continue
        name=$(_desktop_field "$f" Name)
        # Install dir: the top folder under ~/.local/share, ~/opt, ~/apps or /opt that holds the binary
        dir=$(awk -v h="$HOME" -v e="$exe" 'BEGIN{
            n=split(e,p,"/"); base="";
            if (index(e,h"/.local/share/")==1) depth=split(h"/.local/share",q,"/")+1;
            else if (index(e,h"/")==1) depth=split(h,q,"/")+1;
            else depth=2;
            for(i=2;i<=depth && i<=n;i++) base=base"/"p[i]; print base }')
        [[ -z "$dir" || "$dir" == "$HOME/.local/bin" || "$dir" == "$HOME/bin" ]] && dir="$exe"
        is_protected_path "$dir" && dir="$exe"
        _apps+=("local|$f|$name|$(path_bytes "$dir")|$(_atime_of "$exe")|$dir")
    done
}

_ago() {
    local t="$1" now; now=$(date +%s)
    (( t <= 0 )) && { echo "unknown"; return; }
    local d=$(( (now - t) / 86400 ))
    if (( d < 1 )); then echo "today"; elif (( d < 14 )); then echo "${d}d ago"; elif (( d < 60 )); then echo "$((d/7))w ago"; elif (( d < 730 )); then echo "$((d/30))mo ago"; else echo "$((d/365))y ago"; fi
}

# leftover paths for an app record -> prints "cache|path" and "data|path"
app_leftovers() {
    local src="$1" id="$2" name="$3"
    local keys=() k p
    case "$src" in
        flatpak) [[ -d "$HOME/.var/app/$id" ]] && echo "data|$HOME/.var/app/$id"; return ;;
        snap)    [[ -d "$HOME/snap/$id" ]] && echo "data|$HOME/snap/$id"; return ;;
    esac
    local base="${id##*/}"; base="${base%.AppImage}"; base="${base%.desktop}"
    keys+=("$base" "$name" "${name// /}" "${name// /-}")
    keys+=("${base,,}" "${name,,}" "${name// /}" "$(tr ' ' '-' <<<"${name,,}")")
    declare -A seen=()
    for k in "${keys[@]}"; do
        [[ -z "$k" || ${#k} -lt 3 ]] && continue
        [[ -n "${seen[$k]:-}" ]] && continue; seen[$k]=1
        p="$HOME/.cache/$k"; [[ -e "$p" ]] && echo "cache|$p"
        for p in "$HOME/.config/$k" "$HOME/.local/share/$k" "$HOME/.local/state/$k" "$HOME/.$k"; do
            [[ -e "$p" ]] && ! is_protected_path "$p" && echo "data|$p"
        done
        p="$HOME/.config/autostart/$k.desktop"; [[ -e "$p" ]] && echo "cache|$p"
    done | sort -u
}

_uninstall_one() {
    local rec="$1" with_data="$2"
    IFS='|' read -r src id name bytes _ extra <<<"$rec"
    local okay=1
    if [[ "$VOLE_DRY_RUN" == "1" ]]; then step "Would remove $name ($src)"; else
    case "$src" in
        apt)    need_sudo && as_root apt-get remove -y "$id" >/dev/null 2>&1 || okay=0 ;;
        dnf|yum) need_sudo && as_root "$src" remove -y "$id" >/dev/null 2>&1 || okay=0 ;;
        zypper) need_sudo && as_root zypper --non-interactive remove "$id" >/dev/null 2>&1 || okay=0 ;;
        pacman) need_sudo && as_root pacman -Rns --noconfirm "$id" >/dev/null 2>&1 || okay=0 ;;
        flatpak)
            if [[ "$extra" == "system" ]]; then flatpak uninstall -y --noninteractive --system "$id" >/dev/null 2>&1 || { need_sudo && as_root flatpak uninstall -y --noninteractive "$id" >/dev/null 2>&1; } || okay=0
            else flatpak uninstall -y --noninteractive --user "$id" >/dev/null 2>&1 || okay=0; fi ;;
        snap)   need_sudo && as_root snap remove "$id" >/dev/null 2>&1 || okay=0 ;;
        appimage) safe_remove "$id" >/dev/null || okay=0 ;;
        local)
            if [[ -n "$extra" && "$extra" != "$id" ]]; then
                if [[ -w "$(dirname "$extra")" ]]; then safe_remove "$extra" >/dev/null || okay=0
                else need_sudo && ! is_protected_path "$extra" && as_root rm -rf --one-file-system -- "$extra" || okay=0; fi
            fi
            safe_remove "$id" >/dev/null || true ;;
    esac
    fi
    if (( okay )); then
        oplog uninstall "$src:$id" "$bytes"
        local kind path
        while IFS='|' read -r kind path; do
            [[ -z "$path" ]] && continue
            [[ "$kind" == data && "$with_data" != "1" ]] && continue
            safe_remove "$path" >/dev/null || true
        done < <(app_leftovers "$src" "$id" "$name")
        ok "Removed $name"
        return 0
    fi
    err "Could not remove $name ($src)"
    return 1
}

cmd_uninstall() {
    VOLE_COMMAND=uninstall
    local a names=()
    for a in "$@"; do
        case "$a" in
            --dry-run|-n) VOLE_DRY_RUN=1 ;;
            --debug) VOLE_DEBUG=1 ;;
            -y|--yes) VOLE_YES=1 ;;
            --list) VOLE_UNINSTALL_LIST=1 ;;
            -h|--help) echo "Usage: vo uninstall [--dry-run] [--list] [app name...]"; return ;;
            -*) die "Unknown option: $a" ;;
            *) names+=("$a") ;;
        esac
    done
    load_whitelist
    title "Uninstall Apps"
    printf '%sScanning installed apps…%s\r' "$C_GRAY" "$C_RESET"
    _apps=()
    collect_pkg_apps; collect_flatpak_apps; collect_snap_apps; collect_appimages; collect_local_launchers
    printf '\033[2K'
    (( ${#_apps[@]} )) || { say "No removable apps found."; return 0; }
    # sort by size desc
    mapfile -t _apps < <(printf '%s\n' "${_apps[@]}" | sort -t'|' -k4,4nr)

    if [[ "${VOLE_UNINSTALL_LIST:-0}" == "1" ]]; then
        local r; for r in "${_apps[@]}"; do IFS='|' read -r s i n b u _ <<<"$r"; printf '%-34.34s %9s  %-9s %s\n' "$n" "$(human "$b")" "$s" "$(_ago "$u")"; done
        return 0
    fi

    VOLE_MENU_LABELS=(); VOLE_MENU_SELECTED=()
    local r
    for r in "${_apps[@]}"; do
        IFS='|' read -r s i n b u _ <<<"$r"
        local sel=0 want
        for want in "${names[@]}"; do [[ "${n,,}" == *"${want,,}"* || "${i,,}" == *"${want,,}"* ]] && sel=1; done
        VOLE_MENU_LABELS+=("$(printf '%-30.30s %9s | %-8s | %s' "$n" "$(human "$b")" "$s" "$(_ago "$u")")")
        VOLE_MENU_SELECTED+=("$sel")
    done
    if (( ${#names[@]} == 0 )) || [[ -t 0 ]]; then
        select_multi "Select Apps to Remove" || { say "Cancelled."; return 0; }
    fi
    local chosen=() i
    for i in "${!_apps[@]}"; do [[ "${VOLE_MENU_SELECTED[$i]}" == "1" ]] && chosen+=("${_apps[$i]}"); done
    (( ${#chosen[@]} )) || { say "Nothing selected."; return 0; }

    local with_data=0
    while true; do
        echo; say "${C_BOLD}Files to be removed:${C_RESET}"; echo
        local total=0 kept=()
        for r in "${chosen[@]}"; do
            IFS='|' read -r s i n b u extra <<<"$r"
            total=$((total + b))
            ok "$n, $(human "$b")  ${C_GRAY}[$s $( [[ $s == appimage || $s == local ]] && echo "${extra:-$i}" || echo "$i")]${C_RESET}"
            local kind path
            while IFS='|' read -r kind path; do
                [[ -z "$path" ]] && continue
                if [[ "$kind" == data && $with_data -eq 0 ]]; then kept+=("$path"); else printf '    %s✓%s %s\n' "$C_GREEN" "$C_RESET" "${path/#$HOME/\~}"; fi
            done < <(app_leftovers "$s" "$i" "$n")
            if [[ "$s" == apt ]]; then
                local extra_rm; extra_rm=$(apt-get -s remove "$i" 2>/dev/null | grep -c '^Remv' || true)
                (( extra_rm > 3 )) && warn "apt would remove $extra_rm packages for $i — review with: apt-get -s remove $i"
            fi
        done
        if (( ${#kept[@]} )); then echo; say "${C_BOLD}Personal data kept:${C_RESET}"; for r in "${kept[@]}"; do say "  ${C_GRAY}${r/#$HOME/\~}${C_RESET}"; done; fi
        echo
        [[ "$VOLE_YES" == "1" || ! -t 0 ]] && break
        local k; k=$(prompt_key "${C_GRAY}Enter remove · D toggle personal data · q cancel${C_RESET} ")
        case "$k" in
            enter) break ;;
            d|D) with_data=$((1 - with_data)) ;;
            *) say "Cancelled."; return 0 ;;
        esac
    done

    local removed=0 freed=0 done_names=()
    for r in "${chosen[@]}"; do
        IFS='|' read -r s i n b _ _ <<<"$r"
        if _uninstall_one "$r" "$with_data"; then removed=$((removed+1)); freed=$((freed+b)); done_names+=("$n"); fi
    done
    echo; rule
    say "${C_BOLD}Uninstall $( [[ $VOLE_DRY_RUN == 1 ]] && echo "preview" || echo "complete")${C_RESET}"
    local joined; joined=$(IFS=,; echo "${done_names[*]}")
    say "Removed $removed app$( ((removed==1)) || echo s), freed $(human "$freed"): ${joined//,/, }"
    rule
}
