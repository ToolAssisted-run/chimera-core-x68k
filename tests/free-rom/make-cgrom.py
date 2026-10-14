#!/usr/bin/env python3
"""make-cgrom.py <8x16 console font, .psf or .psf.gz> <out cgrom.dat>

The X68000's font ROM (cgrom.dat, 768 KB) holds every character the machine
draws its text with, and it is Sharp's: unlike the IPL-ROM it was never
released. For the test script's free machine (chimera issue 260) this makes
a stand-in from a free console font (the Linux console's Fixed fonts, public
domain): the 256 half-width characters, 8x16 at 0x3A800 where the real ROM
keeps them, and 8x8 at 0x3A000 made from the same shapes by keeping every
other row. Everything else - the kanji, the 12- and 24-dot sets - is left
empty. MAME says the checksum is wrong and runs on.
"""
import gzip
import struct
import sys

CGROM = 786432
ANK8x8 = 0x3A000
ANK8x16 = 0x3A800


def load_psf(path):
    data = open(path, "rb").read()
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    if data[:2] == b"\x36\x04":                     # PSF1
        mode, height = data[2], data[3]
        count = 512 if mode & 1 else 256
        glyphs = [data[4 + i * height:4 + (i + 1) * height] for i in range(count)]
        table = data[4 + count * height:] if mode & 2 else b""
        width, unicode_table, psf2 = 8, table, False
    elif data[:4] == b"\x72\xb5\x4a\x86":           # PSF2
        _, _, headersize, flags, count, size, height, width = struct.unpack("<8I", data[:32])
        glyphs = [data[headersize + i * size:headersize + (i + 1) * size] for i in range(count)]
        unicode_table, psf2 = (data[headersize + count * size:] if flags & 1 else b""), True
    else:
        sys.exit("%s: not a PSF font" % path)
    if width != 8 or height != 16:
        sys.exit("%s: %dx%d, not 8x16" % (path, width, height))
    # which glyph draws each code point (the identity when there is no table)
    where = {}
    if unicode_table:
        i, g = 0, 0
        if psf2:
            for entry in unicode_table.split(b"\xff"):
                for ch in entry.split(b"\xfe")[0].decode("utf-8", "replace"):
                    where.setdefault(ord(ch), g)
                g += 1
        else:
            while i + 1 < len(unicode_table) and g < len(glyphs):
                cp = unicode_table[i] | unicode_table[i + 1] << 8
                i += 2
                if cp == 0xFFFF:
                    g += 1
                elif cp != 0xFFFE:
                    where.setdefault(cp, g)
    return glyphs, where


def main():
    glyphs, where = load_psf(sys.argv[1])
    rom = bytearray(CGROM)
    for code in range(256):
        g = where.get(code, code if not where else None)
        if g is None or g >= len(glyphs):
            continue
        shape = glyphs[g]
        rom[ANK8x16 + code * 16:ANK8x16 + code * 16 + 16] = shape
        rom[ANK8x8 + code * 8:ANK8x8 + code * 8 + 8] = shape[0::2]
    open(sys.argv[2], "wb").write(rom)
    print("%s: %d half-width characters, 8x16 and 8x8" % (sys.argv[2], sum(1 for c in range(256) if where.get(c, c) is not None)))


if __name__ == "__main__":
    main()
