#!/usr/bin/env bash
# Vole test suite: runs every command against a throwaway $HOME. No root needed.
# Coverage follows the README feature list: each clean category, uninstall
# sources, optimize tasks, purge artifact types, installer patterns, plus
# safety, history, completion, install.sh and the Go tools' --json output.
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

# --- test helpers -------------------------------------------------------
fakebin="$T/fakebin"; mkdir -p "$fakebin"
# maketool NAME... -> fake binaries that log their invocation to $T/tool-calls
maketool() { local t; for t in "$@"; do printf '#!/bin/bash\necho "%s $*" >> "%s/tool-calls"\nexit 0\n' "$t" "$T" > "$fakebin/$t"; chmod +x "$fakebin/$t"; done; }
# fakeclean TOOL '$HOME/.../cachedir' -> like maketool but also empties the cache dir
fakeclean() { local t="$1" d="$2"; printf '#!/bin/bash\necho "%s $*" >> "%s/tool-calls"\nrm -rf "%s"\nexit 0\n' "$t" "$T" "$d" > "$fakebin/$t"; chmod +x "$fakebin/$t"; }
# fakeproc NAME -> background process whose comm is NAME (for pgrep -x); echoes pid.
# NOTE: stdio must be redirected away, otherwise the background child keeps the
# $() pipe open and the caller blocks until it exits.
fakeproc() { cp /bin/sleep "$fakebin/$1" 2>/dev/null && { "$fakebin/$1" 120 </dev/null >/dev/null 2>&1 & echo $!; }; }

echo "== safety"
(
source "$ROOT/lib/core/common.sh"
for p in / /usr /etc /home "$HOME" "$HOME/.config" "$HOME/.ssh/id_rsa" /var/lib "$HOME/.cache"; do
    is_protected_path "$p" || { echo "NOT PROTECTED: $p"; exit 1; }
done
is_protected_path "$HOME/.cache/foo" && { echo "wrongly protected"; exit 1; }
load_whitelist
[[ "$(safe_remove "$HOME/.cache")" == "0" ]] || { echo "safe_remove touched protected dir"; exit 1; }
exit 0
) && ok "protected paths refused, normal paths allowed" || bad "protected path checks"

echo "== clean: user essentials"
mk "$HOME/.cache/thumbnails/normal/a.png" 20000
mkdir -p "$HOME/.thumbnails"; mk "$HOME/.thumbnails/old.png" 5000
mk "$HOME/.xsession-errors.old" 3000
mk "$HOME/core.12345" 4000
mk "$HOME/.cache/google-chrome/Default/Cache/data_1" 50000
mk "$HOME/.cache/huggingface/hub/model.bin" 30000
mk "$HOME/.cache/oldapp/blob" 10000; touch -d '60 days ago' "$HOME/.cache/oldapp/blob" "$HOME/.cache/oldapp"
mk "$HOME/.cache/freshapp/blob" 10000
# stale dir with a recently-touched file inside must be kept
mkdir -p "$HOME/.cache/mixed"; mk "$HOME/.cache/mixed/newfile" 5000
touch -d '60 days ago' "$HOME/.cache/mixed"
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
check "legacy thumbnails cleaned" '[[ ! -e "$HOME/.thumbnails/old.png" ]]'
check "xsession-errors.old removed" '[[ ! -e "$HOME/.xsession-errors.old" ]]'
check "core dump in home removed" '[[ ! -e "$HOME/core.12345" ]]'
check "huggingface protected by default whitelist" '[[ -f "$HOME/.cache/huggingface/hub/model.bin" ]]'
check "stale cache (60d) removed" '[[ ! -e "$HOME/.cache/oldapp" ]]'
check "fresh cache kept" '[[ -f "$HOME/.cache/freshapp/blob" ]]'
check "stale dir with recent file kept" '[[ -d "$HOME/.cache/mixed" ]]'
check "trash emptied" '[[ -z "$(ls -A "$HOME/.local/share/Trash/files")" ]]'
check "flatpak orphan data removed" '[[ ! -e "$HOME/.var/app/org.gone.App" ]]'
check "broken launcher removed" '[[ ! -e "$HOME/.local/share/applications/ghost.desktop" ]]'
check "summary printed" 'grep -q "Cleanup complete" <<<"$out"'

