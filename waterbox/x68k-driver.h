// chimera-core-x68k: the Sharp X68000 of upstream MAME as a Chimera core.
// The driver's C interface - what wbx-entry.cpp exports to the sandbox and
// what the native harness calls directly.
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Settings, before x68k_init. Names are MAME's own options (bios, ram,
// rtc, flop1, flop2, ...); "rompath" is where the firmware files are.
void x68k_set_option(const char *name, const char *value);

// Builds and starts the machine and runs it to the end of its first frame.
// 0 on success; otherwise x68k_error() says why.
int x68k_init(void);
const char *x68k_error(void);

// One frame. 0 on success; nonzero once the machine has stopped.
int x68k_frame(void);

// The picture of the last frame, 0x00RRGGBB, width x height.
const uint32_t *x68k_video(int *width, int *height);

// The sound of the last frame: interleaved stereo, *frames sample pairs.
const int16_t *x68k_audio(int *frames);
int x68k_sample_rate(void);

// Inputs, held until changed: a panel button by index, an axis by index.
void x68k_set_button(int index, int pressed);
void x68k_set_axis(int index, int value);
int x68k_button_count(void);
const char *x68k_button_name(int index);

// Frames the machine did not read its controls in.
int x68k_input_was_read(void);

// The screen's refresh now, in thousandths of a hertz.
int x68k_refresh_millihertz(void);

// The machine's RAM, for digests and the memory domain.
uint8_t *x68k_ram(uint32_t *size);

// The 16 KB battery-backed SRAM (the machine's settings: boot device, memory
// switches, and what a program keeps there), in the machine's own byte order -
// big-endian words, as the X68000 holds it and as a dump of one reads. Set
// before x68k_init to power on with it (MAME's own nvram file, in the host's
// order, is recognised by its signature and accepted too); read back any time
// after. 0 on success.
int x68k_set_sram(const uint8_t *data, uint32_t size);
const uint8_t *x68k_sram(uint32_t *size);

#ifdef __cplusplus
}
#endif
