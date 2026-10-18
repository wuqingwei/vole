#!/usr/bin/env bash
# Vole - shared helpers: colors, logging, sizes, safety checks, whitelist, oplog.
# shellcheck disable=SC2034

[[ -n "${VOLE_COMMON_LOADED:-}" ]] && return 0
VOLE_COMMON_LOADED=1

set -o pipefail

VOLE_VERSION="${VOLE_VERSION:-0.1.0}"

# ---------------------------------------------------------------- paths
VOLE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vole"
VOLE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/vole"
VOLE_OPLOG="$VOLE_STATE_DIR/operations.log"
VOLE_WHITELIST="$VOLE_CONFIG_DIR/whitelist"
VOLE_OPT_WHITELIST="$VOLE_CONFIG_DIR/optimize_whitelist"
VOLE_PURGE_PATHS="$VOLE_CONFIG_DIR/purge_paths"
VOLE_TRASH_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/Trash"

# ---------------------------------------------------------------- flags
VOLE_DRY_RUN="${VOLE_DRY_RUN:-0}"
VOLE_DEBUG="${VOLE_DEBUG:-0}"
VOLE_YES="${VOLE_YES:-0}"
VOLE_RUN_ID="${VOLE_RUN_ID:-$(date +%s)-$$}"

# ---------------------------------------------------------------- colors
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'; C_GRAY=$'\033[90m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""
    C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_GRAY=""
fi

ICON_OK="✓"; ICON_SKIP="◎"; ICON_ARROW="➤"; ICON_STEP="→"; ICON_WARN="!"; ICON_ERR="✗"; ICON_GEAR="⚙"

# ---------------------------------------------------------------- output
say()      { printf '%s\n' "$*"; }
title()    { printf '\n%s%s%s\n\n' "$C_BOLD" "$*" "$C_RESET"; }
section()  { printf '\n%s%s %s%s\n' "$C_CYAN$C_BOLD" "$ICON_ARROW" "$*" "$C_RESET"; }
ok()       { printf '  %s%s%s %s\n' "$C_GREEN" "$ICON_OK" "$C_RESET" "$*"; }
step()     { printf '  %s%s%s %s\n' "$C_BLUE" "$ICON_STEP" "$C_RESET" "$*"; }
skip()     { printf '  %s%s %s%s\n' "$C_GRAY" "$ICON_SKIP" "$*" "$C_RESET"; }
warn()     { printf '  %s%s%s %s\n' "$C_YELLOW" "$ICON_WARN" "$C_RESET" "$*" >&2; }
err()      { printf '%s%s %s%s\n' "$C_RED" "$ICON_ERR" "$*" "$C_RESET" >&2; }
die()      { err "$*"; exit 1; }
debug()    { [[ "$VOLE_DEBUG" == "1" ]] && printf '%s[debug] %s%s\n' "$C_GRAY" "$*" "$C_RESET" >&2; return 0; }
rule()     { printf '%s\n' "======================================================================"; }

# ---------------------------------------------------------------- sizes
# human SIZE_IN_BYTES -> 1.2GB
human() {
    local b="${1:-0}"
    awk -v b="$b" 'BEGIN{
        split("B KB MB GB TB PB",u," "); i=1;
        while (b>=1024 && i<6) { b/=1024; i++ }
        if (i==1) printf "%dB", b; else printf "%.1f%s", b, u[i] }'
}

# path_bytes PATH -> apparent disk usage in bytes (does not follow symlinks)
path_bytes() {
    local p="$1"
    [[ -e "$p" || -L "$p" ]] || { echo 0; return; }
    local kb
    kb=$(du -sk -- "$p" 2>/dev/null | awk '{s+=$1} END{print s+0}')
    echo $(( ${kb:-0} * 1024 ))
}

free_bytes() {
    df -Pk -- "${1:-$HOME}" 2>/dev/null | awk 'NR==2{print $4*1024}'
}

# ---------------------------------------------------------------- system info
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v yum >/dev/null 2>&1; then echo yum
    elif command -v pacman >/dev/null 2>&1; then echo pacman
    elif command -v zypper >/dev/null 2>&1; then echo zypper
    elif command -v apk >/dev/null 2>&1; then echo apk
    else echo none; fi
}

distro_name() {
    if [[ -r /etc/os-release ]]; then
        ( . /etc/os-release; echo "${PRETTY_NAME:-${NAME:-Linux}}" )
    else uname -s; fi
}

