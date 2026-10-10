#!/usr/bin/env python3
"""Writes the package's declarations: waterbox.config, file_slots.json and
default_keybinds.json.

The panel is the machine's own: every input field MAME's X68000 declares, in
the order it declares them (x68k-driver.cpp, bind_panel). It is read from the
built core - x68k-probe --list-panel, which needs the firmware because MAME
builds the whole machine before it has ports - so nothing here restates it.
run-gate.sh holds the two together: it asks the core in the sandbox for its
panel and compares it with what this wrote, so a MAME update that moves a key
is a red gate, not a silent misbinding.

usage: waterbox/gen-config.py [--firmware DIR] [OUTDIR]
       (default: the firmware in tests/roms-local, and the three files beside
       this script)
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PROBE = os.path.join(ROOT, "build", "native", "x68k-probe")

# MAME's rom set for the x68000, x68k.cpp ROM_START( x68000 ): the IPL-ROM
# each setting boots, as MAME names the files
IPL_ROMS = [
    # setting, label, [(file, size, sha1)]
    ("ipl10", "IPL-ROM V1.0 (87/05/07)",
     [("iplrom.dat", 131072, "0ed038ed2133b9f78c6e37256807424e0d927560")]),
    ("ipl11", "IPL-ROM V1.1 (91/01/11), the X68000 XVI's",
     [("iplromxv.dat", 131072, "e33cdcdb69cd257b0b211ef46e7a8b144637db57")]),
    ("ipl12", "IPL-ROM V1.2 (91/10/24), the X68000 Compact's",
     [("iplromco.dat", 131072, "77511fc58798404701f66b6bbc9cbde06596eba7")]),
    ("ipl13", "IPL-ROM V1.3 (92/11/27), the X68030's",
     [("iplrom30.dat", 131072, "239e9124568c862c31d9ec0605e32373ea74b86a")]),
    ("cz600ce", "CZ-600CE IPL-ROM V1.0 (87/03/18), the first X68000's two chips",
     [("rh-ix0897cezz.ic12", 65536, "810cae207ffd29926e604cf1eb964ae8ea1fadb5"),
      ("rh-ix0898cezz.ic11", 65536, "f3d4a6506493ea3ac7b9c8e441d781fbdd61abd5")]),
]
RAM_SIZES = ["1M", "2M", "3M", "4M", "5M", "6M", "7M", "8M", "9M", "10M", "11M", "12M"]

# the floppy formats MAME's X68000 reads (x68k_state::floppy_formats: the
# X68000's own, then MAME's MFM containers)
FLOPPY_FORMATS = ["dim", "xdf", "hdm", "2hd", "d88", "d77", "1dd", "mfm", "td0", "imd",
                  "86f", "cqm", "cqi", "dsk", "mfi", "dfi"]
# the ones a file browser may open with this core without asking: the X68000's
# own formats, and D88, which most X68000 disk sets come in
OWN_EXTENSIONS = ["dim", "xdf", "hdm", "2hd", "d88"]

CONTROLLER = "X68000 Keyboard, Mouse and Joysticks"

# the host's keys for the X68000's, by position on a US keyboard where the
# legends differ (the JIS row's ^ @ [ ] : and the Yen key)
KEYS = {
    "ESC": "Escape", "-": "Minus", "^": "Equals", "BS": "Backspace", "TAB": "Tab",
    "@": "LeftBracket", "[": "RightBracket", "Enter": "Enter", ";": "Semicolon",
    ":": "Apostrophe", "]": "Backslash", ",": "Comma", ".": "Period", "/": "Slash",
    "Space": "Space", "HOME": "Home", "DEL": "Delete", "ROLL UP": "PageUp",
    "ROLL DOWN": "PageDown", "UNDO": "End", "Cursor Left": "Left", "Cursor Up": "Up",
    "Cursor Right": "Right", "Cursor Down": "Down", "Tenkey CLR": "NumLock",
    "Tenkey /": "KeypadDivide", "Tenkey *": "KeypadMultiply", "Tenkey -": "KeypadSubtract",
    "Tenkey +": "KeypadAdd", "Tenkey ENTER": "KeypadEnter", "Tenkey .": "KeypadDecimal",
    "CAPS": "CapsLock", "INS": "Insert", "Break": "Pause", "Copy": "PrintScreen",
    "SHIFT": "Shift, LeftShift, RightShift", "CTRL": "Ctrl, LeftCtrl, RightCtrl",
    "OPT.1": "F11", "OPT.2": "F12",
}
for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
    KEYS[c] = c
for d in "0123456789":
    KEYS[d] = "Number" + d
    KEYS["Tenkey " + d] = "Keypad" + d
for f in range(1, 11):
    KEYS[f"F{f}"] = f"F{f}"

# the first joystick on the host's arrows and Z/X as well as the first pad, as
# the DOSBox core does; the second on the second pad
PADS = {
    "Up": ("Up", "POV1U", "DpadUp, X{n} LStickUp"),
    "Down": ("Down", "POV1D", "DpadDown, X{n} LStickDown"),
    "Left": ("Left", "POV1L", "DpadLeft, X{n} LStickLeft"),
    "Right": ("Right", "POV1R", "DpadRight, X{n} LStickRight"),
    "A": ("Z", "B1", "A"),
    "B": ("X", "B2", "B"),
    "Start": ("", "B8", "Start"),
    "Select": ("", "B7", "Back"),
}


def panel(firmware):
    """The core's panel, from the core."""
    for need in ("cgrom.dat", "iplrom.dat"):
        if not os.path.exists(os.path.join(firmware, need)):
            sys.exit(f"gen-config: {need} is not in {firmware} - the panel is read from the "
                     "running machine, which needs its firmware (--firmware DIR)")
    out = subprocess.run([PROBE, "--rompath", firmware, "--opt", "bios=ipl10", "--list-panel"],
                         capture_output=True, text=True, check=True).stdout
    names = [line.split("\t", 1)[1] for line in out.splitlines() if "\t" in line]
    if len(names) < 100:
        sys.exit(f"gen-config: the probe listed {len(names)} controls")
    return names


