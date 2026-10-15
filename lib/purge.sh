#!/usr/bin/env bash
# vole purge - find and delete rebuildable project artifacts (node_modules, target, build, .venv, ...).

PURGE_DEFAULT_ROOTS=(Projects projects GitHub github dev Dev code Code src workspace Workspace work repos git Documents/GitHub Documents/Projects)
PURGE_MAX_DEPTH=6

# Directory names that are always artifacts when found inside a project
PURGE_ALWAYS=(node_modules .next .nuxt .svelte-kit .turbo .parcel-cache .angular .expo __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .nox .gradle .dart_tool .zig-cache zig-cache zig-out .Xil .cache-loader .eslintcache)
# Names that are artifacts only next to a matching build file
#   name:marker1,marker2,...
PURGE_CONDITIONAL=(
    "target:Cargo.toml,pom.xml,build.sbt,project.clj"
    "build:package.json,CMakeLists.txt,build.gradle,build.gradle.kts,setup.py,pyproject.toml,meson.build,pubspec.yaml,Makefile.am,configure.ac"
    "dist:package.json,setup.py,pyproject.toml,vite.config.ts,vite.config.js"
    "out:package.json,next.config.js,next.config.mjs,build.gradle"
    ".build:Package.swift"
    "vendor/bundle:Gemfile"
    ".venv:pyproject.toml,requirements.txt,setup.py,Pipfile,poetry.lock,uv.lock"
    "venv:pyproject.toml,requirements.txt,setup.py,Pipfile"
    "_build:mix.exs,dune-project,conf.py"
    "deps:mix.exs"
    "obj:*.csproj,*.fsproj,*.sln"
    "bin:*.csproj,*.fsproj"
    ".cxx:build.gradle,build.gradle.kts"
)

