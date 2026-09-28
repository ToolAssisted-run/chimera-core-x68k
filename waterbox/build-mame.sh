#!/bin/sh
# Builds the parts of MAME this core links, with MAME's own build system, for
# one flavor: native (the host compiler: the reference) or guest (miniBox's
# musl toolchain: what goes into core.wbx).
#
# THE EMULATOR IS UPSTREAM MAME, built the way MAME builds a single machine:
# SUBTARGET/SOURCES name the X68000's driver file, and MAME's makedep works
# out every CPU, device, sound chip and format it needs. Of the projects that
# generates, only the libraries are built - the emulator core, the devices, the
# driver and the third-party code they use. MAME's frontend (its UI, Lua,
# plugins), its OSD layer (SDL, OpenGL, audio and input back ends) and the
# executable are not: waterbox/ is this core's frontend and OSD.
#
# Usage: waterbox/build-mame.sh native|guest [-m <miniBox dir>] [-j N]
# Output: build/mame-<flavor>/linux_gcc/bin/x64/Release/*.a and the generated
# sources under build/mame-<flavor>/generated.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
flavor="${1:?native or guest}"; shift
mb="${MINIBOX_DIR:-$HOME/chimera/extern/chimera-common-minibox}"
jobs="$(nproc)"
while getopts "m:j:" opt; do
	case "$opt" in
		m) mb="$OPTARG" ;;
		j) jobs="$OPTARG" ;;
		*) exit 2 ;;
	esac
done

mame="$root/extern/mame"
builddir="$root/build/mame-$flavor"
mkdir -p "$builddir"

# One machine, and nothing MAME would add for a desktop.
# MAME's genie takes BUILDDIR as a path relative to the MAME tree (an absolute
# one is appended to it), so it is given one
params="SUBTARGET=x68k SOURCES=src/mame/sharp/x68k.cpp BUILDDIR=../../build/mame-$flavor
	NO_USE_PORTAUDIO=1 NO_USE_PULSEAUDIO=1 NO_USE_PIPEWIRE=1 NO_USE_MIDI=1
	NO_OPENGL=1 USE_QTDEBUG=0 NOWERROR=1 PYTHON_EXECUTABLE=python3"
# Every MAME object is built with these: CHIMERA_CORE switches on this core's
# patches; SOUND_DISABLE_THREADING runs the sound manager's output stage inline
# instead of on a thread of its own, whose timing is the host's (a thread woken
# by a condition variable decides which frame a sample lands in) and which the
# sandbox's scheduler cannot run the same way.
archopts="ARCHOPTS=-DCHIMERA_CORE -DSOUND_DISABLE_THREADING"

case "$flavor" in
	native) ;;
	guest)
		sr="$mb/build/meson-cpp/guest-sysroot"
		[ -f "$sr/lib/musl-gcc.specs" ] || {
			echo "miniBox guest sysroot not found at $sr: build it (meson setup $mb/build/meson-cpp $mb -Dguest_cpp=true && ninja -C $mb/build/meson-cpp)" >&2
			exit 1
		}
		gccver="$(gcc -dumpfullversion)"
		# the flags every guest object in this project is built with (see
		# chimera-cores/azahar/waterbox/guest-toolchain.cmake for each one's reason)
		wb="-I$here/guest-shim -specs=$sr/lib/musl-gcc.specs -fvisibility=hidden -mcmodel=large -mstack-protector-guard=global -fno-stack-protector -fno-pic -fno-pie -fcf-protection=none"
		wbxx="$wb -nostdinc++ -I$sr/include/c++/$gccver -I$sr/include/c++/$gccver/x86_64-linux-musl"
		params="$params TARGETOS=linux PTR64=1 NOASM=1"
		export OVERRIDE_CC="gcc $wb"
		export OVERRIDE_CXX="g++ $wbxx"
		;;
	*) echo "flavor is native or guest" >&2; exit 2 ;;
esac

sh "$here/apply-patches.sh"
cd "$mame"
# generate the projects (and the genie tool, once), then build the libraries
# shellcheck disable=SC2086
projdir="$(make $params "$archopts" -s -p -n generate 2>/dev/null | sed -n 's/^PROJECTDIR := //p' | head -1)"
# Always regenerated: MAME remakes its projects when its own scripts change,
# not when the flags given here do, and a flag that never reaches the
# makefiles is an object built the old way that nothing reports.
rm -f "$projdir/gmake-linux/Makefile"
# shellcheck disable=SC2086
make $params "$archopts" generate "$projdir/gmake-linux/Makefile"
make -C "$projdir/gmake-linux" config=release64 -j"$jobs" precompile
make -C "$projdir/gmake-linux" config=release64 -j"$jobs" \
	emu optional mame_x68k dasm formats utils \
	expat zlib flac 7z zstd utf8proc softfloat3 ymfm wdlfft jpeg ocore_sdl

# The driver list: the one machine this core runs (makedep's own list, as
# MAME's executable would compile it).
gen="$builddir/generated/mame/x68k"
mkdir -p "$gen"
echo "sharp/x68k.cpp" > "$builddir/generated/mame/x68k.flt"
python3 scripts/build/makedep.py -r "$mame/" driverlist src/mame/mame.lst -f "$builddir/generated/mame/x68k.flt" > "$gen/drivlist.cpp"
echo "built: $builddir/linux_gcc/bin/x64/Release"
