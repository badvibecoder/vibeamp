package main

import "core:c"
import "core:strings"
import win "core:sys/windows"

//
// Library: the playlist, folder scanning, and the two file dialogs.
//

foreign import shell32 "system:Shell32.lib"

BFFCALLBACK :: #type proc "system" (hwnd: win.HWND, uMsg: win.UINT, lParam: win.LPARAM, lpData: win.LPARAM) -> c.int

BROWSEINFOW :: struct {
	hwndOwner:      win.HWND,
	pidlRoot:       rawptr,
	pszDisplayName: win.LPWSTR,
	lpszTitle:      win.LPCWSTR,
	ulFlags:        win.UINT,
	lpfn:           BFFCALLBACK,
	lParam:         win.LPARAM,
	iImage:         c.int,
}

BIF_RETURNONLYFSDIRS :: 0x0001
BIF_NEWDIALOGSTYLE   :: 0x0040

BFFM_INITIALIZED   :: 1
BFFM_SETSELECTIONW :: 0x0400 + 102

// Called while the picker is being built; preselect the remembered folder so
// the dialog opens where the user left off.
browse_callback :: proc "system" (hwnd: win.HWND, uMsg: win.UINT, lParam: win.LPARAM, lpData: win.LPARAM) -> c.int {
	if uMsg == BFFM_INITIALIZED && lpData != 0 {
		win.SendMessageW(hwnd, BFFM_SETSELECTIONW, 1, lpData)
	}
	return 0
}

@(default_calling_convention="system")
foreign shell32 {
	SHBrowseForFolderW   :: proc(lpbi: ^BROWSEINFOW) -> rawptr ---
	SHGetPathFromIDListW :: proc(pidl: rawptr, pszPath: win.LPWSTR) -> win.BOOL ---
}

library: struct {
	tracks: [dynamic]string, // full paths
	names:  [dynamic]string, // file names, for the display
	index:  int,
}

library_clear :: proc() {
	for path in library.tracks {
		delete(path)
	}
	for name in library.names {
		delete(name)
	}
	clear(&library.tracks)
	clear(&library.names)
	library.index = 0
}

library_add :: proc(fullpath, name: string) {
	append(&library.tracks, strings.clone(fullpath))
	append(&library.names, strings.clone(name))
}

// Case-insensitive selection sort; playlists are small so this is plenty.
library_sort :: proc() {
	for i in 1 ..< len(library.names) {
		j := i
		for j > 0 && strings.compare(library.names[j], library.names[j-1]) < 0 {
			names := library.names
			names[j], names[j-1] = names[j-1], names[j]
			tracks := library.tracks
			tracks[j], tracks[j-1] = tracks[j-1], tracks[j]
			j -= 1
		}
	}
}

// Windows wildcards match extensions by prefix ("*.mp3" also finds ".mp3x"),
// so the extension is checked explicitly.
is_mp3_name :: proc(name: string) -> bool {
	n := len(name)
	if n < 5 {
		return false
	}
	if name[n-4] != '.' {
		return false
	}
	ext := name[n-3:]
	lower := proc(c: u8) -> u8 {
		if c >= 'A' && c <= 'Z' {
			return c + 32
		}
		return c
	}
	return lower(ext[0]) == 'm' && lower(ext[1]) == 'p' && lower(ext[2]) == '3'
}

// Loads every *.mp3 directly inside `dir` (not recursive). Returns the count.
library_load_folder :: proc(dir: string) -> int {
	library_clear()

	pattern := strings.concatenate({dir, `\*.mp3`})
	defer delete(pattern)

	data: win.WIN32_FIND_DATAW
	handle := win.FindFirstFileW(win.utf8_to_wstring(pattern), &data)
	if handle == nil || handle == win.INVALID_HANDLE_VALUE {
		return 0
	}
	defer win.FindClose(handle)

	for {
		is_dir := (data.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY) != 0
		if !is_dir {
			name, _ := win.wstring_to_utf8(win.wstring(&data.cFileName[0]))
			if is_mp3_name(name) {
				full := strings.concatenate({dir, `\`, name})
				library_add(full, name)
				delete(full)
			}
		}
		if !bool(win.FindNextFileW(handle, &data)) {
			break
		}
	}

	// Temporary strings (names, the wide pattern) are cleaned up by the caller,
	// which owns the temp-allocator scope around the whole click.
	library_sort()
	return len(library.tracks)
}

library_load_single :: proc(path: string) {
	library_clear()
	library_add(path, base_name(path))
	library.index = 0
}

base_name :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '\\' || path[i] == '/' {
			return path[i+1:]
		}
	}
	return path
}

//
// Dialogs
//

open_file_dialog :: proc(hwnd: win.HWND, initial_dir: string) -> string {
	buffer: [1024]u16

	filter := win.utf8_to_utf16_alloc("MP3 files (*.mp3)\x00*.mp3\x00All files (*.*)\x00*.*\x00\x00")
	title  := win.utf8_to_wstring("Open an MP3")
	defext := win.utf8_to_wstring("mp3")

	ofn := win.OPENFILENAMEW {
		lStructSize  = win.DWORD(size_of(win.OPENFILENAMEW)),
		hwndOwner    = hwnd,
		lpstrFilter  = win.wstring(&filter[0]),
		nFilterIndex = 1,
		lpstrFile    = &buffer[0],
		nMaxFile     = win.DWORD(len(buffer)),
		lpstrTitle   = title,
		Flags        = win.DWORD(win.OFN_FILEMUSTEXIST | win.OFN_PATHMUSTEXIST | win.OFN_EXPLORER),
		lpstrDefExt  = defext,
	}
	if len(initial_dir) > 0 {
		ofn.lpstrInitialDir = win.utf8_to_wstring(initial_dir)
	}

	if !bool(win.GetOpenFileNameW(&ofn)) {
		return ""
	}
	path, _ := win.wstring_to_utf8(win.wstring(&buffer[0]))
	return path
}

open_folder_dialog :: proc(hwnd: win.HWND, initial_dir: string) -> string {
	display: [win.MAX_PATH]u16
	path:    [win.MAX_PATH]u16
	title := win.utf8_to_wstring("Choose a folder of MP3s")

	// Kept alive for the duration of the modal call, which is when the
	// callback runs.
	initial_wide: []u16
	if len(initial_dir) > 0 {
		initial_wide = win.utf8_to_utf16_alloc(initial_dir)
	}

	bi := BROWSEINFOW {
		hwndOwner      = hwnd,
		pszDisplayName = &display[0],
		lpszTitle      = title,
		ulFlags        = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE,
		lpfn           = browse_callback,
	}
	if len(initial_wide) > 0 {
		bi.lParam = win.LPARAM(uintptr(rawptr(&initial_wide[0])))
	}

	pidl := SHBrowseForFolderW(&bi)
	if pidl == nil {
		return ""
	}
	// The shell allocated this; release it once the path is copied out.
	defer win.CoTaskMemFree(pidl)

	if !bool(SHGetPathFromIDListW(pidl, &path[0])) {
		return ""
	}
	result, _ := win.wstring_to_utf8(win.wstring(&path[0]))
	return result
}

// Directory part of a path, as a heap string.
dir_of :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '\\' || path[i] == '/' {
			return strings.clone(path[:i])
		}
	}
	return ""
}
