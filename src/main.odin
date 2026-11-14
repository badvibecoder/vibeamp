package main

import "base:runtime"
import "core:strings"
import win "core:sys/windows"

// SetCapture/ReleaseCapture are missing from the shipped bindings.
// (Named user32_lib, not u32: a foreign import named u32 would shadow the
// builtin type.)
foreign import user32_lib "system:User32.lib"

@(default_calling_convention="system")
foreign user32_lib {
	SetCapture     :: proc(hWnd: win.HWND) -> win.HWND ---
	ReleaseCapture :: proc() -> win.BOOL ---
}

// IntersectClipRect is missing from the shipped bindings too.
foreign import g32 "system:Gdi32.lib"

@(default_calling_convention="system")
foreign g32 {
	IntersectClipRect   :: proc(hdc: win.HDC, left, top, right, bottom: win.INT) -> win.INT ---
	CreatePatternBrush  :: proc(hbm: win.HBITMAP) -> win.HBRUSH ---
	SetBrushOrgEx       :: proc(hdc: win.HDC, x, y: win.INT, lppt: ^win.POINT) -> win.BOOL ---
}

//
// vibeamp — v0.6
//
// One LCD panel holds everything: a scrolling dot-matrix title, a static line
// with the file name and the time, the LOAD controls, the size gauge and the
// transport. Everything in the panel is clickable.
//

APP_NAME     :: "vibeamp"
APP_VERSION  :: "v1.0"
WINDOW_CLASS :: "VibeAmpWindowClass"

CLIENT_WIDTH  :: 407
CLIENT_HEIGHT :: 250

SIZE_STEPS := [3]i32{1, 2, 4}

// --- LCD geometry, in device-independent pixels at 1x -------------------

// The matrix is four stacked blocks: a blank dot row at the top, the scrolling
// title, the spectrum analyzer under it, and a blank dot row at the bottom.
LCD_TOP_ROWS    :: 1
LCD_ROWS        :: 8
LCD_SPEC_ROWS   :: 8
LCD_BUFFER_ROWS :: 1
LCD_MATRIX_ROWS :: LCD_TOP_ROWS + LCD_ROWS + LCD_SPEC_ROWS + LCD_BUFFER_ROWS

LCD_DOT        :: i32(3)
LCD_GAP        :: i32(1)
LCD_MARGIN_X   :: i32(10)
LCD_MARGIN_TOP :: i32(10)
LCD_BORDER     :: i32(2)
LCD_PAD        :: i32(4)  // green between the bezel and the dot field

LCD_INFO_GAP :: i32(4)  // text strip -> info line
LCD_INFO_H   :: i32(9)
LCD_LOAD_GAP :: i32(6)  // info line -> load controls
LCD_LOAD_H   :: i32(10)
LCD_ICON_GAP :: i32(4)  // seek band -> icon row
LCD_ICON_H   :: i32(20) // height of the icon row
ICON_H       :: i32(16) // every icon in that row is this tall

// Seek bar: a thin line with a draggable thumb, under the track info.
SEEK_GAP   :: i32(4)  // buffer above and below the band
SEEK_BAND  :: i32(10) // total band height
SEEK_BAR_H :: i32(4)  // visible line thickness
SEEK_THUMB :: i32(4)  // thumb width

// The volume column takes this much off the right of the playlist and transport.
// Big enough that the mute button can sit a full icon-gap after the transport.
VOL_W :: i32(32)

// Playlist block: a framed list of the loaded tracks, under the LOAD controls.
PLAYLIST_ROWS   :: 6
PLAYLIST_GAP    :: i32(6)  // load row -> block
PLAYLIST_BORDER :: i32(2)  // dark frame
PLAYLIST_PAD    :: i32(5)  // buffer between frame and content
PLAYLIST_ROW_H  :: i32(10) // one line, including the gap below it

MAX_COLS :: 256

SCROLL_GAP_COLS     :: 12
SCROLL_DOTS_PER_SEC :: f32(12)
PLAYLIST_SCROLL_PPS :: i32(14) // px per second at 1x, for the selected row
SPECTRUM_GAP :: i32(6)         // matrix -> size dots, in spectrum mode
DEFAULT_MARQUEE     :: "Select File or Folder"

// COLORREF is 0x00BBGGRR, not 0xRRGGBB.
COLOR_BACKGROUND :: win.COLORREF(0x0020_1D1A) // #1A1D20

// The LCD palette. Each theme keeps the same relationship: a mid panel, lighter
// unlit dots, near-black lit dots, a ghost just above the panel and a list
// infill just below it.
Theme :: struct {
	name:  string,
	panel: win.COLORREF,
	unlit: win.COLORREF,
	lit:   win.COLORREF,
	ghost: win.COLORREF,
	list:  win.COLORREF,
}

THEMES := [4]Theme {
	{
		name  = "GREEN",
		panel = win.COLORREF(0x0081_B89D), // #9DB881
		unlit = win.COLORREF(0x00B8_E2CF), // #CFE2B8
		lit   = win.COLORREF(0x0014_2A1C), // #1C2A14
		ghost = win.COLORREF(0x009E_C9B3), // #B3C99E
		list  = win.COLORREF(0x0074_A48C), // #8CA474
	},
	{
		name  = "AMBER",
		panel = win.COLORREF(0x004E_8AC0), // #C08A4E
		unlit = win.COLORREF(0x00B0_DDF0), // #F0DDB0
		lit   = win.COLORREF(0x0008_243A), // #3A2408
		ghost = win.COLORREF(0x0065_9CCD), // #CD9C65
		list  = win.COLORREF(0x0040_79AC), // #AC7940
	},
	{
		name  = "RED",
		panel = win.COLORREF(0x0050_5AC0), // #C05A50
		unlit = win.COLORREF(0x00B6_C2F0), // #F0C2B6
		lit   = win.COLORREF(0x000C_103A), // #3A100C
		ghost = win.COLORREF(0x005E_6ACE), // #CE6A5E
		list  = win.COLORREF(0x0045_4FAC), // #AC4F45
	},
	{
		name  = "GREY",
		panel = win.COLORREF(0x00B2_AFA9), // #A9AFB2
		unlit = win.COLORREF(0x00E5_E3DE), // #DEE3E5
		lit   = win.COLORREF(0x0025_221E), // #1E2225
		ghost = win.COLORREF(0x00CA_C7C1), // #C1C7CA
		list  = win.COLORREF(0x009D_9A94), // #949A9D
	},
}

Playback :: enum u8 {
	Stopped,
	Playing,
	Paused,
}

Loop_Mode :: enum u8 {
	Off,
	All,
	One,
}

Control :: enum u8 {
	None,
	Size_1,
	Size_2,
	Size_4,
	Prev,
	Rewind,
	Play,
	Pause,
	Stop,
	Forward,
	Next,
	Loop_All,
	Loop_One,
	Load_File,
	Load_Folder,
	List_Up,
	List_Down,
	List_Row,
	Theme,
	Seek,
	Volume_Track,
	Volume_Mute,
	Spectrum,
}

SIZE_CONTROLS := [3]Control{.Size_1, .Size_2, .Size_4}
GAUGE_SIZES   := [3]i32{8, 12, 16} // the largest matches ICON_H

TRANSPORT_WIDTHS   := [9]i32{18, 18, 14, 14, 14, 18, 18, 20, 20}
TRANSPORT_HEIGHTS  := [9]i32{16, 16, 16, 16, 16, 16, 16, 16, 16}
TRANSPORT_CONTROLS := [9]Control{.Prev, .Rewind, .Play, .Pause, .Stop, .Forward, .Next, .Loop_All, .Loop_One}
TRANSPORT_GAP      :: i32(10)

g: struct {
	brush_background: win.HBRUSH,
	brush_lcd_panel:  win.HBRUSH,
	brush_lcd_unlit:  win.HBRUSH,
	brush_lcd_lit:    win.HBRUSH,
	brush_lcd_ghost:  win.HBRUSH,
	brush_list_bg:    win.HBRUSH,

	buf_dc:  win.HDC,
	buf_bmp: win.HBITMAP,
	buf_old: win.HGDIOBJ,
	buf_w:   i32,
	buf_h:   i32,

	style:       win.DWORD,
	scale_index: int,
	theme_index: int,

	playback:  Playback,
	loop_mode: Loop_Mode,

	scroll:     f32,
	marquee:    string, // owned copy of the current marquee text
	marquee_cols: int,
	clock_freq: f64,
	last_time:  f64,
	last_save:  f64,

	painted_col:    int,
	painted_second: int,
	painted_flash:  bool,
	painted_idle:   int,

	track_name:   string,
	track_loaded: bool,
	info_text:    string,

	cols:         int,
	bars:         [MAX_COLS]u8,
	painted_bars: [MAX_COLS]u8,
	list_scroll:  int,
	idle_since:   f64, // when playback left Playing; -1 while playing
	seeking:      bool,
	seek_preview: f32,
	last_seek:    f64,
	title:       win.wstring,
	class_name:  win.wstring,
	cursor_hand: win.HCURSOR,

	volume:       f32, // 0..1
	muted:        bool,
	vol_dragging: bool,
	pl_start:     f64, // when the selected row's marquee started
	pl_overflow:  bool,
	pl_frame:     int,
	spectrum_mode: bool,
	spec_frame:    int,
	spec_rows:     int, // spectrum rows in the mode currently drawn

	// Which bands need redrawing. The back buffer persists, so a paint only
	// touches the parts that actually changed.
	dirty:     bit_set[Part; u32],
	dirty_all: bool,

	// Dot glyph as a pattern brush, so a field or a column run is one fill.
	dot_brush_lit:   win.HBRUSH,
	dot_brush_unlit: win.HBRUSH,
	dot_bmp_lit:     win.HBITMAP,
	dot_bmp_unlit:   win.HBITMAP,
	dot_brush_theme: int,
	dot_brush_pitch: i32,

	ctx: runtime.Context,
}

info_buf: [48]u8

TIMER_ID :: 1

//
// Layout
//

Hit :: struct {
	rect:    win.RECT,
	control: Control,
	index:   int,
}

MAX_HITS :: 32

Layout :: struct {
	panel: win.RECT,
	grid:  win.RECT,
	info:  win.RECT,
	seek:  win.RECT,
	load:  win.RECT,
	playlist: win.RECT,
	arrow_up:   win.RECT,
	arrow_down: win.RECT,
	icons: win.RECT,

	size_rects: [3]win.RECT,
	color_btn:  win.RECT,
	volume:     win.RECT,
	vol_speaker: win.RECT,
	vol_track:  win.RECT,
	vol_mute:   win.RECT,
	pl_text_x:     i32,
	pl_text_right: i32,

	prev:    win.RECT,
	rewind:  win.RECT,
	play:    win.RECT,
	pause:   win.RECT,
	stop:    win.RECT,
	forward: win.RECT,
	next:    win.RECT,
	loop:    win.RECT,
	loop1:   win.RECT,

	load_file:   win.RECT,
	load_folder: win.RECT,

	hits:      [MAX_HITS]Hit,
	hit_count: int,
	cols:      int,
	rows:      int,
}

rect :: #force_inline proc "contextless" (l, t, r, b: i32) -> win.RECT {
	return win.RECT{win.LONG(l), win.LONG(t), win.LONG(r), win.LONG(b)}
}

rect_pad :: #force_inline proc "contextless" (r: win.RECT, p: i32) -> win.RECT {
	return win.RECT{r.left - win.LONG(p), r.top - win.LONG(p), r.right + win.LONG(p), r.bottom + win.LONG(p)}
}

add_hit :: proc "contextless" (lay: ^Layout, r: win.RECT, control: Control, index: int = 0) {
	if lay.hit_count < MAX_HITS {
		lay.hits[lay.hit_count] = Hit{rect = r, control = control, index = index}
		lay.hit_count += 1
	}
}

