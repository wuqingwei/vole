# Vole 🐾

<p align="center">
  <b>Keep your Linux clean, light, and running like new.</b><br>
  Deep clean · smart uninstall · optimize · disk analyzer · live monitoring, in one terminal command.
</p>

<p align="center">
  <a href="https://github.com/wuqingwei/vole/actions/workflows/ci.yml"><img src="https://github.com/wuqingwei/vole/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/wuqingwei/vole/releases"><img src="https://img.shields.io/github/v/release/wuqingwei/vole?style=flat-square" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/platform-Linux-orange?style=flat-square" alt="Linux">
</p>

<p align="center"><a href="README.md">中文</a> · English</p>

---

Vole is a Linux take on [Mole](https://github.com/tw93/Mole). It keeps Mole's commands, menus and output style, and swaps the internals for Linux ones: XDG directories, apt / dnf / pacman / zypper, Flatpak, Snap, AppImage, systemd, `/proc` and `/sys`.

## Features

- **All-in-one toolkit**: BleachBit, an app uninstaller, ncdu and btop in one command
- **Deep clean**: user caches, thumbnails, trash, browser and developer caches, package caches, journal, crash dumps, old Snap revisions, unused Flatpak runtimes, leftovers of removed apps
- **Smart uninstaller**: deb / rpm / pacman packages, Flatpak, Snap, AppImage and apps installed into `~/.local` or `/opt`, with their caches; personal data is kept unless you choose it
- **Disk analyzer**: interactive TUI with Vim keys, filtering, multi-select, move to Trash, largest-files view and JSON output
- **Maintenance**: DNS flush, font / icon / menu / MIME caches, browser SQLite vacuum, failed systemd units, TRIM, SMART
- **Live monitoring**: CPU, memory, disk I/O, network, battery, thermals, fans, processes, zombies and a health score
- **Developer friendly**: purges `node_modules`, `target`, `build`, `.venv`, CMake and Qt Creator shadow builds, and Vivado `.Xil` / `<proj>.cache`

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/wuqingwei/vole/main/install.sh | bash
```

or

```bash
git clone https://github.com/wuqingwei/vole.git
cd vole && ./install.sh                 # into ~/.local, no sudo
./install.sh --prefix /usr/local        # system-wide
```

The installer takes the `analyze` / `status` binaries from a local `bin/` build, then from [Releases](https://github.com/wuqingwei/vole/releases), then builds them with Go if installed.

```bash
vo                      # Interactive menu
vo clean                # Deep cleanup
vo uninstall            # Remove apps + leftovers
vo optimize             # Refresh caches & services
vo analyze [path]       # Visual disk explorer
vo status               # Live system dashboard
vo purge                # Clean project build artifacts
vo installer            # Find and remove installer files
vo history [--json]     # What Vole removed
vo completion           # bash / zsh / fish completion
vo update | vo remove | vo --help | vo --version
```

Every destructive command supports `--dry-run`. `vo clean --whitelist`, `vo optimize --whitelist` and `vo purge --paths` set protection and scan roots. `vo clean --user-only` never touches system files.

## Machine-readable output

```bash
vo analyze --json ~/Documents          # entries with scan_status: complete | partial | unavailable
vo status --json                       # one snapshot
vo status | jq .health_score           # JSON automatically when piped
vo status --watch --interval 2s        # NDJSON stream
vo history --json
```

## Safety

- Run without `sudo`; Vole asks for administrator access only for system items.
- Protected paths (`/`, `/usr`, `/etc`, `/var`, `$HOME`, `~/.config`, `~/.local/share`, `~/.ssh`, `~/.gnupg`, keyrings…) are always refused. Symlinks are never followed; `rm --one-file-system`.
- An unreadable whitelist stops `clean`, `purge` and `optimize`.
- Expensive caches (Hugging Face, PyTorch, Playwright, JetBrains) are protected by default.
- Caches of running browsers, editors and Vivado are skipped.
- `purge` skips git-tracked files, nested repos and key material; artifacts touched in the last 7 days start unselected; non-interactive runs need `--yes`.
- `uninstall` refuses desktop shells, systemd, package managers and kernels, and warns when apt would remove extra packages.
- `analyze` moves items to Trash (freedesktop spec), so they can be restored.
- Activity is logged to `~/.local/state/vole/operations.log` (`VOLE_NO_OPLOG=1` disables it).

## Options

| Variable | Effect |
|---|---|
| `VOLE_CLEAN_DOCKER=1` (or `--docker`) | Also prune the Docker builder cache |
| `VOLE_ENABLE_TRIM=1` | Run TRIM once when fstrim.timer is off |
| `VOLE_ENABLE_DISK_VERIFY=1` | Check disks with smartctl |
| `VOLE_ENABLE_SWAP_REFRESH=1` | Move swap back to RAM when there is room |
| `VOLE_NO_OPLOG=1` | Do not write the operations log |
| `NO_COLOR=1` | Disable colors |

## Requirements

Linux, bash 4+, coreutils, findutils. Tested on Debian-family systems; dnf, pacman, zypper and apk are supported. Optional: `sqlite3`, `smartctl`, `gio`. Prebuilt `analyze` / `status` for amd64 and arm64; other architectures need Go 1.22+.

## Development

```bash
make build     # native analyze / status
make release   # static amd64 / arm64 binaries
make test      # integration tests in a throwaway $HOME
make lint      # shellcheck + go vet
```

Publishing a GitHub Release triggers Actions to build and attach the tarball, per-arch binaries and `SHA256SUMS`.

## Credits

Inspired by and modeled on [Mole](https://github.com/tw93/Mole) by [tw93](https://github.com/tw93). Distinct name and upstream credit, as Mole asks of derived projects.

## License

[GPL-3.0](LICENSE)