echo "== clean: browsers"
mk "$HOME/.cache/chromium/f" 12000
mk "$HOME/.cache/microsoft-edge/f" 12000
mk "$HOME/.cache/BraveSoftware/f" 12000
mk "$HOME/.cache/vivaldi/f" 12000
mk "$HOME/.cache/opera/f" 12000
mk "$HOME/.cache/mozilla/f" 12000
mkdir -p "$HOME/snap/firefox/common/.cache"; mk "$HOME/snap/firefox/common/.cache/f" 12000
mkdir -p "$HOME/.config/google-chrome/Default"
mk "$HOME/.config/google-chrome/Default/GPUCache/f" 5000
mk "$HOME/.config/google-chrome/Default/Code Cache/f" 5000
"$VO" clean --user-only >/dev/null 2>&1
for d in chromium microsoft-edge BraveSoftware vivaldi opera mozilla; do
    check "$d cache cleaned" "[[ ! -e \"\$HOME/.cache/$d/f\" ]]"
done
check "firefox (snap) cache cleaned" '[[ ! -e "$HOME/snap/firefox/common/.cache/f" ]]'
check "browser shader/code caches cleaned" '[[ ! -e "$HOME/.config/google-chrome/Default/GPUCache" && ! -e "$HOME/.config/google-chrome/Default/Code Cache" ]]'
# running browsers are skipped
mk "$HOME/.cache/google-chrome/f" 12000
mkdir -p "$HOME/.config/google-chrome/Default/GPUCache"; mk "$HOME/.config/google-chrome/Default/GPUCache/g" 5000
p=$(fakeproc chrome)
out=$("$VO" clean --user-only --dry-run 2>&1)
check "chrome skipped when running" 'grep -q "Chrome cache · skipped (chrome running)" <<<"$out"'
check "chrome cache kept when running" '[[ -f "$HOME/.cache/google-chrome/f" ]]'
check "shader caches skipped when browser running" 'grep -q "Browser shader & code caches · skipped (browser running)" <<<"$out"'
kill "$p" 2>/dev/null || true
"$VO" clean --user-only >/dev/null 2>&1
check "chrome cache cleaned after exit" '[[ ! -e "$HOME/.cache/google-chrome/f" ]]'

echo "== clean: app caches"
for d in "$HOME/.config/Code/Cache" "$HOME/.config/Code/CachedData" "$HOME/.config/Cursor/Cache" \
         "$HOME/.config/Slack/Cache" "$HOME/.config/discord/Cache" "$HOME/.cache/spotify" \
         "$HOME/.cache/wechat" "$HOME/.steam/steam/config/htmlcache" "$HOME/.cache/mesa_shader_cache" \
         "$HOME/.cache/nvidia" "$HOME/.cache/fontconfig" "$HOME/.cache/qtshadercache"; do
    mk "$d/f" 8000
done
"$VO" clean --user-only >/dev/null 2>&1
for d in Code/Cache "Code/CachedData" Cursor/Cache Slack/Cache discord/Cache; do
    check "$d cleaned" "[[ ! -e \"\$HOME/.config/$d/f\" ]]"
done
for d in spotify wechat mesa_shader_cache nvidia fontconfig qtshadercache; do
    check "$d cleaned" "[[ ! -e \"\$HOME/.cache/$d/f\" ]]"
done
check "steam htmlcache cleaned" '[[ ! -e "$HOME/.steam/steam/config/htmlcache/f" ]]'
# running app -> its cache skipped
mk "$HOME/.config/Code/Cache/f" 8000
p=$(fakeproc code)
out=$("$VO" clean --user-only --dry-run 2>&1)
check "VS Code cache skipped when running" 'grep -q "VS Code cache · skipped (code running)" <<<"$out"'
kill "$p" 2>/dev/null || true

echo "== clean: dev tools"
fakeclean npm '$HOME/.npm/_cacache'
fakeclean pnpm '$HOME/.local/share/pnpm/store'
fakeclean yarn '$HOME/.cache/yarn'
fakeclean bun '$HOME/.bun/install/cache'
fakeclean pip3 '$HOME/.cache/pip'
fakeclean uv '$HOME/.cache/uv'
fakeclean go '$HOME/.cache/go-build'
fakeclean composer '$HOME/.cache/composer'
fakeclean ccache '$HOME/.cache/ccache'
maketool conda docker
for d in "$HOME/.npm/_cacache" "$HOME/.local/share/pnpm/store" "$HOME/.cache/yarn" "$HOME/.bun/install/cache" \
         "$HOME/.cache/pip" "$HOME/.cache/uv" "$HOME/.cache/go-build" "$HOME/.cache/composer" "$HOME/.cache/ccache"; do
    mk "$d/f" 20000