// Height of the panel in both modes: the spectrum view keeps the same window
// size, it just gives the matrix the space the other bands would have used.
panel_height :: proc "contextless" (s: Scale, grid_h: i32) -> i32 {
	border  := dm(s, LCD_BORDER)
	lcd_pad := dm(s, LCD_PAD)
	info_h  := dm(s, LCD_INFO_H)
	load_h  := dm(s, LCD_LOAD_H)
	icon_h  := dm(s, LCD_ICON_H)

	pb := dm(s, PLAYLIST_BORDER)
	pp := dm(s, PLAYLIST_PAD)
	ph := dm(s, PLAYLIST_ROW_H)
	playlist_h := 2*pb + 2*pp + i32(PLAYLIST_ROWS)*ph

	return 2*(border + lcd_pad) + grid_h +
		dm(s, LCD_INFO_GAP) + info_h +
		dm(s, LCD_LOAD_GAP) + load_h +
		dm(s, PLAYLIST_GAP) + playlist_h +
		dm(s, SEEK_GAP) + dm(s, SEEK_BAND) +
		dm(s, LCD_ICON_GAP) + icon_h
}

build_layout :: proc "contextless" (client_w: i32, s: Scale) -> Layout {
	lay := Layout{}

	if g.spectrum_mode {
		return build_spectrum_layout(client_w, s)
	}

	dot    := dm(s, LCD_DOT)
	gap    := dm(s, LCD_GAP)
	pitch  := dot + gap
	margin := dm(s, LCD_MARGIN_X)
	border := dm(s, LCD_BORDER)
	lcd_pad    := dm(s, LCD_PAD)

	// The bezel and the green padding are part of the display, so the grid must
	// fit inside them.
	avail := client_w - 2*(margin + border + lcd_pad)
	if pitch <= 0 || avail < dot {
		return lay
	}
	cols := (avail + gap) / pitch
	if cols > MAX_COLS {
		cols = MAX_COLS
	}
	if cols < 1 {
		return lay
	}

	grid_w := cols*pitch - gap
	grid_h := i32(LCD_MATRIX_ROWS)*pitch - gap

	info_h := dm(s, LCD_INFO_H)
	load_h := dm(s, LCD_LOAD_H)
	icon_h := dm(s, LCD_ICON_H)

	pb := dm(s, PLAYLIST_BORDER)
	pp := dm(s, PLAYLIST_PAD)
	ph := dm(s, PLAYLIST_ROW_H)
	playlist_h := 2*pb + 2*pp + i32(PLAYLIST_ROWS)*ph
	g_playlist := dm(s, PLAYLIST_GAP)
	g_info := dm(s, LCD_INFO_GAP)
	g_load := dm(s, LCD_LOAD_GAP)
	g_seek := dm(s, SEEK_GAP)
	seek_h := dm(s, SEEK_BAND)
	g_icon := dm(s, LCD_ICON_GAP)

	top     := dm(s, LCD_MARGIN_TOP)
	panel_w := grid_w + 2*(border + lcd_pad)
	panel_h := panel_height(s, grid_h)

	lay.panel = rect(margin, top, margin + panel_w, top + panel_h)
	lay.cols  = int(cols)
	lay.rows  = LCD_MATRIX_ROWS

	ix := margin + border + lcd_pad
	iy := top + border + lcd_pad
	lay.grid = rect(ix, iy, ix + grid_w, iy + grid_h)

	// The lower half gives up its right edge to the volume column.
	vol_w     := dm(s, VOL_W)
	content_w := grid_w - vol_w

	y := iy + grid_h + g_info
	lay.info = rect(ix, y, ix + grid_w, y + info_h)

	y += info_h + g_load
	lay.load = rect(ix, y, ix + grid_w, y + load_h)

	// Playlist block: dark frame, darker infill, arrows on the right.
	y += load_h + g_playlist
	lay.playlist = rect(ix, y, ix + content_w, y + playlist_h)

	arrow := dm(s, 12)
	content_left := ix + pb + pp
	content_top := y + pb + pp
	content_right := ix + content_w - pb - pp
	content_bottom := y + playlist_h - pb - pp
	lay.arrow_up = rect(content_right - arrow, content_top, content_right, content_top + arrow)
	lay.arrow_down = rect(content_right - arrow, content_bottom - arrow, content_right, content_bottom)
	lay.pl_text_x = content_left
	lay.pl_text_right = lay.arrow_up.left - dm(s, 4)

	// Seek band sits between the playlist and the transport.
	y += playlist_h + g_seek
	lay.seek = rect(ix, y, ix + content_w, y + seek_h)

	y += seek_h + g_icon
	lay.icons = rect(ix, y, ix + content_w, y + icon_h)

	// Volume column: speaker, vertical slider, mute. Spans the playlist top
	// down to the bottom of the transport row.
	lay.volume = rect(ix + content_w, lay.playlist.top, ix + grid_w, lay.icons.bottom)

	icon_size := dm(s, ICON_H)
	icon_top  := lay.icons.top + (icon_h - icon_size)/2
	icon_bot  := icon_top + icon_size

	// The stack is anchored on the mute button: it sits one icon gap after the
	// transport, and the speaker and track are centred on it.
	mute_w := dm(s, 18)
	mute_x := lay.icons.right + dm(s, TRANSPORT_GAP)
	lay.vol_mute = rect(mute_x, icon_top, mute_x + mute_w, icon_bot)

	center := mute_x + mute_w/2

	spk_w := dm(s, 16)
	spk_x := center - spk_w/2
	spk_y := lay.volume.top + dm(s, 4)
	lay.vol_speaker = rect(spk_x, spk_y, spk_x + spk_w, spk_y + icon_size)

	track_x := center - dm(s, 2)
	lay.vol_track = rect(
		track_x,
		lay.vol_speaker.bottom + dm(s, 6),
		track_x + dm(s, 4),
		lay.vol_mute.top - dm(s, 6),
	)

	// Size gauge, sitting on the same baseline as the icons.
	bottom := icon_bot
	x := lay.icons.left
	for v, i in GAUGE_SIZES {
		sz := dm(s, v)
		sy := bottom - sz
		lay.size_rects[i] = rect(x, sy, x + sz, bottom)
		x += sz + dm(s, 5)
	}
	gauge_end := x - dm(s, 5)

	// Transport, right aligned.
	total := i32(0)
	for i in 0 ..< 9 {
		total += dm(s, TRANSPORT_WIDTHS[i])
	}
	total += dm(s, TRANSPORT_GAP) * 8
	transport_left := lay.icons.right - total
	x = transport_left

	for i in 0 ..< 9 {
		w  := dm(s, TRANSPORT_WIDTHS[i])
		h  := dm(s, TRANSPORT_HEIGHTS[i])
		y0 := lay.icons.top + (icon_h - h)/2
		r  := rect(x, y0, x + w, y0 + h)
		switch i {
		case 0: lay.prev = r
		case 1: lay.rewind = r
		case 2: lay.play = r
		case 3: lay.pause = r
		case 4: lay.stop = r
		case 5: lay.forward = r
		case 6: lay.next = r
		case 7: lay.loop = r
		case 8: lay.loop1 = r
		}
		x += w + dm(s, TRANSPORT_GAP)
	}

	// LIGHT: a bordered text button in the load-control font, centred between
	// the gauge and the transport.
	light_w := small_text_width(s, "LIGHT")
	btn_w := light_w + dm(s, 8)
	btn_h := dm(s, 14)
	cx := gauge_end + ((transport_left - gauge_end) - btn_w)/2
	cy := lay.icons.top + (icon_h - btn_h)/2
	lay.color_btn = rect(cx, cy, cx + btn_w, cy + btn_h)

	// LOAD labels.
	lx := lay.load.left
	w1 := small_text_width(s, "LOAD FILE")
	lay.load_file = rect(lx, lay.load.top, lx + w1, lay.load.bottom)
	lx += w1 + dm(s, 18)
	w2 := small_text_width(s, "LOAD FOLDER")
	lay.load_folder = rect(lx, lay.load.top, lx + w2, lay.load.bottom)

	// Click targets, padded a little so they are easy to hit.
	pad := dm(s, 3)
	for i in 0 ..< 3 {
		add_hit(&lay, rect_pad(lay.size_rects[i], pad), SIZE_CONTROLS[i])
	}
	add_hit(&lay, rect_pad(lay.prev, pad), .Prev)
	add_hit(&lay, rect_pad(lay.rewind, pad), .Rewind)
	add_hit(&lay, rect_pad(lay.play, pad), .Play)
	add_hit(&lay, rect_pad(lay.pause, pad), .Pause)
	add_hit(&lay, rect_pad(lay.stop, pad), .Stop)
	add_hit(&lay, rect_pad(lay.forward, pad), .Forward)
	add_hit(&lay, rect_pad(lay.next, pad), .Next)
	add_hit(&lay, rect_pad(lay.loop, pad), .Loop_All)
	add_hit(&lay, rect_pad(lay.loop1, pad), .Loop_One)
	add_hit(&lay, rect_pad(lay.load_file, dm(s, 2)), .Load_File)
	add_hit(&lay, rect_pad(lay.load_folder, dm(s, 2)), .Load_Folder)
	add_hit(&lay, rect_pad(lay.color_btn, dm(s, 3)), .Theme)
	add_hit(&lay, rect_pad(lay.seek, dm(s, 2)), .Seek)
	add_hit(&lay, rect_pad(lay.vol_track, dm(s, 3)), .Volume_Track)
	add_hit(&lay, rect_pad(lay.vol_mute, dm(s, 2)), .Volume_Mute)
	add_hit(&lay, rect_pad(lay.arrow_up, dm(s, 3)), .List_Up)
	add_hit(&lay, rect_pad(lay.arrow_down, dm(s, 3)), .List_Down)

	// Clicking the analyzer's own rows opens the full-window spectrum view.
	spectrum_top := lay.grid.top + i32(LCD_TOP_ROWS + LCD_ROWS)*pitch
	add_hit(&lay, rect(lay.grid.left, spectrum_top, lay.grid.right, lay.grid.bottom), .Spectrum)

	// One click target per visible playlist row.
	row_right := i32(lay.arrow_up.left) - dm(s, 4)
	for i in 0 ..< PLAYLIST_ROWS {
		idx := g.list_scroll + i
		if idx >= len(library.names) {
			break
		}
		ry := content_top + i32(i)*ph
		add_hit(&lay, rect(content_left, ry, row_right, ry + ph), .List_Row, idx)
	}

	return lay
}

// Full-window spectrum view: the matrix takes everything the bands would have
// used, with just the size dots left at the bottom.
build_spectrum_layout :: proc "contextless" (client_w: i32, s: Scale) -> Layout {
	lay := Layout{}

	dot    := dm(s, LCD_DOT)
	gap    := dm(s, LCD_GAP)
	pitch  := dot + gap
	margin := dm(s, LCD_MARGIN_X)
	border := dm(s, LCD_BORDER)
	lcd_pad := dm(s, LCD_PAD)

	avail := client_w - 2*(margin + border + lcd_pad)
	if pitch <= 0 || avail < dot {
		return lay
	}
	cols := (avail + gap) / pitch
	if cols > MAX_COLS {
		cols = MAX_COLS
	}
	if cols < 1 {
		return lay
	}

	grid_w := cols*pitch - gap
	top := dm(s, LCD_MARGIN_TOP)
	panel_w := grid_w + 2*(border + lcd_pad)
	panel_h := panel_height(s, i32(LCD_MATRIX_ROWS)*pitch - gap)

	lay.panel = rect(margin, top, margin + panel_w, top + panel_h)
	lay.cols  = int(cols)

	ix := margin + border + lcd_pad
	iy := top + border + lcd_pad
	content_bottom := top + panel_h - border - lcd_pad

	icon_h := dm(s, LCD_ICON_H)
	icon_top := content_bottom - icon_h
	lay.icons = rect(ix, icon_top, ix + grid_w, content_bottom)

	matrix_bottom := icon_top - dm(s, SPECTRUM_GAP)
	rows := (matrix_bottom - iy + gap) / pitch
	if rows < 1 {
		rows = 1
	}
	lay.rows = int(rows)
	lay.grid = rect(ix, iy, ix + grid_w, iy + rows*pitch - gap)

	// Size squares, on the same baseline as the normal view.
	icon_size := dm(s, ICON_H)
	gauge_bottom := icon_top + (icon_h - icon_size)/2 + icon_size
	x := ix
	for v, i in GAUGE_SIZES {
		sz := dm(s, v)
		lay.size_rects[i] = rect(x, gauge_bottom - sz, x + sz, gauge_bottom)
		x += sz + dm(s, 5)
	}

	add_hit(&lay, lay.grid, .Spectrum)
	for i in 0 ..< 3 {
		add_hit(&lay, rect_pad(lay.size_rects[i], dm(s, 3)), SIZE_CONTROLS[i])
	}
	return lay
}

