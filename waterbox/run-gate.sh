#!/bin/sh
# The X68000 core's gate.
#
# Written against ~/chimera/docs/gates.md, and the ways a gate has already been
# watched to go green on a broken thing:
#
#   * a DEAD machine finishes instantly and every digest agrees with itself,
#     so the machine legs assert the machine got somewhere first;
#   * an END-STATE digest misses a machine that ran differently and arrived
#     at the same place, so flavors are compared as a per-frame digest STREAM;
#   * a comparison that cannot fail proves nothing, so every "the same" and
#     every "it got there" leg has a NEGATIVE CONTROL: a run that must come
#     out different, through the same comparison;
#   * a guest build that failed was silently packaged as the PREVIOUS binary,
#     so the package leg checks core.wbx is newer than its sources.
#
# The machine legs need Sharp's firmware and a game, which cannot ship: put
# cgrom.dat, iplrom.dat and Dog Fight! as dogfight.dim (or links to them) in
# tests/roms-local, or point X68K_ROMS at a folder holding them. Without them
# the gate is ROM-LESS: it builds, packages and checks the declarations, and
# says - visibly - which legs it skipped.
#
# Usage: ./run-gate.sh [-r <chimera root>] [-m <minibox dir>]
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
chimera_root="${CHIMERA_ROOT:-$HOME/chimera}"
mb="${MINIBOX_DIR:-}"
roms="${X68K_ROMS:-$root/tests/roms-local}"
while getopts "r:m:" opt; do
	case "$opt" in
		r) chimera_root="$OPTARG" ;;
		m) mb="$OPTARG" ;;
		*) exit 2 ;;
	esac
done
[ -n "$mb" ] || mb="$chimera_root/extern/chimera-common-minibox"

work="$root/build/gate"
rm -rf "$work"; mkdir -p "$work"
native="$root/build/native/run-native"
probe="$root/build/native/x68k-probe"
wbxrun="$here/bin/run-wbx"
core="$here/bin/core.wbx"
run="$chimera_root/build/meson-linux/chimera-run"
pkg="$root/build/package/x68k.chimeraCore"
config="$here/waterbox.config"

pass=0; fail=0; skip=0
report() {
	case "$1" in
		PASS) pass=$((pass+1)) ;;
		FAIL) fail=$((fail+1)) ;;
		SKIP) skip=$((skip+1)) ;;
	esac
	printf '%-6s %-50s %s\n' "$1" "$2" "${3:-}"
}
finish() {
	printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
	[ "$pass" -eq 0 ] && { echo "NOTHING RAN"; exit 1; }
	[ "$fail" -eq 0 ] || exit 1
	exit 0
}
# check <label> <detail> <condition...>: PASS or FAIL on a shell condition
check() {
	label="$1"; detail="$2"; shift 2
	if "$@"; then report PASS "$label" "$detail"; else report FAIL "$label" "$detail"; fi
}
stream() { awk '/^frame/' "$1"; }
# field <report line> <name>: the value after a name in a report line
field() { echo "$1" | awk -v f="$2" '{for (i=1;i<=NF;i++) if ($i==f) {print $(i+1); exit}}'; }
at() { awk -v n="$2" '$1=="frame" && $2==n' "$1"; }
same() { [ -s "$1" ] && [ -s "$2" ] && cmp -s "$1" "$2"; }
differ() { [ -s "$1" ] && [ -s "$2" ] && ! cmp -s "$1" "$2"; }

# ---------------------------------------------------------------- 1. build
if sh "$here/build-core.sh" native -m "$mb" > "$work/native.log" 2>&1; then
	report PASS "the native reference and harness build"
else
	report FAIL "the native reference and harness build" "see build/gate/native.log"
fi
if sh "$here/build-package.sh" -m "$mb" -o "$root/build/package" > "$work/package.log" 2>&1; then
	report PASS "package builds" "$(grep -o 'sha1 [0-9a-f]*' "$work/package.log")"
else
	report FAIL "package builds" "see build/gate/package.log"