done
for d in "$HOME/.cargo/registry/cache" "$HOME/.cargo/git/checkouts" "$HOME/.gradle/caches/build-cache-1" \
         "$HOME/.cache/node-gyp" "$HOME/.cache/electron" "$HOME/.cache/bazel"; do
    mk "$d/f" 20000
done
mk "$HOME/vivado.jou" 15000; mk "$HOME/vivado.log" 15000; mk "$HOME/.Xil/x" 15000
touch -d '2 days ago' "$HOME/vivado.jou" "$HOME/vivado.log"
rm -f "$T/tool-calls"
out=$(PATH="$fakebin:$PATH" "$VO" clean --user-only 2>&1)
for t in "npm cache clean --force" "pnpm store prune" "yarn cache clean" "bun pm cache rm" \
         "pip3 cache purge" "uv cache clean" "go clean -cache" "conda clean -a -y" \
         "composer clear-cache" "ccache -C"; do
    tool="${t%% *}"
    check "tool cleaner invoked: $tool" 'grep -q "$t" "$T/tool-calls"'
done
for d in "$HOME/.npm/_cacache" "$HOME/.cache/pip" "$HOME/.cache/go-build"; do
    check "$(basename "$d") emptied by its tool" "[[ ! -e \"$d/f\" ]]"
done
for d in "$HOME/.cargo/registry/cache" "$HOME/.gradle/caches/build-cache-1" "$HOME/.cache/node-gyp" \
         "$HOME/.cache/electron" "$HOME/.cache/bazel"; do
    check "$(basename "$(dirname "$d")")/$(basename "$d") cleaned" "[[ ! -e \"$d/f\" ]]"
done
check "vivado logs and .Xil cleaned" '[[ ! -e "$HOME/vivado.jou" && ! -e "$HOME/vivado.log" && ! -e "$HOME/.Xil/x" ]] && grep -q "Vivado logs & .Xil" <<<"$out"'
# docker builder cache only with --docker
out=$(VOLE_CLEAN_DOCKER=1 PATH="$fakebin:$PATH" "$VO" clean --user-only --dry-run 2>&1)
check "docker prune offered with --docker" 'grep -q "Docker builder cache" <<<"$out"'
VOLE_CLEAN_DOCKER=1 PATH="$fakebin:$PATH" "$VO" clean --user-only >/dev/null 2>&1
check "docker builder prune invoked" 'grep -q "^docker builder prune -f" "$T/tool-calls"'
# vivado running -> skipped
mk "$HOME/vivado.jou" 15000; touch -d '2 days ago' "$HOME/vivado.jou"
p=$(fakeproc vivado)
out=$("$VO" clean --user-only --dry-run 2>&1)
check "vivado skipped when running" 'grep -q "skipped (Vivado running)" <<<"$out"'
check "vivado log kept when running" '[[ -f "$HOME/vivado.jou" ]]'
kill "$p" 2>/dev/null || true
rm -f "$HOME/vivado.jou"

echo "== clean: leftovers"
mkdir -p "$HOME/.var/app/org.keep.App" "$HOME/.var/app/org.gone.App"
mk "$HOME/.var/app/org.keep.App/f" 3000; mk "$HOME/.var/app/org.gone.App/f" 3000
cat > "$fakebin/flatpak" <<EOF
#!/bin/bash
if [[ "\$*" == *list* ]]; then echo "org.keep.App"; fi
exit 0
EOF
chmod +x "$fakebin/flatpak"
mkdir -p "$HOME/snap/keepme" "$HOME/snap/gone"
cat > "$fakebin/snap" <<EOF
#!/bin/bash
printf 'Name\tVersion\tRev\nkeepme\t1.0\t1\n'
exit 0
EOF
chmod +x "$fakebin/snap"
printf '[Desktop Entry]\nType=Application\nName=Valid\nExec=/bin/true\n' > "$HOME/.local/share/applications/valid.desktop"
printf '[Desktop Entry]\nType=Application\nName=EnvWrap\nExec=env FOO=1 /nonexistent/x\n' > "$HOME/.local/share/applications/envwrap.desktop"
mkdir -p "$HOME/.config/autostart"
printf '[Desktop Entry]\nType=Application\nName=GoneAuto\nExec=/nonexistent/auto\n' > "$HOME/.config/autostart/gone.desktop"
PATH="$fakebin:$PATH" "$VO" clean --user-only >/dev/null 2>&1
check "flatpak orphan removed, installed kept" '[[ ! -e "$HOME/.var/app/org.gone.App" && -d "$HOME/.var/app/org.keep.App" ]]'
check "snap orphan removed, installed kept" '[[ ! -e "$HOME/snap/gone" && -d "$HOME/snap/keepme" ]]'
check "valid launcher kept" '[[ -f "$HOME/.local/share/applications/valid.desktop" ]]'
check "env-wrapped launcher kept" '[[ -f "$HOME/.local/share/applications/envwrap.desktop" ]]'
check "broken autostart entry removed" '[[ ! -e "$HOME/.config/autostart/gone.desktop" ]]'

