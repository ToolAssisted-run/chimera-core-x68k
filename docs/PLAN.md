# chimera-core-x68k: plan and state

The Sharp X68000 for chimera#159, from MAME's x68k driver - which lives in
MAME's one big tree, so the work was isolating the machine from the rest of
MAME and running it as a core of its own.

## Phases

| Phase | What | State |
|---|---|---|
| 0 | MAME's libraries for one machine, native and for miniBox's musl | done |
| 1 | the driver: boot, frames, sound, the panel, native == sandbox | done |
| 2 | settings, firmware, floppies, SRAM, the declarations, the package | done |
| - | the gate: waterbox/run-gate.sh | done: 26 passed / 0 failed with the firmware and Dog Fight!; 4 passed / 1 skipped without |
| 3 | CI (sparse MAME checkout), a test on Windows, the roster, a release | CI written, not run; the rest needs the user |

## How it is built

MAME's own build, told to build one machine: `SUBTARGET=x68k
SOURCES=src/mame/sharp/x68k.cpp` (`waterbox/build-mame.sh`). MAME's makedep
works out every CPU, device, sound chip and floppy format that driver needs.
Of the projects genie generates, only the libraries are built: `emu`,
`optional`, `mame_x68k`, `dasm`, `formats`, `utils`, `ocore_sdl` and the
third-party ones (expat, zlib, flac, 7z, zstd, utf8proc, softfloat3, ymfm,
wdlfft, jpeg). MAME's frontend (UI, Lua, plugins), its OSD back ends and its
executable are not built.

The same script builds twice: with the host compiler (the native reference)
and with miniBox's musl toolchain (`OVERRIDE_CC`/`OVERRIDE_CXX`, `TARGETOS=linux
PTR64=1 NOASM=1`). Two defines reach every MAME object through `ARCHOPTS`:
`CHIMERA_CORE` (the patches) and `SOUND_DISABLE_THREADING` (below).

`waterbox/build-core.sh` compiles this repository's code with exactly the
flags MAME gave its X68000 driver (`mame-flags.sh` asks MAME's makefile), so
the two can never disagree about a define, and links `run-native` /
`x68k-probe` (native) or `core.wbx` / `run-wbx` (guest).

## The frontend and the OSD (waterbox/x68k-driver.cpp)

- A `machine_manager` whose UI is MAME's base `ui_manager`: no menus, no
  startup text, no warning screens. `before_load_settings` binds the panel
  and unthrottles the video manager; `ui_initialize` - after MAME's nvram
  load and the RTC, before the reset - puts the SRAM in.
- An `osd_interface`: the picture through MAME's own software renderer, of
  the "Pixel Aspect" view (the screen alone, at the machine's pixels; the
  default layout adds the drive and keyboard LEDs); one stereo 48 kHz sound
  node; the inputs as MAME input devices.
- MAME's machine loop returns only when the machine exits, so it runs on a
  libco cothread (16 MB stack). The OSD's `update()`, which MAME calls at
  every VBLANK of the screen, switches back to `x68k_frame()`'s caller: a
  frame is exactly one turn of MAME's loop, nothing reordered.

## Determinism: what was pinned

| Source | Fix |
|---|---|
| MAME paces the machine to the host clock and sleeps | `video_manager::set_throttled(false)` - the `throttle` option is read by MAME's frontend, not its emulator core - and `sleep 0` |
| the sound manager's output stage runs on a thread woken by a condition variable: which frame a sample lands in was the host's timing (and it spun at 100% CPU in the sandbox) | `SOUND_DISABLE_THREADING` |
| MAME's own periodic sound update runs at 50 Hz, not at the screen's rate | patch 0003: `chimera_flush()` at each frame's end - 859 or 860 samples a frame at 55.863 Hz |
| the RTC starts at the host's time; a `-rtc` MAME cannot parse also falls back to it | `rtc` always set; the core checks the value before MAME sees it |
| nvram, cfg and ini files from the working folder | `nvram_save 0`, `readconfig 0`, `writeconfig 0` |
| the host clipboard (SDL) | patch 0002 |

Proven by the gate: native == sandbox as a per-frame digest stream over 3400
frames (power-on to Player Select), over 1200 frames with every control
wandered over, and across a rerecord around every frame and a new host.

## The patches

1. `posixfile.cpp`: a file asked for inside a folder named after the system
   (`x68000/iplrom.dat`) is also found beside where that folder would be. The
   sandbox has no directories, only the files a project mounts by name.
2. `osdlib_unix.cpp`: no SDL, no host clipboard.
3. `sound.h`: `sound_manager::chimera_flush()`, a frame's sound at its end.

## The panel

Built from the machine's ports at `before_load_settings`: every digital field
MAME's X68000 declares - both joystick ports (FM Towns pads), the keyboard,
the mouse's buttons - bound to an item of its own on two "Chimera Panel"
keyboard devices, and the mouse's X/Y to the core's mouse. MAME's defaults
would put both joysticks on the keyboard. `x68k-probe --list-panel` prints
it, `gen-config.py` writes the declarations from it, and the gate compares
the sandbox's panel with the package's (a swapped pair is caught). The pad's
RUN is named Start, because Chimera's column letter for "Run" is Right's.

## Measured

- Dog Fight! (Biwahosi Software, 1992): Human68k boots from the floppy, the
  game copies itself to a RAM disk, and its title is up by frame 3000 (512x512
  at 56.07 Hz); joystick 1 Down and A reach Player Select (256x512).
- A savestate is about 15.9 MB with 4 MB of RAM.
- Native runs ~3.7 s per 900 frames of boot; the sandbox ~5.3 s.

## Open

- **More than two disks.** A game on three or four disks needs a disk swap
  control; MAME can change a drive's image at run time, the core does not
  offer it yet. What a program writes to a floppy stays in memory (and in
  savestates) and is not exported.
- **Lag frames** are not counted (see README): programs read the keyboard and
  mouse from RAM their interrupts fill. A joystick-port read tap would count
  something, but not the truth for a keyboard game.
- **Other models.** MAME's x68ksupr, x68kxvi and x68030 are in the same driver
  file and build; only the x68000 is offered. The XVI and 030 need more
  firmware (SCSI ROMs).
- **Hard disks, MIDI, expansion cards**: not offered.
- MAME's "Enable fake bus errors" configuration switch stays at its default
  (on).
- The package has not been run on Windows, nor in the GUI.
- Chimera: `SystemNames` has no entry for `X68000`, so it shows as the id.
