package main

import ma "vendor:miniaudio"
import "base:intrinsics"
import "core:c"
import win "core:sys/windows"

//
// Audio: a miniaudio device fed by a decoder.
//
// Using the device directly (instead of ma_engine) means every sample passes
// through our callback, which is where the spectrum analyzer taps the signal.
// The callback runs on miniaudio's audio thread: it only uses the decoder,
// atomics and a fixed buffer, never anything that allocates.
//

SAMPLE_RATE :: u32(48000)
CHANNELS    :: u32(2)
TAP_SIZE    :: 8192 // ring of mono samples for the analyzer

audio: struct {
	device:    ma.device,
	device_ok: bool,

	decoder: ma.decoder,
	loaded:  bool, // only changed while the device is stopped

	playing:  b32, // atomics shared with the audio thread
	looping:  b32,
	finished: b32,
	seek_req: i64, // -1 = none
	cursor:   u64, // frames
	tap_pos:  u64,

	duration: f32,

	tap: [TAP_SIZE]f32,
}

audio_data_callback :: proc "c" (device: ^ma.device, output: rawptr, input: rawptr, frame_count: u32) {
	if !audio.loaded {
		return
	}

	// A seek is requested by the UI thread; perform it here, where the decoder
	// is only ever touched.
	req := intrinsics.atomic_load_explicit(&audio.seek_req, .Acquire)
	if req >= 0 {
		intrinsics.atomic_store_explicit(&audio.seek_req, i64(-1), .Release)
		ma.decoder_seek_to_pcm_frame(&audio.decoder, u64(req))
	}

	if !bool(intrinsics.atomic_load_explicit(&audio.playing, .Acquire)) {
		return // miniaudio pre-fills the buffer with silence
	}

	frames := u64(frame_count)
	read: u64
	ma.decoder_read_pcm_frames(&audio.decoder, output, frames, &read)

	if read < frames {
		if bool(intrinsics.atomic_load_explicit(&audio.looping, .Acquire)) {
			ma.decoder_seek_to_pcm_frame(&audio.decoder, 0)
			offset := uintptr(read) * uintptr(CHANNELS) * uintptr(size_of(f32))
			more: u64
			ma.decoder_read_pcm_frames(&audio.decoder, rawptr(uintptr(output) + offset), frames - read, &more)
			read += more
		} else {
			intrinsics.atomic_store_explicit(&audio.finished, b32(true), .Release)
			intrinsics.atomic_store_explicit(&audio.playing, b32(false), .Release)
		}
	}

	cur: u64
	if ma.decoder_get_cursor_in_pcm_frames(&audio.decoder, &cur) == .SUCCESS {
		intrinsics.atomic_store_explicit(&audio.cursor, cur, .Release)
	}

	// Tap: append a mono mix of what was just written.
	out := cast([^]f32) output
	n := int(read)
	if n > 0 {
		pos := intrinsics.atomic_load_explicit(&audio.tap_pos, .Relaxed)
		for i in 0 ..< n {
			pos = (pos + 1) % u64(TAP_SIZE)
			audio.tap[pos] = (out[i*2] + out[i*2+1]) * 0.5
		}
		intrinsics.atomic_store_explicit(&audio.tap_pos, pos, .Release)
	}
}

audio_init :: proc() -> bool {
	cfg := ma.device_config_init(.playback)
	cfg.playback.format = .f32
	cfg.playback.channels = CHANNELS
	cfg.sampleRate = SAMPLE_RATE
	cfg.dataCallback = audio_data_callback

	if ma.device_init(nil, &cfg, &audio.device) != .SUCCESS {
		return false
	}
	if ma.device_start(&audio.device) != .SUCCESS {
		ma.device_uninit(&audio.device)
		return false
	}
	audio.device_ok = true
	return true
}

audio_shutdown :: proc() {
	audio_unload()
	if audio.device_ok {
		ma.device_uninit(&audio.device)
		audio.device_ok = false
	}
}

