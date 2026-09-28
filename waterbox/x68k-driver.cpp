// chimera-core-x68k: the Sharp X68000 of upstream MAME as a Chimera core.
//
// MAME is built the way it builds a single machine (build-mame.sh), and this
// file is the rest of what an emulator needs around it: MAME's frontend and
// its OSD layer are replaced by
//
//  * a machine_manager whose UI does nothing - no menus, no warning screens,
//    no Lua, no plugins;
//  * an osd_interface that hands each frame's picture (MAME's own software
//    renderer, drawing the screen-only view), each frame's sound (one stereo
//    stream) and the panel's inputs (a keyboard, a mouse and two joysticks as
//    MAME input devices, whose items the X68000's default key and joystick
//    codes land on) between MAME and the sandbox.
//
// MAME runs its machine as a loop that returns only when the machine exits.
// That loop runs on a cothread of its own, and the OSD's per-frame update()
// - which MAME calls at every VBLANK of the screen - switches back to the
// caller of x68k_frame(): a frame is exactly one turn of MAME's own loop, and
// nothing in it is reordered.

#include "emu.h"
#include "emuopts.h"
#include "input.h"
#include "inputdev.h"
#include "frontend/mame/ui/menuitem.h"
#include "main.h"
#include "render.h"
#include "rendersw.hxx"
#include "drivenum.h"
#include "machine/ram.h"
#include "screen.h"
#include "sound.h"
#include "video.h"
#include "ui/uimain.h"
#include "osdepend.h"
#include "modules/lib/osdobj_common.h"

#include "libco/libco.h"
#include "x68k-driver.h"

#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace {

// ---- the panel -----------------------------------------------------------
// Built from the machine itself, once its ports exist (chimera_manager::
// before_load_settings): every key of the X68000 keyboard, both joysticks
// (FM Towns pads: the four directions, A, B, Run, Select) and the mouse's
// buttons, in the order MAME lists its ports. Each is bound to an input item
// of its own on the core's devices - not left on MAME's defaults, which put
// both joysticks on the keyboard and the mouse on a player that is not there.
// gen-config.py writes waterbox.config from the same list (run-native
// --list-panel), so the two cannot disagree on the order.
struct panel_entry { std::string name; int slot; };
std::vector<panel_entry> s_panel;
constexpr int kSlotsPerDevice = 100;
constexpr int kDevices = 2;
int32_t s_slot[kSlotsPerDevice * kDevices];
int32_t s_mouse_axis[2];     // this frame's movement, in pixels

s32 read_slot(void *, void *item) { return s_slot[uintptr_t(item)]; }
s32 read_mouse_axis(void *, void *item) { return s_mouse_axis[uintptr_t(item)] * osd::input_device::RELATIVE_PER_PIXEL; }

// A panel name from a field's: the English part of "かな (Kana)", the first
// legend of "1  !  ぬ", and "Key " before a key of the keyboard.
std::string panel_name(ioport_field const &field)
{
	std::string n = field.name();
	auto const open = n.find(" (");
	if (open != std::string::npos && n.back() == ')')
		n = n.substr(open + 2, n.size() - open - 3);
	else if (auto const gap = n.find("  "); gap != std::string::npos)
		n = n.substr(0, gap);
	if (n == "\xc2\xa5") n = "Yen";   // the key with the yen sign on it
	if (field.type_class() == INPUT_CLASS_KEYBOARD) return "Key " + n;
	if (field.type() == IPT_BUTTON1 && std::string_view(field.port().tag()).find("mouse") != std::string_view::npos) return "Mouse Left";
	if (field.type() == IPT_BUTTON2 && std::string_view(field.port().tag()).find("mouse") != std::string_view::npos) return "Mouse Right";
	return n;
}

void bind_panel(running_machine &machine)
{
	s_panel.clear();
	int slot = 0;
	for (auto &port : machine.ioport().ports())
	{
		for (ioport_field &field : port.second->fields())
		{
			if (field.type() == IPT_UNUSED || field.type() == IPT_UNKNOWN) continue;
			ioport_field::user_settings us;
			field.get_user_settings(us);
			for (auto &seq : us.seq) seq = input_seq();
			if (field.type() == IPT_MOUSE_X || field.type() == IPT_MOUSE_Y)
			{
				// the mouse's movement: an axis of the core's one mouse
				us.seq[SEQ_TYPE_STANDARD] = input_seq(input_code(DEVICE_CLASS_MOUSE, 0, ITEM_CLASS_RELATIVE,
					ITEM_MODIFIER_NONE, field.type() == IPT_MOUSE_X ? ITEM_ID_XAXIS : ITEM_ID_YAXIS));
				field.set_user_settings(us);
				continue;
			}
			bool const digital = field.type_class() == INPUT_CLASS_KEYBOARD
				|| (field.type_class() == INPUT_CLASS_CONTROLLER && !field.is_analog());
			if (!digital || slot >= kSlotsPerDevice * kDevices) continue;
			us.seq[SEQ_TYPE_STANDARD] = input_seq(input_code(DEVICE_CLASS_KEYBOARD, slot / kSlotsPerDevice,
				ITEM_CLASS_SWITCH, ITEM_MODIFIER_NONE, input_item_id(ITEM_ID_A + slot % kSlotsPerDevice)));
			field.set_user_settings(us);
			s_panel.push_back({ panel_name(field), slot });
			slot++;
		}
	}
}

