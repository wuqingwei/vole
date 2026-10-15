#!/usr/bin/env bash
# Vole installer.
#   ./install.sh                     install from this folder into ~/.local (no sudo)
#   ./install.sh --prefix /usr/local install system-wide (asks for sudo)
#   ./install.sh --uninstall         remove
#   curl -fsSL https://raw.githubusercontent.com/wuqingwei/vole/main/install.sh | bash
set -euo pipefail

PREFIX="$HOME/.local"
MODE=install
while (( $# )); do
    case "$1" in
        --prefix) PREFIX="${2:?}"; shift ;;
        --prefix=*) PREFIX="${1#*=}" ;;
        --uninstall) MODE=uninstall ;;
        -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done
PREFIX="${PREFIX%/}"
# A prefix pointing at a bin dir (…/bin) means "put the commands here"
if [[ "$(basename "$PREFIX")" == bin ]]; then BIN_DIR="$PREFIX"; PREFIX=$(dirname "$PREFIX"); else BIN_DIR="$PREFIX/bin"; fi
if [[ "$PREFIX" == "$HOME/.local" ]]; then LIB_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/vole"; else LIB_DIR="$PREFIX/lib/vole"; fi

SUDO=""
if [[ ! -w "$(dirname "$LIB_DIR")" && -e "$(dirname "$LIB_DIR")" ]] || [[ ! -w "$PREFIX" && -e "$PREFIX" ]]; then
    [[ $EUID -eq 0 ]] || SUDO="sudo"
fi

say() { printf '\033[35m🐾\033[0m %s\n' "$*"; }

if [[ "$MODE" == uninstall ]]; then
    $SUDO rm -f "$BIN_DIR/vole" "$BIN_DIR/vo"
    $SUDO rm -rf "$LIB_DIR"
    say "Vole removed from $LIB_DIR"
    exit 0
fi

[[ "$(uname -s)" == Linux ]] || { echo "Vole is for Linux." >&2; exit 1; }

SRC=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")
CLEANUP=""
if [[ -z "$SRC" || ! -f "$SRC/vole" ]]; then
    REPO="${VOLE_REPO:-https://github.com/wuqingwei/vole.git}"
    command -v git >/dev/null || { echo "git is required." >&2; exit 1; }
    SRC=$(mktemp -d); CLEANUP="$SRC"
    git clone --depth 1 "$REPO" "$SRC" >/dev/null 2>&1
fi

case "$(uname -m)" in x86_64|amd64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) ARCH=$(uname -m) ;; esac

say "Installing Vole $(cat "$SRC/VERSION") to $LIB_DIR"
$SUDO mkdir -p "$LIB_DIR/bin" "$BIN_DIR"
$SUDO cp -R "$SRC/vole" "$SRC/lib" "$SRC/VERSION" "$SRC/LICENSE" "$LIB_DIR/"

# Go tools: prebuilt for this arch, else build with Go if available
got=0
for t in analyze status; do
    if [[ -x "$SRC/bin/vole-$t-linux-$ARCH" ]]; then
        $SUDO cp "$SRC/bin/vole-$t-linux-$ARCH" "$LIB_DIR/bin/vole-$t"; got=$((got+1))
    elif [[ -x "$SRC/bin/vole-$t" ]] && file "$SRC/bin/vole-$t" 2>/dev/null | grep -qi "$( [[ $ARCH == amd64 ]] && echo x86-64 || echo aarch64 )"; then
        $SUDO cp "$SRC/bin/vole-$t" "$LIB_DIR/bin/vole-$t"; got=$((got+1))
    fi
done
RELEASE_URL="${VOLE_RELEASE_URL:-https://github.com/wuqingwei/vole/releases/latest/download}"
if (( got < 2 )) && command -v curl >/dev/null 2>&1; then
    tmpd=$(mktemp -d); got=0
    for t in analyze status; do
        if curl -fsSL --connect-timeout 10 -o "$tmpd/vole-$t" "$RELEASE_URL/vole-$t-linux-$ARCH" 2>/dev/null; then
            chmod +x "$tmpd/vole-$t"; $SUDO cp "$tmpd/vole-$t" "$LIB_DIR/bin/vole-$t"; got=$((got+1))
        fi
    done
    rm -rf "$tmpd"
    (( got == 2 )) && say "Downloaded prebuilt analyze/status for $ARCH"
fi
if (( got < 2 )); then
    if command -v go >/dev/null 2>&1; then
        say "Building analyze/status with $(go version | awk '{print $3}')…"
        tmpb=$(mktemp -d)
        (cd "$SRC" && go build -trimpath -ldflags "-s -w" -o "$tmpb/vole-analyze" ./cmd/analyze && go build -trimpath -ldflags "-s -w" -o "$tmpb/vole-status" ./cmd/status)
        $SUDO cp "$tmpb"/vole-* "$LIB_DIR/bin/"; rm -rf "$tmpb"
    else
        say "No prebuilt binaries for $ARCH and Go is not installed: 'vo analyze' and 'vo status' will be unavailable."
    fi
fi
$SUDO chmod +x "$LIB_DIR/vole" "$LIB_DIR"/bin/* 2>/dev/null || true
$SUDO ln -sf "$LIB_DIR/vole" "$BIN_DIR/vole"
$SUDO ln -sf "$LIB_DIR/vole" "$BIN_DIR/vo"
[[ -n "$CLEANUP" ]] && rm -rf "$CLEANUP"

say "Done. Run: vo"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) say "Add $BIN_DIR to your PATH:  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc" ;;
esac