echo "== clean: system"
out=$("$VO" clean --user-only 2>&1)
check "user-only skips system section" 'grep -q "System cleanup skipped (--user-only)" <<<"$out"'
if command -v apt-get >/dev/null 2>&1; then
    out=$("$VO" clean --dry-run 2>&1)
    check "dry run reports apt cache" 'grep -q "APT package cache" <<<"$out"'
fi
if command -v journalctl >/dev/null 2>&1; then
    out=$("$VO" clean --dry-run 2>&1)
    check "dry run reports journal vacuum" 'grep -q "Journal logs" <<<"$out"'
fi

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
printf '~/.cache/tmp*\n' > "$XDG_CONFIG_HOME/vole/whitelist"
mk "$HOME/.cache/tmpdata/a" 3000; touch -d '90 days ago' "$HOME/.cache/tmpdata/a" "$HOME/.cache/tmpdata"
"$VO" clean --user-only >/dev/null 2>&1
check "whitelist glob pattern kept" '[[ -f "$HOME/.cache/tmpdata/a" ]]'
rm -f "$XDG_CONFIG_HOME/vole/whitelist"

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

echo "== purge: artifact matrix"
P2="$HOME/Projects/matrix"
pj() { mkdir -p "$P2/$1"; }
pj web2;   mk "$P2/web2/.next/cache/f" 5000
pj py;     mk "$P2/py/__pycache__/f" 5000
pj fpga2;  mk "$P2/fpga2/.Xil/f" 5000
pj rust2;  echo '[package]' > "$P2/rust2/Cargo.toml"; mk "$P2/rust2/target/f" 5000
pj js2;    echo '{}' > "$P2/js2/package.json"; mk "$P2/js2/build/f" 5000
pj js3;    echo '{}' > "$P2/js3/package.json"; mk "$P2/js3/dist/f" 5000
pj js4;    echo '{}' > "$P2/js4/package.json"; mk "$P2/js4/out/f" 5000
pj py2;    echo '[project]' > "$P2/py2/pyproject.toml"; mk "$P2/py2/.venv/f" 5000
pj py3;    echo 'requests' > "$P2/py3/requirements.txt"; mk "$P2/py3/venv/f" 5000
pj ex;     echo 'x' > "$P2/ex/mix.exs"; mk "$P2/ex/_build/f" 5000
pj cs;     echo '<Project/>' > "$P2/cs/app.csproj"; mk "$P2/cs/obj/f" 5000; mk "$P2/cs/bin/f" 5000
pj and;    echo 'x' > "$P2/and/build.gradle"; mk "$P2/and/.cxx/f" 5000
pj cmake2; mk "$P2/cmake2/cmake-build-debug/CMakeCache.txt" 5000
pj qt2;    mk "$P2/qt2/build-app-Desktop_Qt_6_8_0/CMakeCache.txt" 5000
pj viv2;   touch "$P2/viv2/top.xpr"; mk "$P2/viv2/top.ip_user_files/f" 5000
pj rb;     echo "source 'x'" > "$P2/rb/Gemfile"; mk "$P2/rb/vendor/bundle/f" 5000
out=$("$VO" purge --dry-run </dev/null 2>&1)
for pc in web2 py fpga2 rust2 js2 js3 js4 py2 py3 ex cs and cmake2 qt2 viv2 rb; do
    check "purge detects $pc artifact" 'grep -qF "matrix/$pc" <<<"$out"'
done
# protections: key files, nested repos, symlinks are never purged
pj prot1; mk "$P2/prot1/node_modules/f" 5000; head -c 100 /dev/urandom > "$P2/prot1/node_modules/id_rsa"
pj prot2; mk "$P2/prot2/node_modules/f" 5000; mkdir -p "$P2/prot2/node_modules/.git"
pj prot3; mkdir -p "$P2/real_nm"; ln -s "$P2/real_nm" "$P2/prot3/node_modules"
out=$("$VO" purge --dry-run </dev/null 2>&1)
for pc in prot1 prot2 prot3; do
    check "purge protects $pc" '! grep -qF "matrix/$pc" <<<"$out"'