// ---- what one frame leaves behind ---------------------------------------
std::vector<uint32_t> s_video;
int s_width, s_height;
std::vector<int16_t> s_audio;
constexpr int kSampleRate = 48000;

cothread_t s_host, s_mame;
bool s_stopped;
std::string s_error;
std::map<std::string, std::string> s_options;
running_machine *s_machine;

// ---- the OSD --------------------------------------------------------------
class chimera_osd final : public osd_interface
{
public:
	void init(running_machine &machine) override
	{
		m_machine = &machine;
		auto &input = machine.input();

		// the panel's switches: two keyboards of item slots, bound field by field
		for (int d = 0; d < kDevices; d++)
		{
			auto &kbd = input.device_class(DEVICE_CLASS_KEYBOARD).add_device(
				d ? "Chimera Panel 2" : "Chimera Panel 1", d ? "chimera-panel-2" : "chimera-panel-1");
			for (int i = 0; i < kSlotsPerDevice; i++)
				kbd.add_item("", "", input_item_id(ITEM_ID_A + i), read_slot,
					reinterpret_cast<void *>(uintptr_t(d * kSlotsPerDevice + i)));
		}
		auto &mouse = input.device_class(DEVICE_CLASS_MOUSE).add_device("Chimera Mouse", "chimera-mouse");
		mouse.add_item("X", "", ITEM_ID_XAXIS, read_mouse_axis, reinterpret_cast<void *>(uintptr_t(0)));
		mouse.add_item("Y", "", ITEM_ID_YAXIS, read_mouse_axis, reinterpret_cast<void *>(uintptr_t(1)));

		// the screen alone, at the machine's own pixels - not the layout with
		// its drive and keyboard LEDs
		m_target = machine.render().target_alloc();
		for (int v = 0; m_target->view_name(v); v++)
		{
			if (std::strstr(m_target->view_name(v), "Pixel Aspect"))
			{
				m_target->set_view(v);
				break;
			}
		}
	}

	void update(bool skip_redraw) override
	{
		// this frame's sound, all of it (patch 0003): MAME's own periodic update
		// runs at 50 Hz, not at the screen's rate
		m_machine->sound().chimera_flush();
		if (!skip_redraw) draw();
		// the end of a frame: back to x68k_frame's caller
		co_switch(s_host);
	}

	void input_update(bool relative_reset) override { }
	void check_osd_inputs() override { }
	void set_verbose(bool print_verbose) override { }
	void init_debugger() override { }
	void wait_for_debugger(device_t &device, bool firststop) override { }

	bool no_sound() override { return false; }
	bool sound_external_per_channel_volume() override { return false; }
	bool sound_split_streams_per_source() override { return false; }
	uint32_t sound_get_generation() override { return 1; }
	osd::audio_info sound_get_information() override
	{
		osd::audio_info result;
		result.m_generation = 1;
		result.m_default_sink = 1;
		result.m_default_source = 0;
		result.m_nodes.resize(1);
		auto &node = result.m_nodes[0];
		node.m_name = "chimera";
		node.m_display_name = "Chimera";
		node.m_id = 1;
		node.m_rate.m_default_rate = kSampleRate;
		node.m_rate.m_min_rate = kSampleRate;
		node.m_rate.m_max_rate = kSampleRate;
		node.m_sinks = 2;
		node.m_sources = 0;
		node.m_port_names = { "L", "R" };
		node.m_port_positions = { osd::channel_position::FL(), osd::channel_position::FR() };
		if (m_stream)
			result.m_streams.emplace_back(m_stream, 1u);
		return result;
	}
	uint32_t sound_stream_sink_open(uint32_t node, std::string name, uint32_t rate) override { return m_stream = 1; }
	uint32_t sound_stream_source_open(uint32_t node, std::string name, uint32_t rate) override { return 0; }
	void sound_stream_close(uint32_t id) override { if (id == m_stream) m_stream = 0; }
	void sound_stream_sink_update(uint32_t id, const int16_t *buffer, int samples_this_frame) override
	{
		s_audio.insert(s_audio.end(), buffer, buffer + 2 * samples_this_frame);
	}
	void sound_stream_source_update(uint32_t id, int16_t *buffer, int samples_this_frame) override { }
	void sound_stream_set_volumes(uint32_t id, const std::vector<float> &db) override { }
	void sound_begin_update() override { }
	void sound_end_update() override { }

