# Building the MAME X68000 core

This repository builds the Sharp X68000 of MAME as a sandboxed guest
(`core.wbx`) and packs it, with its declarations, into one file:
`x68k.chimeraCore`. Chimera loads that file. The steps below are the ones
`.github/workflows/chimera.yml` runs on a fresh clone on a public runner.
Where this document and the workflow disagree, the workflow is right.

Placeholders used below:

- `<chimera>`: the absolute path of a checkout of
  https://github.com/ToolAssisted-run/chimera
- `<minibox>`: `<chimera>/extern/chimera-common-minibox`, the miniBox submodule
  (the sandbox host and the guest toolchain)

Commands run from the root of this repository unless a step says otherwise.

## Requirements

- Linux on x86-64. CI uses GitHub's `ubuntu-latest` runner. Cores are built on
  Linux only. The package that comes out runs on Linux and on Windows.
- The packages CI installs (one list, for the core and for Chimera):

  ```sh
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends meson ninja-build build-essential cmake pkg-config python3 mono-complete xvfb libgl1-mesa-dev libegl-dev libx11-dev libxext-dev libasound2-dev
  ```

- The .NET SDK 8.0, for Chimera. The workflow uses `actions/setup-dotnet@v4`
  with `dotnet-version: '8.0'`. By hand, Chimera's README gives
  `curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 8.0`.
- The workflow pins no compiler version: it uses the gcc that
  `build-essential` installs. `build-package.sh` records the gcc, binutils and
  musl versions, the miniBox commit and the MAME commit in the package's
  `build.json`.
- What the scripts fetch or build themselves:
  - `waterbox/checkout-mame.sh` fetches MAME from the URL in `.gitmodules`, at
    the pinned commit. Nothing else is downloaded.
  - MAME's own build makes its project generator (genie) the first time.
  - The guest toolchain is built from the miniBox sources (see "Build
    miniBox").
- No firmware is needed to build. Sharp's ROMs and a game are needed to run
  the machine, and so for most of the gate (see "Run the gates").

## Get the sources

This repository. The workflow uses `actions/checkout@v6` WITHOUT submodules,
then checks out the part of MAME the core builds:

```sh
git clone https://github.com/ToolAssisted-run/chimera-core-x68k.git
cd chimera-core-x68k
./waterbox/checkout-mame.sh
```

`waterbox/checkout-mame.sh` takes no options. It makes `extern/mame` a
blobless, sparse, depth-1 clone of MAME at the commit `extern/mame` is pinned
to, holding only the paths in `waterbox/mame-sparse.txt`. If `extern/mame` is
already there at the pinned commit it does nothing; at any other commit it
stops with an error. A full `git submodule update --init extern/mame` works
as well.

A Chimera checkout. The workflow checks out branch `main` with every submodule
(`submodules: recursive`):

```sh
git clone --recursive https://github.com/ToolAssisted-run/chimera.git <chimera>
```

Where the scripts look for Chimera and miniBox when nothing says:

- `waterbox/run-gate.sh`: `CHIMERA_ROOT`, else `$HOME/chimera`; miniBox from
  `MINIBOX_DIR`, else `extern/chimera-common-minibox` under that.
- `waterbox/build-package.sh`: `../chimera` beside this repository, then
  `$HOME/chimera`; miniBox from `MINIBOX_DIR`, else inside that checkout.
- `waterbox/build-mame.sh` and `waterbox/build-core.sh`: `MINIBOX_DIR`, else
  `$HOME/chimera/extern/chimera-common-minibox`.

Set `CHIMERA_ROOT` and `MINIBOX_DIR`, as CI does, when the checkout is
anywhere else.

## Build miniBox

Two builds of miniBox: the host library, and the C++ guest toolchain
(`-Dguest_cpp=true`). These are the workflow's commands:

```sh
mb=<minibox>
[ -f "$mb/build/meson-linux/build.ninja" ] || meson setup "$mb/build/meson-linux" "$mb"
meson compile -C "$mb/build/meson-linux"
[ -f "$mb/build/meson-cpp/build.ninja" ] || meson setup "$mb/build/meson-cpp" "$mb" -Dguest_cpp=true
meson compile -C "$mb/build/meson-cpp"
```

The workflow keeps `build/meson-linux` and `build/meson-cpp` in
`actions/cache@v4`, keyed on the miniBox commit and its `meson.build`. By hand,
that is simply not deleting the two directories: the `[ -f ... ] ||` guards
skip the set-up when they exist.

## Build the core

In CI none of the commands of this section and the next is run directly: the
gate (`waterbox/run-gate.sh`) builds the native reference and the package
itself, which means MAME is built twice. They are here for building without
the gate.

### Patches

MAME is the submodule `extern/mame`, pinned and never committed to. This
repository's changes to it are the numbered patches in `patches/`, applied to
the submodule's working tree by:

```sh
./waterbox/apply-patches.sh
```

It takes no options. `build-mame.sh` runs it first, so a build needs no manual
step. It judges the series as a whole:

- a pristine tree gets every patch, in order (`applied: <patch>`);
- a tree that already carries the whole series is left alone
  (`already applied: all <n> patches`);
- anything in between is an error that names the files and prints the command
  that starts again from the submodule's HEAD;
- the series is tried on a scratch copy first, so a series that does not apply
  never half-patches the real tree;
- a tree that is not checked out is an error.

`MAME_TREE` points the script at another checkout (how the script itself is
tested). The patched code is switched on by the `CHIMERA_CORE` define, which
`build-mame.sh` gives every MAME object.

### MAME's libraries

```sh
./waterbox/build-mame.sh native
./waterbox/build-mame.sh guest -m <minibox>
```

Usage: `waterbox/build-mame.sh native|guest [-m <miniBox dir>] [-j N]`. `-j`
defaults to `nproc`.

MAME's own build system is told to build one machine (`SUBTARGET=x68k`,
`SOURCES=src/mame/sharp/x68k.cpp`), and only its libraries are built: the
emulator, the devices, the driver and the third-party code they use. `native`
uses the host compiler. `guest` uses miniBox's guest toolchain and stops if
`<minibox>/build/meson-cpp/guest-sysroot` is missing. The output is
`build/mame-<flavor>/linux_gcc/bin/x64/Release/*.a`, with generated sources
under `build/mame-<flavor>/generated`.