done
# custom scan roots
printf '%s\n' "$P2" > "$XDG_CONFIG_HOME/vole/purge_paths"
out=$("$VO" purge --dry-run </dev/null 2>&1)
check "purge --paths limits scan roots" 'grep -qF "Scanning: ~/Projects/matrix" <<<"$out"'
rm -f "$XDG_CONFIG_HOME/vole/purge_paths"
# whitelist respected
printf '%s\n' "$P2/web2/.next" > "$XDG_CONFIG_HOME/vole/whitelist"
out=$("$VO" purge --dry-run </dev/null 2>&1)
check "purge respects whitelist" '! grep -qF "matrix/web2" <<<"$out"'
rm -f "$XDG_CONFIG_HOME/vole/whitelist"

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

echo "== installer: pattern matrix"
IDIR="$HOME/Downloads"
for e in .rpm .run .pkg.tar.zst .pkg.tar.xz .flatpakref .snap .apk .msi .exe .dmg .xpi; do
    mk "$IDIR/pkg$e" 60000; touch -d '10 days ago' "$IDIR/pkg$e"
done
mk "$IDIR/tool-installer.tar.gz" 60000; touch -d '10 days ago' "$IDIR/tool-installer.tar.gz"
mkdir -p "$IDIR/prog"; mk "$IDIR/prog/app.exe" 60000; mk "$IDIR/prog/app.dll" 1000; touch -d '10 days ago' "$IDIR/prog/app.exe"
ln -s "$IDIR/pkg.rpm" "$IDIR/link.rpm"
mkdir -p "$HOME/Desktop"; mk "$HOME/Desktop/d.rpm" 60000; touch -d '10 days ago' "$HOME/Desktop/d.rpm"
mkdir -p "$HOME/.cache/yay/somepkg"; mk "$HOME/.cache/yay/somepkg/a.pkg.tar.zst" 60000; touch -d '10 days ago' "$HOME/.cache/yay/somepkg/a.pkg.tar.zst"
out=$("$VO" installer --dry-run </dev/null 2>&1)
for e in .rpm .run .pkg.tar.zst .pkg.tar.xz .flatpakref .snap .apk .msi .exe .dmg .xpi; do
    check "installer finds *$e" "grep -qF 'pkg$e' <<<\"\$out\""
done
check "installer finds *-installer.tar.gz" 'grep -qF "tool-installer.tar.gz" <<<"$out"'
check "installer finds Desktop source" 'grep -qF "d.rpm" <<<"$out"'
check "installer finds yay cache" 'grep -qF "a.pkg.tar.zst" <<<"$out"'
check "installer skips exe with dll sibling" '! grep -qF "app.exe" <<<"$out"'
check "installer skips symlinks" '! grep -qF "link.rpm" <<<"$out"'
rm -rf "$IDIR/pkg"* "$IDIR/tool-installer.tar.gz" "$IDIR/prog" "$IDIR/link.rpm" "$HOME/Desktop" "$HOME/.cache/yay"

echo "== history"
out=$("$VO" history --json)
check "history JSON parses" 'python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert len(d[\"sessions\"])>0" "$out"'
check "history JSON has session keys" 'python3 -c "import json,sys; s=json.loads(sys.argv[1])[\"sessions\"][0]; assert {\"run_id\",\"command\",\"started_at\",\"actions\",\"bytes\",\"items\"} <= set(s)" "$out"'
check "history text works" '"$VO" history | grep -q purge'

echo "== uninstall"
mkdir -p "$HOME/Applications"; mk "$HOME/Applications/Foo-1.0-x86_64.AppImage" 20000; chmod +x "$HOME/Applications/Foo-1.0-x86_64.AppImage"
mk "$HOME/.cache/Foo-1.0-x86_64/c" 100
out=$("$VO" uninstall --list 2>&1)
check "uninstall lists AppImage" 'grep -q "Foo-1.0-x86_64" <<<"$out"'
out=$("$VO" uninstall --dry-run Foo </dev/null 2>&1)
check "uninstall dry run says would remove" 'grep -q "Would remove" <<<"$out"'
check "uninstall dry run removes nothing" '[[ -e "$HOME/Applications/Foo-1.0-x86_64.AppImage" ]]'
check "uninstall dry run does not claim removed" '! grep -q "Removed Foo" <<<"$out"'
check "uninstall dry run summary is conditional" 'grep -q "Would remove 1 app" <<<"$out"'
"$VO" uninstall --yes Foo </dev/null >/dev/null 2>&1
check "AppImage removed by name" '[[ ! -e "$HOME/Applications/Foo-1.0-x86_64.AppImage" ]]'
check "AppImage cache removed" '[[ ! -e "$HOME/.cache/Foo-1.0-x86_64" ]]'