	void customize_input_type_list(std::vector<input_type_entry> &typelist) override { }
	void add_audio_to_recording(const int16_t *buffer, int samples_this_frame) override { }
	std::vector<ui::menu_item> get_slider_list() override { return {}; }
	osd_font::ptr font_alloc() override { return nullptr; }
	bool get_font_families(std::string const &font_path, std::vector<std::pair<std::string, std::string>> &result) override { return false; }
	bool execute_command(const char *command) override { return false; }
	std::unique_ptr<osd::midi_input_port> create_midi_input(std::string_view name) override { return nullptr; }
	std::unique_ptr<osd::midi_output_port> create_midi_output(std::string_view name) override { return nullptr; }
	std::vector<osd::midi_port_info> list_midi_ports() override { return {}; }
	std::unique_ptr<osd::network_device> open_network_device(int id, osd::network_handler &handler) override { return nullptr; }
	std::vector<osd::network_device_info> list_network_devices() override { return {}; }

private:
	void draw()
	{
		s32 w = 0, h = 0;
		m_target->compute_minimum_size(w, h);
		if (w <= 0 || h <= 0) return;
		m_target->set_bounds(w, h);
		s_video.assign(size_t(w) * h, 0);
		s_width = w;
		s_height = h;
		render_primitive_list &prims = m_target->get_primitives();
		prims.acquire_lock();
		software_renderer<uint32_t, 0, 0, 0, 16, 8, 0>::draw_primitives(prims, s_video.data(), w, h, w);
		prims.release_lock();
	}

	running_machine *m_machine = nullptr;
	render_target *m_target = nullptr;
	uint32_t m_stream = 0;
};

// ---- the frontend ---------------------------------------------------------
class chimera_manager final : public machine_manager
{
public:
	chimera_manager(emu_options &options, osd_interface &osd) : machine_manager(options, osd) { }
	// a UI that shows nothing: no menus, no startup text, no warning screens
	ui_manager *create_ui(running_machine &machine) override { return m_ui = new ui_manager(machine); }
	// the ports exist now, and no saved settings are read after this (readconfig off)
	void before_load_settings(running_machine &machine) override
	{
		bind_panel(machine);
		// Unthrottled. The "throttle" option is read by MAME's frontend, not by
		// its emulator core, which otherwise paces the machine to the host's
		// clock - sleeping between frames, and deciding by the host's time.
		machine.video().set_throttled(false);
	}
	~chimera_manager() override { delete m_ui; }
private:
	ui_manager *m_ui = nullptr;
};

chimera_osd *s_osd;
emu_options *s_emu_options;
chimera_manager *s_manager;

void mame_main()
{
	try
	{
		machine_config config(*s_emu_options->system(), *s_emu_options);
		running_machine machine(config, *s_manager);
		s_manager->set_machine(&machine);
		s_machine = &machine;
		int const result = machine.run(false);
		if (s_error.empty())
			s_error = "the machine stopped (MAME exit code " + std::to_string(result) + ")";
	}
	catch (emu_fatalerror const &e)
	{
		s_error = e.what();
	}
	catch (std::exception const &e)
	{
		s_error = e.what();
	}
	s_machine = nullptr;
	s_stopped = true;
	for (;;) co_switch(s_host);
}

void set(core_options &opts, const char *name, std::string const &value)
{
	if (!opts.get_entry(name))
		throw std::runtime_error(std::string("MAME has no option \"") + name + "\"");
	opts.set_value(name, value, OPTION_PRIORITY_CMDLINE);
}

} // anonymous namespace

// MAME's output (errors, warnings) goes to stderr: it is the core's log
class chimera_output : public osd_output
{
public:
	void output_callback(osd_output_channel channel, util::format_argument_pack<char> const &args) override
	{
		if (channel == OSD_OUTPUT_CHANNEL_ERROR || channel == OSD_OUTPUT_CHANNEL_WARNING)
			std::fputs(util::string_format(args).c_str(), stderr);
	}
};

extern "C" void x68k_set_option(const char *name, const char *value)
{
	s_options[name] = value;
}

