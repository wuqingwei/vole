#!/usr/bin/env bash
# vole optimize - bounded maintenance: DNS, font/icon/desktop caches, databases, systemd health, TRIM.

OPT_APPLIED=0; OPT_UNCHANGED=0; OPT_SKIPPED=0; OPT_UNAVAILABLE=0
VOLE_OPT_WL=()

opt_load_whitelist() {
    VOLE_OPT_WL=()
    if [[ -e "$VOLE_OPT_WHITELIST" ]]; then
        [[ -r "$VOLE_OPT_WHITELIST" ]] || die "Optimize whitelist is not readable; refusing to run without it."
        local l; while IFS= read -r l || [[ -n "$l" ]]; do l="${l%%#*}"; l="${l// /}"; [[ -n "$l" ]] && VOLE_OPT_WL+=("$l"); done < "$VOLE_OPT_WHITELIST"
    fi
}
opt_allowed() { local t="$1" w; for w in "${VOLE_OPT_WL[@]}"; do [[ "$t" == "$w" ]] && { skip "$2 · excluded by whitelist"; OPT_SKIPPED=$((OPT_SKIPPED+1)); return 1; }; done; return 0; }

applied()     { step "$*"; OPT_APPLIED=$((OPT_APPLIED+1)); oplog optimize "$*" 0; }
unchanged()   { printf '  %s✓ %s%s\n' "$C_GRAY" "$*" "$C_RESET"; OPT_UNCHANGED=$((OPT_UNCHANGED+1)); }
skipped()     { skip "$*"; OPT_SKIPPED=$((OPT_SKIPPED+1)); }
unavailable() { printf '  %s– %s%s\n' "$C_GRAY" "$*" "$C_RESET"; OPT_UNAVAILABLE=$((OPT_UNAVAILABLE+1)); }

# run_or_dry DESCRIPTION CMD...
run_or_dry() { local d="$1"; shift; if [[ "$VOLE_DRY_RUN" == "1" ]]; then step "$d (dry run)"; OPT_APPLIED=$((OPT_APPLIED+1)); return 0; fi; if "$@" >/dev/null 2>&1; then applied "$d"; else skipped "$d · failed"; return 1; fi; }

opt_header() {
    local mt ma dt du up
    mt=$(awk '/MemTotal/{print $2}' /proc/meminfo); ma=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    read -r dt du < <(df -Pk / | awk 'NR==2{print $2, $3}')
    up=$(awk '{d=int($1/86400); h=int(($1%86400)/3600); if(d>0) printf "%dd", d; else printf "%dh", h}' /proc/uptime)
    printf '%s System  %d/%d GB RAM | %d/%d GB Disk | Uptime %s\n' "$ICON_GEAR" $(( (mt-ma)/1048576 )) $(( mt/1048576 )) $(( du/1048576 )) $(( dt/1048576 )) "$up"
}