### The core, in two flavors

```sh
./waterbox/build-core.sh native -m <minibox>
./waterbox/build-core.sh guest -m <minibox>
```

Usage: `waterbox/build-core.sh native|guest [-m <miniBox dir>]`.

- `native` builds `build/native/run-native`, the native reference: the same
  exports and driver linked for the host, with no sandbox. The gate compares
  the sandboxed core against it. It also builds `build/native/x68k-probe`,
  which prints the machine's ports and panel (`waterbox/gen-config.py` uses
  it).
- `guest` builds `waterbox/bin/core.wbx` and `waterbox/bin/run-wbx`, the host
  program that runs it through miniBox, and runs miniBox's
  `source/guest/check-wbx.sh` on the core.

Both flavors need the miniBox checkout (its headers). `build-core.sh` runs
`build-mame.sh` itself when MAME's libraries are missing. It also rebuilds
them from nothing when what they were built from changed: the pinned commit,
the patch series, `build-mame.sh`, the gcc version, and for the guest the
toolchain's specs file. This repository's own sources are compiled with
exactly the flags MAME gave its X68000 driver (`waterbox/mame-flags.sh`).

## Build the package

```sh
./waterbox/build-package.sh -m <minibox> -r <chimera>
```

Options:

- `-m <miniBox dir>`: the miniBox checkout. Default: `MINIBOX_DIR`, then the
  one inside the Chimera checkout.
- `-r <chimera root>`: the Chimera checkout. The package goes to
  `<chimera>/build/Cores/x68k.chimeraCore`. Default: `../chimera`, then
  `$HOME/chimera`.
- `-o <dir>`: write `<dir>/x68k.chimeraCore` instead. No Chimera checkout is
  looked for; miniBox then comes from `-m`, `MINIBOX_DIR` or
  `$HOME/chimera/extern/chimera-common-minibox`.

What it does, in order:

1. Runs `build-core.sh guest` (MAME's guest libraries when needed, then
   `core.wbx`, checked).
2. Stages `core.wbx`, `waterbox.config`, `default_keybinds.json`,
   `file_slots.json`, the licence texts (from `waterbox/package-licenses.json`)
   and `build.json` (what built the package). The three declarations are
   packaged as committed; they are not regenerated here.
3. Stamps the version into the staged `waterbox.config`.
4. Writes the package, twice, and stops if the two files differ. It prints
   `package sha1 <hash>`: the package's SHA-1 is the core's identity.