def binding(name):
    if name.startswith("Key "):
        return KEYS.get(name[4:], "")
    if name == "Mouse Left":
        return "WMouse L"
    if name == "Mouse Right":
        return "WMouse R"
    player, _, control = name.partition(" ")
    if player in ("P1", "P2") and control in PADS:
        n = int(player[1])
        host, joy, pad = PADS[control]
        parts = ([host] if host and n == 1 else []) + [f"J{n} {joy}", f"X{n} {pad.format(n=n)}"]
        return ", ".join(parts)
    return ""


# ---- what the controls and the system are called ----
# The frontend keeps no table of these: a core says what its own are called.
# MNEMONICS is the letter each button writes into a movie's text and heads its
# input column with, by the button's name - whole, or without its player ("P2
# Up" is found under "Up"), so one line serves every pad. AXIS_HEADERS is the
# short header of each axis's column. (An entry is read by position: a letter
# may change and no movie made before it is harmed.)
MNEMONICS = {
    "Up": "U", "Down": "D", "Left": "L", "Right": "R", "A": "A", "B": "B", "Start": "S",
    "Select": "s", "Key ESC": "E", "Key 1": "1", "Key 2": "2", "Key 3": "3", "Key 4": "4",
    "Key 5": "5", "Key 6": "6", "Key 7": "7", "Key 8": "8", "Key 9": "9", "Key 0": "0",
    "Key -": "-", "Key ^": "^", "Key Yen": "Y", "Key BS": "B", "Key TAB": "T", "Key Q": "Q",
    "Key W": "W", "Key E": "E", "Key R": "r", "Key T": "T", "Key Y": "Y", "Key U": "U",
    "Key I": "I", "Key O": "O", "Key P": "P", "Key @": "@", "Key [": "[", "Key Enter": "E",
    "Key A": "A", "Key S": "S", "Key D": "D", "Key F": "F", "Key G": "G", "Key H": "H",
    "Key J": "J", "Key K": "K", "Key L": "l", "Key ;": ";", "Key :": ":", "Key ]": "]",
    "Key Z": "Z", "Key X": "X", "Key C": "C", "Key V": "V", "Key B": "B", "Key N": "N",
    "Key M": "M", "Key ,": ",", "Key .": "p", "Key /": "/", "Key _": "_", "Key Space": "S",
    "Key HOME": "H", "Key DEL": "D", "Key ROLL UP": "U", "Key ROLL DOWN": "D", "Key UNDO": "U",
    "Key Cursor Left": "L", "Key Cursor Up": "U", "Key Cursor Right": "R", "Key Cursor Down": "D",
    "Key Tenkey CLR": "C", "Key Tenkey /": "/", "Key Tenkey *": "*", "Key Tenkey -": "-",
    "Key Tenkey 7": "7", "Key Tenkey 8": "8", "Key Tenkey 9": "9", "Key Tenkey +": "+",
    "Key Tenkey 4": "4", "Key Tenkey 5": "5", "Key Tenkey 6": "6", "Key Tenkey =": "=",
    "Key Tenkey 1": "1", "Key Tenkey 2": "2", "Key Tenkey 3": "3", "Key Tenkey ENTER": "E",
    "Key Tenkey 0": "0", "Key Tenkey ,": ",", "Key Tenkey .": "T", "Key Symbol input": "i",
    "Key Register": "R", "Key Help": "H", "Key XF1": "X", "Key XF2": "X", "Key XF3": "X",
    "Key XF4": "X", "Key XF5": "X", "Key Kana": "K", "Key Romaji": "R", "Key Code input": "i",
    "Key CAPS": "C", "Key INS": "I", "Key Hiragana": "H", "Key Fullwidth": "F", "Key Break": "B",
    "Key Copy": "C", "Key F1": "1", "Key F2": "2", "Key F3": "3", "Key F4": "4", "Key F5": "5",
    "Key F6": "6", "Key F7": "7", "Key F8": "8", "Key F9": "9", "Key F10": "0", "Key SHIFT": "S",
    "Key CTRL": "C", "Key OPT.1": "O", "Key OPT.2": "O", "Mouse Right": "r", "Mouse Left": "l",
}
AXIS_HEADERS = {
    "Mouse X": "mX", "Mouse Y": "mY",
}
SYSTEM_NAMES = {
    "X68000": "Sharp X68000",
}


