package main

import "core:os"
import "core:strings"
import win "core:sys/windows"

// CreateMutexW is not in the shipped bindings; declare the one entry we need.
foreign import k32 "system:Kernel32.lib"

@(default_calling_convention="system")
foreign k32 {
	CreateMutexW :: proc(lpMutexAttributes: rawptr, bInitialOwner: win.BOOL, lpName: win.LPCWSTR) -> win.HANDLE ---
}

//
// Persistence: a small UTF-8 key=value file under %LOCALAPPDATA%\vibeamp.
//
// Everything is written atomically (temp file + replace) so a kill mid-save
// can never leave a truncated config behind. Strings are owned by the settings
// struct and replaced through `set_string`.
//

Playlist_Mode :: enum u8 {
	None,
	Folder,
	Single,
}

Settings :: struct {
	version:      int,
	scale:        int, // index into SIZE_STEPS
	theme:        int, // index into THEMES
	position:     f32, // seconds into last_track
	mode:         Playlist_Mode,
	folder_dir:   string, // last LOAD FOLDER choice
	file_dir:     string, // directory of the last LOAD FILE choice
	playlist_dir: string, // what was actually loaded, for restoring
	last_track:   string,
}

settings: Settings

SETTINGS_VERSION :: 1
SETTINGS_DIR     :: "vibeamp"
SETTINGS_FILE    :: "settings.ini"

// Windows keeps this per-process for the session; holding it for the life of
// the program is what declares the instance.
single_instance_mutex: win.HANDLE

free_string :: proc(s: ^string) {
	if len(s^) > 0 {
		delete(s^)
	}
	s^ = ""
}

set_string :: proc(dst: ^string, value: string) {
	if len(dst^) > 0 && len(value) > 0 && strings.compare(dst^, value) == 0 {
		return
	}
	free_string(dst)
	if len(value) > 0 {
		dst^ = strings.clone(value)
	}
}

// %LOCALAPPDATA%, via the shell so relocated profiles resolve correctly.
local_app_data :: proc() -> string {
	guid := win.FOLDERID_LocalAppData
	pp: win.LPWSTR
	if win.SHGetKnownFolderPath(&guid, 0, nil, &pp) != 0 {
		return ""
	}
	defer win.CoTaskMemFree(rawptr(pp))
	// Heap-allocated, because the caller frees it with `delete`.
	path, _ := win.wstring_to_utf8(win.wstring(pp), -1, context.allocator)
	return path
}