fi
stale=""
for src in "$here"/x68k-driver.cpp "$here"/wbx-entry.cpp "$here"/emulator-info.cpp "$here"/build-core.sh; do
	[ "$core" -nt "$src" ] || stale="$stale $(basename "$src")"
done
if [ -f "$core" ] && [ -z "$stale" ]; then
	report PASS "core.wbx is not stale"
else
	report FAIL "core.wbx is not stale" "older than:$stale"
fi

# MAME's cothread stack is a stack to the sandbox: mmap'd with MAP_STACK, not
# malloc'd. On Windows miniBox cannot deliver a fault on a page the stack
# pointer is in unless it was told the page is a stack, and the process died on
# the first frame with 0xC0000005 and no word (miniBox memblock.c). Linux runs
# the same core either way, so this is where it can be seen.
if nm "$root/build/guest/libco.o" 2>/dev/null | grep -q ' U mmap$' \
	&& ! nm "$root/build/guest/libco.o" 2>/dev/null | grep -q ' U malloc$'; then
	report PASS "MAME's stack is a MAP_STACK mapping" "what Windows needs to run it"
else
	report FAIL "MAME's stack is a MAP_STACK mapping" "libco.o takes it from malloc: the core dies on Windows"
fi

# The declarations hold together: every control has a binding entry, every
# IPL-ROM has its firmware, the slots are well formed. Needs nothing but them.
python3 - "$config" "$here/default_keybinds.json" "$here/file_slots.json" > "$work/decl.log" 2>&1 <<'PY' && ok=1 || ok=0
import json, sys
cfg = json.load(open(sys.argv[1])); kb = json.load(open(sys.argv[2])); slots = json.load(open(sys.argv[3]))
name = cfg["input"]["name"]
buttons = cfg["input"]["buttons"]; axes = [a["name"] for a in cfg["input"]["axes"]]
assert len(buttons) == len(set(buttons)), "a control is declared twice"
assert set(kb["AllTrollers"][name]) == set(buttons), "the keybinds are not the panel"
assert set(kb["AllTrollersAnalog"][name]) == set(axes), "the analog binds are not the axes"
ipl = next(s for s in cfg["settings"] if s["name"] == "ipl_rom")
for option in ipl["options"]:
    assert any(f.get("requiredWhen", {}).get("is") == option for f in cfg["firmware"]), f"no firmware for {option}"
assert any(f["id"] == "cgrom.dat" and "requiredWhen" not in f for f in cfg["firmware"])
ids = [s["id"] for s in slots["slots"]]
assert ids == ["floppy", "savedata"] and cfg["romFile"] == "floppy", ids
print(f"{len(buttons)} controls, {len(axes)} axes, {len(cfg['firmware'])} firmware files")
PY
if [ "$ok" = 1 ]; then
	report PASS "the declarations hold together" "$(cat "$work/decl.log")"
else
	report FAIL "the declarations hold together" "$(tail -1 "$work/decl.log")"
fi

if [ ! -f "$roms/cgrom.dat" ] || [ ! -f "$roms/iplrom.dat" ] || [ ! -f "$roms/dogfight.dim" ]; then
	report SKIP "every machine leg (ROM-less gate)" "needs cgrom.dat, iplrom.dat, dogfight.dim in $roms"
	finish
fi

# The declarations are what gen-config.py writes from the running machine:
# nobody hand-edits one of the three files and leaves the generator behind.
mkdir -p "$work/gen"
if python3 "$here/gen-config.py" --firmware "$roms" "$work/gen" > "$work/gen.log" 2>&1; then
	drift=""
	for f in waterbox.config file_slots.json default_keybinds.json; do
		cmp -s "$work/gen/$f" "$here/$f" || drift="$drift $f"
	done
	if [ -z "$drift" ]; then
		report PASS "the declarations are gen-config.py's"
	else
		report FAIL "the declarations are gen-config.py's" "differs:$drift (run waterbox/gen-config.py)"
	fi
else
	report FAIL "the declarations are gen-config.py's" "$(tail -1 "$work/gen.log")"
fi