audio_load :: proc(path: string) -> bool {
	if !audio.device_ok {
		return false
	}
	audio_unload()

	// The decoder is the audio thread's, so park the thread while swapping it.
	ma.device_stop(&audio.device)

	wide := win.utf8_to_wstring(path)
	cfg := ma.decoder_config_init(.f32, CHANNELS, SAMPLE_RATE)
	if ma.decoder_init_file_w(cast([^]c.wchar_t) wide, &cfg, &audio.decoder) != .SUCCESS {
		ma.device_start(&audio.device)
		return false
	}
	audio.loaded = true

	length: u64
	if ma.decoder_get_length_in_pcm_frames(&audio.decoder, &length) == .SUCCESS {
		audio.duration = f32(f64(length) / f64(SAMPLE_RATE))
	} else {
		audio.duration = 0
	}

	intrinsics.atomic_store_explicit(&audio.cursor, 0, .Release)
	intrinsics.atomic_store_explicit(&audio.finished, b32(false), .Release)
	intrinsics.atomic_store_explicit(&audio.playing, b32(false), .Release)
	intrinsics.atomic_store_explicit(&audio.seek_req, i64(-1), .Release)

	for i in 0 ..< TAP_SIZE {
		audio.tap[i] = 0
	}
	intrinsics.atomic_store_explicit(&audio.tap_pos, 0, .Release)

	ma.device_start(&audio.device)
	return true
}

audio_unload :: proc() {
	if !audio.loaded {
		return
	}
	if audio.device_ok {
		ma.device_stop(&audio.device)
	}
	ma.decoder_uninit(&audio.decoder)
	audio.loaded = false
	intrinsics.atomic_store_explicit(&audio.playing, b32(false), .Release)
	intrinsics.atomic_store_explicit(&audio.cursor, 0, .Release)
	if audio.device_ok {
		ma.device_start(&audio.device)
	}
}

audio_play :: proc "contextless" () {
	if audio.loaded {
		intrinsics.atomic_store_explicit(&audio.finished, b32(false), .Release)
		intrinsics.atomic_store_explicit(&audio.playing, b32(true), .Release)
	}
}

audio_pause :: proc "contextless" () {
	intrinsics.atomic_store_explicit(&audio.playing, b32(false), .Release)
}

audio_rewind :: proc "contextless" () {
	if !audio.loaded {
		return
	}
	intrinsics.atomic_store_explicit(&audio.playing, b32(false), .Release)
	intrinsics.atomic_store_explicit(&audio.seek_req, i64(0), .Release)
	intrinsics.atomic_store_explicit(&audio.cursor, 0, .Release)
}

audio_seek :: proc "contextless" (seconds: f32) {
	if !audio.loaded {
		return
	}
	t := seconds
	if t < 0 {
		t = 0
	}
	if audio.duration > 0.5 && t > audio.duration - 0.3 {
		t = audio.duration - 0.3
	}
	frames := u64(f64(t) * f64(SAMPLE_RATE))
	intrinsics.atomic_store_explicit(&audio.seek_req, i64(frames), .Release)
	intrinsics.atomic_store_explicit(&audio.cursor, frames, .Release)
}

audio_set_looping :: proc "contextless" (on: bool) {
	intrinsics.atomic_store_explicit(&audio.looping, b32(on), .Release)
}

audio_position :: proc "contextless" () -> f32 {
	return f32(f64(intrinsics.atomic_load_explicit(&audio.cursor, .Acquire)) / f64(SAMPLE_RATE))
}

audio_finished :: proc "contextless" () -> bool {
	return bool(intrinsics.atomic_load_explicit(&audio.finished, .Acquire))
}

audio_clear_finished :: proc "contextless" () {
	intrinsics.atomic_store_explicit(&audio.finished, b32(false), .Release)
}

// Copies the newest `dst` samples out of the tap ring, oldest first.
audio_read_tap :: proc "contextless" (dst: []f32) {
	n := len(dst)
	if n == 0 || n > TAP_SIZE {
		return
	}
	end := intrinsics.atomic_load_explicit(&audio.tap_pos, .Acquire)
	start := (end + u64(TAP_SIZE) - u64(n)) % u64(TAP_SIZE)
	for i in 0 ..< n {
		dst[i] = audio.tap[(start + u64(i)) % u64(TAP_SIZE)]
	}
}