// Full path to settings.ini, creating the folder if needed. Heap string.
settings_path :: proc() -> string {
	base := local_app_data()
	if len(base) == 0 {
		return ""
	}
	defer delete(base)

	dir := strings.concatenate({base, `\`, SETTINGS_DIR})
	defer delete(dir)

	win.CreateDirectoryW(win.utf8_to_wstring(dir), nil) // harmless if it exists

	return strings.concatenate({dir, `\`, SETTINGS_FILE})
}

find_char :: proc(s: string, c: u8) -> int {
	for i in 0 ..< len(s) {
		if s[i] == c {
			return i
		}
	}
	return -1
}

parse_int :: proc(s: string) -> (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	v := 0
	for i in 0 ..< len(s) {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v*10 + int(c - '0')
	}
	return v, true
}

int_str :: proc(buf: []u8, v: int) -> string {
	if v < 0 {
		buf[0] = '-'
		return string(buf[:1])
	}
	if v == 0 {
		buf[0] = '0'
		return string(buf[:1])
	}
	digits: [12]u8
	n := 0
	x := v
	for x > 0 {
		digits[n] = u8('0' + x % 10)
		n += 1
		x /= 10
	}
	for i in 0 ..< n {
		buf[i] = digits[n-1-i]
	}
	return string(buf[:n])
}

settings_load :: proc() {
	path := settings_path()
	if len(path) == 0 {
		return
	}
	defer delete(path)

	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return
	}
	defer delete(data)

	rest := string(data)
	for len(rest) > 0 {
		nl := find_char(rest, '\n')
		line: string
		if nl < 0 {
			line = rest
			rest = ""
		} else {
			line = rest[:nl]
			rest = rest[nl+1:]
		}

		line = strings.trim_space(line)
		if len(line) == 0 || line[0] == '#' || line[0] == ';' {
			continue
		}

		eq := find_char(line, '=')
		if eq <= 0 {
			continue
		}
		key := strings.trim_space(line[:eq])
		val := strings.trim_space(line[eq+1:])

		switch key {
		case "version":
			if n, ok := parse_int(val); ok {
				settings.version = n
			}
		case "scale":
			if n, ok := parse_int(val); ok {
				settings.scale = n
			}
		case "theme":
			if n, ok := parse_int(val); ok {
				settings.theme = n
			}
		case "position":
			if n, ok := parse_int(val); ok {
				settings.position = f32(n)
			}
		case "mode":
			switch val {
			case "folder":
				settings.mode = .Folder
			case "single":
				settings.mode = .Single
			}
		case "folder_dir":
			set_string(&settings.folder_dir, val)
		case "file_dir":
			set_string(&settings.file_dir, val)
		case "playlist_dir":
			set_string(&settings.playlist_dir, val)
		case "last_track":
			set_string(&settings.last_track, val)
		}
	}
}

// Updates the live parts of the settings from the current state.
settings_capture :: proc() {
	settings.version = SETTINGS_VERSION
	settings.scale = g.scale_index
	settings.theme = g.theme_index
	settings.position = audio_position()
	if g.track_loaded && library.index >= 0 && library.index < len(library.tracks) {
		set_string(&settings.last_track, library.tracks[library.index])
	}
}

settings_save :: proc() {
	settings_capture()

	path := settings_path()
	if len(path) == 0 {
		return
	}
	defer delete(path)

	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)

	num: [24]u8

	strings.write_string(&b, "version=1\n")
	strings.write_string(&b, "scale=")
	strings.write_string(&b, int_str(num[:], settings.scale))
	strings.write_string(&b, "\ntheme=")
	strings.write_string(&b, int_str(num[:], settings.theme))
	strings.write_string(&b, "\nposition=")
	strings.write_string(&b, int_str(num[:], int(settings.position)))
	strings.write_string(&b, "\nmode=")
	switch settings.mode {
	case .Folder:
		strings.write_string(&b, "folder")
	case .Single:
		strings.write_string(&b, "single")
	case .None:
		strings.write_string(&b, "none")
	}
	strings.write_string(&b, "\nfolder_dir=")
	strings.write_string(&b, settings.folder_dir)
	strings.write_string(&b, "\nfile_dir=")
	strings.write_string(&b, settings.file_dir)
	strings.write_string(&b, "\nplaylist_dir=")
	strings.write_string(&b, settings.playlist_dir)
	strings.write_string(&b, "\nlast_track=")
	strings.write_string(&b, settings.last_track)
	strings.write_string(&b, "\n")

	// Write beside the target, then replace it in one step.
	tmp := strings.concatenate({path, ".tmp"})
	defer delete(tmp)

	if err := os.write_entire_file(tmp, strings.to_string(b)); err != nil {
		return
	}
	win.MoveFileExW(win.utf8_to_wstring(tmp), win.utf8_to_wstring(path), win.MOVEFILE_REPLACE_EXISTING)
}

settings_free :: proc() {
	free_string(&settings.folder_dir)
	free_string(&settings.file_dir)
	free_string(&settings.playlist_dir)
	free_string(&settings.last_track)
}

// True when another instance is already running. The mutex is held for the
// life of the process.
acquire_single_instance :: proc() -> bool {
	name := win.utf8_to_wstring(`Local\vibeamp-single-instance`)
	single_instance_mutex = CreateMutexW(nil, win.BOOL(false), name)
	if single_instance_mutex == nil {
		return true // could not create it: do not block the user
	}
	return win.GetLastError() != win.ERROR_ALREADY_EXISTS
}

path_exists :: proc(path: string) -> bool {
	if len(path) == 0 {
		return false
	}
	attrs := win.GetFileAttributesW(win.utf8_to_wstring(path))
	if attrs == win.INVALID_FILE_ATTRIBUTES {
		return false
	}
	return (attrs & win.FILE_ATTRIBUTE_DIRECTORY) == 0
}

dir_exists :: proc(path: string) -> bool {
	if len(path) == 0 {
		return false
	}
	attrs := win.GetFileAttributesW(win.utf8_to_wstring(path))
	if attrs == win.INVALID_FILE_ATTRIBUTES {
		return false
	}
	return (attrs & win.FILE_ATTRIBUTE_DIRECTORY) != 0
}
