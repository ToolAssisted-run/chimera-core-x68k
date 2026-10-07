# chimera-core-x68k

The Sharp X68000 of [MAME](https://github.com/mamedev/mame) as a
[Chimera](https://github.com/ToolAssisted-run/chimera) core, running in
miniBox's sandbox (chimera#159).

MAME is not forked: `extern/mame` is upstream at a pinned commit, built the
way MAME builds a single machine (`SUBTARGET=x68k`, the one driver file
`src/mame/sharp/x68k.cpp`), with three small patches in `patches/`. Of that
build only the libraries are used - the emulator, the devices, the X68000
driver. MAME's own frontend and OSD layer are replaced by `waterbox/`: no
menus, no Lua, no SDL, no threads, no host clock. A Chimera frame is one turn
of MAME's own machine loop, from one VBLANK of the screen to the next.

## Controls

One controller, `X68000 Keyboard, Mouse and Joysticks`, in the order MAME's
X68000 declares its inputs:

- **two joysticks** (MAME plugs FM Towns pads in): Up, Down, Left, Right, A,
  B, Start (the pad's RUN) and Select;
- **the keyboard**, all 112 keys by their X68000 legends (`Key ROLL UP`,
  `Key XF1`, `Key OPT.1`, `Key Tenkey 5`, ...);
- **the mouse**: its two buttons, and Mouse X / Mouse Y, the movement this
  frame in pixels.

The panel is read from the running machine (`waterbox/gen-config.py`) and the
gate checks the package still declares the one the core binds. By default the
keyboard is the host's key for key (by position where the JIS legends differ;
OPT.1/OPT.2 are F11/F12), joystick 1 is on the first pad and on the arrows and
Z/X, and the mouse is the host's mouse.

Lag frames are not counted: a program reads the keyboard and the mouse from
what their interrupts left in RAM, so "the machine read no input this frame"
cannot be told from the hardware.

## Settings

- **IPL-ROM**: `ipl10` (IPL-ROM 1.0, `iplrom.dat`, the default), `ipl11`
  (the XVI's), `ipl12` (the Compact's), `ipl13` (the X68030's) or `cz600ce`
  (the first X68000's two chips). MAME's own default is `cz600ce`; this core's
  is the ROM most collections carry.
- **RAM**: 1M to 12M, default 4M.
- **Clock at power-on**: the RP5C15's date and time, `YYYY-MM-DD HH:MM:SS`,
  1980 to 2079, default `2000-01-01 00:00:00`. It runs with the machine from
  there, never with the host's clock.

All three are part of the machine: a movie needs the same values.

## Save data

The 16 KB battery-backed SRAM exports as `SRAM.DAT`, in the machine's byte
order (as a real X68000's reads), and the SRAM slot puts one back before the
machine powers on. MAME's own nvram file, in the host's byte order, is
recognised by its signature and taken too. Without one the machine powers on
with a blank SRAM and the IPL-ROM fills it in.

## What a project needs

- **Firmware**: `cgrom.dat` (the character generator ROM) and the IPL-ROM the
  setting names (`iplrom.dat` for the default).
- **Floppy disks**: one or two, in drives 0 and 1; the first is the one the
  machine boots. The X68000's own images (`.dim`, `.xdf`/`.hdm`/`.2hd`), the
  D88 family (`.d88`, `.d77`, `.1dd`), and MAME's other floppy containers
  (`.mfm`, `.td0`, `.imd`, `.86f`, `.cqm`, `.dsk`, `.mfi`, `.dfi`).

The package carries no ROM and no disk.

## Using it in Chimera

Chimera ships no cores and downloads nothing. Download the `.chimeraCore`
package from this repository's
[Releases](https://github.com/ToolAssisted-run/chimera-core-x68k/releases)
page, or build it, and put it in the `Cores` folder beside `Chimera.exe`.
File > Core Manager lists it. The same file works on Linux and on Windows.

## Building

[docs/BUILDING.md](docs/BUILDING.md) has the full instructions, as CI runs
them, and [AGENTS.md](AGENTS.md) is the operating guide for an AI coding
agent. In short:

```sh
./waterbox/checkout-mame.sh     # the part of MAME it builds, at the pinned commit
./waterbox/build-mame.sh native && ./waterbox/build-core.sh native   # run-native, x68k-probe
./waterbox/build-mame.sh guest                                       # MAME for miniBox's musl
./waterbox/build-package.sh     # core.wbx -> ~/chimera/build/Cores/x68k.chimeraCore
./waterbox/run-gate.sh          # the gate
```

`checkout-mame.sh` fetches a blobless, sparse, depth-1 clone of MAME at the
commit `extern/mame` is pinned to - the paths in `waterbox/mame-sparse.txt`,
about a third of MAME's tree; `git submodule update --init extern/mame` works
too. The guest build needs miniBox's C++ guest toolchain
(`$MINIBOX_DIR/build/meson-cpp`, by default the one in `~/chimera`).

The gate's machine legs need `cgrom.dat`, `iplrom.dat` and Dog Fight! as
`dogfight.dim` in `tests/roms-local` (or `X68K_ROMS`). Without them it builds,
packages, checks the declarations, and says it skipped every machine leg.

## Licence

This repository's own files are MIT (see `LICENSE`). MAME as a whole is under
the GNU GPL version 2 (`extern/mame/COPYING`), and so is the built core; the
X68000 driver and most of its devices are BSD-3-Clause. `waterbox/libco` is
ares's libco (ISC).