hit_test_at :: proc "contextless" (hwnd: win.HWND, x, y: i32) -> (Control, int) {
	client: win.RECT
	win.GetClientRect(hwnd, &client)
	w := client.right - client.left

	s := Scale{dpi = win.GetDpiForWindow(hwnd), step = current_step()}
	lay := build_layout(w, s)

	for i in 0 ..< lay.hit_count {
		r := lay.hits[i].rect
		if x >= r.left && x < r.right && y >= r.top && y < r.bottom {
			return lay.hits[i].control, lay.hits[i].index
		}
	}
	return .None, 0
}

//
// Entry point
//

main :: proc() {
	g.ctx = context

	// Only one player at a time; the mutex lives as long as the process.
	if !acquire_single_instance() {
		win.MessageBoxW(
			nil,
			to_wide("vibeamp is already running."),
			to_wide(APP_NAME),
			win.MB_OK | win.MB_ICONINFORMATION,
		)
		return
	}

	enable_dpi_awareness()

	// The new-style folder picker is a shell COM object. Without an apartment
	// on this thread SHBrowseForFolderW creates an invisible dialog and the
	// modal loop hangs forever.
	win.CoInitializeEx(nil, .APARTMENTTHREADED)

	settings_load()
	if settings.scale >= 0 && settings.scale < len(SIZE_STEPS) {
		g.scale_index = settings.scale
	}
	if settings.theme >= 0 && settings.theme < len(THEMES) {
		g.theme_index = settings.theme
	}
	g.volume = f32(settings.volume)/100
	if g.volume < 0 {
		g.volume = 0
	}
	if g.volume > 1 {
		g.volume = 1
	}
	g.muted = settings.muted != 0

	audio_init()
	volume_apply()
	spectrum_init()
	set_marquee(DEFAULT_MARQUEE)

	instance := win.GetModuleHandleW(nil)

	g.brush_background = win.CreateSolidBrush(COLOR_BACKGROUND)
	apply_theme()

	g.class_name  = to_wide(WINDOW_CLASS)
	// The app has no About box, so the title bar is the only place a running
	// copy names its version.
	g.title       = to_wide(strings.concatenate({APP_NAME, " - ", APP_VERSION}))
	g.cursor_hand = win.LoadCursorW(nil, win.wstring(win.MAKEINTRESOURCEW(32649))) // IDC_HAND

	freq: win.LARGE_INTEGER
	win.QueryPerformanceFrequency(&freq)
	g.clock_freq = f64(freq)
	g.last_time  = clock_seconds()
	g.idle_since = -1

	g.style = win.DWORD(win.WS_OVERLAPPED | win.WS_CAPTION | win.WS_SYSMENU | win.WS_MINIMIZEBOX)

	wc := win.WNDCLASSEXW {
		cbSize        = win.UINT(size_of(win.WNDCLASSEXW)),
		style         = win.CS_HREDRAW | win.CS_VREDRAW,
		lpfnWndProc   = window_proc,
		hInstance     = win.HINSTANCE(instance),
		hCursor       = win.LoadCursorW(nil, win.wstring(win.MAKEINTRESOURCEW(32512))), // IDC_ARROW
		hbrBackground = nil,
		lpszClassName = g.class_name,
		hIcon         = win.LoadIconW(win.HINSTANCE(instance), win.wstring(win.MAKEINTRESOURCEW(1))),
	}
	wc.hIconSm = wc.hIcon
	if win.RegisterClassExW(&wc) == 0 {
		fatal("Could not register the window class.")
		return
	}

	dpi := win.GetDpiForSystem()
	w, h := outer_size(dpi, current_step())

	work: win.RECT
	win.SystemParametersInfoW(win.SPI_GETWORKAREA, 0, &work, 0)
	x := work.left + ((work.right - work.left) - w) / 2
	y := work.top + ((work.bottom - work.top) - h) / 2

	hwnd := win.CreateWindowExW(
		0, g.class_name, g.title, g.style,
		win.INT(x), win.INT(y), win.INT(w), win.INT(h),
		nil, nil, win.HINSTANCE(instance), nil,
	)
	if hwnd == nil {
		fatal("Could not create the window.")
		return
	}

	apply_dark_titlebar(hwnd)
	win.ShowWindow(hwnd, win.SW_SHOWDEFAULT)
	win.UpdateWindow(hwnd)

	restore_session(hwnd)

	win.SetTimer(hwnd, TIMER_ID, 16, nil)
	g.painted_col = -1

	msg: win.MSG
	for {
		if win.GetMessageW(&msg, nil, 0, 0) <= 0 {
			break
		}
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}

	settings_save()
	settings_free()

	audio_shutdown()
	destroy_gdi_objects()
	if len(g.marquee) > 0 {
		delete(g.marquee)
	}
	win.CoUninitialize()
}

//
// Window procedure
//

window_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	// The procedure has no implicit context; give it the one captured in main so
	// it can allocate (loading files, dialogs, playlist work).
	context = g.ctx

	switch msg {
	case win.WM_ERASEBKGND:
		return 1

	case win.WM_PAINT:
		paint(hwnd)
		return 0

	case win.WM_TIMER:
		if wparam == win.WPARAM(TIMER_ID) {
			tick(hwnd)
		}
		return 0

	case win.WM_LBUTTONDOWN:
		on_click(hwnd, lparam)
		return 0

	case win.WM_MOUSEMOVE:
		if g.seeking {
			x := i32(i16(u16(lparam & 0xFFFF)))
			g.seek_preview = seek_time_at(hwnd, x)
			// Seeking a long MP3 makes the decoder scan, so throttle while
			// dragging; the bar itself still follows the mouse every move.
			now := clock_seconds()
			if now - g.last_seek >= 0.12 {
				g.last_seek = now
				audio_seek(g.seek_preview)
			}
			invalidate(hwnd)
			return 0
		}
		if g.vol_dragging {
			y := i32(i16(u16((lparam >> 16) & 0xFFFF)))
			g.volume = volume_at(hwnd, y)
			volume_apply()
			invalidate(hwnd)
			return 0
		}

	case win.WM_LBUTTONUP:
		if g.seeking {
			g.seeking = false
			audio_seek(g.seek_preview)
			win.ReleaseCapture()
			invalidate(hwnd)
			return 0
		}
		if g.vol_dragging {
			g.vol_dragging = false
			win.ReleaseCapture()
			settings_save()
			invalidate(hwnd)
			return 0
		}

	case win.WM_KEYDOWN:
		on_key(hwnd, int(wparam))
		return 0

	case win.WM_SETCURSOR:
		if u16(lparam & 0xFFFF) == 1 { // HTCLIENT
			p: win.POINT
			if bool(win.GetCursorPos(&p)) && bool(win.ScreenToClient(hwnd, &p)) {
				c, _ := hit_test_at(hwnd, i32(p.x), i32(p.y))
				if c != .None {
					win.SetCursor(g.cursor_hand)
					return 1
				}
			}
		}
		return win.DefWindowProcW(hwnd, msg, wparam, lparam)

	case win.WM_DPICHANGED:
		suggested := (^win.RECT)(rawptr(uintptr(lparam)))
		if suggested != nil {
			win.SetWindowPos(
				hwnd, nil,
				suggested.left, suggested.top,
				suggested.right - suggested.left,
				suggested.bottom - suggested.top,
				win.SWP_NOZORDER | win.SWP_NOACTIVATE,
			)
		}
		win.InvalidateRect(hwnd, nil, true)
		g.dirty_all = true
		return 0

	case win.WM_DESTROY:
		win.KillTimer(hwnd, TIMER_ID)
		win.PostQuitMessage(0)
		return 0
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

//
// Animation tick
//

// The idle scene shows when nothing is loaded, or a few seconds after playback
// is paused or stopped.
IDLE_DELAY :: f64(3.0)

idle_active :: proc "contextless" (now: f64) -> bool {
	if !g.track_loaded {
		return true
	}
	if g.playback == .Playing {
		return false
	}
	if g.idle_since < 0 {
		return false
	}
	return now - g.idle_since >= IDLE_DELAY
}

tick :: proc (hwnd: win.HWND) {
	now := clock_seconds()
	dt  := f32(now - g.last_time)
	g.last_time = now
	if dt < 0 || dt > 0.5 {
		dt = 0
	}

	g.scroll += SCROLL_DOTS_PER_SEC*dt
	if g.marquee_cols > 0 {
		for g.scroll >= f32(g.marquee_cols) {
			g.scroll -= f32(g.marquee_cols)
		}
	}

	// The 60 Hz timer is twice what the display needs; analyse and paint at 30.
	frame := int(now*30)
	if frame == g.spec_frame {
		return
	}
	g.spec_frame = frame

	// Persist the position periodically, so a kill or crash loses at most a
	// few seconds of progress.
	if g.playback == .Playing && now - g.last_save >= 5.0 {
		g.last_save = now
		settings_save()
	}

	// Loop-1 is handled inside the audio callback, so this only fires for the
	// other modes.
	if g.playback == .Playing && audio_finished() {
		audio_clear_finished()
		if g.loop_mode == .Off && library.index + 1 >= len(library.tracks) {
			transport_stop(hwnd)
		} else {
			step_track(hwnd, 1)
		}
		return
	}

	spectrum_update(g.cols, dt, g.playback == .Playing)
	build_info_text()

	dirty: bit_set[Part; u32]

	// A long name in the playing row scrolls between the marquee's own steps.
	if g.pl_overflow {
		frame := int(now*20)
		if frame != g.pl_frame {
			g.pl_frame = frame
			dirty |= {.Playlist_Row}
		}
	}

	// The idle scene animates on its own, faster than the marquee steps.
	idle_frame := 0
	if idle_active(now) {
		idle_frame = int(now*20)
	}
	if idle_frame != g.painted_idle {
		dirty |= {.Matrix}
		g.painted_idle = idle_frame
	}

	col   := int(g.scroll)
	flash := g.playback == .Paused && flash_on(now)
	sec   := int(audio_position())
	if col != g.painted_col {
		dirty |= {.Matrix}
		g.painted_col = col
	}
	if flash != g.painted_flash {
		dirty |= {.Icons}
		g.painted_flash = flash
	}
	if sec != g.painted_second {
		// The seek bar tracks the position, so it moves with the clock too.
		dirty |= {.Info, .Seek}
		g.painted_second = sec
	}

	// Bars are stored in rows of the current mode, so a repaint only happens
	// when the drawn height actually changes.
	rows := g.spec_rows
	if rows < 1 {
		rows = LCD_SPEC_ROWS
	}
	for x in 0 ..< g.cols {
		h := u8(f32(rows)*spectrum.levels[x] + 0.5)
		if h > u8(rows) {
			h = u8(rows)
		}
		g.bars[x] = h
		if h != g.painted_bars[x] {
			dirty |= {.Matrix}
			g.painted_bars[x] = h
		}
	}

	if dirty != {} {
		g.dirty |= dirty
		win.InvalidateRect(hwnd, nil, false)
	}
}

build_info_text :: proc "contextless" () {
	b := info_buf[:]
	if !g.track_loaded {
		g.info_text = ""
		return
	}
	pos := audio_position()
	if g.seeking {
		pos = g.seek_preview
	}
	n := put_clock(b, 0, pos)
	n  = put_str(b, n, " / ")
	n  = put_clock(b, n, audio.duration)
	n  = put_str(b, n, " MP3")
	g.info_text = string(b[:n])
}

put_str :: proc "contextless" (b: []u8, n: int, s: string) -> int {
	for i in 0 ..< len(s) {
		b[n+i] = s[i]
	}
	return n + len(s)
}

put_clock :: proc "contextless" (b: []u8, n: int, secs: f32) -> int {
	t := int(secs)
	if t < 0 {
		t = 0
	}
	m := t / 60
	s := t % 60
	at := n
	if m >= 10 {
		b[at] = u8('0' + m/10)
		at += 1
	}
	b[at] = u8('0' + m%10)
	at += 1
	b[at] = ':'
	at += 1
	b[at] = u8('0' + s/10)
	at += 1
	b[at] = u8('0' + s%10)
	at += 1
	return at
}

//
// Input
//

on_key :: proc (hwnd: win.HWND, vk: int) {
	// High bit set means the key is down.
	ctrl := win.GetKeyState(win.VK_CONTROL) < 0

	switch {
	case vk == win.VK_OEM_PLUS || vk == win.VK_ADD:
		set_scale(hwnd, g.scale_index + 1)
	case vk == win.VK_OEM_MINUS || vk == win.VK_SUBTRACT:
		set_scale(hwnd, g.scale_index - 1)
	case vk == win.VK_SPACE:
		if g.playback == .Playing {
			transport_pause(hwnd)
		} else {
			transport_play(hwnd)
		}
	case vk == win.VK_S:
		transport_stop(hwnd)
	case vk == win.VK_L:
		if ctrl {
			// Ctrl+L: loop the current file only.
			if g.loop_mode == .One {
				g.loop_mode = .Off
			} else {
				g.loop_mode = .One
			}
		} else {
			// L: loop the whole list.
			if g.loop_mode == .All {
				g.loop_mode = .Off
			} else {
				g.loop_mode = .All
			}
		}
		audio_set_looping(g.loop_mode == .One)
		invalidate(hwnd)
	case vk == win.VK_UP:
		step_track(hwnd, -1)
	case vk == win.VK_DOWN:
		step_track(hwnd, 1)
	case vk == win.VK_LEFT:
		transport_seek(hwnd, -5)
	case vk == win.VK_RIGHT:
		transport_seek(hwnd, 5)
	case vk == win.VK_PRIOR:
		volume_step(hwnd, 0.05)
	case vk == win.VK_NEXT:
		volume_step(hwnd, -0.05)
	case vk == win.VK_C:
		cycle_theme(hwnd)
	case vk == win.VK_M:
		g.muted = !g.muted
		volume_apply()
		settings_save()
		invalidate(hwnd)
	case vk == win.VK_ESCAPE:
		if g.spectrum_mode {
			g.spectrum_mode = false
			invalidate(hwnd)
		}
	case vk == win.VK_O:
		if ctrl {
			load_file_dialog(hwnd)
		}
	case vk == win.VK_F:
		if ctrl {
			load_folder_dialog(hwnd)
		}
	}
}

// Keyboard volume step: always comes off mute, like dragging the slider.
volume_step :: proc (hwnd: win.HWND, delta: f32) {
	v := g.volume + delta
	if v < 0 {
		v = 0
	}
	if v > 1 {
		v = 1
	}
	g.volume = v
	g.muted = false
	volume_apply()
	settings_save()
	invalidate(hwnd)
}

on_click :: proc (hwnd: win.HWND, lparam: win.LPARAM) {
	// Dialogs and file loading allocate scratch strings; this bounds them.
	defer free_all(context.temp_allocator)

	x := i32(i16(u16(lparam & 0xFFFF)))
	y := i32(i16(u16((lparam >> 16) & 0xFFFF)))

	ctrl, index := hit_test_at(hwnd, x, y)

	switch ctrl {
	case .None:
		return
	case .Size_1:
		set_scale(hwnd, 0)
	case .Size_2:
		set_scale(hwnd, 1)
	case .Size_4:
		set_scale(hwnd, 2)
	case .Prev:
		step_track(hwnd, -1)
	case .Rewind:
		transport_seek(hwnd, -5)
	case .Play:
		transport_play(hwnd)
	case .Pause:
		transport_pause(hwnd)
	case .Stop:
		transport_stop(hwnd)
	case .Forward:
		transport_seek(hwnd, 5)
	case .Next:
		step_track(hwnd, 1)
	case .Loop_All:
		toggle_loop(hwnd, .All)
	case .Loop_One:
		toggle_loop(hwnd, .One)
	case .Load_File:
		load_file_dialog(hwnd)
	case .Load_Folder:
		load_folder_dialog(hwnd)
	case .List_Up:
		scroll_list(hwnd, -1)
	case .List_Down:
		scroll_list(hwnd, 1)
	case .List_Row:
		if index >= 0 && index < len(library.tracks) {
			library.index = index
			load_current(hwnd)
		}
	case .Theme:
		cycle_theme(hwnd)
	case .Seek:
		g.seeking      = true
		g.seek_preview = seek_time_at(hwnd, x)
		audio_seek(g.seek_preview)
		g.last_seek = clock_seconds()
		win.SetCapture(hwnd)
		invalidate(hwnd)
	case .Volume_Track:
		g.vol_dragging = true
		g.muted = false
		g.volume = volume_at(hwnd, y)
		volume_apply()
		win.SetCapture(hwnd)
		invalidate(hwnd)
	case .Volume_Mute:
		g.muted = !g.muted
		volume_apply()
		settings_save()
		invalidate(hwnd)
	case .Spectrum:
		g.spectrum_mode = !g.spectrum_mode
		invalidate(hwnd)
	}
}

scroll_list :: proc (hwnd: win.HWND, delta: int) {
	max_scroll := len(library.names) - PLAYLIST_ROWS
	if max_scroll < 0 {
		max_scroll = 0
	}
	next := g.list_scroll + delta
	if next < 0 {
		next = 0
	}
	if next > max_scroll {
		next = max_scroll
	}
	if next != g.list_scroll {
		g.list_scroll = next
		invalidate(hwnd)
	}
}

//
// Transport
//

// The window is painted band by band, and only the bands that changed are
// redrawn into the persistent back buffer.
Part :: enum {
	Matrix,
	Info,
	Load,
	Playlist,
	Playlist_Row, // just the playing row, for its scrolling name
	Seek,
	Icons,
	Volume,
}

invalidate :: #force_inline proc (hwnd: win.HWND) {
	g.dirty_all = true
	win.InvalidateRect(hwnd, nil, true)
}

