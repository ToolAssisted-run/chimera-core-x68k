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
4. `posixfile.cpp`: a file MAME opens for writing (a floppy, the hard disk) is
   a copy in memory, read once from the file and then kept; nothing is ever
   written to a file, and a savestate holds what the machine wrote. Taken
   from chimera-core-mamehome (its 0011).
5. `floppy.cpp`: a disk taken out keeps what was written to it, by the name
   of its file, and putting it in again takes the kept image. With the image
   kept there is nothing to write back: the X68000 ejects disks itself, and
   its unload callback stops the motor, which wrote back an image that was no
   longer there and crashed (the gate's swap legs found it). From
   chimera-core-mamehome's 0012, without its CPC disk export.

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

## A free machine in CI (chimera issue 260, user-decided 2026-10-14)

A public runner may not hold Sharp's ROMs, so CI booted nothing. Sharp and
four other rights holders released the four IPL-ROMs for free use in 2000,
through the Sharp Products Users Forum; the X68000 LIBRARY distributes them
with the licence text, which allows use on Sharp X machines and their
emulators and redistribution free of charge only. The owner's decision: a
test may use one, downloaded in CI and never kept in this repository or put
in the package.

`tests/free-rom/fetch.sh` downloads `X68BIOSE.LZH` (IPL-ROM 1.0, the X68000
EXPERT's), refuses it unless its SHA-256 is the one `x68bios.ref` names, and
unpacks it with `lhasa`. Its `IPLROM.DAT` is byte for byte the `iplrom.dat`
MAME names. The font ROM was never released, so `make-cgrom.py` makes a
stand-in: the Linux console's public-domain Fixed 8x16 font where the real
ROM keeps its 8x16 half-width characters (0x3A800), the same shapes every
other row for the 8x8 ones (0x3A000), and nothing else. MAME reports the
wrong checksum and runs on. With no disk the IPL draws its "insert a disk"
box with the disk-and-hand picture; the Japanese text in it is empty,
because the stand-in has no kanji.

Not covered: a disk, so nothing after the IPL; and any text drawn in kanji.

## Disks and the hard disk (chimera issues 351 and 352, 2026-10-22)

A game can have any number of floppies. The first two are in drives 0 and 1
at power-on; each drive has Previous Disk, Next Disk and Eject Disk controls
of the core's own, after the machine's. They go through the project's list
(round the end), a drive passing over the disk in the other one, and act at
the start of the frame they are pressed for, in MAME's own turn. Whether a
drive holds a disk is asked of MAME each time: the IPL-ROM ejects a disk it
cannot start from. The SASI hard disk (MAME's x68k_hdc, `.hdf`) is the Hard
disk slot, mounted as MAME's `sasi` option; it is a copy in memory (patch 4)
and goes out with the save data under its own name.

The gate runs them on the free machine, so in CI too: three blank disks of the
gate's own, five presses, and what each drive holds after each one (the native
runner prints it with `X68K_DRIVES`); native == sandbox and a save and load
around every frame with those presses; and a blank hard disk of MAME's own
size coming back unchanged in the save data. Each of those was seen to fail
broken. Not tested: a game on several disks (no free one here), a program
writing to a disk and reading it back after a swap, and booting from a hard
disk (no bootable image here).

## Open

- What a program writes to a floppy stays in memory (and in savestates) and is
  not exported.
- **Lag frames** are not counted (see README): programs read the keyboard and
  mouse from RAM their interrupts fill. A joystick-port read tap would count
  something, but not the truth for a keyboard game.
- **Other models.** MAME's x68ksupr, x68kxvi and x68030 are in the same driver
  file and build; only the x68000 is offered. The XVI and 030 need more
  firmware (SCSI ROMs).
- **MIDI, expansion cards**: not offered. The hard disk is the original
  X68000's SASI one only.
- MAME's "Enable fake bus errors" configuration switch stays at its default
  (on).
- The package has not been run on Windows, nor in the GUI.
- Chimera: `SystemNames` has no entry for `X68000`, so it shows as the id.

## A project of a hard disk alone (2026-10-24, chimera#362)

A disk opened with no project has no slot map, and the core boots the file
rom.name names from the first floppy drive. That fallback also ran for a
project with no floppy: the engine mounts rom.name in a project too, naming
its first file, so a project of a hard disk alone put the .hdf in the floppy
drive, and MAME stopped: "Device 5.25" high density floppy drive load failed:
Unable to identify image file format" (exit code 4). The fallback now runs
only when there is no slot map; a project's files go where its slot map says.

Tested: the gate's new check "a project of a hard disk alone builds, its disk
in no floppy drive" (a blank SASI image in the Hard disk slot, rom.name naming
it, natively and in the sandbox) fails with the old fallback, with the
reported error, and passes with the new; the gate: 29 passed, 0 failed, 1
skipped (the free machine's legs: no X68K_FREE_ROMS folder here).