opt_diagnose() {
    echo; say "${C_BOLD}PERFORMANCE DIAGNOSIS${C_RESET}"
    local cores load1 load15
    cores=$(nproc 2>/dev/null || echo 1)
    read -r load1 _ load15 _ < /proc/loadavg
    if awk -v l="$load15" -v c="$cores" 'BEGIN{exit !(l > c*1.5)}'; then
        warn "Sustained load $load15 on $cores cores"
        ps -eo pid,comm,%cpu --sort=-%cpu 2>/dev/null | awk 'NR>1 && NR<=4{printf "      %s (%s) %s%% CPU\n",$2,$1,$3}'
    else ok "No sustained high-CPU bottleneck detected (load $load15, $cores cores)"; fi
    local mt ma st sf
    mt=$(awk '/MemTotal/{print $2}' /proc/meminfo); ma=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    st=$(awk '/SwapTotal/{print $2}' /proc/meminfo); sf=$(awk '/SwapFree/{print $2}' /proc/meminfo)
    if (( ma * 10 < mt )); then warn "Memory pressure: only $(( ma/1024 )) MB available"
        ps -eo comm,rss --sort=-rss 2>/dev/null | awk 'NR>1 && NR<=4{printf "      %s %d MB\n",$1,$2/1024}'
    else ok "Memory OK ($(( ma/1024 )) MB available)"; fi
    if (( st > 0 && (st - sf) * 2 > st )); then warn "Swap more than half used ($(( (st-sf)/1024 )) MB)"; fi
    local z; z=$(ps -eo stat 2>/dev/null | grep -c '^Z' || true)
    (( z > 0 )) && warn "$z zombie process(es)"
    local rootuse; rootuse=$(df -P / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    (( rootuse >= 90 )) && warn "Root filesystem ${rootuse}% full — run: vo clean / vo analyze"
    return 0
}

opt_dns() {
    section "DNS & Network"
    opt_allowed dns "DNS cache" || return
    if command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        if [[ "$VOLE_DRY_RUN" == "1" ]]; then step "DNS cache flushed (dry run)"; OPT_APPLIED=$((OPT_APPLIED+1))
        elif resolvectl flush-caches >/dev/null 2>&1 || { need_sudo && as_root resolvectl flush-caches >/dev/null 2>&1; }; then applied "DNS cache flushed (systemd-resolved)"
        else skipped "DNS flush failed"; fi
    elif command -v nscd >/dev/null 2>&1 && pgrep -x nscd >/dev/null; then
        need_sudo && run_or_dry "nscd hosts cache invalidated" as_root nscd -i hosts
    elif pgrep -x dnsmasq >/dev/null 2>&1; then
        need_sudo && run_or_dry "dnsmasq cache cleared" as_root pkill -HUP -x dnsmasq
    else unavailable "No local DNS cache service"; fi
}

opt_desktop_caches() {
    section "Desktop Cache Refresh"
    if opt_allowed fonts "Font cache" && command -v fc-cache >/dev/null 2>&1; then run_or_dry "Font cache rebuilt" fc-cache -f; fi
    if opt_allowed desktop-db "Desktop database" && command -v update-desktop-database >/dev/null 2>&1 && [[ -d "$HOME/.local/share/applications" ]]; then
        run_or_dry "Application menu database refreshed" update-desktop-database "$HOME/.local/share/applications"
    fi
    if opt_allowed mime "MIME database" && command -v update-mime-database >/dev/null 2>&1 && [[ -d "$HOME/.local/share/mime/packages" ]]; then
        run_or_dry "MIME database refreshed" update-mime-database "$HOME/.local/share/mime"
    fi
    if opt_allowed icons "Icon caches" && command -v gtk-update-icon-cache >/dev/null 2>&1; then
        local t n=0
        for t in "$HOME/.local/share/icons"/*/ "$HOME/.icons"/*/; do
            [[ -f "$t/index.theme" ]] || continue
            [[ "$VOLE_DRY_RUN" == "1" ]] || gtk-update-icon-cache -f -q "$t" >/dev/null 2>&1 && n=$((n+1))
        done
        (( n > 0 )) && applied "Icon caches rebuilt ($n themes)" || unchanged "No user icon themes to rebuild"
    fi
    if opt_allowed thumbnails "Failed thumbnails"; then
        if [[ -d "$HOME/.cache/thumbnails/fail" ]] && [[ -n "$(ls -A "$HOME/.cache/thumbnails/fail" 2>/dev/null)" ]]; then
            run_or_dry "Failed thumbnail records reset" rm -rf -- "$HOME/.cache/thumbnails/fail"
        else unchanged "No failed thumbnails"; fi
    fi
    if opt_allowed kde-cache "KDE service cache" && command -v kbuildsycoca6 >/dev/null 2>&1; then run_or_dry "KDE service cache rebuilt" kbuildsycoca6 --noincremental
    elif opt_allowed kde-cache "KDE service cache" && command -v kbuildsycoca5 >/dev/null 2>&1; then run_or_dry "KDE service cache rebuilt" kbuildsycoca5 --noincremental; fi
}

opt_databases() {
    section "Database Optimization"
    opt_allowed sqlite "SQLite vacuum" || return
    command -v sqlite3 >/dev/null 2>&1 || { unavailable "sqlite3 not installed (apt install sqlite3)"; return; }
    local busy=() targets=() f
    pgrep -x -u "$(id -u)" firefox >/dev/null 2>&1 && busy+=("Firefox")
    pgrep -u "$(id -u)" -f 'chrome|chromium' >/dev/null 2>&1 && busy+=("Chrome")
    if (( ${#busy[@]} )); then skipped "Close these apps before database optimization: ${busy[*]}"; return; fi
    while IFS= read -r -d '' f; do targets+=("$f"); done < <(find "$HOME/.mozilla/firefox" "$HOME/snap/firefox/common/.mozilla/firefox" "$HOME/.config/google-chrome" "$HOME/.config/chromium" -maxdepth 3 -type f \( -name 'places.sqlite' -o -name 'cookies.sqlite' -o -name 'favicons.sqlite' -o -name 'formhistory.sqlite' -o -name 'History' -o -name 'Favicons' -o -name 'Web Data' \) -print0 2>/dev/null)
    (( ${#targets[@]} )) || { unchanged "No browser databases found"; return; }
    local before after n=0
    before=0; for f in "${targets[@]}"; do before=$((before + $(stat -c %s "$f"))); done
    if [[ "$VOLE_DRY_RUN" == "1" ]]; then step "Would vacuum ${#targets[@]} browser databases"; OPT_APPLIED=$((OPT_APPLIED+1)); return; fi
    for f in "${targets[@]}"; do
        if [[ "$(sqlite3 "$f" 'PRAGMA integrity_check;' 2>/dev/null | head -1)" == "ok" ]]; then
            sqlite3 "$f" 'VACUUM; REINDEX;' >/dev/null 2>&1 && n=$((n+1))
        fi
    done
    after=0; for f in "${targets[@]}"; do after=$((after + $(stat -c %s "$f"))); done
    applied "Vacuumed $n browser databases (saved $(human $((before-after > 0 ? before-after : 0))))"
}

opt_systemd() {
    section "Services"
    command -v systemctl >/dev/null 2>&1 || { unavailable "systemd not present"; return; }
    if opt_allowed failed-units "Failed units"; then
        local fu fs
        fu=$(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
        fs=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
        if [[ -n "$fs" ]]; then warn "Failed system units: $(tr '\n' ' ' <<<"$fs")"; say "      inspect: systemctl status <unit>"; fi
        if [[ -n "$fu" ]]; then run_or_dry "Reset failed user units: $(tr '\n' ' ' <<<"$fu")" systemctl --user reset-failed
        elif [[ -z "$fs" ]]; then unchanged "No failed services"; fi
    fi
    if opt_allowed boot "Boot time"; then
        local bt; bt=$(systemd-analyze 2>/dev/null | head -1 | sed 's/^Startup finished in //')
        [[ -n "$bt" ]] && say "  ${C_GRAY}Boot: $bt${C_RESET}"
        local slow; slow=$(systemd-analyze blame 2>/dev/null | head -3 | awk '{$1=$1; print}' | paste -sd ',' -)
        [[ -n "$slow" ]] && say "  ${C_GRAY}Slowest units: ${slow//,/, }${C_RESET}"
    fi
}

opt_storage() {
    section "Disk Health"
    if opt_allowed trim "SSD TRIM"; then
        if systemctl is-enabled --quiet fstrim.timer 2>/dev/null; then unchanged "Periodic TRIM enabled (fstrim.timer)"
        elif command -v fstrim >/dev/null 2>&1; then
            if [[ "${VOLE_ENABLE_TRIM:-0}" == "1" ]]; then need_sudo && run_or_dry "TRIM run on all mounted filesystems" as_root fstrim -av
            else skipped "fstrim.timer disabled (enable: sudo systemctl enable --now fstrim.timer, or VOLE_ENABLE_TRIM=1)"; fi
        else unavailable "fstrim not available"; fi
    fi
    if opt_allowed smart "SMART"; then
        if [[ "${VOLE_ENABLE_DISK_VERIFY:-0}" == "1" ]] && command -v smartctl >/dev/null 2>&1 && need_sudo; then
            local d
            for d in $(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
                local h; h=$(as_root smartctl -H "/dev/$d" 2>/dev/null | awk -F: '/overall-health|SMART Health Status/{gsub(/^ +/,"",$2); print $2}')
                [[ -n "$h" ]] && step "/dev/$d SMART: $h"
            done
        else skipped "Disk verify skipped (set VOLE_ENABLE_DISK_VERIFY=1 with smartctl installed)"; fi
    fi
    if opt_allowed journal "Journal size" && command -v journalctl >/dev/null 2>&1; then
        local js; js=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1)
        [[ -n "$js" ]] && unchanged "Journal uses $js (vo clean vacuums it)"
    fi
}

opt_memory() {
    section "Memory"
    opt_allowed swap "Swap refresh" || return
    local st sf ma
    st=$(awk '/SwapTotal/{print $2}' /proc/meminfo); sf=$(awk '/SwapFree/{print $2}' /proc/meminfo); ma=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    local used=$(( st - sf ))
    if (( st == 0 )); then unavailable "No swap configured"; return; fi
    if (( used < 262144 )); then unchanged "Swap usage low ($(( used/1024 )) MB)"; return; fi
    if (( ma > used * 2 )) && [[ "${VOLE_ENABLE_SWAP_REFRESH:-0}" == "1" ]]; then
        need_sudo && run_or_dry "Swap refreshed ($(( used/1024 )) MB moved back to RAM)" bash -c "sudo swapoff -a && sudo swapon -a"
    else skipped "Swap holds $(( used/1024 )) MB (set VOLE_ENABLE_SWAP_REFRESH=1 to move it back to RAM when there is room)"; fi
}

opt_whitelist_menu() {
    mkdir -p "$VOLE_CONFIG_DIR"
    local ids=(dns fonts desktop-db mime icons thumbnails kde-cache sqlite failed-units boot trim smart journal swap)
    opt_load_whitelist
    VOLE_MENU_LABELS=("${ids[@]}"); VOLE_MENU_SELECTED=()
    local i w s; for i in "${ids[@]}"; do s=0; for w in "${VOLE_OPT_WL[@]}"; do [[ "$w" == "$i" ]] && s=1; done; VOLE_MENU_SELECTED+=("$s"); done
    select_multi "Exclude optimization tasks" || { say "Cancelled."; return; }
    { echo "# Vole optimize whitelist: task ids to skip"; for i in "${!ids[@]}"; do [[ "${VOLE_MENU_SELECTED[$i]}" == 1 ]] && echo "${ids[$i]}"; done; } > "$VOLE_OPT_WHITELIST"
    ok "Saved to ${VOLE_OPT_WHITELIST/#$HOME/\~}"
}

cmd_optimize() {
    VOLE_COMMAND=optimize
    local a
    for a in "$@"; do
        case "$a" in
            --dry-run|-n) VOLE_DRY_RUN=1 ;; --debug) VOLE_DEBUG=1 ;; -y|--yes) VOLE_YES=1 ;;
            --whitelist) opt_whitelist_menu; return ;;
            -h|--help) echo "Usage: vo optimize [--dry-run] [--whitelist]"; return ;;
            *) die "Unknown option: $a" ;;
        esac
    done
    opt_load_whitelist
    title "Optimize$( [[ "$VOLE_DRY_RUN" == "1" ]] && printf '  %s(dry run)%s' "$C_YELLOW" "$C_RESET")"
    opt_header
    opt_diagnose
    opt_dns; opt_desktop_caches; opt_databases; opt_systemd; opt_memory; opt_storage
    echo; rule
    say "${C_BOLD}Optimization Complete${C_RESET}"
    say "Applied $OPT_APPLIED optimization$( ((OPT_APPLIED==1)) || echo s)"
    say "$OPT_UNCHANGED unchanged | $OPT_SKIPPED skipped | $OPT_UNAVAILABLE unavailable"
    rule
}