# ---------------------------------------------------------- 2. the machine
# workdir <dir> [floppy] [savedata]: the files a project would mount
workdir() {
	d="$1"; rm -rf "$d"; mkdir -p "$d"
	for f in cgrom.dat iplrom.dat dogfight.dim; do ln -s "$roms/$f" "$d/$f"; done
	if [ -n "${2:-}" ]; then
		printf '{"floppy":["%s"]%s}' "$2" "${3:+,\"savedata\":[\"$3\"]}" > "$d/slots"
	else
		printf '{}' > "$d/slots"
	fi
	printf '{"ipl_rom":"ipl10","ram":"4M","clock":"2000-01-01 00:00:00"}' > "$d/settings"
}
w="$work/df"
workdir "$w" dogfight.dim

# the panel the core binds is the panel the package declares; the comparer is
# shown a declaration with two controls swapped and must refuse it
"$wbxrun" "$core" "$w" --frames 1 --list-panel > "$work/panel" 2>&1 || true
panelcheck() {
	python3 - "$1" "$work/panel" <<'PY'
import json, re, sys
cfg = json.load(open(sys.argv[1]))
got = [re.match(r"panel \d+ '(.*)' ", l).group(1) for l in open(sys.argv[2]) if l.startswith("panel ")]
axes = sum(1 for l in open(sys.argv[2]) if l.startswith("axis "))
if got != cfg["input"]["buttons"] or axes != len(cfg["input"]["axes"]):
    sys.exit(1)
print(f"{len(got)} controls and {axes} axes, all live" if all(
    l.rstrip().endswith("active") for l in open(sys.argv[2]) if l.startswith(("panel ", "axis "))) else "")
PY
}
python3 -c "
import json, sys
c = json.load(open(sys.argv[1])); b = c['input']['buttons']; b[4], b[5] = b[5], b[4]
json.dump(c, open(sys.argv[2], 'w'))" "$config" "$work/swapped.config"
if detail="$(panelcheck "$config")" && [ -n "$detail" ] && ! panelcheck "$work/swapped.config" > /dev/null; then
	report PASS "the panel is the declared one" "$detail; negative control: a swap is caught"
else
	report FAIL "the panel is the declared one" "see build/gate/panel"
fi

# The long runs, side by side: the game from power-on to its Player Select
# screen (Dog Fight! is at its title by frame 3000; joystick 1 Down picks
# "1up vs 2up", A enters it), idle, and with the keyboard and the mouse.
game="--press 1:3100:6 --press 4:3200:6"
nogame="$work/nodisk"
workdir "$nogame"
"$native" "$w" --frames 3400 --report 100 $game > "$work/game.n" 2>"$work/game.ne" &
"$wbxrun" "$core" "$w" --frames 3400 --report 100 $game > "$work/game.w" 2>/dev/null &
"$native" "$w" --frames 3400 --report 100 > "$work/idle.n" 2>/dev/null &
"$native" "$w" --frames 3300 --report 100 --press 77:3100:6 > "$work/key.n" 2>/dev/null &
"$native" "$w" --frames 3300 --report 100 --axis 0:10:3100:20 --axis 1:-5:3100:20 > "$work/mouse.n" 2>/dev/null &
"$native" "$nogame" --frames 3000 --report 100 > "$work/nodisk.n" 2>/dev/null &
wait

# reached: Dog Fight!'s title, in its 512x512 mode; with no disk in the drive
# the IPL-ROM is still asking for one at 768x512
title="$(field "$(at "$work/idle.n" 3000)" vid)"
nodisk="$(field "$(at "$work/nodisk.n" 3000)" vid)"
check "the game boots from its floppy" "frame 3000: $title; negative control: no disk, $nodisk" \
	[ "$title" = 512x512 -a "$nodisk" = 768x512 ]

# the input reaches the machine: each against the idle run, which the
# determinism leg below shows is the same every time
gamepic="$(field "$(at "$work/game.n" 3300)" vid)"
check "joystick 1 reaches the game" "Down, A: Player Select at $gamepic; negative control: idle stays at the title" \
	[ "$gamepic" = 256x512 -a "$(field "$(at "$work/idle.n" 3300)" vid)" = 512x512 ]