invalidate_part :: #force_inline proc (hwnd: win.HWND, part: Part) {
	g.dirty |= {part}
	win.InvalidateRect(hwnd, nil, false)
}

transport_play :: proc (hwnd: win.HWND) {
	if g.track_loaded {
		audio_play()
		g.playback = .Playing
		g.idle_since = -1
	} else if len(library.tracks) > 0 {
		library.index = 0
		load_current(hwnd)
		return
	} else {
		load_file_dialog(hwnd)
		return
	}
	invalidate(hwnd)
}

transport_pause :: proc (hwnd: win.HWND) {
	switch g.playback {
	case .Playing:
		audio_pause()
		g.playback = .Paused
		g.idle_since = clock_seconds()
	case .Paused:
		audio_play()
		g.playback = .Playing
		g.idle_since = -1
	case .Stopped:
		transport_play(hwnd)
		return
	}
	settings_save()
	invalidate(hwnd)
}

transport_stop :: proc (hwnd: win.HWND) {
	audio_rewind()
	g.playback = .Stopped
	g.idle_since = clock_seconds()
	settings_save()
	invalidate(hwnd)
}

transport_seek :: proc (hwnd: win.HWND, delta: f32) {
	if !g.track_loaded {
		return
	}
	audio_seek(audio_position() + delta)
	invalidate(hwnd)
}

// Steps through the playlist, always wrapping: next at the end returns to the
// top, prev at the top goes to the bottom. The loop mode is about what happens
// when a track ends, not about manual stepping.
step_track :: proc (hwnd: win.HWND, direction: int) {
	n := len(library.tracks)
	if n == 0 {
		return
	}
	i := library.index + direction
	if i < 0 {
		i = n - 1
	}
	if i >= n {
		i = 0
	}
	library.index = i
	load_current(hwnd)
}

toggle_loop :: proc (hwnd: win.HWND, mode: Loop_Mode) {
	if g.loop_mode == mode {
		g.loop_mode = .Off
	} else {
		g.loop_mode = mode
	}
	audio_set_looping(g.loop_mode == .One)
	invalidate(hwnd)
}

cycle_loop :: proc (hwnd: win.HWND) {
	switch g.loop_mode {
	case .Off:
		g.loop_mode = .All
	case .All:
		g.loop_mode = .One
	case .One:
		g.loop_mode = .Off
	}
	audio_set_looping(g.loop_mode == .One)
	invalidate(hwnd)
}

load_current :: proc (hwnd: win.HWND, play_now := true, at := f32(0)) {
	if library.index < 0 || library.index >= len(library.tracks) {
		return
	}
	if !audio_load(library.tracks[library.index]) {
		g.track_loaded = false
		g.track_name   = ""
		set_marquee(DEFAULT_MARQUEE)
		invalidate(hwnd)
		return
	}
	g.track_loaded = true
	g.track_name   = library.names[library.index]
	g.pl_start     = clock_seconds()
	set_marquee(g.track_name)
	audio_set_looping(g.loop_mode == .One)

	if play_now {
		audio_play()
		g.playback   = .Playing
		g.idle_since = -1
	} else {
		// Restored session: park at the saved position without making noise.
		audio_pause()
		audio_seek(at)
		g.playback   = .Paused
		g.idle_since = clock_seconds()
		settings.position = at
	}

	g.painted_col = -1
	ensure_list_visible()
	invalidate(hwnd)
}

// Reopens whatever was playing when the app last closed, paused at the saved
// position. A missing file simply leaves the player idle; a missing playlist
// folder leaves it empty.
restore_session :: proc (hwnd: win.HWND) {
	if len(settings.last_track) == 0 {
		return
	}

	switch settings.mode {
	case .Folder:
		if !dir_exists(settings.playlist_dir) {
			return
		}
		if library_load_folder(settings.playlist_dir) == 0 {
			invalidate(hwnd)
			return
		}
		// The playlist is back even if the exact track has been deleted.
		if !path_exists(settings.last_track) {
			invalidate(hwnd)
			return
		}
		idx := -1
		for track, i in library.tracks {
			if strings.compare(track, settings.last_track) == 0 {
				idx = i
				break
			}
		}
		if idx < 0 {
			invalidate(hwnd)
			return
		}
		library.index = idx
		g.list_scroll = 0
		load_current(hwnd, false, settings.position)

	case .Single:
		if !path_exists(settings.last_track) {
			return
		}
		library_load_single(settings.last_track)
		library.index = 0
		g.list_scroll = 0
		load_current(hwnd, false, settings.position)

	case .None:
	}
}

// Scrolls the playlist window just enough to keep the playing row in view.
ensure_list_visible :: proc () {
	n := len(library.names)
	if n == 0 {
		return
	}
	if library.index < g.list_scroll {
		g.list_scroll = library.index
	} else if library.index >= g.list_scroll + PLAYLIST_ROWS {
		g.list_scroll = library.index - PLAYLIST_ROWS + 1
	}

	max_scroll := n - PLAYLIST_ROWS
	if max_scroll < 0 {
		max_scroll = 0
	}
	if g.list_scroll > max_scroll {
		g.list_scroll = max_scroll
	}
	if g.list_scroll < 0 {
		g.list_scroll = 0
	}
}

load_file_dialog :: proc (hwnd: win.HWND) {
	path := open_file_dialog(hwnd, settings.file_dir)
	if path == "" {
		return
	}

	dir := dir_of(path)
	set_string(&settings.file_dir, dir)
	delete(dir)

	library_load_single(path)
	library.index = 0
	settings.mode = .Single
	set_string(&settings.last_track, path)
	set_string(&settings.playlist_dir, "")
	g.list_scroll = 0
	load_current(hwnd)
	settings_save()
}

load_folder_dialog :: proc (hwnd: win.HWND) {
	dir := open_folder_dialog(hwnd, settings.folder_dir)
	if dir == "" {
		return
	}
	if library_load_folder(dir) == 0 {
		// library_load_folder clears the list first, so the panel is stale now.
		invalidate(hwnd)
		return
	}
	set_string(&settings.folder_dir, dir)
	set_string(&settings.playlist_dir, dir)
	settings.mode = .Folder
	library.index = 0
	g.list_scroll = 0
	load_current(hwnd)
	settings_save()
}