echo "== uninstall: local apps and flatpak"
mkdir -p "$HOME/.local/share/fakeapp/bin"
printf '#!/bin/bash\ntrue\n' > "$HOME/.local/share/fakeapp/bin/fakeapp"; chmod +x "$HOME/.local/share/fakeapp/bin/fakeapp"
printf '[Desktop Entry]\nType=Application\nName=FakeApp\nExec=%s/.local/share/fakeapp/bin/fakeapp\n' "$HOME" > "$HOME/.local/share/applications/fakeapp.desktop"
mk "$HOME/.cache/fakeapp/c" 3000
"$VO" uninstall --yes FakeApp </dev/null >/dev/null 2>&1
check "local app dir removed" '[[ ! -e "$HOME/.local/share/fakeapp" ]]'
check "local app launcher removed" '[[ ! -e "$HOME/.local/share/applications/fakeapp.desktop" ]]'
check "local app cache removed" '[[ ! -e "$HOME/.cache/fakeapp" ]]'
cat > "$fakebin/flatpak" <<EOF
#!/bin/bash
echo "flatpak \$*" >> "$T/tool-calls"
if [[ "\$*" == *"--columns=application,name,size,installation"* ]]; then
    printf 'org.fake.App\tFakeFlat\t10.0 MB\tuser\n'
fi
exit 0
EOF
chmod +x "$fakebin/flatpak"
mkdir -p "$HOME/.var/app/org.fake.App"; mk "$HOME/.var/app/org.fake.App/f" 3000
out=$(PATH="$fakebin:$PATH" "$VO" uninstall --list 2>&1)
check "uninstall lists flatpak app" 'grep -q "FakeFlat" <<<"$out"'
rm -f "$T/tool-calls"
PATH="$fakebin:$PATH" "$VO" uninstall --yes FakeFlat </dev/null >/dev/null 2>&1
check "flatpak uninstall invoked" 'grep -q "flatpak uninstall -y --noninteractive --user org.fake.App" "$T/tool-calls"'
check "flatpak user data kept by default" '[[ -d "$HOME/.var/app/org.fake.App" ]]'

echo "== uninstall: deny list"
(
source "$ROOT/lib/core/common.sh"
source "$ROOT/lib/uninstall.sh"
for p in gnome-shell gnome-session-binary nautilus plasma-desktop kwin_x11 systemsettings \
         systemd dbus-daemon gdm3 apt dpkg dnf rpm pacman zypper snapd flatpak sudo bash coreutils \
         linux-image-6.8.0-40-generic grub-pc firmware-sof-signed ubuntu-desktop; do
    [[ "$p" =~ $VOLE_UNINSTALL_DENY_RE ]] || { echo "NOT DENIED: $p"; exit 1; }
done
for p in vim firefox code libreoffice-writer org.gnome.Calculator; do
    [[ "$p" =~ $VOLE_UNINSTALL_DENY_RE ]] && { echo "WRONGLY DENIED: $p"; exit 1; }
done
exit 0
) && ok "deny list blocks core packages, allows normal apps" || bad "deny list blocks core packages, allows normal apps"

echo "== desktop_field"
(
source "$ROOT/lib/core/common.sh"
printf '[Desktop Entry]\nType=Application\nName=X\nExec=env FOO=bar /opt/x/run --a=1 %%U\n' > "$T/d.desktop"
[[ "$(desktop_field "$T/d.desktop" Exec)" == 'env FOO=bar /opt/x/run --a=1 %U' ]] || exit 1
[[ "$(desktop_field "$T/d.desktop" Name)" == "X" ]] || exit 1
exit 0
) && ok "desktop_field keeps = inside values" || bad "desktop_field keeps = inside values"