check "the keyboard reaches the machine" "Cursor Down at the title: RAM moves; negative control: idle" \
	[ "$(field "$(at "$work/key.n" 3300)" ram)" != "$(field "$(at "$work/idle.n" 3300)" ram)" ]
check "the mouse reaches the machine" "10,-5 a frame for 20 frames: RAM moves; negative control: idle" \
	[ "$(field "$(at "$work/mouse.n" 3300)" ram)" != "$(field "$(at "$work/idle.n" 3300)" ram)" ]

# the sound: silence while it boots, the game's music at the title, a frame's
# worth of samples every frame
pairs="$(stream "$work/idle.n" | awk '{print $9}' | sort -u | tr '\n' ' ')"
bootsnd="$(stream "$work/idle.n" | awk '$2 <= 2500 {print $10}' | sort -u | wc -l)"
titlesnd="$(stream "$work/idle.n" | awk '$2 > 3000 {print $10}' | sort -u | wc -l)"
check "the sound is alive, a frame's worth a frame" "$titlesnd distinct at the title, $bootsnd while booting; pairs: $pairs" \
	[ "$titlesnd" -ge 3 -a "$bootsnd" -le 2 ]

# native == sandbox, as a stream, over the whole game run; the idle run is
# the negative control through the same comparison
if same "$work/game.n" "$work/game.w" && differ "$work/game.n" "$work/idle.n"; then
	report PASS "native == sandbox (3400 frames, the game)" "34 reports; negative control: idle differs"
else
	report FAIL "native == sandbox (3400 frames, the game)" \
		"first difference: $(diff "$work/game.n" "$work/game.w" | awk 'NR==2' | cut -c1-60)"
fi

# power-on to Human68k, 600 frames reported every 25: the floppy's reads, the
# RAM disk, the clock. Deterministic, the same in the sandbox, across a
# rerecord around every frame and across a new host; a different clock at
# power-on is the negative control for all of them.
"$native" "$w" --frames 600 --report 25 > "$work/boot.n" 2>/dev/null &
"$native" "$w" --frames 600 --report 25 > "$work/boot.n2" 2>/dev/null &
"$wbxrun" "$core" "$w" --frames 600 --report 25 > "$work/boot.w" 2>/dev/null &
"$wbxrun" "$core" "$w" --frames 600 --report 25 --rerecord > "$work/boot.r" 2>"$work/boot.re" &
"$wbxrun" "$core" "$w" --frames 600 --report 25 --session > "$work/boot.s" 2>"$work/boot.se" &
wait
workdir "$work/clock" dogfight.dim
printf '{"clock":"1999-12-31 23:59:50"}' > "$work/clock/settings"
"$native" "$work/clock" --frames 600 --report 25 > "$work/clock.n" 2>/dev/null &
"$wbxrun" "$core" "$work/clock" --frames 600 --report 25 --rerecord > "$work/clock.r" 2>/dev/null &
wait
if same "$work/boot.n" "$work/boot.n2" && differ "$work/boot.n" "$work/clock.n"; then
	report PASS "native is deterministic (600 frames, power-on)" "24 reports; negative control: another clock differs"
else
	report FAIL "native is deterministic (600 frames, power-on)"
fi
if same "$work/boot.n" "$work/boot.w" && differ "$work/boot.w" "$work/clock.n"; then
	report PASS "native == sandbox (600 frames, power-on)" "negative control: another clock differs"
else
	report FAIL "native == sandbox (600 frames, power-on)"
fi
if same "$work/boot.w" "$work/boot.r" && differ "$work/boot.r" "$work/clock.r"; then
	report PASS "rerecord changes nothing" "$(grep -o 'stateBytes=[0-9]*' "$work/boot.re"); negative control: another clock"
else
	report FAIL "rerecord changes nothing"