//
// Painting
//

paint :: proc "contextless" (hwnd: win.HWND) {
	ps: win.PAINTSTRUCT
	hdc := win.BeginPaint(hwnd, &ps)
	defer win.EndPaint(hwnd, &ps)

	client: win.RECT
	win.GetClientRect(hwnd, &client)
	w := client.right - client.left
	h := client.bottom - client.top
	if w <= 0 || h <= 0 {
		return
	}

	// A fresh or resized buffer holds nothing, so it needs a full repaint.
	if ensure_back_buffer(hdc, w, h) {
		g.dirty_all = true
	}
	dc := g.buf_dc

	s   := Scale{dpi = win.GetDpiForWindow(hwnd), step = current_step()}
	lay := build_layout(w, s)
	g.cols = lay.cols
	g.spec_rows = LCD_SPEC_ROWS
	if g.spectrum_mode {
		g.spec_rows = lay.rows
	}

	now := clock_seconds()
	if g.dirty_all {
		win.FillRect(dc, &client, g.brush_background)
		win.FillRect(dc, &lay.panel, g.brush_lcd_panel)
		draw_panel_all(dc, &lay, s, now)
		g.dirty_all = false
		g.dirty = {}
	} else if g.dirty != {} {
		draw_panel_parts(dc, &lay, s, now, g.dirty)
		g.dirty = {}
	}

	win.BitBlt(hdc, 0, 0, win.INT(w), win.INT(h), dc, 0, 0, win.SRCCOPY)
}

// Vertical volume column: speaker at the top, slider in the middle, mute at the
// bottom. The slider is the seek bar rotated: light above the level, ink below.
draw_volume :: proc "contextless" (dc: win.HDC, lay: ^Layout, s: Scale) {
	win.FillRect(dc, &lay.volume, g.brush_lcd_panel)
	ink := g.brush_lcd_lit

	// Speaker, with waves showing the level.
	draw_speaker(dc, lay.vol_speaker, ink)
	draw_volume_waves(dc, lay.vol_speaker, s, ink)

	tr := lay.vol_track
	tw := tr.right - tr.left
	th := tr.bottom - tr.top
	if tw > 0 && th > 0 {
		lev := g.volume
		if g.muted {
			lev = 0
		}
		if lev < 0 {
			lev = 0
		}
		if lev > 1 {
			lev = 1
		}
		filled := i32(f32(th)*lev + 0.5)

		fill_rect(dc, tr.left, tr.top, tw, th, g.brush_lcd_unlit)
		if filled > 0 {
			fill_rect(dc, tr.left, tr.bottom - filled, tw, filled, ink)
		}

		// Thumb: the seek bar's 4x10 rotated to 10x4.
		thumb_w := dm(s, 10)
		thumb_h := dm(s, 4)
		ty := tr.bottom - filled - thumb_h/2
		if ty < tr.top {
			ty = tr.top
		}
		if ty + thumb_h > tr.bottom {
			ty = tr.bottom - thumb_h
		}
		tx := tr.left + tw/2 - thumb_w/2
		fill_rect(dc, tx, ty, thumb_w, thumb_h, ink)
	}

	// Mute button: speaker with a cross.
	m := lay.vol_mute
	draw_speaker(dc, m, ink)
	cx0 := m.left + dm(s, 10)
	cy0 := m.top + dm(s, 5)
	cx1 := cx0 + dm(s, 6)
	cy1 := cy0 + dm(s, 6)
	pen := win.CreatePen(0, dm(s, 1), THEMES[g.theme_index].lit)
	if pen != nil {
		old := win.SelectObject(dc, win.HGDIOBJ(pen))
		win.MoveToEx(dc, cx0, cy0, nil)
		win.LineTo(dc, cx1, cy1)
		win.MoveToEx(dc, cx1, cy0, nil)
		win.LineTo(dc, cx0, cy1)
		win.SelectObject(dc, old)
		win.DeleteObject(win.HGDIOBJ(pen))
	}
}

// Speaker silhouette, scaled to the height of `r`.
draw_speaker :: proc "contextless" (dc: win.HDC, r: win.RECT, brush: win.HBRUSH) {
	h := r.bottom - r.top
	if h <= 0 {
		return
	}
	u := h/16
	if u < 1 {
		u = 1
	}
	x := r.left
	y := r.top
	fill_rect(dc, x, y + 5*u, 3*u, 6*u, brush)
	fill_quad(dc, [4]win.POINT {
		{x + 3*u, y + 5*u},
		{x + 8*u, y + 2*u},
		{x + 8*u, y + 14*u},
		{x + 3*u, y + 11*u},
	}, brush)
}

// Level meter beside the speaker: a wave per third, and a bigger one at full.
draw_volume_waves :: proc "contextless" (dc: win.HDC, r: win.RECT, s: Scale, brush: win.HBRUSH) {
	u := (r.bottom - r.top)/16
	if u < 1 {
		u = 1
	}
	x := r.left + 9*u
	y := r.top

	vol := g.volume
	if g.muted {
		vol = 0
	}

	n := 0
	if vol > 0.02 {
		n = 1
	}
	if vol > 0.34 {
		n = 2
	}
	if vol > 0.67 {
		n = 3
	}

	heights := [3]i32{4, 7, 10}
	for i in 0 ..< n {
		bh := heights[i]*u
		by := y + (16*u - bh)/2
		fill_rect(dc, x + i32(i)*2*u, by, u, bh, brush)
	}

	if vol >= 0.99 {
		bh := i32(15)*u
		by := y + (16*u - bh)/2
		fill_rect(dc, x + 6*u, by, u, bh, brush)
	}
}

fill_quad :: proc "contextless" (dc: win.HDC, pts: [4]win.POINT, brush: win.HBRUSH) {
	p := pts
	old_brush := win.SelectObject(dc, win.HGDIOBJ(brush))
	old_pen   := win.SelectObject(dc, win.GetStockObject(win.NULL_PEN))
	win.Polygon(dc, &p[0], 4)
	win.SelectObject(dc, old_pen)
	win.SelectObject(dc, old_brush)
}

draw_panel_all :: proc "contextless" (dc: win.HDC, lay: ^Layout, s: Scale, now: f64) {
	// Spectrum mode: the matrix takes the whole panel, only the dots remain.
	if g.spectrum_mode {
		draw_matrix(dc, lay, s, now)
		draw_size_gauge(dc, lay, s)
		return
	}

	draw_matrix(dc, lay, s, now)
	draw_info_row(dc, lay, s)
	draw_seek(dc, lay, s)
	draw_load_row(dc, lay, s)
	draw_playlist(dc, lay, s, now, 0, PLAYLIST_ROWS)
	draw_icons(dc, lay, s, now)
	draw_volume(dc, lay, s)
}

// Repaints only the bands in `parts`, leaving the rest of the back buffer as is.
draw_panel_parts :: proc "contextless" (dc: win.HDC, lay: ^Layout, s: Scale, now: f64, parts: bit_set[Part; u32]) {
	if g.spectrum_mode {
		if .Matrix in parts {
			draw_matrix(dc, lay, s, now)
		}
		if .Icons in parts {
			win.FillRect(dc, &lay.icons, g.brush_lcd_panel)
			draw_size_gauge(dc, lay, s)
		}
		// The playlist is not on screen, so its marquee must not drive repaints.
		g.pl_overflow = false
		return
	}

	if .Matrix in parts {
		draw_matrix(dc, lay, s, now)
	}
	if .Info in parts {
		draw_info_row(dc, lay, s)
	}
	if .Seek in parts {
		draw_seek(dc, lay, s)
	}
	if .Load in parts {
		draw_load_row(dc, lay, s)
	}
	if .Playlist in parts {
		draw_playlist(dc, lay, s, now, 0, PLAYLIST_ROWS)
	} else if .Playlist_Row in parts {
		row := library.index - g.list_scroll
		if row >= 0 && row < PLAYLIST_ROWS {
			draw_playlist(dc, lay, s, now, row, 1)
		}
	}
	if .Icons in parts {
		draw_icons(dc, lay, s, now)
	}
	if .Volume in parts {
		draw_volume(dc, lay, s)
	}
}

// The whole matrix: marquee rows on top, spectrum bars under them, then one
// blank buffer row. All of it is the same dot field.
// A COLORREF is 0x00BBGGRR; a 32bpp DIB pixel is 0x00RRGGBB.
dib_pixel :: #force_inline proc "contextless" (c: win.COLORREF) -> u32 {
	return (u32(c & 0xFF) << 16) | (u32((c >> 8) & 0xFF) << 8) | u32((c >> 16) & 0xFF)
}

// Builds a tiled dot pattern as a brush: one dot on the panel colour, repeated
// every `pitch`. GDI wants at least 8x8, so small pitches are tiled into it.
dot_pattern :: proc "contextless" (pitch, dot: i32, bg, fg: win.COLORREF) -> (win.HBRUSH, win.HBITMAP) {
	if pitch <= 0 || dot <= 0 {
		return nil, nil
	}
	size := pitch
	if size < 8 {
		size = 8
	}

	dc := win.CreateCompatibleDC(nil)
	if dc == nil {
		return nil, nil
	}
	defer win.DeleteDC(dc)

	bmi: win.BITMAPINFO
	bmi.bmiHeader.biSize        = u32(size_of(win.BITMAPINFOHEADER))
	bmi.bmiHeader.biWidth       = size
	bmi.bmiHeader.biHeight      = -size
	bmi.bmiHeader.biPlanes      = 1
	bmi.bmiHeader.biBitCount    = 32
	bmi.bmiHeader.biCompression = 0

	bits: rawptr
	bmp := win.CreateDIBSection(dc, &bmi, 0, &bits, nil, 0)
	if bmp == nil || bits == nil {
		return nil, nil
	}

	px := cast([^]u32) bits
	back := dib_pixel(bg)
	fore := dib_pixel(fg)
	for y in 0 ..< size {
		for x in 0 ..< size {
			c := back
			if (x % pitch) < dot && (y % pitch) < dot {
				c = fore
			}
			px[y*size + x] = c
		}
	}

	brush := CreatePatternBrush(bmp)
	if brush == nil {
		win.DeleteObject(win.HGDIOBJ(bmp))
		return nil, nil
	}
	return brush, bmp
}

destroy_dot_brushes :: proc "contextless" () {
	if g.dot_brush_lit != nil {
		win.DeleteObject(win.HGDIOBJ(g.dot_brush_lit))
		g.dot_brush_lit = nil
	}
	if g.dot_brush_unlit != nil {
		win.DeleteObject(win.HGDIOBJ(g.dot_brush_unlit))
		g.dot_brush_unlit = nil
	}
	if g.dot_bmp_lit != nil {
		win.DeleteObject(win.HGDIOBJ(g.dot_bmp_lit))
		g.dot_bmp_lit = nil
	}
	if g.dot_bmp_unlit != nil {
		win.DeleteObject(win.HGDIOBJ(g.dot_bmp_unlit))
		g.dot_bmp_unlit = nil
	}
	g.dot_brush_theme = -1
	g.dot_brush_pitch = 0
}

ensure_dot_brushes :: proc "contextless" (s: Scale) {
	pitch := dm(s, LCD_DOT) + dm(s, LCD_GAP)
	if g.dot_brush_lit != nil && g.dot_brush_unlit != nil &&
	   g.dot_brush_theme == g.theme_index && g.dot_brush_pitch == pitch {
		return
	}
	destroy_dot_brushes()

	t := THEMES[g.theme_index]
	dot := dm(s, LCD_DOT)
	g.dot_brush_lit, g.dot_bmp_lit = dot_pattern(pitch, dot, t.panel, t.lit)
	g.dot_brush_unlit, g.dot_bmp_unlit = dot_pattern(pitch, dot, t.panel, t.unlit)
	g.dot_brush_theme = g.theme_index
	g.dot_brush_pitch = pitch
}