echo "== optimize"
out=$("$VO" optimize --dry-run 2>&1)
check "optimize runs and summarizes" 'grep -q "Optimization Complete" <<<"$out"'
mkdir -p "$HOME/.local/share/icons/TestTheme"
touch "$HOME/.local/share/icons/TestTheme/index.theme"
printf '#!/bin/bash\necho RAN >> "%s/icon-ran"\n' "$T" > "$fakebin/gtk-update-icon-cache"
chmod +x "$fakebin/gtk-update-icon-cache"
out=$(PATH="$fakebin:$PATH" "$VO" optimize --dry-run 2>&1)
check "icon dry run does not claim rebuilt" '! grep -q "Icon caches rebuilt" <<<"$out"'
check "icon dry run says would rebuild" 'grep -q "would be rebuilt" <<<"$out"'
check "icon dry run runs nothing" '[[ ! -e "$T/icon-ran" ]]'
out=$(PATH="$fakebin:$PATH" "$VO" optimize 2>&1)
check "icon real run rebuilds" 'grep -q "Icon caches rebuilt" <<<"$out"'
check "icon real run executed the tool" '[[ -f "$T/icon-ran" ]]'
rm -rf "$HOME/.local/share/icons"

echo "== optimize: extras"
maketool resolvectl fc-cache update-desktop-database update-mime-database
cat > "$fakebin/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$T/tool-calls"
case "\$*" in
    *is-active*systemd-resolved*|*is-enabled*fstrim.timer*) exit 0 ;;
esac
exit 0
EOF
chmod +x "$fakebin/systemctl"
cat > "$fakebin/sqlite3" <<EOF
#!/bin/bash
if [[ "\$2" == *integrity_check* ]]; then echo ok; else echo "vacuum \$1" >> "$T/sqlite-calls"; fi
exit 0
EOF
chmod +x "$fakebin/sqlite3"
mkdir -p "$HOME/.local/share/applications" "$HOME/.local/share/mime/packages"
mkdir -p "$HOME/.cache/thumbnails/fail"; mk "$HOME/.cache/thumbnails/fail/x" 100
mkdir -p "$HOME/.mozilla/firefox/abcd.default"; mk "$HOME/.mozilla/firefox/abcd.default/places.sqlite" 20000
rm -f "$T/tool-calls" "$T/sqlite-calls"
out=$(PATH="$fakebin:$PATH" "$VO" optimize 2>&1)
check "dns cache flushed" 'grep -q "DNS cache flushed (systemd-resolved)" <<<"$out"'
check "font cache rebuilt" 'grep -q "Font cache rebuilt" <<<"$out"'
check "desktop database refreshed" 'grep -q "Application menu database refreshed" <<<"$out"'
check "mime database refreshed" 'grep -q "MIME database refreshed" <<<"$out"'
check "failed thumbnails reset" '[[ ! -e "$HOME/.cache/thumbnails/fail" ]]'
check "browser databases vacuumed" 'grep -q "Vacuumed 1 browser databases" <<<"$out" && grep -q "places.sqlite" "$T/sqlite-calls"'
check "trim timer detected" 'grep -q "Periodic TRIM enabled (fstrim.timer)" <<<"$out"'
# running browser -> sqlite skipped
p=$(fakeproc firefox)
out=$(PATH="$fakebin:$PATH" "$VO" optimize --dry-run 2>&1)
check "sqlite skipped when firefox running" 'grep -q "Close these apps before database optimization: Firefox" <<<"$out"'
kill "$p" 2>/dev/null || true
# optimize whitelist
printf 'dns\n' > "$XDG_CONFIG_HOME/vole/optimize_whitelist"
out=$(PATH="$fakebin:$PATH" "$VO" optimize --dry-run 2>&1)
check "optimize whitelist excludes task" 'grep -q "excluded by whitelist" <<<"$out"'
rm -f "$XDG_CONFIG_HOME/vole/optimize_whitelist"