fi
if same "$work/boot.w" "$work/boot.s" && differ "$work/boot.s" "$work/clock.n"; then
	report PASS "a state reopens in a new host" "at frame 300; negative control: another clock"
else
	report FAIL "a state reopens in a new host"
fi

# native == sandbox with every control wandered over (the keyboard, both
# joysticks, the mouse's buttons), 1200 frames of Human68k's boot
"$native" "$w" --frames 1200 --report 50 --exercise > "$work/ex.n" 2>/dev/null &
"$wbxrun" "$core" "$w" --frames 1200 --report 50 --exercise > "$work/ex.w" 2>/dev/null &
"$native" "$w" --frames 1200 --report 50 > "$work/ex.idle" 2>/dev/null &
wait
if same "$work/ex.n" "$work/ex.w" && differ "$work/ex.n" "$work/ex.idle"; then
	report PASS "native == sandbox (1200 frames, exercised)" "negative control: idle differs"
else
	report FAIL "native == sandbox (1200 frames, exercised)"
fi

# ------------------------------------------------------------ 3. settings
# setrun <name> <settings json> [run options]: 600 frames in the sandbox, the
# last report line (or the load error)
setrun() {
	d="$work/set-$1"; workdir "$d" dogfight.dim
	printf '%s' "$2" > "$d/settings"; shift 2
	"$wbxrun" "$core" "$d" --frames 600 --report 600 "$@" 2>&1 | tail -1
}
base="$(tail -1 "$work/boot.w")"
digits="$(setrun digits '{"clock":"20000101000000"}')"
check "the clock is part of the machine" "negative control: the default as digits is the default" \
	[ "$(field "$(tail -1 "$work/clock.n")" ram)" != "$(field "$base" ram)" -a "$(field "$digits" ram)" = "$(field "$base" ram)" ]
bad="$(setrun badclock '{"clock":"2000-02-30 12:00:00"}')"
case "$bad" in
	*"is not a date and time"*) report PASS "a clock that is no date is refused" "2000-02-30" ;;
	*) report FAIL "a clock that is no date is refused" "$bad" ;;
esac
setrun ram12 '{"ram":"12M"}' --dump-domain "Main RAM" "$work/ram12.bin" > "$work/ram12.log"
setrun ram4 '{"ram":"4M"}' --dump-domain "Main RAM" "$work/ram4.bin" > "$work/ram4.log"
r12="$(wc -c < "$work/ram12.bin" 2>/dev/null || echo 0)"; r4="$(wc -c < "$work/ram4.bin" 2>/dev/null || echo 0)"
check "the RAM setting sizes the machine" "12M: $r12 bytes; negative control: 4M, $r4" \
	[ "$r12" = 12582912 -a "$r4" = 4194304 ]
for ipl in ipl11 cz600ce; do
	missing="$(setrun "$ipl" "{\"ipl_rom\":\"$ipl\"}")"
	want=iplromxv.dat; [ "$ipl" = cz600ce ] && want=rh-ix0897cezz.ic12
	case "$missing" in
		*"needs $want"*) report PASS "$ipl without its ROM is a load error naming it" "$want" ;;
		*) report FAIL "$ipl without its ROM is a load error naming it" "$missing" ;;
	esac
done

