#!/bin/sh
# Builds this core for one flavor, from the MAME libraries build-mame.sh made:
#
#   native: build/native/run-native (the gate's reference: the exports and the
#           driver linked for the host) and build/native/x68k-probe (the
#           driver's own API, for looking at ports and the panel)
#   guest:  waterbox/bin/core.wbx (the exports and the driver in miniBox's
#           sandbox) and waterbox/bin/run-wbx (the host that runs it)
#
# Every object here is compiled with exactly the flags MAME's own build gave
# its X68000 driver (mame-flags.sh), so this code and the MAME code it
# includes can never disagree about a define or a header.
#
# Usage: waterbox/build-core.sh native|guest [-m <miniBox dir>]
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
flavor="${1:?native or guest}"; shift
mb="${MINIBOX_DIR:-$HOME/chimera/extern/chimera-common-minibox}"
while getopts "m:" opt; do
	case "$opt" in
		m) mb="$OPTARG" ;;
		*) exit 2 ;;
	esac
done
mb="$(cd "$mb" && pwd)"
mame="$root/extern/mame"
lib="$root/build/mame-$flavor/linux_gcc/bin/x64/Release"
# MAME's libraries, rebuilt from nothing whenever what they were built from
# changes: the pinned commit, the patch series, build-mame.sh's flags, and for
# the guest the toolchain. A flag change rebuilds nothing in MAME's makefiles,
# and an object built the old way reports nothing either.
inputs="$( {
	git -C "$root" ls-tree HEAD extern/mame
	cat "$here/build-mame.sh" "$root"/patches/*.patch
	gcc -dumpfullversion
	[ "$flavor" = guest ] && cat "$mb/build/meson-cpp/guest-sysroot/lib/musl-gcc.specs"
} 2>/dev/null | sha1sum | cut -c1-40)"
stamp="$root/build/mame-$flavor/chimera-inputs"
if [ ! -f "$lib/libemu.a" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$inputs" ]; then
	[ -f "$lib/libemu.a" ] && { echo "MAME's $flavor inputs changed: rebuilding it"; rm -rf "$root/build/mame-$flavor"; }
	sh "$here/build-mame.sh" "$flavor" -m "$mb"
	echo "$inputs" > "$stamp"
fi
obj="$root/build/$flavor"
mkdir -p "$obj"

cxxcmd="$(sh "$here/mame-flags.sh" "$flavor")"
# shellcheck disable=SC2086
eval set -- $cxxcmd
cxx="$1"; shift
cxxflags="$*"

case "$flavor" in
	native)
		cc="gcc"
		cflags="-O2"
		shim="-I$here/native-shim"
		;;
	guest)
		sr="$mb/build/meson-cpp/guest-sysroot"
		cc="gcc -specs=$sr/lib/musl-gcc.specs -fvisibility=hidden -mcmodel=large -fno-stack-protector -fno-pic -fno-pie -fcf-protection=none"
		cflags="-O2"
		shim="-I$mb/extern/emulibc"
		;;
esac
guestinc="-I$mb/source/guest/include -I$mb/extern/jsmn"

compile_cxx() { # <source> <object> [extra flags]  (sh has no locals: cc_* names only)
	cc_src="$1"; cc_obj="$2"; shift 2
	# shellcheck disable=SC2086
	eval "$cxx" $cxxflags -I"$here" -I"$mame/src" -Wno-suggest-override "$@" -c "$cc_src" -o "$cc_obj"
}

objs=""
# MAME's OSD interface pieces the emulator core calls (input sequences, the
# network handler base, audio info) - the rest of MAME's OSD layer is not used
for part in inputseq nethandler audio; do
	compile_cxx "$mame/src/osd/interface/$part.cpp" "$obj/osd-$part.o"
	objs="$objs $obj/osd-$part.o"
done
compile_cxx "$root/build/mame-$flavor/generated/mame/x68k/drivlist.cpp" "$obj/drivlist.o"
compile_cxx "$here/x68k-driver.cpp" "$obj/x68k-driver.o"
compile_cxx "$here/emulator-info.cpp" "$obj/emulator-info.o"
compile_cxx "$here/wbx-entry.cpp" "$obj/wbx-entry.o" $shim $guestinc
# shellcheck disable=SC2086
eval $cc $cflags -c "$here/libco/libco.c" -o "$obj/libco.o"
objs="$objs $obj/drivlist.o $obj/x68k-driver.o $obj/emulator-info.o $obj/libco.o"

libs="$lib/mame_x68k/libmame_x68k.a $lib/mame_x68k/liboptional.a $lib/libemu.a $lib/mame_x68k/libdasm.a
	$lib/mame_x68k/libformats.a $lib/libutils.a $lib/libocore_sdl.a $lib/libexpat.a $lib/libzlib.a
	$lib/libflac.a $lib/lib7z.a $lib/libzstd.a $lib/libutf8proc.a $lib/libsoftfloat3.a $lib/libymfm.a
	$lib/libwdlfft.a $lib/libjpeg.a"

case "$flavor" in
	native)
		gcc -O2 -I"$here" -I"$here/native-shim" -c "$here/run-native.c" -o "$obj/run-native.o"
		# shellcheck disable=SC2086
		g++ -o "$obj/run-native" $objs "$obj/wbx-entry.o" "$obj/run-native.o" \
			-Wl,--start-group $libs -Wl,--end-group -lpthread -ldl -lutil
		compile_cxx "$here/x68k-probe.cpp" "$obj/x68k-probe.o"
		# shellcheck disable=SC2086
		g++ -o "$obj/x68k-probe" $objs "$obj/x68k-probe.o" \
			-Wl,--start-group $libs -Wl,--end-group -lpthread -ldl -lutil
		echo "built $obj/run-native $obj/x68k-probe"
		;;
	guest)
		mbuild="$mb/build/meson-cpp"
		compile_cxx "$here/guest-syscalls.cpp" "$obj/guest-syscalls.o"
		mkdir -p "$here/bin"
		# shellcheck disable=SC2086
		g++ -specs "$sr/lib/musl-gcc.specs" -mcmodel=large -fno-pic -fno-pie \
			-static -no-pie -Wl,--eh-frame-hdr,-O2,--no-relax,-z,stack-size=8388608 -T "$mb/source/guest/linkscript.T" \
			-Wl,-u,pthread_once -Wl,-u,pthread_cond_wait -Wl,-u,pthread_cond_broadcast -Wl,-u,pthread_key_create \
			-o "$here/bin/core.wbx" $objs "$obj/wbx-entry.o" "$obj/guest-syscalls.o" \
			"$mbuild/source/guest/cxxglue.c.o" "$mbuild/source/guest/emulibc.c.o" \
			-Wl,--start-group $libs -Wl,--end-group \
			-L"$sr/lib" -lstdc++ -lgcc -lgcc_eh -lc
		sh "$mb/source/guest/check-wbx.sh" "$here/bin/core.wbx"
		mbhost="$mb/build/meson-linux/source/host"
		gcc -O2 -Wall -I"$mb/source/host" -I"$here" -o "$here/bin/run-wbx" "$here/run-wbx.c" \
			"$mbhost/libminiboxhost.so" -Wl,-rpath,"$mbhost"
		echo "built $here/bin/core.wbx $here/bin/run-wbx"
		;;
esac