def _bare(name):
    """A control's name without its player: "P2 Up" -> "Up"."""
    head, _, rest = name.partition(" ")
    return rest if rest and head[:1] == "P" and head[1:].isdigit() else name


def mnemonics_for(buttons):
    """The "mnemonics" of an input declaration: a letter for every one of its
    buttons, and for nothing else. A button nobody gave a letter stops the
    build - the engine would give it its rule's guess, and two columns of one
    pad would share a letter with nobody having decided it."""
    out = {}
    for b in buttons:
        key = b if b in MNEMONICS else _bare(b)
        if key not in MNEMONICS:
            raise SystemExit("no mnemonic for the button %r (MNEMONICS in %s)" % (b, __file__))
        out[key] = MNEMONICS[key]
    return out


def with_headers(axes):
    """The axes with their column headers; an axis nobody named stops the build."""
    missing = [a["name"] for a in axes if a["name"] not in AXIS_HEADERS]
    if missing:
        raise SystemExit("no header for the axes %s (AXIS_HEADERS in %s)" % (missing, __file__))
    return [dict(a, header=AXIS_HEADERS[a["name"]]) for a in axes]


def main():
    args = sys.argv[1:]
    firmware = os.path.join(ROOT, "tests", "roms-local")
    if args[:1] == ["--firmware"]:
        firmware, args = args[1], args[2:]
    out = args[0] if args else HERE
    buttons = panel(firmware)

    firmware_decls = [{
        "id": "cgrom.dat",
        "display": "Character generator ROM (cgrom.dat)",
        "description": (
            "The X68000's font ROM (768 KB). It holds the kanji, kana and "
            "ASCII characters that every model draws its text with. It is "
            "Sharp's and you have to supply it. The same file is used with "
            "every IPL-ROM."
        ),
        "name": "cgrom.dat",
        "size": 786432,
        "sha1": "8d72c5b4d63bb14c5dbdac495244d659aa1498b6",
    }]
    for setting, label, files in IPL_ROMS:
        for name, size, sha1 in files:
            firmware_decls.append({
                "id": name,
                "display": f"{label} ({name})",
                "description": (
                    f"The {label}. The IPL-ROM setting \"{setting}\" starts the machine from this "
                    "file, which has the name MAME gives it. It is Sharp's and you have to supply it."
                ),
                "name": name,
                "size": size,
                "sha1": sha1,
                "requiredWhen": {"setting": "ipl_rom", "is": setting},
            })

    config = {
        "coreName": "MAME X68000",
        "systemId": "X68000",
        "systemNames": SYSTEM_NAMES,
        "author": "The MAME team; chimera port by Sergio Martin",
        "url": "https://github.com/ToolAssisted-run/chimera-core-x68k",
        "romFile": "floppy",
        "deterministic": True,
        "memoryLayoutMiB": [64, 8, 8, 64, 768],
        "_memoryLayoutMiB_note": (
            "sbrk, sealed, invisible, plain, mmap. MAME allocates the machine - its 1 to 12 MB "
            "of RAM, the video RAMs, the floppies as MAME holds them - with new, which lands "
            "on the mmap heap; a savestate is about 16 MB at 4 MB of RAM."
        ),
        "video": {
            "_comment": (
                "The BUFFER CAPACITY. The X68000 changes mode as it likes (256 to 768 pixels "
                "wide, 240 to 512 lines, 31 or 15 kHz), so the live size comes from "
                "GetVideoWidth/Height every frame; the picture is handed out at the machine's "
                "own pixels and shown at 4:3."
            ),
            "width": 1024,
            "height": 1024,
            "virtualWidth": 768,
            "virtualHeight": 576,
            "vsyncNumerator": 55863,
            "vsyncDenominator": 1000,
            "_vsync_note": (
                "The 55.863 Hz the machine boots at (the IPL-ROM's 768x512 mode, 31 kHz). A "
                "program that picks another mode picks another rate, and GetVsyncNumerator "
                "reports the screen's rate as the machine runs it now, in thousandths of a hertz."
            ),
            "getBgra": "GetVideoBgra",
        },
        "audio": {
            "_comment": (
                "MAME's mix of the YM2151 and the MSM6258 ADPCM, 48 kHz stereo, all of a "
                "frame's at its end: 859 or 860 pairs a frame at 55.863 Hz."
            ),
            "rate": 48000,
            "samplesPerFrame": 4096,
            "channels": 2,
            "get": "GetAudio",
        },
        "extensions": {"." + e: "X68000" for e in OWN_EXTENSIONS},
        "input": {
            "name": CONTROLLER,
            "_comment": (
                "The machine's own controls, in the order MAME's X68000 declares them: the two "
                "joystick ports (FM Towns pads: the four directions, A, B, RUN - named Start, "
                "which it is - and Select), the "
                "keyboard key by key, the mouse's two buttons. Generated from the core "
                "(gen-config.py); wider than 64, so every button rides SetButton. The axes "
                "are the mouse's movement this frame, in pixels."
            ),
            "buttons": buttons,
            "mnemonics": mnemonics_for(buttons),
            "axes": with_headers([
                {"name": "Mouse X", "min": -127, "max": 127, "neutral": 0},
                {"name": "Mouse Y", "min": -127, "max": 127, "neutral": 0},
            ]),
        },
        "settings": [
            {
                "name": "ipl_rom",
                "display": "IPL-ROM",
                "type": "enum",
                "options": [s for s, _, _ in IPL_ROMS],
                "default": "ipl10",
                "description": (
                    "Which IPL-ROM (the X68000's BIOS) the machine boots: " + "; ".join(
                        f"{s} = {label}" for s, label, _ in IPL_ROMS) + ". Each is its own "
                    "firmware file. MAME's own default is cz600ce; this core's is ipl10, "
                    "the ROM most collections carry as iplrom.dat. Part of the machine: a movie "
                    "needs the same one."
                ),
            },
            {
                "name": "ram",
                "display": "RAM",
                "type": "enum",
                "options": RAM_SIZES,
                "default": "4M",
                "description": (
                    "The main memory, from 1 to 12 MB. An X68000 was sold "
                    "with 1 or 2 MB. MAME's default and this core's is 4 MB,"
                    " which is enough for most software. It is part of the "
                    "machine, so a movie needs the same size."
                ),
            },
            {
                "name": "clock",
                "display": "Clock at power-on",
                "type": "string",
                "default": "2000-01-01 00:00:00",
                "description": (
                    "The date and time of the machine's clock (the RP5C15 "
                    "chip) at power-on, written as YYYY-MM-DD HH:MM:SS, from"
                    " 1980 to 2079. From there it runs with the emulated "
                    "machine and never with your computer's clock. The "
                    "Human68k system stamps files with it and some programs "
                    "pick their random numbers from it. It is part of the "
                    "machine, so a movie needs the same value."
                ),
            },
        ],
        "firmware": firmware_decls,
    }
    with open(os.path.join(out, "waterbox.config"), "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=True)
        f.write("\n")

    slots = {
        "_comment": "This file lists the kinds of file an X68000 project can hold. "
            "Chimera's New Project window is built from it. A project is its"
            " floppy disks, and the SRAM it starts with.",
        "slots": [
            {
                "id": "floppy",
                "title": "Floppy disks",
                "min": 1,
                "max": 2,
                "formats": FLOPPY_FORMATS,
                "help": (
                    "The disks in drives 0 and 1, in that order. The machine"
                    " starts from the first one. Accepted are the X68000's "
                    "own image formats (.dim, .xdf, .hdm, .2hd), the D88 "
                    "family, and MAME's floppy formats (.mfm, .td0, .imd, "
                    ".86f, .mfi and others). A game on more than two disks "
                    "needs its first two here."
                ),
            },
            {
                "id": "savedata",
                "title": "SRAM",
                "min": 0,
                "max": 1,
                "formats": ["dat", "nv", "bin"],
                "help": (
                    "The machine's 16 KB of battery-backed memory (SRAM) as "
                    "it is at power-on, in the file Export Save Data wrote "
                    "(SRAM.DAT). It holds the machine's settings (start-up "
                    "device, screen mode, memory switches) and anything a "
                    "program stored there. The file is in the byte order a "
                    "real X68000 reads. MAME's own nvram file is also "
                    "recognised and accepted. With no file the machine "
                    "starts with an empty SRAM, which the IPL-ROM then fills"
                    " in."
                ),
            },
        ],
    }
    with open(os.path.join(out, "file_slots.json"), "w") as f:
        json.dump(slots, f, indent=2, ensure_ascii=True)
        f.write("\n")

    binds = {CONTROLLER: {name: binding(name) for name in buttons}}
    kb = {
        "_comment": [
            "The keyboard key for key, by position where the JIS legends differ (^ on =, @ on [, "
            "[ on ], : on ', ] on \\); Yen, _, the XF keys, Kana, Romaji, Code input, Symbol "
            "input, Register, Help, Hiragana, Fullwidth and the keypad's = and , ship unbound. "
            "OPT.1 and OPT.2 are F11 and F12, UNDO is End, ROLL UP and DOWN are Page Up and "
            "Down, CLR is Num Lock, Break is Pause and Copy is Print Screen.",
            "Joystick 1 on the arrows and Z/X (A/B) as well as the first pad, as the DOSBox "
            "core does; joystick 2 on the second pad. The mouse on the host's mouse.",
        ],
        "AllTrollers": binds,
        "AllTrollersAutoFire": {CONTROLLER: {}},
        "AllTrollersAnalog": {CONTROLLER: {
            "Mouse X": {"Value": "RMouse X", "Mult": 1.0, "Deadzone": 0.0},
            "Mouse Y": {"Value": "RMouse Y", "Mult": 1.0, "Deadzone": 0.0},
        }},
    }
    with open(os.path.join(out, "default_keybinds.json"), "w") as f:
        json.dump(kb, f, indent=1, ensure_ascii=True)
        f.write("\n")


if __name__ == "__main__":
    main()
