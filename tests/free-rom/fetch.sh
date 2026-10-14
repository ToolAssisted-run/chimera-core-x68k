#!/bin/sh
# fetch.sh <out dir>: the test script's free X68000 (chimera issue 260).
#
# The machine cannot start without Sharp's IPL-ROM. Sharp and four other
# rights holders released the IPL-ROMs for free use in 2000, through the
# Sharp Products Users Forum, on these terms (the licence text, which comes
# with the file and goes wherever it goes): use on Sharp X machines and their
# emulators only, redistribution free of charge only, nothing for profit.
# The X68000 LIBRARY distributes them; this fetches version 1.0 (the X68000
# EXPERT's) from there, refuses a file that is not the one x68bios.ref names,
# and unpacks it with lhasa. The owner's decision (2026-10-14): for the tests
# only, downloaded in CI and never kept in this repository or put in the
# package.
#
# The font ROM was never released, so make-cgrom.py makes a stand-in for it
# from a public-domain console font (the Linux console's Lat15-Fixed16, from
# console-setup).
#
# Writes iplrom.dat, cgrom.dat and the licence text (licence.txt, as it came,
# in Shift JIS) to <out dir>.
set -eu
out="$1"
here="$(cd "$(dirname "$0")" && pwd)"
url="$(sed -n 's/^url //p' "$here/x68bios.ref")"
want="$(sed -n 's/^sha256 //p' "$here/x68bios.ref")"
font="${X68K_FREE_FONT:-/usr/share/consolefonts/Lat15-Fixed16.psf.gz}"
command -v lhasa >/dev/null 2>&1 || { echo "no lhasa: install lhasa"; exit 1; }
[ -f "$font" ] || { echo "no console font at $font: install console-setup-linux"; exit 1; }
rm -rf "$out"
mkdir -p "$out/lzh"
curl -sS -f -m 120 -o "$out/lzh/X68BIOSE.LZH" "$url"
have="$(sha256sum "$out/lzh/X68BIOSE.LZH" | cut -c1-64)"
if [ "$have" != "$want" ]; then
	echo "X68BIOSE.LZH is $have, not $want (tests/free-rom/x68bios.ref): not the file the test was written for"
	exit 1
fi
(cd "$out/lzh" && lhasa -xq X68BIOSE.LZH)
# the name is IPLROM.DAT in the archive; lhasa writes it in lower case
cp "$(find "$out/lzh" -iname iplrom.dat | head -1)" "$out/iplrom.dat"
cp "$(ls "$out/lzh"/*.txt | head -1)" "$out/licence.txt"
python3 "$here/make-cgrom.py" "$font" "$out/cgrom.dat" > /dev/null
echo "iplrom.dat: sha1 $(sha1sum "$out/iplrom.dat" | cut -c1-40) (Sharp's free IPL-ROM 1.0); cgrom.dat: a stand-in from $(basename "$font")"