# ----------------------------------------------------------- 4. save data
# The SRAM comes out in the machine's order (its signature first); a changed
# field (the RS-232C settings at 0x1A, which nothing at power-on touches)
# goes back in and comes out again, from the machine's order and from
# MAME's; without it the field is what the IPL-ROM writes.
mkdir -p "$work/sram0" "$work/sram1" "$work/sram2"
"$wbxrun" "$core" "$w" --frames 600 --report 600 --savedata-out "$work/sram0" > /dev/null 2>&1 || true
python3 - "$work/sram0/SRAM.DAT" "$work" <<'PY' || true
import sys
d = bytearray(open(sys.argv[1], "rb").read())
d[0x1a:0x1c] = b"\x12\x34"
open(sys.argv[2] + "/SRAM.DAT", "wb").write(d)
swapped = bytearray(len(d)); swapped[0::2] = d[1::2]; swapped[1::2] = d[0::2]
open(sys.argv[2] + "/mame.nv", "wb").write(swapped)
PY
workdir "$work/save1" dogfight.dim SRAM.DAT; cp "$work/SRAM.DAT" "$work/save1/"
workdir "$work/save2" dogfight.dim mame.nv; cp "$work/mame.nv" "$work/save2/"
"$wbxrun" "$core" "$work/save1" --frames 600 --report 600 --savedata-out "$work/sram1" > /dev/null 2>&1 || true
"$wbxrun" "$core" "$work/save2" --frames 600 --report 600 --savedata-out "$work/sram2" > /dev/null 2>&1 || true
sig="$(head -c 8 "$work/sram0/SRAM.DAT" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
f0="$(od -An -tx1 -j26 -N2 "$work/sram0/SRAM.DAT" 2>/dev/null | tr -d ' ')"
f1="$(od -An -tx1 -j26 -N2 "$work/sram1/SRAM.DAT" 2>/dev/null | tr -d ' ')"
size0="$(wc -c < "$work/sram0/SRAM.DAT" 2>/dev/null || echo 0)"
check "the SRAM exports in the machine's order" "$size0 bytes, $sig" \
	[ "$sig" = 8277363830303057 -a "$size0" = 16384 ]
if [ "$f1" = 1234 ] && [ "$f0" != 1234 ] && same "$work/sram1/SRAM.DAT" "$work/sram2/SRAM.DAT"; then
	report PASS "the SRAM goes back in" "0x1A: $f1, either byte order; negative control: $f0 without it"
else
	report FAIL "the SRAM goes back in" "0x1A: $f1 (without: $f0)"
fi

# ---------------------------------------------------------- 5. the engine
# The package in Chimera's engine (chimera-run): 600 idle frames of a movie,
# then its Main RAM against the native reference's at the same frame. The
# reference one frame either side is the negative control, and without its
# firmware the package refuses to start.
if [ -x "$run" ] && [ -f "$pkg" ]; then
	python3 - "$config" "$work/idle.movie" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))["input"]["buttons"]
console = sum(1 for n in b if not n.startswith(("P1 ", "P2 ")))
line = "|    0,    0," + "." * console + "|" + "." * 8 + "|" + "." * 8 + "|\n"
open(sys.argv[2], "w").write(line * 600)
PY
	"$run" "$pkg" "$roms/dogfight.dim" "$work/idle.movie" \
		--firmware cgrom.dat="$roms/cgrom.dat" --firmware iplrom.dat="$roms/iplrom.dat" \
		--dump "Main RAM=$work/engine.ram" > "$work/engine.log" 2>&1 || true
	for n in 599 600 601; do
		"$native" "$w" --frames "$n" --report "$n" --dump-domain "Main RAM" "$work/native$n.ram" > /dev/null 2>&1 || true
	done
	if grep -q '^frames=600' "$work/engine.log" && same "$work/engine.ram" "$work/native600.ram" \
		&& differ "$work/engine.ram" "$work/native599.ram" && differ "$work/engine.ram" "$work/native601.ram"; then
		report PASS "the engine runs it: RAM == native at 600" "negative control: frames 599 and 601 differ"
	else
		report FAIL "the engine runs it: RAM == native at 600" "see build/gate/engine.log"
	fi
	"$run" "$pkg" "$roms/dogfight.dim" "$work/idle.movie" \
		--firmware iplrom.dat="$roms/iplrom.dat" > "$work/nofw.log" 2>&1 || true
	if grep -q 'cgrom.dat' "$work/nofw.log" && ! grep -q '^frames=600' "$work/nofw.log"; then
		report PASS "without cgrom.dat the engine refuses it" "$(grep -o 'cgrom.dat[^"]*' "$work/nofw.log" | head -1 | cut -c1-50)"
	else
		report FAIL "without cgrom.dat the engine refuses it" "$(tail -1 "$work/nofw.log")"
	fi
else
	report SKIP "the engine legs" "no chimera-run at $run"
fi

finish