// Shared per-column state for the dot field, so both the batched and the
// fallback paths agree on which dots are lit.
Matrix_Ctx :: struct {
	spectrum:  bool,
	idle:      bool,
	now:       f64,
	cols:      int,
	rows:      int,
	spec_rows: int,
	columns:   [MAX_COLS]u8,
	bar_rows:  [MAX_COLS]i32,
}

matrix_lit :: #force_inline proc "contextless" (m: ^Matrix_Ctx, x, row: int) -> bool {
	if m.spectrum {
		if m.idle {
			return idle_lit(x, row, m.cols, m.rows, m.now)
		}
		return row >= m.spec_rows - int(m.bar_rows[x])
	}

	content := row - LCD_TOP_ROWS
	switch {
	case content < 0 || content >= LCD_ROWS + LCD_SPEC_ROWS:
		return false
	case content < LCD_ROWS:
		return is_lit(m.columns[x], content)
	}
	at := content - LCD_ROWS
	if m.idle {
		return idle_lit(x, at, m.cols, m.spec_rows, m.now)
	}
	return at >= m.spec_rows - int(m.bar_rows[x])
}

// One fill for a vertical run of lit dots. The pattern tiles from the grid
// origin, so the run lines up with the rest of the field.
fill_dot_run :: #force_inline proc "contextless" (
	dc: win.HDC, gx, gy: i32, x: int, r0, r1: int, pitch, dot, gap: i32, brush: win.HBRUSH,
) {
	r := win.RECT {
		left   = gx + i32(x)*pitch,
		top    = gy + i32(r0)*pitch,
		right  = gx + i32(x)*pitch + dot,
		bottom = gy + i32(r1+1)*pitch - gap,
	}
	win.FillRect(dc, &r, brush)
}

draw_matrix :: proc "contextless" (dc: win.HDC, lay: ^Layout, s: Scale, now: f64) {
	dot   := dm(s, LCD_DOT)
	gap   := dm(s, LCD_GAP)
	pitch := dot + gap
	gx    := lay.grid.left
	gy    := lay.grid.top

	n := lay.cols
	if n > MAX_COLS {
		n = MAX_COLS
	}

	spec_rows := LCD_SPEC_ROWS
	if g.spectrum_mode {
		spec_rows = lay.rows
	}

	m: Matrix_Ctx
	m.spectrum  = g.spectrum_mode
	m.idle      = idle_active(now)
	m.now       = now
	m.cols      = n
	m.rows      = lay.rows
	m.spec_rows = spec_rows

	base := int(g.scroll)
	for x in 0 ..< n {
		m.columns[x]  = message_column(base + x)
		m.bar_rows[x] = i32(g.bars[x])
		if m.bar_rows[x] > i32(spec_rows) {
			m.bar_rows[x] = i32(spec_rows)
		}
		// A loaded track always shows a baseline, so mute reads as a flat line
		// rather than an empty display.
		if !m.idle && m.bar_rows[x] < 1 {
			m.bar_rows[x] = 1
		}
	}

	ensure_dot_brushes(s)
	batched := g.dot_brush_lit != nil && g.dot_brush_unlit != nil

	if batched {
		// The whole unlit field in one patterned fill.
		SetBrushOrgEx(dc, gx, gy, nil)
		win.FillRect(dc, &lay.grid, g.dot_brush_unlit)
	}

	for x in 0 ..< n {
		if !batched {
			for row in 0 ..< lay.rows {
				brush := g.brush_lcd_unlit
				if matrix_lit(&m, x, row) {
					brush = g.brush_lcd_lit
				}
				fill_rect(dc, gx + i32(x)*pitch, gy + i32(row)*pitch, dot, dot, brush)
			}
			continue
		}

		run := -1
		for row in 0 ..< lay.rows {
			if matrix_lit(&m, x, row) {
				if run < 0 {
					run = row
				}
			} else if run >= 0 {
				fill_dot_run(dc, gx, gy, x, run, row-1, pitch, dot, gap, g.dot_brush_lit)
				run = -1
			}
		}
		if run >= 0 {
			fill_dot_run(dc, gx, gy, x, run, lay.rows-1, pitch, dot, gap, g.dot_brush_lit)
		}
	}
}

draw_info_row :: proc "contextless" (dc: win.HDC, lay: ^Layout, s: Scale) {
	win.FillRect(dc, &lay.info, g.brush_lcd_panel)
	ink := g.brush_lcd_lit

	name := g.track_name
	if !g.track_loaded {
		name = "NO TRACK"
	}

	time_w := small_text_width(s, g.info_text)
	reserve := time_w + dm(s, 10)
	avail := (lay.info.right - lay.info.left) - reserve

	cell := dm(s, 6)
	if cell < 1 {
		cell = 1
	}
	max_chars := int(avail / cell)
	if max_chars < 0 {
		max_chars = 0
	}
	if len(name) > max_chars {
		name = name[:max_chars]
	}

	y := lay.info.top + dm(s, 1)
	draw_small_text(dc, lay.info.left, y, s, name, ink)
	draw_small_text(dc, lay.info.right - time_w, y, s, g.info_text, ink)
}

// Progress line: light for unheard, dark for played, with a draggable thumb.
draw_seek :: proc "contextless" (dc: win.HDC, lay: ^Layout, s: Scale) {
	win.FillRect(dc, &lay.seek, g.brush_lcd_panel)
	band_h  := dm(s, SEEK_BAND)
	bar_h   := dm(s, SEEK_BAR_H)
	thumb_w := dm(s, SEEK_THUMB)

	left  := lay.seek.left
	width := lay.seek.right - lay.seek.left
	if width <= 0 || bar_h <= 0 {
		return
	}
	bar_y := lay.seek.top + (band_h - bar_h)/2

	// Unheard portion, always drawn so the control reads as a track.
	fill_rect(dc, left, bar_y, width, bar_h, g.brush_lcd_unlit)

	if !g.track_loaded || audio.duration <= 0.0 {
		return
	}

	dur := audio.duration
	pos := audio_position()
	if g.seeking {
		pos = g.seek_preview
	}
	if pos < 0 {
		pos = 0
	}
	if pos > dur {
		pos = dur
	}

	played := i32(f32(width)*(pos/dur) + 0.5)
	if played > width {
		played = width
	}
	fill_rect(dc, left, bar_y, played, bar_h, g.brush_lcd_lit)

	// The thumb sits on the boundary and is taller than the line.
	tx := left + played - thumb_w/2
	if tx < left {
		tx = left
	}
	if tx + thumb_w > lay.seek.right {
		tx = lay.seek.right - thumb_w
	}
	fill_rect(dc, tx, lay.seek.top, thumb_w, band_h, g.brush_lcd_lit)
}

// Maps a client y to a volume 0..1 along the vertical track.
volume_at :: proc "contextless" (hwnd: win.HWND, y: i32) -> f32 {
	client: win.RECT
	if !bool(win.GetClientRect(hwnd, &client)) {
		return g.volume
	}
	s := Scale{dpi = win.GetDpiForWindow(hwnd), step = current_step()}
	lay := build_layout(client.right - client.left, s)

	tr := lay.vol_track
	h := tr.bottom - tr.top
	if h <= 0 {
		return g.volume
	}
	f := f32(tr.bottom - y)/f32(h)
	if f < 0 {
		f = 0
	}
	if f > 1 {
		f = 1
	}
	return f
}

volume_apply :: proc "contextless" () {
	if g.muted {
		audio_set_volume(0)
	} else {
		audio_set_volume(g.volume)
	}
}

// Maps a client x to a time in the current track, pixel by pixel.
seek_time_at :: proc "contextless" (hwnd: win.HWND, x: i32) -> f32 {
	if audio.duration <= 0.0 {
		return 0
	}
	client: win.RECT
	win.GetClientRect(hwnd, &client)

	s := Scale{dpi = win.GetDpiForWindow(hwnd), step = current_step()}
	lay := build_layout(client.right - client.left, s)

	width := lay.seek.right - lay.seek.left
	if width <= 0 {
		return 0
	}
	rel := x - lay.seek.left
	if rel < 0 {
		rel = 0
	}
	if rel > width {
		rel = width
	}
	return f32(rel) / f32(width) * audio.duration
}

draw_load_row :: proc "contextless" (dc: win.HDC, lay: ^Layout, s: Scale) {
	win.FillRect(dc, &lay.load, g.brush_lcd_panel)
	ink := g.brush_lcd_lit
	y := lay.load.top + dm(s, 1)
	draw_small_text(dc, lay.load_file.left, y, s, "LOAD FILE", ink)
	draw_small_text(dc, lay.load_folder.left, y, s, "LOAD FOLDER", ink)
}

// The playlist: a dark frame, a darker-green infill, light-green lines.
draw_playlist :: proc "contextless" (dc: win.HDC, lay: ^Layout, s: Scale, now: f64, first: int, count: int) {
	pb := dm(s, PLAYLIST_BORDER)
	pp := dm(s, PLAYLIST_PAD)
	row_h := dm(s, PLAYLIST_ROW_H)

	l := i32(lay.playlist.left)
	t := i32(lay.playlist.top)
	r := i32(lay.playlist.right)
	b := i32(lay.playlist.bottom)

	text_x := lay.pl_text_x
	text_top := t + pb + pp
	text_right := lay.pl_text_right
	avail := text_right - text_x

	full := first == 0 && count >= PLAYLIST_ROWS
	if full {
		// Dark frame, then the infill inside it.
		win.FillRect(dc, &lay.playlist, g.brush_lcd_lit)
		inner := rect(l + pb, t + pb, r - pb, b - pb)
		win.FillRect(dc, &inner, g.brush_list_bg)
	} else {
		// Partial repaint: clear just the rows being redrawn, stopping short of
		// the arrow column so the arrows survive.
		for k in 0 ..< count {
			row_top := text_top + i32(first + k)*row_h
			band := rect(l + pb, row_top, lay.arrow_up.left, row_top + row_h)
			win.FillRect(dc, &band, g.brush_list_bg)
		}
	}

	cell := dm(s, 6)
	max_chars := 0
	if cell > 0 {
		max_chars = int(avail / cell)
	}

	g.pl_overflow = false

	for k in 0 ..< count {
		i := first + k
		idx := g.list_scroll + i
		if idx >= len(library.names) {
			break
		}

		row_top := text_top + i32(i)*row_h
		selected := g.track_loaded && idx == library.index

		// The playing track gets a dark bar so the light text pops.
		if selected {
			fill_rect(dc, text_x, row_top, (text_right + dm(s, 2)) - text_x, row_h, g.brush_lcd_lit)
		}

		name := library.names[idx]
		text_w := small_text_width(s, name)

		if selected && text_w > avail {
			// Long name in the playing row: slide it, then come round again
			// after a gap. Clipped to the row so it cannot run into the arrows.
			g.pl_overflow = true
			gap := dm(s, 16)
			cycle := f32(text_w + gap)
			off := f32(now - g.pl_start)*f32(dm(s, PLAYLIST_SCROLL_PPS))
			for off >= cycle {
				off -= cycle
			}
			ox := text_x - i32(off)

			saved := win.SaveDC(dc)
			IntersectClipRect(dc, text_x, row_top, text_right, row_top + row_h)
			draw_small_text(dc, ox, row_top + dm(s, 1), s, name, g.brush_lcd_unlit)
			draw_small_text(dc, ox + i32(cycle), row_top + dm(s, 1), s, name, g.brush_lcd_unlit)
			win.RestoreDC(dc, saved)
		} else {
			shown := name
			if len(shown) > max_chars {
				shown = shown[:max_chars]
			}
			draw_small_text(dc, text_x, row_top + dm(s, 1), s, shown, g.brush_lcd_unlit)
		}
	}

	if full {
		triangle_up(dc, lay.arrow_up, g.brush_lcd_lit)
		triangle_down(dc, lay.arrow_down, g.brush_lcd_lit)
	}
}

// Backlight glyph: a disc with eight rays, sized to match the stop icon.
draw_size_gauge :: proc "contextless" (dc: win.HDC, lay: ^Layout, s: Scale) {
	for i in 0 ..< 3 {
		r := lay.size_rects[i]
		if i == g.scale_index {
			win.FillRect(dc, &r, g.brush_lcd_lit)
		} else {
			hollow_r(dc, r, max(1, dm(s, 1)), g.brush_lcd_ghost)
		}
	}
}