echo "== misc"
check "help" '"$VO" --help | grep -q "vo clean"'
check "version" '"$VO" --version | grep -q Vole'
check "completion bash" '"$VO" completion bash | grep -q "complete -F"'
check "completion zsh" '"$VO" completion zsh | grep -q compdef'
check "completion fish" '"$VO" completion fish | grep -q "complete -c"'
check "unknown command fails" '! "$VO" frobnicate >/dev/null 2>&1'
if bin=$(ls "$ROOT"/bin/vole-status* 2>/dev/null | head -1) && [[ -x "$bin" ]]; then
    check "status --json" '"$VO" status --json | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"memory\"][\"total\"]>0"'
    check "status json has required keys" '"$VO" status --json | python3 -c "import json,sys; d=json.load(sys.stdin); assert all(k in d for k in (\"cpu\",\"memory\",\"disks\",\"disk_io\",\"network\",\"power\",\"health_score\",\"process_count\",\"uptime_seconds\",\"top_processes\")); assert 0 <= d[\"health_score\"] <= 100; assert d[\"cpu\"][\"logical_cpu\"] > 0"'
    check "status piped auto-json" '"$VO" status 2>/dev/null | python3 -c "import json,sys; assert json.load(sys.stdin)[\"health_score\"] >= 0"'
    check "status proc-cpu flags accepted" '"$VO" status --json --proc-cpu-threshold 90 --proc-cpu-window 10s --proc-cpu-alerts=false | python3 -c "import json,sys; json.load(sys.stdin)"'
    timeout 5 "$VO" status --watch --interval 1s 2>/dev/null | head -n 2 > "$T/watch.jsonl" || true
    check "status watch streams NDJSON" 'python3 -c "import json; ls=[json.loads(l) for l in open(\"$T/watch.jsonl\") if l.strip()]; assert len(ls) >= 1 and all(\"collected_at\" in d for d in ls)"'
    check "analyze --json" '"$VO" analyze --json "$HOME" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"scan_status\"] in (\"complete\",\"partial\")"'
    check "analyze overview lists Home" '"$VO" analyze --json | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"overview\"] and any(e[\"name\"]==\"Home\" for e in d[\"entries\"])"'
    mkdir -p "$T/count/sub"; mk "$T/count/a" 100; mk "$T/count/b" 100; mk "$T/count/sub/c" 100
    check "analyze counts each file once" '"$VO" analyze --json "$T/count" | python3 -c "import json,sys; assert json.load(sys.stdin)[\"total_files\"]==3"'
    mkdir -p "$T/hl"; mk "$T/hl/orig" 102400; ln "$T/hl/orig" "$T/hl/link"
    check "analyze counts hardlink size once" '"$VO" analyze --json "$T/hl" | python3 -c "import json,sys; assert json.load(sys.stdin)[\"total_size\"] < 150000"'
    mkdir -p "$T/sl/real"; mk "$T/sl/real/f" 102400; ln -s "$T/sl/real" "$T/sl/link"
    check "analyze does not follow symlinked dir" '"$VO" analyze --json "$T/sl" | python3 -c "import json,sys; assert json.load(sys.stdin)[\"total_size\"] < 150000"'
    mkdir -p "$T/deep/a/b/c"; mk "$T/deep/a/b/c/f" 1000
    check "analyze timeout gives partial" '"$VO" analyze --json --timeout 1ns "$T/deep" | python3 -c "import json,sys; assert json.load(sys.stdin)[\"scan_status\"]==\"partial\""'
    if [[ $EUID -ne 0 ]]; then
        mkdir -p "$T/noperm/sub"; mk "$T/noperm/sub/f" 1000; chmod 000 "$T/noperm/sub"
        check "analyze marks unreadable partial" '"$VO" analyze --json "$T/noperm" | python3 -c "import json,sys; assert json.load(sys.stdin)[\"scan_status\"]==\"partial\""'
        chmod 755 "$T/noperm/sub"
    fi
    fallocate -l 60M "$T/bigfile" 2>/dev/null || dd if=/dev/zero of="$T/bigfile" bs=1M count=60 2>/dev/null
    check "analyze lists large files" '"$VO" analyze --json "$T" | python3 -c "import json,sys; d=json.load(sys.stdin); assert any(f[\"name\"]==\"bigfile\" for f in d[\"large_files\"])"'
fi

echo "== install.sh"
if command -v go >/dev/null 2>&1; then
    "$ROOT/install.sh" >/dev/null 2>&1
    check "install.sh creates vo link" '[[ -x "$HOME/.local/bin/vo" ]]'
    check "installed vo runs" '"$HOME/.local/bin/vo" --version 2>/dev/null | grep -q Vole'
    "$ROOT/install.sh" --uninstall >/dev/null 2>&1
    check "install.sh --uninstall removes links" '[[ ! -e "$HOME/.local/bin/vo" && ! -e "$HOME/.local/bin/vole" ]]'
    check "install.sh --uninstall removes lib dir" '[[ ! -e "$HOME/.local/share/vole" ]]'
else
    say "  (skipped: go not installed)"
fi

echo "== remove"
VOLE_YES=1 "$VO" remove </dev/null >/dev/null 2>&1
check "remove deletes config dir" '[[ ! -e "$XDG_CONFIG_HOME/vole" ]]'
check "remove deletes state dir" '[[ ! -e "$XDG_STATE_HOME/vole" ]]'
check "remove keeps the repo" '[[ -x "$ROOT/vole" ]]'

echo
echo "Passed: $PASS  Failed: $FAIL"
(( FAIL == 0 ))