5. With a Chimera checkout, removes `<chimera>/build/CoreCache/x68k-*`.

The version stamp:

- CI sets `CORE_VERSION` to the commit it built (`${{ github.sha }}`), and the
  script uses it as given.
- Without `CORE_VERSION`, the stamp is `<commit>+local` (12 hex digits), or
  `<commit>-dirty+local` when the tree has changes. The patched `extern/mame`
  does not count as a change here: the script tests with
  `--ignore-submodules=dirty`.
- `versionDate` is the commit's date in UTC, never the build's.

A hand-built package is for testing. Chimera's publish step refuses a version
carrying `+local` or `-dirty`.

## Install it into Chimera

Chimera ships no cores and downloads nothing: it has no network code. A core
gets there as a file.

- In a Chimera SOURCE checkout the cores folder is `<chimera>/build/Cores/`.
  `build-package.sh -r <chimera>` writes `x68k.chimeraCore` straight there.
  The gate does not: it writes `build/package/x68k.chimeraCore` in this
  repository, and the workflow copies it:

  ```sh
  mkdir -p <chimera>/build/Cores
  cp build/package/x68k.chimeraCore <chimera>/build/Cores/
  ```

  Start Chimera with `build/ChimeraMono.sh` on Linux or `build\Chimera.exe` on
  Windows.
- In a release bundle, copy the `.chimeraCore` file into the `Cores` folder
  beside `Chimera.exe`, or into the folder chosen in
  File > Core Manager > Change folder...
- File > Core Manager lists what is in the folder. Refresh List rescans it.

The same package file works on Linux and on Windows: Chimera's sandbox
(miniBox) runs the guest inside it on either.

