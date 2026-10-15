#!/usr/bin/env bash
# Vole test suite: runs every command against a throwaway $HOME. No root needed.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
T=$(mktemp -d /tmp/vole-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_STATE_HOME="$T/home/.local/state" XDG_DATA_HOME="$T/home/.local/share" NO_COLOR=1
mkdir -p "$HOME"

ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
mk()   { mkdir -p "$(dirname "$1")"; head -c "${2:-4096}" /dev/urandom > "$1"; }
VO="$ROOT/vole"

echo "== safety"
(
source "$ROOT/lib/core/common.sh"
for p in / /usr /etc /home "$HOME" "$HOME/.config" "$HOME/.ssh/id_rsa" /var/lib "$HOME/.cache"; do
    is_protected_path "$p" || { echo "NOT PROTECTED: $p"; exit 1; }
done
is_protected_path "$HOME/.cache/foo" && { echo "wrongly protected"; exit 1; }
exit 0
) && ok "protected paths refused, normal paths allowed" || bad "protected path checks"

echo "== clean"
mk "$HOME/.cache/thumbnails/normal/a.png" 20000
mk "$HOME/.cache/google-chrome/Default/Cache/data_1" 50000
mk "$HOME/.cache/huggingface/hub/model.bin" 30000
mk "$HOME/.cache/oldapp/blob" 10000; touch -d '60 days ago' "$HOME/.cache/oldapp/blob" "$HOME/.cache/oldapp"
mk "$HOME/.cache/freshapp/blob" 10000
mk "$HOME/.local/share/Trash/files/junk.txt" 8000; mkdir -p "$HOME/.local/share/Trash/info"; printf '[Trash Info]\nPath=/x\n' > "$HOME/.local/share/Trash/info/junk.txt.trashinfo"
mkdir -p "$HOME/.var/app/org.gone.App/data"; mk "$HOME/.var/app/org.gone.App/data/x" 5000
mkdir -p "$HOME/.local/share/applications"
printf '[Desktop Entry]\nType=Application\nName=Ghost\nExec=/nonexistent/ghost %%U\n' > "$HOME/.local/share/applications/ghost.desktop"

out=$("$VO" clean --dry-run --user-only 2>&1)
check "dry run reports cache" 'grep -q "Chrome cache" <<<"$out"'
check "dry run removes nothing" '[[ -f "$HOME/.cache/google-chrome/Default/Cache/data_1" ]]'
check "dry run mentions dry run" 'grep -qi "dry run" <<<"$out"'

out=$("$VO" clean --user-only 2>&1)
check "chrome cache emptied" '[[ ! -e "$HOME/.cache/google-chrome/Default" ]]'
check "cache dir itself kept" '[[ -d "$HOME/.cache/google-chrome" ]]'
check "thumbnails cleaned" '[[ ! -e "$HOME/.cache/thumbnails/normal" ]]'
check "huggingface protected by default whitelist" '[[ -f "$HOME/.cache/huggingface/hub/model.bin" ]]'
check "stale cache (60d) removed" '[[ ! -e "$HOME/.cache/oldapp" ]]'
check "fresh cache kept" '[[ -f "$HOME/.cache/freshapp/blob" ]]'
check "trash emptied" '[[ -z "$(ls -A "$HOME/.local/share/Trash/files")" ]]'
check "flatpak orphan data removed" '[[ ! -e "$HOME/.var/app/org.gone.App" ]]'
check "broken launcher removed" '[[ ! -e "$HOME/.local/share/applications/ghost.desktop" ]]'
check "summary printed" 'grep -q "Cleanup complete" <<<"$out"'

echo "== whitelist"
mkdir -p "$XDG_CONFIG_HOME/vole"; printf '~/.cache/keepme\ntrash\n' > "$XDG_CONFIG_HOME/vole/whitelist"
mk "$HOME/.cache/keepme/a" 3000; touch -d '90 days ago' "$HOME/.cache/keepme/a" "$HOME/.cache/keepme"
mk "$HOME/.local/share/Trash/files/keep.txt" 100
"$VO" clean --user-only >/dev/null 2>&1
check "whitelisted path kept" '[[ -f "$HOME/.cache/keepme/a" ]]'
check "trash kept when whitelisted" '[[ -f "$HOME/.local/share/Trash/files/keep.txt" ]]'
chmod 000 "$XDG_CONFIG_HOME/vole/whitelist"
if [[ $EUID -ne 0 ]]; then
    "$VO" clean --user-only >/dev/null 2>&1; rc=$?
    check "unreadable whitelist stops clean" '[[ $rc -ne 0 ]]'
fi
chmod 644 "$XDG_CONFIG_HOME/vole/whitelist"; rm -f "$XDG_CONFIG_HOME/vole/whitelist"

echo "== purge"
P="$HOME/Projects"
mkdir -p "$P/web" "$P/rust" "$P/plain/build" "$P/cmakeproj" "$P/fpga" "$P/tracked"
echo '{}' > "$P/web/package.json"; mk "$P/web/node_modules/lodash/index.js" 40000; mk "$P/web/node_modules/lodash/node_modules/x/y.js" 100
find "$P/web/node_modules" -exec touch -d '30 days ago' {} +
echo '[package]' > "$P/rust/Cargo.toml"; mk "$P/rust/target/debug/app" 60000; touch -d '30 days ago' "$P/rust/target/debug/app" "$P/rust/target/debug" "$P/rust/target"
mk "$P/plain/build/notes.txt" 1000                      # no marker -> keep
echo 'cmake_minimum_required()' > "$P/cmakeproj/CMakeLists.txt"; mk "$P/cmakeproj/build/CMakeCache.txt" 7000
touch -d '20 days ago' "$P/cmakeproj/build/CMakeCache.txt" "$P/cmakeproj/build"
touch "$P/fpga/top.xpr"; mk "$P/fpga/top.cache/wt/x" 9000; touch -d '20 days ago' "$P/fpga/top.cache/wt/x" "$P/fpga/top.cache/wt" "$P/fpga/top.cache"
mk "$P/fpga/.Xil/tmp" 2000
( cd "$P/tracked" && git init -q && echo '{}' > package.json && mk dist/app.js 3000 && git add -A >/dev/null && git -c user.email=a@b -c user.name=t commit -qm init )
touch -d '20 days ago' "$P/tracked/dist/app.js" "$P/tracked/dist"
out=$("$VO" purge --dry-run </dev/null 2>&1)
check "purge dry run lists node_modules" 'grep -q node_modules <<<"$out"'
check "purge dry run lists vivado cache" 'grep -q "top.cache" <<<"$out"'
check "purge skips build/ without marker" '! grep -q "plain/build" <<<"$out"'
check "purge skips git-tracked dist" '! grep -q "tracked/dist" <<<"$out"'
check "purge lists nested node_modules once" '[[ $(grep -c node_modules <<<"$out") -eq 1 ]]'
"$VO" purge </dev/null >/dev/null 2>&1; rc=$?
check "non-interactive purge needs --yes" '[[ $rc -ne 0 && -d "$P/web/node_modules" ]]'
"$VO" purge --yes </dev/null >/dev/null 2>&1
check "node_modules purged" '[[ ! -e "$P/web/node_modules" ]]'
check "cargo target purged" '[[ ! -e "$P/rust/target" ]]'
check "cmake build purged" '[[ ! -e "$P/cmakeproj/build" ]]'
check "vivado .cache purged" '[[ ! -e "$P/fpga/top.cache" ]]'
check "project sources kept" '[[ -f "$P/web/package.json" && -f "$P/rust/Cargo.toml" && -f "$P/fpga/top.xpr" ]]'
check "unmarked build kept" '[[ -f "$P/plain/build/notes.txt" ]]'
check "git-tracked dist kept" '[[ -f "$P/tracked/dist/app.js" ]]'

echo "== installer"
mk "$HOME/Downloads/vscode_1.95_amd64.deb" 70000; touch -d '10 days ago' "$HOME/Downloads/vscode_1.95_amd64.deb"
mk "$HOME/Downloads/ubuntu-24.04.iso" 90000; touch -d '10 days ago' "$HOME/Downloads/ubuntu-24.04.iso"
mk "$HOME/Downloads/today.rpm" 1000
mk "$HOME/Downloads/report.pdf" 1000
out=$("$VO" installer --dry-run </dev/null 2>&1)
check "installer finds .deb and .iso" 'grep -q "vscode_1.95_amd64.deb" <<<"$out" && grep -q "ubuntu-24.04.iso" <<<"$out"'
check "installer ignores pdf" '! grep -q report.pdf <<<"$out"'
"$VO" installer --yes </dev/null >/dev/null 2>&1
check "old installers removed" '[[ ! -e "$HOME/Downloads/vscode_1.95_amd64.deb" && ! -e "$HOME/Downloads/ubuntu-24.04.iso" ]]'
check "recent installer kept (not preselected)" '[[ -f "$HOME/Downloads/today.rpm" ]]'
check "other downloads kept" '[[ -f "$HOME/Downloads/report.pdf" ]]'

echo "== history"
out=$("$VO" history --json)
check "history JSON parses" 'python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert len(d[\"sessions\"])>0" "$out"'
check "history text works" '"$VO" history | grep -q purge'

echo "== uninstall"
mkdir -p "$HOME/Applications"; mk "$HOME/Applications/Foo-1.0-x86_64.AppImage" 20000; chmod +x "$HOME/Applications/Foo-1.0-x86_64.AppImage"
mk "$HOME/.cache/Foo-1.0-x86_64/c" 100
out=$("$VO" uninstall --list 2>&1)
check "uninstall lists AppImage" 'grep -q "Foo-1.0-x86_64" <<<"$out"'
"$VO" uninstall --yes Foo </dev/null >/dev/null 2>&1
check "AppImage removed by name" '[[ ! -e "$HOME/Applications/Foo-1.0-x86_64.AppImage" ]]'
check "AppImage cache removed" '[[ ! -e "$HOME/.cache/Foo-1.0-x86_64" ]]'

echo "== optimize"
out=$("$VO" optimize --dry-run 2>&1)
check "optimize runs and summarizes" 'grep -q "Optimization Complete" <<<"$out"'

echo "== misc"
check "help" '"$VO" --help | grep -q "vo clean"'
check "version" '"$VO" --version | grep -q Vole'
check "completion bash" '"$VO" completion bash | grep -q "complete -F"'
check "completion zsh" '"$VO" completion zsh | grep -q compdef'
check "unknown command fails" '! "$VO" frobnicate >/dev/null 2>&1'
if bin=$(ls "$ROOT"/bin/vole-status* 2>/dev/null | head -1) && [[ -x "$bin" ]]; then
    check "status --json" '"$VO" status --json | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"memory\"][\"total\"]>0"'
    check "analyze --json" '"$VO" analyze --json "$HOME" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"scan_status\"] in (\"complete\",\"partial\")"'
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
(( FAIL == 0 ))