is_running() { pgrep -x -u "$(id -u)" "$1" >/dev/null 2>&1 || pgrep -f -u "$(id -u)" -- "$1" >/dev/null 2>&1; }

# desktop_field FILE KEY -> value of the first "KEY=" line, split on the first '=' only
desktop_field() { awk -v k="$2" 'index($0, k "=")==1 { print substr($0, length(k)+2); exit }' "$1" 2>/dev/null; }

# ---------------------------------------------------------------- sudo
VOLE_SUDO_OK=""
need_sudo() {
    # Returns 0 when we can run privileged commands (asks once).
    [[ $EUID -eq 0 ]] && return 0
    [[ "$VOLE_SUDO_OK" == "1" ]] && return 0
    [[ "$VOLE_SUDO_OK" == "0" ]] && return 1
    command -v sudo >/dev/null 2>&1 || { VOLE_SUDO_OK=0; return 1; }
    if sudo -n true 2>/dev/null; then VOLE_SUDO_OK=1; return 0; fi
    if [[ ! -t 0 ]]; then VOLE_SUDO_OK=0; return 1; fi
    printf '  %s%s%s Administrator access needed for system items.\n' "$C_YELLOW" "$ICON_GEAR" "$C_RESET"
    if sudo -v; then VOLE_SUDO_OK=1; return 0; fi
    VOLE_SUDO_OK=0; return 1
}
as_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

# ---------------------------------------------------------------- confirm
confirm() {
    # confirm "Question" [default y|n]
    local q="$1" def="${2:-n}" ans hint="[y/N]"
    [[ "$VOLE_YES" == "1" ]] && return 0
    [[ "$def" == "y" ]] && hint="[Y/n]"
    [[ -t 0 ]] || return 1
    printf '%s %s ' "$q" "$hint"
    read -r ans </dev/tty || return 1
    ans="${ans:-$def}"
    [[ "$ans" =~ ^[Yy] ]]
}

# ---------------------------------------------------------------- safety
# Paths that must never be removed themselves, whatever a caller asks.
VOLE_PROTECTED_EXACT=(
    / /bin /boot /dev /etc /home /lib /lib32 /lib64 /libx32 /media /mnt /opt /proc /root
    /run /sbin /srv /sys /tmp /usr /var /var/lib /var/log /var/cache /snap
)

realpath_nofollow() {
    # Resolve the parent dir but keep the last component (so symlinks are removed, not followed).
    local p="$1" d b
    d=$(dirname -- "$p"); b=$(basename -- "$p")
    d=$(cd -- "$d" 2>/dev/null && pwd -P) || { echo "$p"; return; }
    [[ "$d" == "/" ]] && echo "/$b" || echo "$d/$b"
}

is_protected_path() {
    local p
    p=$(realpath_nofollow "$1")
    p="${p%/}"; [[ -z "$p" ]] && p="/"
    local x
    for x in "${VOLE_PROTECTED_EXACT[@]}"; do [[ "$p" == "$x" ]] && return 0; done
    [[ "$p" == "$HOME" || "$p" == "$(cd ~ && pwd -P)" ]] && return 0
    # top level of home config/data dirs themselves
    case "$p" in
        "$HOME/.config"|"$HOME/.local"|"$HOME/.local/share"|"$HOME/.local/bin"|"$HOME/.cache"|"$HOME/.ssh"|"$HOME/.gnupg") return 0 ;;
        "$HOME/.ssh/"*|"$HOME/.gnupg/"*|"$HOME/.password-store"*|"$HOME/.local/share/keyrings"*) return 0 ;;
    esac
    # must be at least 2 levels deep
    local depth
    depth=$(awk -F/ '{print NF-1}' <<<"$p")
    (( depth < 2 )) && return 0
    return 1
}

# ---------------------------------------------------------------- whitelist
# Default protected caches, used when the user has no whitelist file yet.
VOLE_DEFAULT_WHITELIST=(
    "$HOME/.cache/huggingface"
    "$HOME/.cache/torch"
    "$HOME/.cache/ms-playwright"
    "$HOME/.cache/JetBrains"
    "$HOME/.cache/vole"
)

load_whitelist() {
    VOLE_WL=()
    if [[ -e "$VOLE_WHITELIST" ]]; then
        [[ -r "$VOLE_WHITELIST" ]] || die "Whitelist $VOLE_WHITELIST is not readable; refusing to run without it."
        local line
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" ]] && continue
            line="${line/#\~/$HOME}"
            VOLE_WL+=("$line")
        done < "$VOLE_WHITELIST"
    else
        VOLE_WL=("${VOLE_DEFAULT_WHITELIST[@]}")
    fi
}