draw_icons :: proc "contextless" (dc: win.HDC, lay: ^Layout, s: Scale, now: f64) {
	win.FillRect(dc, &lay.icons, g.brush_lcd_panel)
	ink   := g.brush_lcd_lit
	ghost := g.brush_lcd_ghost
	panel := g.brush_lcd_panel
	enabled := g.track_loaded

	// Size gauge.
	draw_size_gauge(dc, lay, s)

	// LIGHT: a bordered label in the same font as LOAD FILE.
	btn := lay.color_btn
	hollow_r(dc, btn, max(1, dm(s, 1)), ink)
	lw := small_text_width(s, "LIGHT")
	lh := dm(s, 8)
	tx := btn.left + (btn.right - btn.left - lw)/2
	ty := btn.top + (btn.bottom - btn.top - lh)/2
	draw_small_text(dc, tx, ty, s, "LIGHT", ink)

	nav := ghost
	if enabled {
		nav = ink
	}
	draw_prev(dc, lay.prev, s, nav)
	draw_rewind(dc, lay.rewind, s, nav)
	draw_forward(dc, lay.forward, s, nav)
	draw_next(dc, lay.next, s, nav)

	draw_play(dc, lay.play, s, brush_if(g.playback == .Playing, ink, ghost))

	paused_on := g.playback == .Paused && flash_on(now)
	draw_pause(dc, lay.pause, s, brush_if(paused_on, ink, ghost))

	draw_stop(dc, lay.stop, s, brush_if(g.playback == .Stopped, ink, ghost))

	draw_loop(dc, lay.loop, s, brush_if(g.loop_mode == .All, ink, ghost), panel, false)
	draw_loop(dc, lay.loop1, s, brush_if(g.loop_mode == .One, ink, ghost), panel, true)
}

//
// Icons
//

draw_play :: proc "contextless" (dc: win.HDC, r: win.RECT, s: Scale, brush: win.HBRUSH) {
	triangle_right(dc, r.left, r.top, r.right - r.left, r.bottom - r.top, brush)
}

draw_pause :: proc "contextless" (dc: win.HDC, r: win.RECT, s: Scale, brush: win.HBRUSH) {
	w   := r.right - r.left
	h   := r.bottom - r.top
	bar := w*5/14
	if bar < 1 {
		bar = 1
	}
	gap := w - 2*bar
	fill_rect(dc, r.left, r.top, bar, h, brush)
	fill_rect(dc, r.left + bar + gap, r.top, bar, h, brush)
}

draw_stop :: proc "contextless" (dc: win.HDC, r: win.RECT, s: Scale, brush: win.HBRUSH) {
	w := r.right - r.left
	h := r.bottom - r.top
	side := min(w, h)
	fill_rect(dc, r.left + (w - side)/2, r.top + (h - side)/2, side, side, brush)
}

draw_prev :: proc "contextless" (dc: win.HDC, r: win.RECT, s: Scale, brush: win.HBRUSH) {
	w   := r.right - r.left
	h   := r.bottom - r.top
	bar := max(1, dm(s, 2))
	fill_rect(dc, r.left, r.top, bar, h, brush)
	triangle_left(dc, r.left + bar, r.top, w - bar, h, brush)
}

draw_next :: proc "contextless" (dc: win.HDC, r: win.RECT, s: Scale, brush: win.HBRUSH) {
	w   := r.right - r.left
	h   := r.bottom - r.top
	bar := max(1, dm(s, 2))
	fill_rect(dc, r.right - bar, r.top, bar, h, brush)
	triangle_right(dc, r.left, r.top, w - bar, h, brush)
}

draw_rewind :: proc "contextless" (dc: win.HDC, r: win.RECT, s: Scale, brush: win.HBRUSH) {
	w    := r.right - r.left
	h    := r.bottom - r.top
	half := w/2
	triangle_left(dc, r.left, r.top, half, h, brush)
	triangle_left(dc, r.left + half, r.top, w - half, h, brush)
}

draw_forward :: proc "contextless" (dc: win.HDC, r: win.RECT, s: Scale, brush: win.HBRUSH) {
	w    := r.right - r.left
	h    := r.bottom - r.top
	half := w/2
	triangle_right(dc, r.left, r.top, half, h, brush)
	triangle_right(dc, r.left + half, r.top, w - half, h, brush)
}

// Loop: a hollow box with arrowheads at opposite corners. `one` adds the "1".
draw_loop :: proc "contextless" (dc: win.HDC, r: win.RECT, s: Scale, brush, panel: win.HBRUSH, one: bool) {
	x := r.left
	y := r.top
	w := r.right - r.left
	h := r.bottom - r.top
	t := max(1, dm(s, 2))

	hollow_r(dc, r, t, brush)

	aw := t*3
	ox := x + w - t*4
	fill_rect(dc, ox, y, aw, t, panel)
	triangle_right(dc, ox, y - t, aw, t*3, brush)

	fill_rect(dc, x + t, y + h - t, aw, t, panel)
	triangle_left(dc, x + t, y + h - t*2, aw, t*3, brush)

	if one {
		// Inset the "1" by one unit top and bottom so it cannot touch the border.
		inset := max(1, dm(s, 1))
		stem_w := max(1, t/2)
		stem_h := h - 2*t - 2*inset
		if stem_h < inset {
			stem_h = inset
		}
		sx := x + w/2 - stem_w/2
		sy := y + t + inset
		fill_rect(dc, sx, sy, stem_w, stem_h, brush)
		fill_rect(dc, sx - t, sy, t, t, brush)                    // top serif
		fill_rect(dc, sx - t, sy + stem_h - t, t*2, t, brush)     // base
	}
}

//
// Small LCD text
//

small_text_width :: #force_inline proc "contextless" (s: Scale, text: string) -> i32 {
	return i32(len(text)) * dm(s, 6)
}

draw_small_text :: proc "contextless" (dc: win.HDC, x, y: i32, s: Scale, text: string, brush: win.HBRUSH) -> i32 {
	unit := dm(s, 1)
	if unit < 1 {
		unit = 1
	}
	cell := unit * 6
	cx := x

	for i in 0 ..< len(text) {
		ch := text[i]
		if ch != ' ' {
			rows := glyph(ch)
			for r in 0 ..< 8 {
				bits := rows[r]
				if bits == 0 {
					continue
				}
				// One fill per horizontal run of pixels, not one per pixel.
				run := -1
				for col in 0 ..< 6 {
					on := col < 5 && (bits >> u8(4 - col)) & 1 == 1
					if on {
						if run < 0 {
							run = col
						}
					} else if run >= 0 {
						fill_rect(dc, cx + i32(run)*unit, y + i32(r)*unit, i32(col - run)*unit, unit, brush)
						run = -1
					}
				}
			}
		}
		cx += cell
	}
	return cx - x
}

//
// Message bitstream (the marquee)
//

// Replaces the marquee text. The string is copied, and the scroll restarts so
// a new title always enters from the right.
set_marquee :: proc (text: string) {
	if len(g.marquee) > 0 && strings.compare(text, g.marquee) == 0 {
		return
	}
	if len(g.marquee) > 0 {
		delete(g.marquee)
	}
	g.marquee = strings.clone(text)
	g.marquee_cols = len(text)*6 + SCROLL_GAP_COLS
	g.scroll = 0
}

message_column :: proc "contextless" (col: int) -> u8 {
	if g.marquee_cols <= 0 || len(g.marquee) == 0 {
		return 0
	}

	c := col % g.marquee_cols
	if c < 0 {
		c += g.marquee_cols
	}

	cell := c / 6
	if cell >= len(g.marquee) {
		return 0
	}

	within := c % 6
	if within >= 5 {
		return 0
	}

	rows := glyph(g.marquee[cell])
	out: u8
	for row in 0 ..< LCD_ROWS {
		if (rows[row] >> u8(4 - within)) & 1 == 1 {
			out |= u8(1) << u8(row)
		}
	}
	return out
}

is_lit :: #force_inline proc "contextless" (column: u8, row: int) -> bool {
	return (column >> u8(row)) & 1 == 1
}

// 5x7 font in 8 rows; row 7 carries descenders. Each row is 5 bits, MSB left.
glyph :: proc "contextless" (ch: u8) -> [8]u8 {
	switch ch {
	case '0': return {0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110, 0}
	case '1': return {0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110, 0}
	case '2': return {0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111, 0}
	case '3': return {0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110, 0}
	case '4': return {0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010, 0}
	case '5': return {0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110, 0}
	case '6': return {0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110, 0}
	case '7': return {0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0}
	case '8': return {0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110, 0}
	case '9': return {0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100, 0}

	case 'A': return {0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001, 0}
	case 'B': return {0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110, 0}
	case 'C': return {0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110, 0}
	case 'D': return {0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110, 0}
	case 'E': return {0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111, 0}
	case 'F': return {0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000, 0}
	case 'G': return {0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111, 0}
	case 'H': return {0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001, 0}
	case 'I': return {0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110, 0}
	case 'J': return {0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100, 0}
	case 'K': return {0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001, 0}
	case 'L': return {0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111, 0}
	case 'M': return {0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001, 0}
	case 'N': return {0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001, 0}
	case 'O': return {0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110, 0}
	case 'P': return {0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000, 0}
	case 'Q': return {0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101, 0}
	case 'R': return {0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001, 0}
	case 'S': return {0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110, 0}
	case 'T': return {0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0}
	case 'U': return {0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110, 0}
	case 'V': return {0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100, 0}
	case 'W': return {0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001, 0}
	case 'X': return {0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001, 0}
	case 'Y': return {0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100, 0}
	case 'Z': return {0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111, 0}

	case 'a': return {0b00000, 0b00000, 0b01110, 0b00001, 0b01111, 0b10001, 0b01111, 0}
	case 'b': return {0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b10001, 0b11110, 0}
	case 'c': return {0b00000, 0b00000, 0b01110, 0b10001, 0b10000, 0b10001, 0b01110, 0}
	case 'd': return {0b00001, 0b00001, 0b01111, 0b10001, 0b10001, 0b10001, 0b01111, 0}
	case 'e': return {0b00000, 0b00000, 0b01110, 0b10001, 0b11111, 0b10000, 0b01111, 0}
	case 'f': return {0b00110, 0b01000, 0b01000, 0b11110, 0b01000, 0b01000, 0b01000, 0}
	case 'g': return {0b00000, 0b00000, 0b01111, 0b10001, 0b10001, 0b01111, 0b00001, 0b01110}
	case 'h': return {0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0}
	case 'i': return {0b00100, 0b00000, 0b01100, 0b00100, 0b00100, 0b00100, 0b01110, 0}
	case 'j': return {0b00010, 0b00000, 0b00110, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100}
	case 'k': return {0b10000, 0b10000, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0}
	case 'l': return {0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110, 0}
	case 'm': return {0b00000, 0b00000, 0b11010, 0b10101, 0b10101, 0b10101, 0b10101, 0}
	case 'n': return {0b00000, 0b00000, 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0}
	case 'o': return {0b00000, 0b00000, 0b01110, 0b10001, 0b10001, 0b10001, 0b01110, 0}
	case 'p': return {0b00000, 0b00000, 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000}
	case 'q': return {0b00000, 0b00000, 0b01111, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001}
	case 'r': return {0b00000, 0b00000, 0b10110, 0b11000, 0b10000, 0b10000, 0b10000, 0}
	case 's': return {0b00000, 0b00000, 0b01111, 0b10000, 0b01110, 0b00001, 0b11110, 0}
	case 't': return {0b01000, 0b01000, 0b11100, 0b01000, 0b01000, 0b01001, 0b00110, 0}
	case 'u': return {0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b10011, 0b01101, 0}
	case 'v': return {0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100, 0}
	case 'w': return {0b00000, 0b00000, 0b10001, 0b10001, 0b10101, 0b10101, 0b01010, 0}
	case 'x': return {0b00000, 0b00000, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0}
	case 'y': return {0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b01111, 0b00001, 0b01110}
	case 'z': return {0b00000, 0b00000, 0b11111, 0b00010, 0b00100, 0b01000, 0b11111, 0}

	case ' ': return {0, 0, 0, 0, 0, 0, 0, 0}
	case '_': return {0, 0, 0, 0, 0, 0, 0, 0b11111}
	case '-': return {0, 0, 0, 0b11111, 0, 0, 0, 0}
	case '.': return {0, 0, 0, 0, 0, 0, 0b01100, 0b01100}
	case ',': return {0, 0, 0, 0, 0, 0b01100, 0b00100, 0b01000}
	case ':': return {0, 0b01100, 0b01100, 0, 0b01100, 0b01100, 0, 0}
	case '/': return {0b00001, 0b00010, 0b00010, 0b00100, 0b01000, 0b01000, 0b10000, 0}
	case '(': return {0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010, 0}
	case ')': return {0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000, 0}
	case '[': return {0b01110, 0b01000, 0b01000, 0b01000, 0b01000, 0b01000, 0b01110, 0}
	case ']': return {0b01110, 0b00010, 0b00010, 0b00010, 0b00010, 0b00010, 0b01110, 0}
	case '!': return {0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00000, 0b00100, 0}
	case '?': return {0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b00000, 0b00100, 0}
	case '+': return {0, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0, 0}
	case '&': return {0b01100, 0b10010, 0b10100, 0b01000, 0b10101, 0b10010, 0b01101, 0}
	case '\'': return {0b00100, 0b00100, 0, 0, 0, 0, 0, 0}
	case '=': return {0, 0, 0b11111, 0, 0b11111, 0, 0, 0}
	case '*': return {0, 0b00100, 0b10101, 0b01110, 0b10101, 0b00100, 0, 0}
	case '#': return {0b01010, 0b01010, 0b11111, 0b01010, 0b11111, 0b01010, 0b01010, 0}
	case '%': return {0b11001, 0b11010, 0b00010, 0b00100, 0b01000, 0b01011, 0b10011, 0}
	}
	return {0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b00000, 0b00100, 0} // '?'
}