extern "C" int x68k_init(void)
{
	static chimera_output output;
	osd_output::push(&output);
	try
	{
		s_emu_options = new emu_options();
		auto &o = *s_emu_options;
		// fixed, whatever the project says: nothing may depend on the host
		set(o, OPTION_THROTTLE, "0");
		set(o, OPTION_SLEEP, "0");
		set(o, OPTION_SAMPLERATE, std::to_string(kSampleRate));
		set(o, OPTION_RTC_TIME, "20000101000000");
		set(o, OPTION_NVRAM_SAVE, "0");
		set(o, OPTION_READCONFIG, "0");
		set(o, OPTION_WRITECONFIG, "0");
		set(o, OPTION_MEDIAPATH, ".");
		o.set_system_name("x68000");
		for (auto const &kv : s_options)
			set(o, kv.first.c_str(), kv.second);
		if (!o.system())
			throw std::runtime_error("the X68000 is not in this build's driver list");

		s_osd = new chimera_osd();
		s_manager = new chimera_manager(o, *s_osd);
		// what MAME's frontend always does; the machine asks for the server object
		// whether or not it serves anything, and with http off it serves nothing
		s_manager->start_http_server();
	}
	catch (std::exception const &e)
	{
		s_error = e.what();
		return 1;
	}
	s_host = co_active();
	s_mame = co_create(16 * 1024 * 1024, mame_main);
	co_switch(s_mame);
	return s_stopped ? 1 : 0;
}

extern "C" const char *x68k_error(void) { return s_error.c_str(); }

extern "C" int x68k_frame(void)
{
	if (s_stopped) return 1;
	s_audio.clear();
	co_switch(s_mame);
	return s_stopped ? 1 : 0;
}

extern "C" const uint32_t *x68k_video(int *width, int *height)
{
	*width = s_width;
	*height = s_height;
	return s_video.data();
}

extern "C" const int16_t *x68k_audio(int *frames)
{
	*frames = int(s_audio.size() / 2);
	return s_audio.data();
}

extern "C" int x68k_sample_rate(void) { return kSampleRate; }

extern "C" void x68k_set_button(int index, int pressed)
{
	if (index < 0 || index >= int(s_panel.size())) return;
	s_slot[s_panel[index].slot] = pressed ? 1 : 0;
}

extern "C" void x68k_set_axis(int index, int value)
{
	// 0 and 1: the mouse's movement this frame, in pixels
	if (index >= 0 && index < 2) s_mouse_axis[index] = value;
}

extern "C" int x68k_button_count(void) { return int(s_panel.size()); }
extern "C" const char *x68k_button_name(int index)
{
	return index >= 0 && index < int(s_panel.size()) ? s_panel[index].name.c_str() : "";
}

extern "C" int x68k_input_was_read(void) { return 1; }

extern "C" uint8_t *x68k_ram(uint32_t *size)
{
	*size = 0;
	if (!s_machine) return nullptr;
	ram_device *ram = s_machine->device<ram_device>(RAM_TAG);
	if (!ram) return nullptr;
	*size = ram->size();
	return ram->pointer();
}

// Every input field of the running machine, with its type and the input code
// its default sequence names: what gen-panel.py builds the panel from, and what
// gen-settings.py reads the DIP switches and configuration from.
extern "C" void x68k_list_ports(void)
{
	if (!s_machine) return;
	for (auto &port : s_machine->ioport().ports())
	{
		for (ioport_field const &field : port.second->fields())
		{
			std::printf("port\t%s\tmask\t%u\tclass\t%d\ttype\t%d\tname\t%s\tseq\t%s\n",
				port.first.c_str(), unsigned(field.mask()), int(field.type_class()), int(field.type()),
				field.name().c_str(),
				s_machine->input().seq_to_tokens(field.seq(SEQ_TYPE_STANDARD)).c_str());
			if (field.type_class() == INPUT_CLASS_DIPSWITCH || field.type_class() == INPUT_CLASS_CONFIG)
				for (ioport_setting const &setting : field.settings())
					std::printf("setting\t%s\t%u\t%s%s\n", field.name().c_str(), unsigned(setting.value()),
						setting.name(), setting.value() == field.defvalue() ? "\t(default)" : "");
		}
	}
}

// The screen's refresh as the machine runs it now, in thousandths of a hertz:
// 55.46 Hz in the 31 kHz modes, 61.46 Hz in the 15 kHz ones.
extern "C" int x68k_refresh_millihertz(void)
{
	if (!s_machine) return 55458;
	screen_device *const screen = screen_device_enumerator(s_machine->root_device()).first();
	if (!screen) return 55458;
	return int(screen->frame_period().as_hz() * 1000.0 + 0.5);
}