is_whitelisted() {
    local p="$1" w
    for w in "${VOLE_WL[@]}"; do
        # shellcheck disable=SC2053
        [[ "$p" == $w || "$p" == "$w" || "$p" == "$w"/* ]] && return 0
    done
    return 1
}

whitelist_has() { local k="$1" w; for w in "${VOLE_WL[@]}"; do [[ "$w" == "$k" ]] && return 0; done; return 1; }

# ---------------------------------------------------------------- oplog
oplog() {
    # oplog ACTION DETAIL [BYTES]
    [[ "${VOLE_NO_OPLOG:-0}" == "1" ]] && return 0
    [[ "$VOLE_DRY_RUN" == "1" ]] && return 0
    mkdir -p "$VOLE_STATE_DIR" 2>/dev/null || return 0
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$VOLE_RUN_ID" "${VOLE_COMMAND:-?}" "$1" "${3:-0}" "$2" >> "$VOLE_OPLOG" 2>/dev/null || true
}

# ---------------------------------------------------------------- removal
VOLE_TOTAL_BYTES=0
VOLE_TOTAL_ITEMS=0

# safe_remove PATH -> removes file/dir/symlink after safety checks. Echoes bytes freed.
safe_remove() {
    local p="$1" bytes
    [[ -e "$p" || -L "$p" ]] || { echo 0; return 0; }
    if is_protected_path "$p"; then debug "protected, refused: $p"; echo 0; return 1; fi
    if is_whitelisted "$p"; then debug "whitelisted, kept: $p"; echo 0; return 1; fi
    bytes=$(path_bytes "$p")
    if [[ "$VOLE_DRY_RUN" == "1" ]]; then
        debug "would remove: $p ($(human "$bytes"))"
        echo "$bytes"; return 0
    fi
    if rm -rf --one-file-system -- "$p" 2>/dev/null; then
        oplog remove "$p" "$bytes"
        echo "$bytes"; return 0
    fi
    # partial removal: report what is gone
    local left; left=$(path_bytes "$p")
    oplog remove-partial "$p" $(( bytes - left ))
    echo $(( bytes - left )); return 1
}

# clean_dir_contents DIR -> removes everything inside DIR (not DIR itself). Prints "items bytes".
clean_dir_contents() {
    local d="$1" items=0 bytes=0 b e
    [[ -d "$d" && ! -L "$d" ]] || { echo "0 0"; return; }
    while IFS= read -r -d '' e; do
        is_whitelisted "$e" && continue
        b=$(safe_remove "$e") || true
        if (( ${b:-0} > 0 )) || [[ ! -e "$e" && ! -L "$e" ]] || [[ "$VOLE_DRY_RUN" == "1" ]]; then items=$((items+1)); bytes=$((bytes + ${b:-0})); fi
    done < <(find "$d" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    echo "$items $bytes"
}

# report_line LABEL ITEMS BYTES
report_line() {
    local label="$1" items="$2" bytes="$3"
    [[ "$VOLE_DRY_RUN" == "1" ]] && (( bytes == 0 )) && return 1
    if (( items > 0 || bytes > 0 )); then
        local verb="" cnt=""; [[ "$VOLE_DRY_RUN" == "1" ]] && verb=" (dry run)"
        (( items > 1 )) && cnt="$items items, "
        ok "$label · $cnt$(human "$bytes")$verb"
        VOLE_TOTAL_BYTES=$((VOLE_TOTAL_BYTES + bytes)); VOLE_TOTAL_ITEMS=$((VOLE_TOTAL_ITEMS + items))
        return 0
    fi
    return 1
}

# Days-old helper for find
older_than_days() { find "$1" -mindepth 1 -maxdepth "${3:-1}" -mtime +"$2" -print0 2>/dev/null; }

vole_bin_dir() {
    local d
    for d in "$VOLE_ROOT/bin" "$VOLE_ROOT/../lib/vole/bin"; do
        [[ -d "$d" ]] && { echo "$d"; return; }
    done
    echo "$VOLE_ROOT/bin"
}

go_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; armv7l|armv6l) echo arm ;; riscv64) echo riscv64 ;; *) uname -m ;;
    esac
}

# find_go_binary NAME -> path to vole-NAME binary for this arch
find_go_binary() {
    local name="$1" d; d=$(vole_bin_dir)
    local c
    for c in "$d/vole-$name" "$d/vole-$name-linux-$(go_arch)"; do
        [[ -x "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}
