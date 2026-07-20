# BubiBoyLite

A CLI-centric Game Boy Color emulator written in Odin + SDL2. The executable is named `bbl`.

[![Build Linux](https://github.com/bubio/BubiBoyLite/actions/workflows/build-linux.yml/badge.svg)](https://github.com/bubio/BubiBoyLite/actions/workflows/build-linux.yml)
[![Build macOS](https://github.com/bubio/BubiBoyLite/actions/workflows/build-macos.yml/badge.svg)](https://github.com/bubio/BubiBoyLite/actions/workflows/build-macos.yml)

## Overview

BubiBoyLite plays Game Boy and Game Boy Color games. Launch it with a ROM to jump
straight into a game, or run it with no arguments to open a terminal UI (TUI) where
you can browse and start ROMs, all without leaving your terminal. Game controllers are
supported alongside the keyboard.

## Supported platforms

| OS | Architecture |
|---|---|
| macOS 13.5 or later | x86_64, Apple Silicon (arm64) |
| Ubuntu 22.04 or later | amd64, arm64 |

macOS builds are shipped as separate binaries per architecture (not universal binaries).
Windows, Raspberry Pi OS, and FreeBSD are not supported.

## Requirements

SDL2 must be installed on your system (BubiBoyLite links to it dynamically at runtime).

```sh
brew install sdl2               # macOS
sudo apt install libsdl2-2.0-0  # Linux
```

## Install

Download the zip for your platform from the
[Releases](https://github.com/bubio/BubiBoyLite/releases) page and extract it. Inside
you will find the `bbl` executable, `LICENSE`, and `README.md` in the same directory.

```sh
unzip bbl-<version>-<platform>-<arch>.zip
./bbl game.gbc
```

On macOS, Gatekeeper may warn that the developer cannot be verified the first time you
run it. If so, either run `xattr -d com.apple.quarantine ./bbl`, or right-click the
binary in Finder and choose **Open**.

## Usage

```
Usage: bbl [options] game.gbc

  -h, --help        Show command-line usage
  -v, --version     Show the version
  --scale N         Display scale (1-8; values above 8 are clamped to 8, default 4)
  --fullscreen      Fullscreen display (--scale is ignored)
  --shader KIND     Shader: nearest, smooth (default nearest)
  --recent          List recently used files and pick one
```

Run `bbl` with no ROM to open the TUI, which lists the `.gb`/`.gbc` files in the current
directory (or in `rom_dir` if configured). Use the arrow keys to select, Enter to start,
and `q` to quit. Passing `--recent` lets you pick from your history of recently used files
(up to 20). If a ROM is given on the command line, it takes priority and `--recent` is
ignored.

### Keyboard shortcuts (while a ROM is running)

```
  Arrow keys        D-pad
  Z / X             B / A
  Enter             Start
  Right Shift       Select
  F1-F4             Select save-state slot (1-4, default 1)
  F5                Save a save-state to the current slot
  F7                Load a save-state from the current slot
  Esc               Quit
```

While a game is running, the SDL window takes center stage, but the launching terminal
keeps showing a status line (FPS, volume, slot, cartridge type, etc.). You can also
control the emulator from the terminal with the following keys (they behave the same as
the SDL-window shortcuts):

| Key | Action |
|---|---|
| `+` / `-` | Volume up / down |
| `1`-`4` | Select save-state slot |
| `s` | Save to the current slot |
| `l` | Load from the current slot |
| `p` | Pause / resume |

## Configuration file (bbl.ini)

On first launch, a `bbl.ini` file is created with all default values in the same directory
as the executable. Command-line arguments temporarily override the values written here but
are never written back to the file (priority: CLI arguments > config file > defaults).
Text from `#` to the end of a line is treated as a comment.

| Key | Description | Default |
|---|---|---|
| `scale` | Display scale (1-8) | `4` |
| `fullscreen` | Fullscreen display (`true`/`false`) | `false` |
| `shader` | Shader (`nearest`/`smooth`) | `nearest` |
| `save_dir` | Where save files (`.sav`/`.rtc`) are stored. Empty means alongside the ROM | (empty) |
| `state_dir` | Where state files (`.state`) are stored. Empty means alongside the ROM | (empty) |
| `rom_dir` | Directory the TUI ROM list opens in. Empty means the current directory | (empty) |
| `volume` | Volume (0-100) | `100` |
| `key_up`/`key_down`/`key_left`/`key_right`/`key_a`/`key_b`/`key_start`/`key_select` | Keyboard bindings (SDL key names) | Arrow keys / Z·X / Enter / Right Shift |
| `pad_up`/`pad_down`/`pad_left`/`pad_right`/`pad_a`/`pad_b`/`pad_start`/`pad_select` | Game controller bindings (SDL button names) | D-pad / B·A / Start / Back |

`save_dir`/`state_dir` support `~` and environment variable expansion (e.g. `HOME`). If a
key/button binding conflicts with a save-state shortcut (F1-F5, F7) or the quit shortcut
(Esc), a warning is shown at startup.

## Build from source

You need [Odin](https://odin-lang.org/) and SDL2 (including development headers) installed.
This project pins the Odin version via [mise](https://mise.jdx.dev/).

```sh
sudo apt install libsdl2-dev   # Linux: SDL2 development headers (macOS: brew install sdl2)
mise install                   # Install the pinned Odin toolchain
./scripts/build_macos.sh       # On Linux, use build_linux.sh
```

Build script options:

- `--debug` — debug build
- `--release` — release build (optimized; on macOS also sets `-minimum-os-version`)
- `--test` — after building, also run `odin test tests -collection:bbl=src`

To create a distributable zip, run `./scripts/package_zip.sh <binary> <platform> <arch>`
(it bundles `bbl`/`LICENSE`/`README.md` with no directory nesting). Creating a tagged
GitHub Release automatically attaches the zips for every platform via CI.

## License

[MIT](LICENSE). Only the BubiBoyLite source code is covered.

BubiBoyLite does not support loading a real BIOS (boot ROM). At startup it sets the
post-boot register state for each mode directly.
