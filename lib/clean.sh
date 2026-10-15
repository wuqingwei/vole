#!/usr/bin/env bash
# vole clean - deep cleanup of caches, logs, trash, developer caches, package caches and leftovers.

# clean_target LABEL PATH [PROCESS_NAME]  -> cleans contents of a cache dir, reports a line
clean_target() {
    local label="$1" dir="$2" proc="${3:-}"
    [[ -d "$dir" ]] || return 1
    if is_whitelisted "$dir"; then skip "$label · protected by whitelist"; return 1; fi
    if [[ -n "$proc" ]] && pgrep -x -u "$(id -u)" "$proc" >/dev/null 2>&1; then
        skip "$label · skipped ($proc running)"; return 1
    fi
    local r items bytes
    r=$(clean_dir_contents "$dir"); items=${r% *}; bytes=${r#* }
    report_line "$label" "$items" "$bytes"
    VOLE_CLEANED_DIRS+=("$dir")
}

# clean_glob LABEL GLOB... -> remove matching paths
clean_paths() {
    local label="$1"; shift
    local items=0 bytes=0 p b
    for p in "$@"; do
        [[ -e "$p" || -L "$p" ]] || continue
        is_whitelisted "$p" && continue
        b=$(safe_remove "$p") || true
        items=$((items+1)); bytes=$((bytes + ${b:-0}))
    done
    report_line "$label" "$items" "$bytes"
}

# run_tool_clean LABEL BINARY CMD... -> runs a tool's own cache cleaner and measures DIR delta
run_tool_clean() {
    local label="$1" bin="$2" dir="$3"; shift 3
    command -v "$bin" >/dev/null 2>&1 || return 1
    [[ -n "$dir" && ! -d "$dir" ]] && return 1
    if [[ -n "$dir" ]] && is_whitelisted "$dir"; then skip "$label · protected by whitelist"; return 1; fi
    local before after
    before=$( [[ -n "$dir" ]] && path_bytes "$dir" || echo 0 )
    if (( before == 0 )) && [[ -n "$dir" ]]; then return 1; fi
    if [[ "$VOLE_DRY_RUN" == "1" ]]; then
        report_line "$label" 1 "$before"; return 0
    fi
    if timeout 300 "$@" >/dev/null 2>&1; then
        after=$( [[ -n "$dir" ]] && path_bytes "$dir" || echo 0 )
        local freed=$(( before - after )); (( freed < 0 )) && freed=0
        oplog tool-clean "$label" "$freed"
        if (( freed > 0 )); then report_line "$label" 1 "$freed"; else ok "$label · cleaned"; fi
        VOLE_CLEANED_DIRS+=("$dir")
    else
        skip "$label · skipped ($bin busy or failed)"
    fi
}

clean_user_essentials() {
    section "User essentials"
    local any=0
    # Thumbnails
    clean_target "Thumbnail cache" "$HOME/.cache/thumbnails" && any=1
    [[ -d "$HOME/.thumbnails" ]] && clean_target "Legacy thumbnails" "$HOME/.thumbnails" && any=1
    # Old session logs
    clean_paths "Session error logs" "$HOME/.xsession-errors.old" "$HOME/.local/share/xorg/"*.old && any=1
    # Old core dumps in home
    local cores=()
    while IFS= read -r -d '' f; do cores+=("$f"); done < <(find "$HOME" -maxdepth 1 -type f -name 'core.[0-9]*' -print0 2>/dev/null)
    (( ${#cores[@]} )) && clean_paths "Core dumps in home" "${cores[@]}" && any=1
    # Trash
    if whitelist_has "trash" || whitelist_has "Trash"; then
        skip "Trash · kept (whitelisted)"
    elif [[ -d "$VOLE_TRASH_DIR" ]]; then
        local r1 r2
        r1=$(clean_dir_contents "$VOLE_TRASH_DIR/files")
        r2=$(clean_dir_contents "$VOLE_TRASH_DIR/info")
        clean_dir_contents "$VOLE_TRASH_DIR/expunged" >/dev/null
        rm -f "$VOLE_TRASH_DIR/directorysizes" 2>/dev/null || true
        report_line "Trash · emptied" "${r1% *}" "$(( ${r1#* } + ${r2#* } ))" && any=1
    fi
    (( any )) || skip "Nothing to clean"
}

clean_browsers() {
    section "Browsers"
    local any=0 d
    clean_target "Chrome cache"   "$HOME/.cache/google-chrome" chrome && any=1
    clean_target "Chromium cache" "$HOME/.cache/chromium" chromium && any=1
    clean_target "Edge cache"     "$HOME/.cache/microsoft-edge" msedge && any=1
    clean_target "Brave cache"    "$HOME/.cache/BraveSoftware" brave && any=1
    clean_target "Vivaldi cache"  "$HOME/.cache/vivaldi" vivaldi-bin && any=1
    clean_target "Opera cache"    "$HOME/.cache/opera" opera && any=1
    clean_target "Firefox cache"  "$HOME/.cache/mozilla" firefox && any=1
    clean_target "Firefox cache (snap)" "$HOME/snap/firefox/common/.cache" firefox && any=1
    # Chromium-family code/GPU caches inside profiles (safe to rebuild)
    local extra=()
    for d in "$HOME/.config/google-chrome" "$HOME/.config/chromium" "$HOME/.config/microsoft-edge" "$HOME/.config/BraveSoftware/Brave-Browser"; do
        [[ -d "$d" ]] || continue
        while IFS= read -r -d '' c; do extra+=("$c"); done < <(find "$d" -maxdepth 3 -type d \( -name GPUCache -o -name 'Code Cache' -o -name GrShaderCache -o -name ShaderCache -o -name DawnCache \) -print0 2>/dev/null)
    done
    if (( ${#extra[@]} )); then
        if pgrep -u "$(id -u)" -f 'chrome|chromium|msedge|brave' >/dev/null 2>&1; then
            skip "Browser shader & code caches · skipped (browser running)"
        else
            clean_paths "Browser shader & code caches" "${extra[@]}" && any=1
        fi
    fi
    (( any )) || skip "Nothing to clean"
}

clean_app_caches() {
    section "App caches"
    local any=0
    clean_target "VS Code cache" "$HOME/.config/Code/Cache" code && any=1
    clean_target "VS Code cached data" "$HOME/.config/Code/CachedData" code && any=1
    clean_target "VS Code extension VSIX cache" "$HOME/.config/Code/CachedExtensionVSIXs" code && any=1
    clean_target "Cursor cache" "$HOME/.config/Cursor/Cache" cursor && any=1
    clean_target "Cursor cached data" "$HOME/.config/Cursor/CachedData" cursor && any=1
    clean_target "Slack cache" "$HOME/.config/Slack/Cache" slack && any=1
    clean_target "Discord cache" "$HOME/.config/discord/Cache" Discord && any=1
    clean_target "Spotify cache" "$HOME/.cache/spotify" spotify && any=1
    clean_target "WeChat (wine) cache" "$HOME/.cache/wechat" && any=1
    clean_target "Steam HTML cache" "$HOME/.steam/steam/config/htmlcache" steam && any=1
    clean_target "Mesa shader cache" "$HOME/.cache/mesa_shader_cache" && any=1
    clean_target "NVIDIA GL cache" "$HOME/.cache/nvidia" && any=1
    clean_target "fontconfig cache" "$HOME/.cache/fontconfig" && any=1
    clean_target "Qt shader cache" "$HOME/.cache/qtshadercache" && any=1
    # Everything else directly under ~/.cache that has not been touched for 30 days
    local stale=() e
    while IFS= read -r -d '' e; do
        local seen=0 c
        for c in "${VOLE_CLEANED_DIRS[@]}"; do [[ "$e" == "$c" || "$c" == "$e"/* ]] && { seen=1; break; }; done
        (( seen )) && continue
        is_whitelisted "$e" && continue
        # skip if anything inside was modified recently
        if [[ -d "$e" ]] && [[ -n "$(find "$e" -mindepth 1 -mtime -30 -print -quit 2>/dev/null)" ]]; then continue; fi
        stale+=("$e")
    done < <(find "$HOME/.cache" -mindepth 1 -maxdepth 1 -mtime +30 -print0 2>/dev/null)
    (( ${#stale[@]} )) && clean_paths "Unused user caches (30d+)" "${stale[@]}" && any=1
    (( any )) || skip "Nothing to clean"
}

clean_dev_tools() {
    section "Developer tools"
    local any=0
    run_tool_clean "npm cache"  npm  "$HOME/.npm/_cacache" npm cache clean --force && any=1
    run_tool_clean "pnpm store" pnpm "${PNPM_HOME:-$HOME/.local/share/pnpm}/store" pnpm store prune && any=1
    run_tool_clean "Yarn cache" yarn "$HOME/.cache/yarn" yarn cache clean && any=1
    run_tool_clean "Bun cache"  bun  "$HOME/.bun/install/cache" bun pm cache rm && any=1
    run_tool_clean "pip cache"  pip3 "$HOME/.cache/pip" pip3 cache purge && any=1
    run_tool_clean "uv cache"   uv   "$HOME/.cache/uv" uv cache clean && any=1
    run_tool_clean "Go build cache" go "$HOME/.cache/go-build" go clean -cache && any=1
    run_tool_clean "Conda packages" conda "" conda clean -a -y && any=1
    run_tool_clean "Composer cache" composer "$HOME/.cache/composer" composer clear-cache && any=1
    run_tool_clean "ccache" ccache "$HOME/.cache/ccache" ccache -C && any=1
    clean_target "Cargo registry cache" "$HOME/.cargo/registry/cache" cargo && any=1
    clean_target "Cargo git checkouts" "$HOME/.cargo/git/checkouts" cargo && any=1
    clean_target "Gradle build cache" "$HOME/.gradle/caches/build-cache-1" java && any=1
    clean_target "Gradle daemon logs" "$HOME/.gradle/daemon" java && any=1
    clean_target "node-gyp headers" "$HOME/.cache/node-gyp" && any=1
    clean_target "Electron download cache" "$HOME/.cache/electron" && any=1
    clean_target "Bazel cache" "$HOME/.cache/bazel" bazel && any=1
    # Xilinx / AMD tools leave big logs and journals in home
    local xil=()
    while IFS= read -r -d '' f; do xil+=("$f"); done < <(find "$HOME" -maxdepth 1 -type f \( -name 'vivado*.jou' -o -name 'vivado*.log' -o -name 'vivado_pid*.str' -o -name 'webtalk*.jou' -o -name 'webtalk*.log' -o -name 'xsim*.log' \) -mtime +1 -print0 2>/dev/null)
    [[ -d "$HOME/.Xil" ]] && xil+=("$HOME/.Xil")
    (( ${#xil[@]} )) && { pgrep -u "$(id -u)" -f vivado >/dev/null 2>&1 && skip "Vivado logs & .Xil · skipped (Vivado running)" || { clean_paths "Vivado logs & .Xil" "${xil[@]}" && any=1; }; }
    if command -v docker >/dev/null 2>&1 && [[ "${VOLE_CLEAN_DOCKER:-0}" == "1" ]]; then
        if [[ "$VOLE_DRY_RUN" == "1" ]]; then step "Docker builder cache · would prune"
        elif docker builder prune -f >/dev/null 2>&1; then ok "Docker builder cache · pruned"; oplog tool-clean "docker builder prune" 0; any=1; fi
    fi
    (( any )) || skip "Nothing to clean"
}

clean_leftovers() {
    section "Leftovers of removed apps"
    local any=0 d id
    # Flatpak app data whose app is no longer installed
    if [[ -d "$HOME/.var/app" ]]; then
        local installed="" orphans=()
        command -v flatpak >/dev/null 2>&1 && installed=$(flatpak list --app --columns=application 2>/dev/null)
        for d in "$HOME/.var/app"/*/; do
            [[ -d "$d" ]] || continue
            id=$(basename "$d")
            grep -qxF "$id" <<<"$installed" || orphans+=("${d%/}")
        done
        if (( ${#orphans[@]} )); then clean_paths "Flatpak data of removed apps" "${orphans[@]}" && any=1; fi
    fi
    # Snap data whose snap is no longer installed
    if [[ -d "$HOME/snap" ]]; then
        local snaps="" sorph=()
        command -v snap >/dev/null 2>&1 && snaps=$(snap list 2>/dev/null | awk 'NR>1{print $1}')
        if command -v snap >/dev/null 2>&1; then
            for d in "$HOME/snap"/*/; do
                [[ -d "$d" ]] || continue
                id=$(basename "$d")
                grep -qxF "$id" <<<"$snaps" || sorph+=("${d%/}")
            done
        fi
        (( ${#sorph[@]} )) && clean_paths "Snap data of removed snaps" "${sorph[@]}" && any=1
    fi
    # Broken desktop entries / autostart pointing to binaries that no longer exist
    local broken=() f exe
    for f in "$HOME/.local/share/applications"/*.desktop "$HOME/.config/autostart"/*.desktop; do
        [[ -f "$f" ]] || continue
        exe=$(awk -F= '/^Exec=/{print $2; exit}' "$f" | awk '{print $1}' | tr -d '"')
        [[ -z "$exe" ]] && continue
        case "$exe" in env|sh|bash|flatpak|snap|wine|/usr/bin/env) continue ;; esac
        if [[ "$exe" == /* ]]; then [[ -e "$exe" ]] || broken+=("$f")
        else command -v "$exe" >/dev/null 2>&1 || broken+=("$f"); fi
    done
    (( ${#broken[@]} )) && clean_paths "Broken launchers (app gone)" "${broken[@]}" && any=1
    (( any )) || skip "Nothing to clean"
}

clean_system() {
    section "System"
    if [[ "${VOLE_SKIP_SYSTEM:-0}" == "1" ]]; then skip "System cleanup skipped (--user-only)"; return; fi
    if [[ "$VOLE_DRY_RUN" != "1" ]] && ! need_sudo; then skip "System items · skipped (no administrator access)"; return; fi
    local pm; pm=$(detect_pkg_manager)
    local before after freed
    _sys_measure() { as_root du -skx "$@" 2>/dev/null | awk '{s+=$1} END{print (s+0)*1024}'; }
    _sys_measure_dry() { du -skx "$@" 2>/dev/null | awk '{s+=$1} END{print (s+0)*1024}'; }
    local m=_sys_measure; [[ "$VOLE_DRY_RUN" == "1" ]] && ! sudo -n true 2>/dev/null && [[ $EUID -ne 0 ]] && m=_sys_measure_dry

    case "$pm" in
        apt)
            before=$($m /var/cache/apt/archives)
            if [[ "$VOLE_DRY_RUN" == "1" ]]; then report_line "APT package cache" 1 "$before"
            else as_root apt-get clean >/dev/null 2>&1 && { after=$($m /var/cache/apt/archives); freed=$((before-after)); oplog sys-clean "apt-get clean" "$freed"; report_line "APT package cache" 1 "$freed" || ok "APT package cache · already clean"; }; fi ;;
        dnf|yum)
            before=$($m /var/cache/dnf /var/cache/yum)
            if [[ "$VOLE_DRY_RUN" == "1" ]]; then report_line "${pm^^} package cache" 1 "$before"
            else as_root "$pm" clean all >/dev/null 2>&1 && { after=$($m /var/cache/dnf /var/cache/yum); freed=$((before-after)); oplog sys-clean "$pm clean all" "$freed"; report_line "${pm^^} package cache" 1 "$freed" || ok "${pm^^} cache · already clean"; }; fi ;;
        pacman)
            before=$($m /var/cache/pacman/pkg)
            if [[ "$VOLE_DRY_RUN" == "1" ]]; then report_line "Pacman package cache (keeps 2 versions)" 1 "$before"
            else
                if command -v paccache >/dev/null 2>&1; then as_root paccache -rk2 >/dev/null 2>&1; as_root paccache -ruk0 >/dev/null 2>&1
                else yes | as_root pacman -Sc >/dev/null 2>&1; fi
                after=$($m /var/cache/pacman/pkg); freed=$((before-after)); oplog sys-clean "pacman cache" "$freed"
                report_line "Pacman package cache" 1 "$freed" || ok "Pacman cache · already clean"
            fi ;;
        zypper)
            before=$($m /var/cache/zypp/packages)
            if [[ "$VOLE_DRY_RUN" == "1" ]]; then report_line "Zypper package cache" 1 "$before"
            else as_root zypper --non-interactive clean --all >/dev/null 2>&1; after=$($m /var/cache/zypp/packages); freed=$((before-after)); oplog sys-clean "zypper clean" "$freed"; report_line "Zypper package cache" 1 "$freed" || ok "Zypper cache · already clean"; fi ;;
        apk)
            if [[ "$VOLE_DRY_RUN" != "1" ]]; then as_root apk cache clean >/dev/null 2>&1 && ok "apk cache · cleaned"; fi ;;
    esac

    # systemd journal: keep the last 2 weeks / 500M
    if command -v journalctl >/dev/null 2>&1; then
        local jdir=/var/log/journal; [[ -d $jdir ]] || jdir=/run/log/journal
        before=$($m "$jdir")
        if [[ "$VOLE_DRY_RUN" == "1" ]]; then (( before > 0 )) && step "Journal logs · would vacuum to 14 days / 500M (now $(human "$before"))"
        else
            as_root journalctl --vacuum-time=14d --vacuum-size=500M >/dev/null 2>&1
            after=$($m "$jdir"); freed=$((before-after)); (( freed < 0 )) && freed=0
            oplog sys-clean "journal vacuum" "$freed"
            report_line "Journal logs (older than 14d)" 1 "$freed" || ok "Journal logs · within limits ($(human "$after"))"
        fi
    fi

    # Rotated logs older than 14 days
    local rotated=()
    while IFS= read -r -d '' f; do rotated+=("$f"); done < <(find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' -o -name '*.xz' \) -mtime +14 -print0 2>/dev/null)
    if (( ${#rotated[@]} )); then
        before=$($m "${rotated[@]}")
        if [[ "$VOLE_DRY_RUN" == "1" ]]; then report_line "Rotated system logs (14d+)" "${#rotated[@]}" "$before"
        else as_root rm -f -- "${rotated[@]}" && { oplog sys-clean "rotated logs" "$before"; report_line "Rotated system logs (14d+)" "${#rotated[@]}" "$before"; }; fi
    fi

    # Crash reports
    if [[ -d /var/crash ]] && [[ -n "$(ls -A /var/crash 2>/dev/null)" ]]; then
        before=$($m /var/crash)
        if [[ "$VOLE_DRY_RUN" == "1" ]]; then report_line "Crash reports" 1 "$before"
        else as_root find /var/crash -mindepth 1 -maxdepth 1 -type f -delete 2>/dev/null; oplog sys-clean "/var/crash" "$before"; report_line "Crash reports" 1 "$before"; fi
    fi
    if command -v coredumpctl >/dev/null 2>&1 && [[ -d /var/lib/systemd/coredump ]]; then
        before=$($m /var/lib/systemd/coredump)
        if (( before > 0 )); then
            if [[ "$VOLE_DRY_RUN" == "1" ]]; then report_line "systemd core dumps" 1 "$before"
            else as_root find /var/lib/systemd/coredump -mindepth 1 -type f -delete 2>/dev/null; oplog sys-clean "coredumps" "$before"; report_line "systemd core dumps" 1 "$before"; fi
        fi
    fi

    # Old snap revisions
    if command -v snap >/dev/null 2>&1; then
        local revs; revs=$(LANG=C snap list --all 2>/dev/null | awk '/disabled/{print $1" "$3}')
        if [[ -n "$revs" ]]; then
            local n; n=$(wc -l <<<"$revs")
            if [[ "$VOLE_DRY_RUN" == "1" ]]; then step "Old snap revisions · would remove $n"
            else
                before=$($m /var/lib/snapd/snaps)
                while read -r name rev; do as_root snap remove "$name" --revision="$rev" >/dev/null 2>&1; done <<<"$revs"
                after=$($m /var/lib/snapd/snaps); freed=$((before-after)); oplog sys-clean "snap revisions" "$freed"
                report_line "Old snap revisions" "$n" "$freed"
            fi
        fi
    fi
    # Unused flatpak runtimes
    if command -v flatpak >/dev/null 2>&1; then
        local unused; unused=$(flatpak uninstall --unused --noninteractive --assumeno 2>/dev/null | grep -cE '^\s*[0-9]+\.' || true)
        if [[ "$VOLE_DRY_RUN" == "1" ]]; then (( unused > 0 )) && step "Unused Flatpak runtimes · would remove $unused"
        else
            before=$(path_bytes "$HOME/.local/share/flatpak"); local sb; sb=$($m /var/lib/flatpak)
            flatpak uninstall --unused -y --noninteractive >/dev/null 2>&1
            as_root flatpak uninstall --unused -y --noninteractive >/dev/null 2>&1
            after=$(path_bytes "$HOME/.local/share/flatpak"); local sa; sa=$($m /var/lib/flatpak)
            freed=$(( before - after + sb - sa )); (( freed < 0 )) && freed=0
            oplog sys-clean "flatpak unused" "$freed"
            report_line "Unused Flatpak runtimes" 1 "$freed" || ok "Flatpak runtimes · nothing unused"
        fi
    fi
    unset -f _sys_measure _sys_measure_dry
}

clean_whitelist_menu() {
    mkdir -p "$VOLE_CONFIG_DIR"
    local opts=(
        "$HOME/.cache/huggingface|Hugging Face models"
        "$HOME/.cache/torch|PyTorch hub models"
        "$HOME/.cache/ms-playwright|Playwright browsers"
        "$HOME/.cache/JetBrains|JetBrains IDE caches"
        "$HOME/.cache/pip|pip cache"
        "$HOME/.cache/go-build|Go build cache"
        "$HOME/.npm/_cacache|npm cache"
        "$HOME/.cargo/registry/cache|Cargo registry cache"
        "$HOME/.cache/mozilla|Firefox cache"
        "$HOME/.cache/google-chrome|Chrome cache"
        "$HOME/.Xil|Vivado .Xil"
        "trash|Trash (do not empty)"
    )
    load_whitelist
    VOLE_MENU_LABELS=(); VOLE_MENU_SELECTED=()
    local o
    for o in "${opts[@]}"; do
        VOLE_MENU_LABELS+=("${o#*|}  ${C_GRAY}${o%%|*}${C_RESET}")
        whitelist_has "${o%%|*}" && VOLE_MENU_SELECTED+=(1) || VOLE_MENU_SELECTED+=(0)
    done
    select_multi "Protect from cleanup" || { say "Cancelled."; return 0; }
    local custom=()
    if [[ -f "$VOLE_WHITELIST" ]]; then
        local line known
        while IFS= read -r line; do
            known=0; for o in "${opts[@]}"; do [[ "${line/#\~/$HOME}" == "${o%%|*}" ]] && known=1; done
            [[ $known -eq 0 && -n "$line" ]] && custom+=("$line")
        done < "$VOLE_WHITELIST"
    fi
    {
        echo "# Vole whitelist: one path or glob per line. 'trash' keeps the Trash."
        local i; for i in "${!opts[@]}"; do [[ "${VOLE_MENU_SELECTED[$i]}" == "1" ]] && echo "${opts[$i]%%|*}" | sed "s#^$HOME#~#"; done
        for line in "${custom[@]}"; do [[ "$line" == \#* ]] || echo "$line"; done
    } > "$VOLE_WHITELIST"
    ok "Saved to ${VOLE_WHITELIST/#$HOME/\~}"
}

cmd_clean() {
    VOLE_COMMAND=clean
    local a
    for a in "$@"; do
        case "$a" in
            --dry-run|-n) VOLE_DRY_RUN=1 ;;
            --debug) VOLE_DEBUG=1 ;;
            --whitelist) clean_whitelist_menu; return ;;
            --user-only) VOLE_SKIP_SYSTEM=1 ;;
            --docker) VOLE_CLEAN_DOCKER=1 ;;
            -y|--yes) VOLE_YES=1 ;;
            -h|--help) cat <<EOF
Usage: vo clean [--dry-run] [--debug] [--user-only] [--docker] [--whitelist]
  --dry-run    Show what would be removed, change nothing
  --user-only  Skip system items that need sudo
  --docker     Also prune Docker builder cache
  --whitelist  Choose caches to protect (~/.config/vole/whitelist)
EOF
                return ;;
            *) die "Unknown option: $a" ;;
        esac
    done
    load_whitelist
    VOLE_CLEANED_DIRS=()
    local free_before; free_before=$(free_bytes "$HOME")
    title "Clean Your Linux${VOLE_DRY_RUN:+}$( [[ "$VOLE_DRY_RUN" == "1" ]] && printf '  %s(dry run)%s' "$C_YELLOW" "$C_RESET")"
    printf '%s %s | %s | Free space: %s\n' "$ICON_GEAR" "$(distro_name)" "$(uname -m)" "$(human "$free_before")"
    oplog run-start "clean" 0
    local cats=0
    clean_user_essentials; clean_browsers; clean_app_caches; clean_dev_tools; clean_leftovers; clean_system
    oplog run-end "clean" "$VOLE_TOTAL_BYTES"
    local free_after; free_after=$(free_bytes "$HOME")
    local delta=$(( free_after - free_before )); (( delta < 0 )) && delta=0
    echo; rule
    if [[ "$VOLE_DRY_RUN" == "1" ]]; then
        say "${C_BOLD}Dry run complete${C_RESET} — nothing was removed"
        say "Would free: $(human "$VOLE_TOTAL_BYTES") | Items: $VOLE_TOTAL_ITEMS"
    else
        say "${C_BOLD}Cleanup complete${C_RESET}"
        say "Tracked cleanup: $(human "$VOLE_TOTAL_BYTES") | Items cleaned: $VOLE_TOTAL_ITEMS"
        say "Free space: $(human "$free_after") (+$(human "$delta"))"
    fi
    rule
}
