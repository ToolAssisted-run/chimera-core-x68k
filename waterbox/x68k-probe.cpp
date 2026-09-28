// chimera-core-x68k's native harness: the driver, linked with MAME built by the
// host compiler, run the way the sandbox runs it. The reference every sandbox
// run is compared against, and the quickest way to look at the machine.
//
//   run-native --rompath DIR [--opt name=value]... [--frames N] [--report K]
//              [--press I:F:N]... [--ppm F=file.ppm]... [--list-ports]
#include "x68k-driver.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

extern "C" void x68k_list_ports(void);

static uint64_t fnv(uint64_t h, const void *p, size_t n)
{
	const uint8_t *b = static_cast<const uint8_t *>(p);
	if (!h) h = 1469598103934665603ull;
	for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ull; }
	return h;
}

int main(int argc, char **argv)
{
	long frames = 300, report = 60;
	bool listPorts = false, listPanel = false;
	struct press { long first, count; int index; };
	std::vector<press> presses;
	std::vector<std::pair<long, std::string>> ppms;
	for (int i = 1; i < argc; i++)
	{
		std::string a = argv[i];
		auto next = [&]() -> const char * { return i + 1 < argc ? argv[++i] : ""; };
		if (a == "--rompath") x68k_set_option("rompath", next());
		else if (a == "--opt")
		{
			std::string kv = next();
			auto eq = kv.find('=');
			if (eq != std::string::npos) x68k_set_option(kv.substr(0, eq).c_str(), kv.substr(eq + 1).c_str());
		}
		else if (a == "--frames") frames = std::atol(next());
		else if (a == "--report") report = std::atol(next());
		else if (a == "--list-ports") listPorts = true;
		else if (a == "--list-panel") listPanel = true;
		else if (a == "--press")
		{
			press p{};
			if (std::sscanf(next(), "%d:%ld:%ld", &p.index, &p.first, &p.count) == 3) presses.push_back(p);
		}
		else if (a == "--ppm")
		{
			std::string kv = next();
			auto eq = kv.find('=');
			if (eq != std::string::npos) ppms.emplace_back(std::atol(kv.substr(0, eq).c_str()), kv.substr(eq + 1));
		}
		else { std::fprintf(stderr, "unknown argument %s\n", a.c_str()); return 2; }
	}
	if (x68k_init() != 0) { std::fprintf(stderr, "init: %s\n", x68k_error()); return 1; }
	if (listPorts) { x68k_list_ports(); return 0; }
	if (listPanel)
	{
		for (int i = 0; i < x68k_button_count(); i++) std::printf("%d\t%s\n", i, x68k_button_name(i));
		return 0;
	}
	uint64_t ram_acc = 0, vid_acc = 0, aud_acc = 0;
	for (long f = 1; f <= frames; f++)
	{
		for (auto const &p : presses) x68k_set_button(p.index, f >= p.first && f < p.first + p.count);
		if (x68k_frame() != 0) { std::fprintf(stderr, "frame %ld: %s\n", f, x68k_error()); return 1; }
		int w, h, n;
		const uint32_t *v = x68k_video(&w, &h);
		const int16_t *s = x68k_audio(&n);
		uint32_t ramsize;
		uint8_t *ram = x68k_ram(&ramsize);
		vid_acc = fnv(vid_acc, v, size_t(w) * h * 4);
		aud_acc = fnv(aud_acc, s, size_t(n) * 4);
		ram_acc = fnv(ram_acc, ram, ramsize);
		for (auto const &pp : ppms)
		{
			if (pp.first != f) continue;
			FILE *out = std::fopen(pp.second.c_str(), "wb");
			if (!out) continue;
			std::fprintf(out, "P6\n%d %d\n255\n", w, h);
			for (int i = 0; i < w * h; i++)
			{
				uint8_t rgb[3] = { uint8_t(v[i] >> 16), uint8_t(v[i] >> 8), uint8_t(v[i]) };
				std::fwrite(rgb, 1, 3, out);
			}
			std::fclose(out);
		}
		if (f % report == 0)
			std::printf("frame %5ld ram %016llx vid %dx%d %016llx aud %d %016llx\n", f,
				(unsigned long long)fnv(0, ram, ramsize), w, h, (unsigned long long)fnv(0, v, size_t(w) * h * 4),
				n, (unsigned long long)fnv(0, s, size_t(n) * 4));
	}
	std::printf("stream ram %016llx vid %016llx aud %016llx\n", (unsigned long long)ram_acc,
		(unsigned long long)vid_acc, (unsigned long long)aud_acc);
	return 0;
}
