/* wbx-entry.cpp - the chimera guest ABI over x68k-driver.
 *
 * Compiles identically for the guest (miniBox emulibc) and for the native
 * reference build (native-shim/emulibc.h), which is what makes the
 * equivalence gate a real proof: the same driver, the same exports, one in
 * the sandbox and one out of it.
 * SPDX-License-Identifier: MIT
 */
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

#include <emulibc.h>
#include <waterbox_settings.h>
#include <waterbox_slots.h>

#include "x68k-driver.h"

static char g_loadError[512];

static bool Exists(const char *name)
{
	FILE *f = fopen(name, "rb");
	if (!f) return false;
	fclose(f);
	return true;
}

/* The IPL-ROM each "IPL-ROM" setting needs, as MAME names the files. */
static const char *IplFile(const std::string &bios)
{
	if (bios == "ipl10") return "iplrom.dat";
	if (bios == "ipl11") return "iplromxv.dat";
	if (bios == "ipl12") return "iplromco.dat";
	if (bios == "ipl13") return "iplrom30.dat";
	return nullptr;
}

ECL_EXPORT const char *GetLoadError(void) { return g_loadError; }

ECL_EXPORT int Init(void)
{
	char val[256];

	/* the machine: settings are MAME's own options, checked against the list
	 * waterbox.config declares */
	std::string bios = "ipl10";
	if (wbx_setting_str("ipl_rom", val, sizeof val) > 0) bios = val;
	const char *ipl = IplFile(bios);
	if (!ipl)
	{
		snprintf(g_loadError, sizeof g_loadError, "unknown IPL-ROM \"%s\"", bios.c_str());
		return 0;
	}
	x68k_set_option("bios", bios.c_str());
	if (wbx_setting_str("ram", val, sizeof val) > 0) x68k_set_option("ramsize", val);

	/* the firmware, mounted under the names MAME looks for */
	for (const char *need : { "cgrom.dat", ipl })
	{
		if (!Exists(need))
		{
			snprintf(g_loadError, sizeof g_loadError,
				"the X68000 needs %s - add it as the project's firmware", need);
			return 0;
		}
	}

	/* the floppies: the Floppy disks slot's files, in the drives in order */
	char entry[512];
	const int32_t disks = wbx_slot_count("floppy");
	for (int32_t i = 0; i < disks && i < 2; i++)
	{
		if (wbx_slot_name("floppy", i, entry, sizeof entry) == nullptr) continue;
		char opt[8];
		snprintf(opt, sizeof opt, "flop%d", int(i + 1));
		x68k_set_option(opt, entry);
	}
	if (disks == 0)
	{
		/* a disk opened with no project has no slot map: it is mounted under
		 * its own name, and rom.name says which */
		FILE *f = fopen("rom.name", "rb");
		if (f)
		{
			size_t got = fread(entry, 1, sizeof entry - 1, f);
			fclose(f);
			entry[got] = '\0';
			x68k_set_option("flop1", entry);
		}
	}

	if (x68k_init() != 0)
	{
		snprintf(g_loadError, sizeof g_loadError, "%s", x68k_error());
		return 0;
	}
	return 1;
}

ECL_EXPORT void SetButton(int32_t index, int32_t state) { x68k_set_button(index, state); }
ECL_EXPORT int IsButtonActive(int32_t index) { return index >= 0 && index < x68k_button_count(); }
ECL_EXPORT const char *GetButtonName(int32_t index) { return x68k_button_name(index); }
ECL_EXPORT int GetButtonCount(void) { return x68k_button_count(); }

/* The panel is wider than the packed 64: every control arrives through
 * SetButton (the engine sends a wide panel's changes that way), and the
 * packed mask is not read. */
ECL_EXPORT void FrameAdvance(uint64_t) { x68k_frame(); }

/* the mouse's movement this frame, in pixels: X, Y */
ECL_EXPORT int IsAxisActive(int32_t index) { return index >= 0 && index < 2; }
ECL_EXPORT void SetAxis(int32_t index, int32_t value) { x68k_set_axis(index, value); }
ECL_EXPORT int GetAxisCount(void) { return 2; }

ECL_EXPORT int InputWasRead(void) { return x68k_input_was_read(); }
ECL_EXPORT void SetRenderingEnabled(int) {}

ECL_EXPORT uint32_t *GetVideoBgra(void)
{
	int w, h;
	return const_cast<uint32_t *>(x68k_video(&w, &h));
}
ECL_EXPORT int GetVideoWidth(void)
{
	int w, h;
	x68k_video(&w, &h);
	return w;
}
ECL_EXPORT int GetVideoHeight(void)
{
	int w, h;
	x68k_video(&w, &h);
	return h;
}
/* the picture is handed out at the machine's own pixels; a monitor showed
 * every mode at 4:3 */
ECL_EXPORT int GetDisplayAspectX(void) { return 4; }
ECL_EXPORT int GetDisplayAspectY(void) { return 3; }

ECL_EXPORT int16_t *GetAudio(void)
{
	int n;
	return const_cast<int16_t *>(x68k_audio(&n));
}
ECL_EXPORT int GetAudioSampleCount(void)
{
	int n;
	x68k_audio(&n);
	return n;
}

ECL_EXPORT int GetVsyncNumerator(void) { return x68k_refresh_millihertz(); }
ECL_EXPORT int GetVsyncDenominator(void) { return 1000; }

ECL_EXPORT const char *DescribeDips(void) { return ""; }

ECL_EXPORT int32_t GetSaveDataFileCount(void) { return 0; }
ECL_EXPORT const char *GetSaveDataFileName(int32_t) { return ""; }
ECL_EXPORT int64_t GetSaveDataFileSize(int32_t) { return 0; }
ECL_EXPORT const uint8_t *GetSaveDataFileBuffer(int32_t) { return nullptr; }

ECL_EXPORT int GetMemoryDomainCount(void) { return 1; }
ECL_EXPORT const char *GetMemoryDomainName(int i) { return i == 0 ? "Main RAM" : ""; }
ECL_EXPORT uint8_t *GetMemoryDomainPtr(int i)
{
	uint32_t size;
	return i == 0 ? x68k_ram(&size) : nullptr;
}
ECL_EXPORT int64_t GetMemoryDomainSize(int i)
{
	uint32_t size = 0;
	if (i == 0) x68k_ram(&size);
	return size;
}
ECL_EXPORT int GetMemoryDomainWritable(int i) { return i == 0; }