purge_roots() {
    PURGE_ROOTS=()
    if [[ -f "$VOLE_PURGE_PATHS" ]]; then
        local l; while IFS= read -r l || [[ -n "$l" ]]; do l="${l%%#*}"; l="${l%"${l##*[![:space:]]}"}"; [[ -z "$l" ]] && continue; l="${l/#\~/$HOME}"; [[ -d "$l" ]] && PURGE_ROOTS+=("$l"); done < "$VOLE_PURGE_PATHS"
    fi
    if (( ${#PURGE_ROOTS[@]} == 0 )); then
        local r; for r in "${PURGE_DEFAULT_ROOTS[@]}"; do [[ -d "$HOME/$r" ]] && PURGE_ROOTS+=("$HOME/$r"); done
    fi
}

_has_marker() {
    local dir="$1" markers="$2" m
    IFS=',' read -ra ms <<<"$markers"
    for m in "${ms[@]}"; do compgen -G "$dir/$m" >/dev/null && return 0; done
    return 1
}

# is_artifact PATH -> 0 if PATH is a rebuildable artifact
is_artifact() {
    local p="$1" name parent n e
    name=$(basename "$p"); parent=$(dirname "$p")
    for n in "${PURGE_ALWAYS[@]}"; do [[ "$name" == "$n" ]] && return 0; done
    for e in "${PURGE_CONDITIONAL[@]}"; do
        n=${e%%:*}
        if [[ "$n" == */* ]]; then [[ "$p" == */"$n" ]] && _has_marker "${p%/"$n"}" "${e#*:}" && return 0
        elif [[ "$name" == "$n" ]]; then _has_marker "$parent" "${e#*:}" && return 0; fi
    done
    # CMake / Qt Creator shadow builds: cmake-build-*, build-<proj>-Desktop_Qt_*
    if [[ "$name" == cmake-build-* || "$name" == build-*-Desktop* || "$name" == build-*-Qt_* ]]; then
        [[ -f "$p/CMakeCache.txt" || -f "$p/Makefile" || -f "$p/build.ninja" || -f "$p/.qmake.stash" ]] && return 0
    fi
    # Vivado: <proj>.cache / <proj>.hw / <proj>.ip_user_files next to <proj>.xpr
    if [[ "$name" == *.cache || "$name" == *.ip_user_files ]] && [[ -f "$parent/${name%.*}.xpr" ]]; then return 0; fi
    return 1
}

# Protection: refuse artifacts containing git-tracked files, nested repos, or key material.
artifact_protected() {
    local p="$1"
    [[ -L "$p" ]] && { echo "symlink"; return 0; }
    if [[ -n "$(find "$p" -maxdepth 2 -name .git -print -quit 2>/dev/null)" ]] ||
       [[ -n "$(find "$p" -maxdepth 1 \( -name '*.pem' -o -name 'id_rsa' -o -name 'id_ed25519' -o -name '*.keystore' -o -name '*.jks' \) -print -quit 2>/dev/null)" ]]; then
        echo "contains repo or key files"; return 0
    fi
    local top
    if top=$(git -C "$(dirname "$p")" rev-parse --show-toplevel 2>/dev/null); then
        if [[ -n "$(git -C "$top" ls-files -- "$p" 2>/dev/null | head -1)" ]]; then echo "git-tracked files"; return 0; fi
    fi
    return 1
}

purge_scan() {
    # outputs: bytes|recent(0/1)|age_days|project|artifact
    local root n e
    local always=() cond=() first=1
    for n in "${PURGE_ALWAYS[@]}"; do (( first )) || always+=(-o); first=0; always+=(-name "$n"); done
    first=1
    local cnames=()
    for e in "${PURGE_CONDITIONAL[@]}"; do n=${e%%:*}; cnames+=("${n##*/}"); done
    cnames+=("cmake-build-*" "build-*" "*.cache" "*.ip_user_files")
    for n in "${cnames[@]}"; do (( first )) || cond+=(-o); first=0; cond+=(-name "$n"); done
    local p now last=""; now=$(date +%s)
    for root in "${PURGE_ROOTS[@]}"; do
        while IFS= read -r -d '' p; do
            [[ -n "$last" && "$p" == "$last"/* ]] && continue
            is_artifact "$p" || continue
            is_whitelisted "$p" && continue
            if artifact_protected "$p" >/dev/null; then debug "protected: $p ($(artifact_protected "$p"))"; continue; fi
            local bytes recent=0 newest age
            bytes=$(path_bytes "$p")
            (( bytes == 0 )) && continue
            last="$p"
            if [[ -n "$(find "$p" -mindepth 1 -maxdepth 2 -newermt '-7 days' -print -quit 2>/dev/null)" ]]; then recent=1; fi
            newest=$(stat -c %Y -- "$p" 2>/dev/null || echo "$now")
            age=$(( (now - newest) / 86400 ))
            printf '%s|%s|%s|%s|%s\n' "$bytes" "$recent" "$age" "$(dirname "$p")" "$p"
        done < <(find "$root" -maxdepth "$PURGE_MAX_DEPTH" \( -name .git -o -name .hg -o -name .svn \) -prune \
                    -o -type d \( "${always[@]}" \) -print0 -prune \
                    -o -type d \( "${cond[@]}" \) -print0 2>/dev/null)
    done
}

purge_paths_menu() {
    mkdir -p "$VOLE_CONFIG_DIR"
    if [[ ! -f "$VOLE_PURGE_PATHS" ]]; then
        { echo "# Vole purge scan roots, one per line. When any are set, only these are scanned."; purge_roots; local r; for r in "${PURGE_ROOTS[@]}"; do echo "${r/#$HOME/\~}"; done; } > "$VOLE_PURGE_PATHS"
    fi
    "${EDITOR:-${VISUAL:-nano}}" "$VOLE_PURGE_PATHS" 2>/dev/null || vi "$VOLE_PURGE_PATHS"
    ok "Scan roots saved in ${VOLE_PURGE_PATHS/#$HOME/\~}"
}

_age_fmt() { local d="$1"; if (( d < 1 )); then echo "<1d"; elif (( d < 7 )); then echo "<7d"; elif (( d < 60 )); then echo "${d}d"; elif (( d < 730 )); then echo "$((d/30))mo"; else echo "$((d/365))y"; fi; }

cmd_purge() {
    VOLE_COMMAND=purge
    local a
    for a in "$@"; do
        case "$a" in
            --dry-run|-n) VOLE_DRY_RUN=1 ;; --debug) VOLE_DEBUG=1 ;; -y|--yes) VOLE_YES=1 ;;
            --paths) purge_paths_menu; return ;;
            -h|--help) echo "Usage: vo purge [--dry-run] [--yes] [--paths]"; return ;;
            *) die "Unknown option: $a" ;;
        esac
    done
    load_whitelist; purge_roots
    title "Purge Project Artifacts"
    (( ${#PURGE_ROOTS[@]} )) || { say "No project folders found. Configure them with: vo purge --paths"; return 0; }
    say "${C_GRAY}Scanning: $(printf '%s ' "${PURGE_ROOTS[@]/#$HOME/\~}")${C_RESET}"
    local rows=()
    mapfile -t rows < <(purge_scan | sort -t'|' -k4,4 -k1,1nr)
    (( ${#rows[@]} )) || { say "No rebuildable artifacts found."; return 0; }

    VOLE_MENU_LABELS=(); VOLE_MENU_SELECTED=()
    local r prev="" i
    for i in "${!rows[@]}"; do
        IFS='|' read -r b rec age proj path <<<"${rows[$i]}"
        local next_proj=""; (( i + 1 < ${#rows[@]} )) && { IFS='|' read -r _ _ _ next_proj _ <<<"${rows[$((i+1))]}"; }
        local glyph="─"
        if [[ "$proj" != "$prev" && "$proj" == "$next_proj" ]]; then glyph="┌"
        elif [[ "$proj" == "$prev" && "$proj" == "$next_proj" ]]; then glyph="│"
        elif [[ "$proj" == "$prev" ]]; then glyph="└"; fi
        prev="$proj"
        VOLE_MENU_LABELS+=("$(printf '%s %-40.40s %9s | %-14.14s | %s' "$glyph" "${proj/#$HOME/\~}" "$(human "$b")" "${path##*/}" "$(_age_fmt "$age")")")
        VOLE_MENU_SELECTED+=($(( rec == 1 ? 0 : 1 )))
    done

    if [[ "$VOLE_DRY_RUN" == "1" && ! -t 0 ]]; then
        local tot=0 cnt=0
        echo
        for i in "${!rows[@]}"; do
            local mark="○"; [[ "${VOLE_MENU_SELECTED[$i]}" == 1 ]] && { mark="●"; IFS='|' read -r b _ <<<"${rows[$i]}"; tot=$((tot+b)); cnt=$((cnt+1)); }
            say "  $mark ${VOLE_MENU_LABELS[$i]}"
        done
        echo; rule; say "${C_BOLD}Dry run${C_RESET} — ${#rows[@]} candidates, $cnt preselected (~$(human "$tot")); ○ = active in the last 7 days"; rule
        return 0
    fi
    if [[ -t 0 && "$VOLE_YES" != "1" ]]; then
        select_multi "Select Artifacts to Purge" || { say "Cancelled."; return 0; }
    elif [[ "$VOLE_DRY_RUN" != "1" && "$VOLE_YES" != "1" ]]; then
        die "Non-interactive purge needs --yes (or use --dry-run to review)."
    fi

    local chosen=() total=0
    for i in "${!rows[@]}"; do
        [[ "${VOLE_MENU_SELECTED[$i]}" == 1 ]] || continue
        chosen+=("${rows[$i]}"); IFS='|' read -r b _ <<<"${rows[$i]}"; total=$((total+b))
    done
    (( ${#chosen[@]} )) || { say "Nothing selected."; return 0; }

    echo; say "${C_BOLD}Will permanently delete ${#chosen[@]} artifacts, ~$(human "$total"):${C_RESET}"
    for r in "${chosen[@]}"; do IFS='|' read -r b _ _ _ path <<<"$r"; say "  ${C_GRAY}${path/#$HOME/\~}${C_RESET}  $(human "$b")"; done
    if [[ "$VOLE_DRY_RUN" == "1" ]]; then echo; rule; say "${C_BOLD}Dry run${C_RESET} — would free ~$(human "$total") | Items: ${#chosen[@]}"; rule; return 0; fi
    echo
    if [[ "$VOLE_YES" != "1" ]]; then confirm "Delete these?" n || { say "Cancelled."; return 0; }; fi

    local freed=0 n=0 got
    for r in "${chosen[@]}"; do
        IFS='|' read -r b _ _ _ path <<<"$r"
        artifact_protected "$path" >/dev/null && { skip "${path/#$HOME/\~} · changed, now protected"; continue; }
        got=$(safe_remove "$path") || true
        freed=$((freed + ${got:-0})); n=$((n+1))
    done
    echo; rule
    say "${C_BOLD}Purge complete${C_RESET}"
    say "Estimated space freed: $(human "$freed") | Items: $n | Free: $(human "$(free_bytes "$HOME")")"
    rule
}