Released packages are on this repository's Releases page
(https://github.com/ToolAssisted-run/chimera-core-x68k/releases): a rolling
`dev` release on every green push to `main`, and a dated `nightly-YYYY-MM-DD`
release from the scheduled run when `main` moved since the last one.

## Run the gates

### Core gate

The workflow builds Chimera before the gate (in `<chimera>`):

```sh
meson setup build/meson-linux --prefix "$PWD/build" --libdir dll
meson compile -C build/meson-linux
meson install -C build/meson-linux
dotnet build source/gui/Chimera.sln -c Release /nodeReuse:false -p:UseSharedCompilation=false
```

The first three commands give `<chimera>/build/meson-linux/chimera-run`, the
engine runner the gate's engine legs use. The `dotnet build` is for the
contract tests below.

Then, from this repository:

```sh
CHIMERA_ROOT=<chimera> MINIBOX_DIR=<minibox> ./waterbox/run-gate.sh
```

Options: `-r <chimera root>` and `-m <minibox dir>`.

The gate builds what it tests: `build-core.sh native`, then
`build-package.sh -o build/package`. Its work directory is `build/gate/`,
emptied at the start. Each leg prints `PASS`, `FAIL` or `SKIP`; it ends with
`<n> passed, <m> failed, <k> skipped` and exits non-zero on any failure, or
with `NOTHING RAN` when nothing passed. The workflow allows the job 180
minutes.

The machine legs need Sharp's firmware and a game, and neither is
distributed, so the gate has two shapes. It looks in `X68K_ROMS`, else in
`tests/roms-local/` (gitignored), for three files: `cgrom.dat`, `iplrom.dat`
and the floppy image of Dog Fight! named `dogfight.dim`.

WITHOUT those files (this is what CI runs), these legs run and nothing else:

- `the native reference and harness build`
- `package builds`
- `core.wbx is not stale`: newer than `x68k-driver.cpp`, `wbx-entry.cpp`,
  `emulator-info.cpp` and `build-core.sh`
- `MAME's stack is a MAP_STACK mapping`: the guest's libco takes its stack
  from `mmap`, not `malloc`, which is what the core needs to run on Windows
- `the declarations hold together`: every control has a binding entry, every
  IPL-ROM option has its firmware, `cgrom.dat` is always required, the slots
  are `floppy` and `savedata`

It then prints `SKIP every machine leg (ROM-less gate)` and stops. Nothing in
CI boots the machine, compares native with sandbox, or loads a savestate.

WITH the three files, every leg after that runs. They prove:

- `the declarations are gen-config.py's`: the three committed declaration
  files are exactly what `waterbox/gen-config.py` writes from the running
  machine;
- `the panel is the declared one`: the sandboxed core binds the panel the
  package declares (a swapped pair is caught);
- the game boots from its floppy, and the picture fills its buffer in a mode
  the machine did not boot in;
- joystick 1, the keyboard and the mouse reach the machine, and the sound is
  alive;
- native == sandbox as a per-frame digest stream (3400 frames of the game,
  600 frames of power-on, 1200 frames with the controls exercised), native is
  deterministic, a rerecord changes nothing, and a state reopens in a new
  host;
- the settings: the clock, a clock that is no date is refused, the RAM size,
  an IPL-ROM without its file is a load error that names it;
- the SRAM exports as save data and goes back in;
- the engine legs: the package in `chimera-run` has the native reference's
  RAM at frame 600, and refuses to start without `cgrom.dat`. Without
  `chimera-run` these report `SKIP the engine legs`.

Every "the same" and every "it got there" leg carries a negative control: a
run that must come out different through the same comparison.

### Chimera's contract tests

Chimera's own tests, run against the packages in a cores folder: readable,
built for a guest ABI this frontend runs, a working factory, binding only
declared buttons, stamping a version. They need no firmware. Copy the package
into `<chimera>/build/Cores/` first (see "Install it into Chimera"), then in
`<chimera>`:

```sh
CHIMERA_CORES_DIR=<chimera>/build/Cores \
dotnet test source/gui/Chimera.Tests.Client.Common/Chimera.Tests.Client.Common.csproj \
  -c Release --nologo \
  --filter "FullyQualifiedName~InstalledCorePackagesTests|FullyQualifiedName~MnemonicUniquenessTests"
```

## Files the core needs at run time

No ROM and no disk is in this repository or in the package. The user provides:

- Firmware (`waterbox/waterbox.config`, `firmware`):
  - `cgrom.dat`, the character generator ROM, always;
  - the IPL-ROM the IPL-ROM setting names: `iplrom.dat` for `ipl10` (the
    default), `iplromxv.dat` for `ipl11`, `iplromco.dat` for `ipl12`,
    `iplrom30.dat` for `ipl13`, or `rh-ix0897cezz.ic12` and
    `rh-ix0898cezz.ic11` for `cz600ce`.
- Floppy disks (`waterbox/file_slots.json`): one or two, for drives 0 and 1;
  the first is the one the machine boots. Formats: `.dim`, `.xdf`, `.hdm`,
  `.2hd`, `.d88`, `.d77`, `.1dd`, `.mfm`, `.td0`, `.imd`, `.86f`, `.cqm`,
  `.cqi`, `.dsk`, `.mfi`, `.dfi`.
- Optionally the SRAM the machine powers on with (`.dat`, `.nv`, `.bin`), as
  Export Save Data wrote it.

## Troubleshooting

- `extern/mame is checked out at <commit>, not the pinned <commit>`
  (`checkout-mame.sh`): the tree is at another commit. The script does not
  move an existing checkout.
- `miniBox guest sysroot not found at ...` (`build-mame.sh guest`): the
  `meson-cpp` build of miniBox is missing. The message prints the commands.
- `run waterbox/build-mame.sh <flavor> first` (`mame-flags.sh`): MAME's
  libraries for that flavor are not built.
- `MAME's <flavor> inputs changed: rebuilding it` (`build-core.sh`): expected
  after a change to the pin, the patches, `build-mame.sh`, gcc or the guest
  toolchain. MAME's makefiles rebuild nothing when a flag changes, so the
  script starts that flavor again from nothing.
- `extern/mame is partly patched` (`apply-patches.sh`): it names the files and
  prints the reset command. That command discards edits made in the tree: turn
  them into a patch first.
- `the series does not apply to the submodule's HEAD at <patch>`: the pin was
  moved without rebasing the patches.
- `chimera checkout not found; pass -r <path> or -o <dir>`
  (`build-package.sh`): give one of the two.
- `FAIL the declarations are gen-config.py's ... (run waterbox/gen-config.py)`:
  a declaration file was edited by hand, or the generator changed and was not
  run. `gen-config.py` needs the firmware and the built
  `build/native/x68k-probe`.
- `FAIL MAME's stack is a MAP_STACK mapping`: libco must be compiled with
  `-DCO_MMAP_STACKS=1`, as `build-core.sh` does, or the core dies on Windows.
- `checkout-mame.sh` checks out only the paths listed in
  `waterbox/mame-sparse.txt`. A change that makes the build need another MAME
  path must add it there.