//
// Size steps
//

current_step :: #force_inline proc "contextless" () -> i32 {
	return SIZE_STEPS[g.scale_index]
}

set_scale :: proc (hwnd: win.HWND, index: int) {
	if index < 0 || index >= len(SIZE_STEPS) || index == g.scale_index {
		return
	}
	g.scale_index = index
	resize_for_step(hwnd)
	settings_save()
	invalidate(hwnd)
}

resize_for_step :: proc "contextless" (hwnd: win.HWND) {
	dpi := win.GetDpiForWindow(hwnd)
	w, h := outer_size(dpi, current_step())

	cur: win.RECT
	win.GetWindowRect(hwnd, &cur)
	cx := cur.left + (cur.right - cur.left)/2
	cy := cur.top + (cur.bottom - cur.top)/2

	work := work_area(hwnd)
	x := cx - w/2
	y := cy - h/2

	if w >= work.right - work.left {
		x = work.left
	} else {
		x = clamp_range(x, work.left, work.right - w)
	}
	if h >= work.bottom - work.top {
		y = work.top
	} else {
		y = clamp_range(y, work.top, work.bottom - h)
	}

	win.SetWindowPos(hwnd, nil, win.INT(x), win.INT(y), win.INT(w), win.INT(h), win.SWP_NOZORDER | win.SWP_NOACTIVATE)
}

clamp_range :: #force_inline proc "contextless" (v, lo, hi: i32) -> i32 {
	if v < lo { return lo }
	if v > hi { return hi }
	return v
}

//
// Scale, primitives
//

Scale :: struct {
	dpi:  win.UINT,
	step: i32,
}

dm :: #force_inline proc "contextless" (s: Scale, v: i32) -> i32 {
	return dip_to_px(v*s.step, s.dpi)
}

fill_rect :: #force_inline proc "contextless" (dc: win.HDC, x, y, w, h: i32, brush: win.HBRUSH) {
	r := win.RECT{win.LONG(x), win.LONG(y), win.LONG(x + w), win.LONG(y + h)}
	win.FillRect(dc, &r, brush)
}

hollow_r :: proc "contextless" (dc: win.HDC, r: win.RECT, t: i32, brush: win.HBRUSH) {
	thick := t
	if thick < 1 {
		thick = 1
	}
	w := r.right - r.left
	h := r.bottom - r.top
	if w <= 2*thick || h <= 2*thick {
		return
	}
	fill_rect(dc, r.left, r.top, w, thick, brush)
	fill_rect(dc, r.left, r.bottom - thick, w, thick, brush)
	fill_rect(dc, r.left, r.top + thick, thick, h - 2*thick, brush)
	fill_rect(dc, r.right - thick, r.top + thick, thick, h - 2*thick, brush)
}

triangle_right :: proc "contextless" (dc: win.HDC, x, y, w, h: i32, brush: win.HBRUSH) {
	pts := [3]win.POINT {
		{win.LONG(x), win.LONG(y)},
		{win.LONG(x), win.LONG(y + h)},
		{win.LONG(x + w), win.LONG(y + h/2)},
	}
	fill_triangle(dc, pts, brush)
}

triangle_left :: proc "contextless" (dc: win.HDC, x, y, w, h: i32, brush: win.HBRUSH) {
	pts := [3]win.POINT {
		{win.LONG(x + w), win.LONG(y)},
		{win.LONG(x + w), win.LONG(y + h)},
		{win.LONG(x), win.LONG(y + h/2)},
	}
	fill_triangle(dc, pts, brush)
}

triangle_up :: proc "contextless" (dc: win.HDC, r: win.RECT, brush: win.HBRUSH) {
	pts := [3]win.POINT {
		{win.LONG(r.left), win.LONG(r.bottom)},
		{win.LONG(r.right), win.LONG(r.bottom)},
		{win.LONG((r.left + r.right)/2), win.LONG(r.top)},
	}
	fill_triangle(dc, pts, brush)
}

triangle_down :: proc "contextless" (dc: win.HDC, r: win.RECT, brush: win.HBRUSH) {
	pts := [3]win.POINT {
		{win.LONG(r.left), win.LONG(r.top)},
		{win.LONG(r.right), win.LONG(r.top)},
		{win.LONG((r.left + r.right)/2), win.LONG(r.bottom)},
	}
	fill_triangle(dc, pts, brush)
}

fill_triangle :: proc "contextless" (dc: win.HDC, pts: [3]win.POINT, brush: win.HBRUSH) {
	p := pts
	old_brush := win.SelectObject(dc, win.HGDIOBJ(brush))
	old_pen   := win.SelectObject(dc, win.GetStockObject(win.NULL_PEN))
	win.Polygon(dc, &p[0], 3)
	win.SelectObject(dc, old_pen)
	win.SelectObject(dc, old_brush)
}

brush_if :: #force_inline proc "contextless" (cond: bool, yes, no: win.HBRUSH) -> win.HBRUSH {
	if cond {
		return yes
	}
	return no
}

// 0.9 s lit, 0.7 s dark.
flash_on :: #force_inline proc "contextless" (now: f64) -> bool {
	period := 1.6
	return now - f64(i64(now/period))*period < 0.9
}

//
// Helpers
//

ensure_back_buffer :: proc "contextless" (hdc: win.HDC, w, h: i32) -> bool {
	if g.buf_dc != nil && g.buf_w == w && g.buf_h == h {
		return false
	}
	destroy_back_buffer()

	g.buf_dc  = win.CreateCompatibleDC(hdc)
	g.buf_bmp = win.CreateCompatibleBitmap(hdc, win.INT(w), win.INT(h))
	if g.buf_bmp != nil {
		g.buf_old = win.SelectObject(g.buf_dc, win.HGDIOBJ(g.buf_bmp))
	}
	g.buf_w = w
	g.buf_h = h
	return true
}

destroy_back_buffer :: proc "contextless" () {
	if g.buf_dc == nil {
		return
	}
	if g.buf_old != nil {
		win.SelectObject(g.buf_dc, g.buf_old)
	}
	if g.buf_bmp != nil {
		win.DeleteObject(win.HGDIOBJ(g.buf_bmp))
	}
	win.DeleteDC(g.buf_dc)
	g.buf_dc  = nil
	g.buf_bmp = nil
	g.buf_old = nil
	g.buf_w   = 0
	g.buf_h   = 0
}

outer_size :: proc "contextless" (dpi: win.UINT, step: i32) -> (w, h: i32) {
	cw := dip_to_px(CLIENT_WIDTH*step, dpi)
	ch := dip_to_px(CLIENT_HEIGHT*step, dpi)

	r := win.RECT{0, 0, win.LONG(cw), win.LONG(ch)}
	win.AdjustWindowRectExForDpi(&r, g.style, false, 0, dpi)
	return i32(r.right - r.left), i32(r.bottom - r.top)
}

work_area :: proc "contextless" (hwnd: win.HWND) -> win.RECT {
	mi: win.MONITORINFO
	mi.cbSize = win.DWORD(size_of(win.MONITORINFO))

	monitor := win.MonitorFromWindow(hwnd, .MONITOR_DEFAULTTONEAREST)
	if monitor != nil && bool(win.GetMonitorInfoW(monitor, &mi)) {
		return mi.rcWork
	}

	r: win.RECT
	win.SystemParametersInfoW(win.SPI_GETWORKAREA, 0, &r, 0)
	return r
}

enable_dpi_awareness :: proc() {
	if !bool(win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) {
		win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_SYSTEM_AWARE)
	}
}

apply_dark_titlebar :: proc(hwnd: win.HWND) {
	enabled := win.BOOL(true)
	win.DwmSetWindowAttribute(
		hwnd,
		win.DWORD(win.DWMWINDOWATTRIBUTE.DWMWA_USE_IMMERSIVE_DARK_MODE),
		rawptr(&enabled),
		win.DWORD(size_of(enabled)),
	)
}

dip_to_px :: #force_inline proc "contextless" (dip: i32, dpi: win.UINT) -> i32 {
	return i32(f32(dip)*f32(dpi)/96.0 + 0.5)
}

to_wide :: proc(s: string) -> win.wstring {
	return win.utf8_to_wstring(s)
}

clock_seconds :: #force_inline proc "contextless" () -> f64 {
	ticks: win.LARGE_INTEGER
	win.QueryPerformanceCounter(&ticks)
	return f64(ticks)/g.clock_freq
}

// Rebuilds the LCD brushes for the current theme.
apply_theme :: proc () {
	t := THEMES[g.theme_index]

	old := [5]win.HBRUSH {
		g.brush_lcd_panel,
		g.brush_lcd_unlit,
		g.brush_lcd_lit,
		g.brush_lcd_ghost,
		g.brush_list_bg,
	}
	for brush in old {
		if brush != nil {
			win.DeleteObject(win.HGDIOBJ(brush))
		}
	}

	g.brush_lcd_panel = win.CreateSolidBrush(t.panel)
	g.brush_lcd_unlit = win.CreateSolidBrush(t.unlit)
	g.brush_lcd_lit   = win.CreateSolidBrush(t.lit)
	g.brush_lcd_ghost = win.CreateSolidBrush(t.ghost)
	g.brush_list_bg   = win.CreateSolidBrush(t.list)
}

cycle_theme :: proc (hwnd: win.HWND) {
	g.theme_index = (g.theme_index + 1) % len(THEMES)
	apply_theme()
	settings.theme = g.theme_index
	settings_save()
	invalidate(hwnd)
}

destroy_gdi_objects :: proc() {
	destroy_back_buffer()

	for brush in ([6]win.HBRUSH {
		g.brush_background,
		g.brush_lcd_panel,
		g.brush_lcd_unlit,
		g.brush_lcd_lit,
		g.brush_lcd_ghost,
		g.brush_list_bg,
	}) {
		if brush != nil {
			win.DeleteObject(win.HGDIOBJ(brush))
		}
	}
}

fatal :: proc(message: string) {
	win.MessageBoxW(nil, to_wide(message), to_wide(APP_NAME), win.MB_OK | win.MB_ICONERROR)
}




