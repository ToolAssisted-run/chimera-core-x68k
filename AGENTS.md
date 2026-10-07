# AGENTS.md - MAME X68000 core for Chimera

This repository builds the Sharp X68000 of MAME as a sandboxed guest for
Chimera (https://github.com/ToolAssisted-run/chimera), a frontend for
tool-assisted speedruns. MAME is not forked: it is built for one machine, and
`waterbox/` replaces its frontend and OSD layer. The result is one file,
`x68k.chimeraCore`: the guest binary `core.wbx` plus the declarations Chimera
reads. Chimera ships no cores and downloads nothing; a user puts that file in
Chimera's `Cores` folder. `docs/BUILDING.md` has the detail behind every
command here.

## Layout

- `extern/mame/` - upstream MAME at a pinned commit (submodule). Never commit
  in it.
- `patches/` - numbered patches against `extern/mame`.
- `waterbox/checkout-mame.sh` - sparse checkout of MAME at the pin; the paths
  it takes are in `waterbox/mame-sparse.txt`.
- `waterbox/apply-patches.sh` - applies the series to the MAME tree.
- `waterbox/build-mame.sh` - MAME's libraries, `native` or `guest`.
- `waterbox/build-core.sh` - this repository's code linked against them.
- `waterbox/mame-flags.sh` - the flags MAME compiles its X68000 driver with.
- `waterbox/build-package.sh` - builds the guest and writes the package.
- `waterbox/run-gate.sh` - the gate. It builds both flavors itself.
- `waterbox/x68k-driver.cpp`, `wbx-entry.cpp`, `emulator-info.cpp`,
  `guest-syscalls.cpp` - the driver (MAME's frontend and OSD), the guest ABI.
- `waterbox/run-native.c`, `run-wbx.c`, `x68k-probe.cpp`, `gate-harness.h` -
  the native reference, the sandbox runner, the panel probe.
- `waterbox/gen-config.py` - GENERATES `waterbox.config`, `file_slots.json`
  and `default_keybinds.json` (all three committed).
- `waterbox/libco/` - ares's libco. `guest-shim/`, `native-shim/` - headers.
- `waterbox/bin/`, `build/` - build output (gitignored).
- `tests/roms-local/` - where the gate looks for firmware (gitignored).
- `docs/PLAN.md` - how it is built, what was pinned for determinism.

## Set up the build environment

Linux x86-64. CI uses `ubuntu-latest`.

```sh
sudo apt-get update
sudo apt-get install -y --no-install-recommends meson ninja-build build-essential cmake pkg-config python3 mono-complete xvfb libgl1-mesa-dev libegl-dev libx11-dev libxext-dev libasound2-dev

./waterbox/checkout-mame.sh           # MAME at the pinned commit, sparse

CHIMERA=/absolute/path/to/chimera     # a Chimera checkout, branch main, cloned --recursive
MB=$CHIMERA/extern/chimera-common-minibox

[ -f "$MB/build/meson-linux/build.ninja" ] || meson setup "$MB/build/meson-linux" "$MB"
meson compile -C "$MB/build/meson-linux"
[ -f "$MB/build/meson-cpp/build.ninja" ] || meson setup "$MB/build/meson-cpp" "$MB" -Dguest_cpp=true
meson compile -C "$MB/build/meson-cpp"
```

The gate's engine legs need `$CHIMERA/build/meson-linux/chimera-run`, and the
contract tests need Chimera's solution built with the .NET SDK 8.0: see
`docs/BUILDING.md`.

## Build

```sh
./waterbox/build-package.sh -m "$MB" -r "$CHIMERA"
./waterbox/build-core.sh native -m "$MB"     # the native reference, for the gate
```

The first command builds MAME's guest libraries when they are missing or out
of date (applying the patches first), builds `waterbox/bin/core.wbx`, checks
it and writes `$CHIMERA/build/Cores/x68k.chimeraCore`. With `-o <dir>` instead
of `-r`, the package goes to `<dir>/x68k.chimeraCore`. The second builds
`build/native/run-native` and `build/native/x68k-probe`. MAME's libraries are
built once per flavor and reused until what they were built from changes.

## Install the core into Chimera

`build-package.sh -r "$CHIMERA"` puts the package in `$CHIMERA/build/Cores/`,
the cores folder of a source checkout. The gate writes
`build/package/x68k.chimeraCore` instead; copy that file there. For a release
bundle, copy the `.chimeraCore` file into the `Cores` folder beside
`Chimera.exe` (or the folder set in File > Core Manager > Change folder...);
Refresh List rescans. The same file works on Linux and on Windows.

A package built by hand stamps `<commit>+local`, or `<commit>-dirty+local`
when the tree has changes (the patched `extern/mame` does not count). It is
for testing. Published packages come only from CI.

## Test before you commit

```sh
CHIMERA_ROOT="$CHIMERA" MINIBOX_DIR="$MB" ./waterbox/run-gate.sh
```

It must end with `0 failed`. Read the `skipped` count too:

- WITH `cgrom.dat`, `iplrom.dat` and `dogfight.dim` in `tests/roms-local/`
  (or in the folder `X68K_ROMS` names), every machine leg runs: boot, input,
  sound, native == sandbox, rerecord, settings, save data, the engine. This is
  the gate that counts for a change to the driver, the patches or the pin.
- WITHOUT them, five legs run: the native reference builds, the package
  builds, `core.wbx is not stale`, MAME's stack is a MAP_STACK mapping, and
  the declarations hold together. This is all CI runs. It boots no machine.

The firmware and the game are not distributed. If you have none, run the
ROM-less gate and say in your report that no machine leg ran. Do not call that
a green gate for a change in emulation behaviour.

## Rules of this repository

- Never commit inside `extern/mame`. A change to MAME is a numbered patch in
  `patches/` (paths relative to `extern/mame`, `git apply` format), taking the
  next number. The existing patches keep their code under the `CHIMERA_CORE`
  define; do the same. `./waterbox/apply-patches.sh` must then print
  `already applied: all <n> patches` on your tree.
- Determinism is the product. The guest must not read host time, host
  randomness or anything else that differs between runs, and a savestate must
  round-trip. No threads, no host clock, no SDL (`docs/PLAN.md`,
  "Determinism: what was pinned"). The machine legs check it; a change that
  breaks one is a bug, not a gate problem.
- Run the gate before committing. Every "the same" and every "it got there"
  leg has a negative control: a new leg needs one too.
- Do not hand-edit `waterbox/waterbox.config`, `waterbox/file_slots.json` or
  `waterbox/default_keybinds.json`. Edit `waterbox/gen-config.py` and run it
  (`waterbox/gen-config.py [--firmware DIR] [OUTDIR]`; it needs the firmware
  and the built `build/native/x68k-probe`). The gate compares the committed
  files with its output.
- If a change needs a MAME path that is not checked out, add it to
  `waterbox/mame-sparse.txt`.
- Keep `-DCO_MMAP_STACKS=1` on libco: without it the core dies on Windows.
- Never commit firmware, a ROM, a disk image or a game. Never add network
  access.
- The scripts under `waterbox/` must stay executable (git mode 100755): the
  workflow and the README run them directly.
- Documentation prose is plain ASCII.
- Commit messages: `type(scope): a sentence saying what is now true`, the
  scope optional, with the Chimera issue in parentheses when there is one, for
  example `fix(video): ... (chimera #209)`. Types in use: feat, fix, test,
  build. The body says what was measured and gives the gate's count.
- Do not edit `.github/workflows` unless the task is the workflow.

## Where to read more

- `docs/BUILDING.md` - every step, option and gate leg in detail.
- `docs/PLAN.md` - how MAME is isolated, the determinism table, the patches.
- `README.md` - controls, settings, save data, what a project needs.
- `.github/workflows/chimera.yml` - the authoritative build recipe.
- In the Chimera checkout: `docs/porting-a-core.md`, `docs/gates.md` (how a
  gate goes green on a broken thing) and `docs/core-manager.md`.
