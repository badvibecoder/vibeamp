# vibeamp — handover notes

**Audience:** the next agent (or human) picking this up cold.
**Status:** v1.0, feature-complete and stable.
**Reading order:** §2 for orientation, §5–§7 before touching code, §8 before
testing anything, §9–§11 for the parts that aren't in the code.

`README.md` is the user-facing document. This file is the maintainer's one: why
the code is shaped the way it is, what has already been tried and rejected, and
how to drive the app from a script without wasting an hour on the same traps.

---

## 1. What this is

A native Windows MP3 player in Odin, styled as an old LCD module. One 407×250
window, no frameworks, no installer, ~940 KB executable, GDI for everything.

The display is a dot-matrix panel: an 8-row scrolling title, an 8-row spectrum
analyzer, a scrubber, a playlist, transport icons and a vertical volume column,
all drawn as dots or crisp GDI shapes onto a mid-green "LCD" surface that sits
inset in a dark background.

Everything the user sees is painted by hand into a memory DC, then blitted.

---

## 2. The 90-second orientation

```
F:\deepseek-harness\vibeamp\
  build.bat            odin build + resource; "release" arg switches -o:speed
  README.md            user-facing
  HANDOVER.md          this file
  bin\vibeamp.exe      build output
  res\app.rc + app.ico icon resource (rc.exe compiles it)
  docs\*.png           screenshots referenced by README
  src\main.odin        2481 lines — window, layout, paint, input, all drawing
  src\audio.odin        222 — miniaudio device + decoder, the sample tap
  src\spectrum.odin     158 — FFT and band folding
  src/idle.odin          55 — sea-and-birds idle scene
  src/library.odin      200 — playlist, folder scan, the two file dialogs
  src/settings.odin     303 — settings file, restore helpers, single instance
  tests\fft_test.odin         standalone FFT check (not part of the app build)
```

There is no git repository. Keep it that way unless the human asks.

---

## 3. Build and release

```bat
build.bat            :: debug build
build.bat release    :: -o:speed
```

The Odin binary is at `F:\bin\odin-windows-amd64-dev-2026-11a\dist\odin.exe`
(version `dev-2026-11-nightly:9a69916`). It is on the user's PATH but **not** in
the shell you get here — call it by full path or set `$env:ODIN`.

`build.bat` passes `-resource:%ROOT%res\app.rc`, which makes Odin invoke `rc.exe`
from the Visual Studio SDK to embed the icon. That leaves a `res\app.res`
artifact next to the `.rc`; it is gitignored, not source.

A build fails with "don't have access to write to bin\vibeamp.exe" whenever an
instance is running. Kill it first:

```powershell
Get-Process vibeamp -ErrorAction SilentlyContinue | Stop-Process -Force
```

---

## 4. Architecture

### 4.1 Process and event model

- One `main` on the UI thread: `CoInitializeEx(APARTMENTTHREADED)`, settings,
  audio, window, message loop.
- A `SetTimer(hwnd, TIMER_ID, 16, nil)` drives everything animated: `WM_TIMER →
  tick(hwnd)`. There is no worker thread. Audio runs on miniaudio's own thread.
- `tick` is throttled to 30 fps by comparing `int(now*30)` against the last
  frame index, so half the 60 Hz timer ticks return immediately.
- The app is single-instance (`CreateMutexW` on
  `Local\vibeamp-single-instance`); a second launch shows a message box and
  exits. **This matters for testing** — see §8.

### 4.2 Rendering

Three ideas carry the whole renderer.

**Double buffering.** `paint()` creates/resizes a memory DC in
`ensure_back_buffer`, draws into it, and `BitBlt`s the whole client at the end.
`ensure_back_buffer` returns whether it recreated the buffer, and `paint` sets
`dirty_all` when it did — a fresh buffer holds garbage otherwise.

**Dirty bands, not full repaints.** The back buffer persists between frames.
`g.dirty` is a `bit_set[Part]` naming which bands changed; `paint` either does a
full repaint (`dirty_all`) or calls `draw_panel_parts(dc, lay, s, now, g.dirty)`
which draws only those bands and blits. This is the single biggest performance
decision in the app: normal-mode playback went 21% → 7% of one core from it.

Every band draw function **fills its own rectangle with the panel brush first**,
so a partial repaint cannot leave ghosts. If you add a band, do the same.

**Batched drawing.** Two hot spots are batched:

- The dot field is a GDI *pattern brush* (`dot_pattern`) holding one dot on the
  panel colour; `SetBrushOrgEx(dc, grid.left, grid.top)` aligns the pattern phase
  to the grid, then the whole unlit field is one `FillRect` and each column's
  lit run is one more. 4,300 calls per frame became ~95.
- `draw_small_text` emits one `FillRect` per horizontal run of glyph pixels
  instead of one per pixel.

### 4.3 Layout and hit testing

`build_layout(client_w, s) -> Layout` computes every rectangle once per paint
and once per hit test. Nothing is cached between calls; it is cheap.

`Scale{dpi, step}` + `dm(s, v)` converts design pixels to device pixels:
`dip_to_px(v * step, dpi)`. **Every** dimension is expressed this way, which is
why the UI scales cleanly at 1×/2×/4× and on high-DPI screens.

`Layout` carries both drawing rects and a small `hits` array of
`{rect, control, index}`. `hit_test_at` walks it. Click targets are padded a few
pixels beyond their visual bounds.

`g.spectrum_mode` switches `build_layout` to `build_spectrum_layout`, where the
matrix fills the panel and only the size dots remain.

### 4.4 The dot matrix and the font

- Dot 3×3 px, gap 1 px → 4 px pitch; 94 columns fit the panel width at 1×.
- The normal matrix is 18 rows: 1 blank, 8 title, 8 spectrum, 1 blank.
- Spectrum mode reuses the same pitch and gives the matrix ~48 rows.
- The font is a hand-rolled 5×7 bitmap in `glyph()`, drawn 1 unit per pixel with
  a 6-unit cell. ASCII only; anything else renders `?`.
- The marquee scrolls at 12 dots/second; a selected playlist row scrolls at
  14 px/second with a 16 px gap before wrapping.

### 4.5 Audio

`ma_device` + `ma_decoder` — not `ma_engine` — so every sample passes through
`audio_data_callback`, which is where the analyzer taps the signal.

- 48 kHz, stereo, f32.
- The callback owns the decoder. It handles a pending seek, reads frames,
  handles loop-one at the sample level, reports `finished`, and pushes a mono
  mix into an 8192-sample ring (`audio.tap`) for the UI to read.
- The UI never touches the decoder. `audio_load` stops the device, swaps the
  decoder, then restarts it.
- `audio_seek` stores the target frame in `seek_req` **and** moves the displayed
  cursor immediately, so the bar responds instantly. The callback applies the
  seek and republishes the cursor — but **only when no new seek is pending**.
  That guard exists because a slow MP3 seek used to finish late and drag the
  progress bar backwards. Do not remove it.
- Volume is `ma_device_set_master_volume`, applied at the device, so the tap
  keeps seeing the unattenuated signal and the analyzer doesn't shrink when the
  user turns the volume down. (The bars scale by volume separately — see §4.6.)

### 4.6 Spectrum analysis

`spectrum_update(cols, dt, playing)`:

1. Copy the newest 2048 samples out of the tap ring.
2. Hann window, radix-2 FFT.
3. Fold the bins into one bar per column on a log axis, 40 Hz → 16 kHz.
4. Map dB (−85 … −18) to 0…1 and add a +21 dB tilt across the band, because music
   rolls off with frequency and would otherwise leave the right half dark.
5. Multiply by the current volume (0 when muted) — the display is an output
   meter, not an input meter.
6. Smooth: instant attack, fall of 1.6 units/second.

Bars are stored in `g.bars[x]` **in rows of the mode currently drawn** (8 or 48),
so a repaint only happens when the drawn height actually changes. A loaded track
always gets at least one row, which is what makes mute read as a flat line;
when nothing is playing the idle scene replaces it entirely.

### 4.7 Idle scene

`idle_lit(x, row, cols, rows, now)` draws a sea from two out-of-phase sines plus
three 7×3 flapping birds. It is authored against an 8-row band and scales row
positions to whatever height it is given, while the birds keep their 3-row size.
Shown when nothing is loaded, or 3 s after playback leaves Playing.

### 4.8 Settings

`%LOCALAPPDATA%\vibeamp\settings.ini` — plain UTF-8 `key=value`:

```
version=1  scale=0  theme=0  volume=50  muted=0
position=<seconds>  mode=folder|single|none
folder_dir=  file_dir=  playlist_dir=  last_track=
```

- `%LOCALAPPDATA%` on purpose: music paths and positions are machine-specific,
  so roaming them buys nothing.
- Writes go to `settings.ini.tmp` then `MoveFileExW(..., REPLACE_EXISTING)`, so a
  kill mid-write cannot truncate the file.
- `settings_load` sets defaults **before** parsing — `volume` falls back to 50
  rather than 0. Missing-key behaviour is a real user-visible bug class here.
- Saved every 5 s while playing, and immediately on pause, stop, track change,
  volume/mute change, theme change, size change and exit.
- Restore opens the playlist (rescanning the folder, or the single file), finds
  the track *by path*, and parks there **paused**. A deleted track falls back to
  the marquee prompt with no dialog.

### 4.9 Dialogs and COM

- Open file: `GetOpenFileNameW`, `lpstrInitialDir` from `settings.file_dir`.
- Open folder: `SHBrowseForFolderW` with a `BFFCALLBACK` that sends
  `BFFM_SETSELECTIONW` on `BFFM_INITIALIZED`, so it opens on `settings.folder_dir`.
- `SHBrowseForFolderW` **requires** `CoInitializeEx(APARTMENTTHREADED)` on this
  thread. Without it the picker creates an invisible dialog and hangs the app.

### 4.10 Themes

Four palettes (GREEN / AMBER / RED / GREY), each a `Theme` of five COLORREFs:
`panel`, `unlit`, `lit`, `ghost`, `list`. `apply_theme()` deletes the old brushes
and creates new ones; everything else reads `g.brush_lcd_*`.

**COLORREF is `0x00BBGGRR`, not `0xRRGGBB`.** This has bitten twice — once in
the theme table (copying hex from a design tool) and once in `dib_pixel`, where
red and blue were swapped, which made the pattern-brush dots come out `#B8E2CF`
instead of `#CFE2B8`. When a colour looks subtly wrong, dump the actual pixel
value before trusting your eyes.

### 4.11 Keyboard

| Key | Action |
|---|---|
| `=` / `-` | size step (also numpad + / -) |
| `Space` | play / pause |
| `S` | stop |
| `L` / `Ctrl+L` | loop all / loop one (independent toggles) |
| `Up` / `Down` | previous / next track (wraps) |
| `Left` / `Right` | seek ∓5 s |
| `Page Up` / `Page Down` | volume ±5%, comes off mute |
| `Ctrl+O` / `Ctrl+F` | open file / folder |
| `C` | cycle palette |
| `M` | mute |
| `Esc` | leave spectrum mode |

`on_key` reads Ctrl with `GetKeyState(VK_CONTROL) < 0` (the high bit means down).
`GetKeyState` returns `i16`; comparing against `0x8000` will not compile.

---

## 5. Rules the code depends on

**`proc "system"` has no context.** `window_proc` starts with `context = g.ctx`
or every allocation, string op and `free_all` in the handlers breaks. Draw
routines are declared `"contextless"` so they cannot accidentally allocate.

**Never `delete` a temp-allocator string.** `win.wstring_to_utf8(s)` returns a
temp-allocated string; passing it to `delete` corrupts the heap (the app died
with `0xC0000374` from exactly this). Use `win.wstring_to_utf8(s, -1, context.allocator)`
if the result must outlive the call.

**Do not name a foreign import after a builtin type.** `foreign import u32
"system:User32.lib"` shadowed the `u32` type and compiled fine for weeks — until
something used `u32` as a type. It is now `user32_lib`.

**Odin has no ternary**, immutable parameters cannot be assigned, and constant
arrays/strings cannot be indexed with runtime values — that last one is why
`SIZE_STEPS`, `TRANSPORT_WIDTHS` and `marquee` are variables, not constants.

**GDI `Ellipse` degenerates to a diamond below ~10 px.** Draw small circles as
scanline runs (see the speaker glyph) or don't draw them.

**`AlphaBlend` with `AC_SRC_ALPHA` expects premultiplied pixels.** If you ever
revisit the glass idea, the correct single-pass pixel for white at `wa` over
black at `ba` is `alpha = 1-(1-ba)(1-wa)`, `rgb = wa*(1-ba)`.

**`SetBrushOrgEx` is what aligns pattern brushes to the dot grid.** Without it
the field is offset by the difference between the brush origin and the grid.

---

## 6. The dirty-region contract

If you touch anything that changes what is on screen, you must say which band
changed. The current contract:

| Change | Must dirty |
|---|---|
| marquee column, bar heights, idle frame | `Matrix` |
| clock/position text, and the scrubber that follows it | `Info` + `Seek` |
| playlist scroll, selection change, track change | `Playlist` |
| playing row's name scrolling | `Playlist_Row` |
| play/pause/stop/loop icon state | `Icons` |
| volume level or mute | `Volume` |
| theme, size step, track load, DPI change, buffer recreate | `invalidate(hwnd)` (everything) |

Getting this wrong is silent: the app keeps running and one band freezes. That
is exactly what happened to the seek bar (tick dirtied `Info` but not `Seek`, so
progress only moved when something else forced a full repaint). If a region
stops updating, suspect the contract first.

`draw_panel_parts` handles `Playlist_Row` by computing `library.index - g.list_scroll`
and redrawing that single row — and the partial fill stops at `lay.arrow_up.left`
so it cannot erase the scroll arrows.

---

## 7. Testing the app from a script

The app has no test harness beyond `tests/fft_test.odin`. Everything else has
been verified by driving it from PowerShell with P/Invoke. Techniques that work:

**Click.** `lparam = (y << 16) | (x & 0xFFFF)`, then:

```powershell
[void][P]::PostMessage($h, 0x0201, [IntPtr]1, [IntPtr](($y -shl 16) -bor $x))  # down
[void][P]::PostMessage($h, 0x0202, [IntPtr]0, [IntPtr](($y -shl 16) -bor $x))  # up
```

PostMessage is enough for clicks, drags (send intermediate `WM_MOUSEMOVE` 0x0200)
and plain keys (`WM_KEYDOWN` 0x0100 with the virtual-key code).

**Screenshot.** `PrintWindow` into a `Bitmap` — works even when the window is
behind others:

```powershell
$bmp = [System.Drawing.Bitmap]::new($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc()
[void][P]::PrintWindow($h, $hdc, 1); $g.ReleaseHdc($hdc); $g.Dispose()
$bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
```

**Check the client size first.** At 2× or 4× every coordinate doubles. More than
one test "failure" was just a click landing in the wrong place because the app
remembered a larger scale.

**Picking a folder.** The picker is a modal shell dialog; drive it through the
process:

1. `VirtualAllocEx` + `WriteProcessMemory` a UTF-16 path into the target process.
2. `BFFM_SETEXPANDED` (0x046A, wParam 1) with the remote pointer — this step is
   required for reliability.
3. `BFFM_SETSELECTIONW` (0x0466, wParam 1).
4. `WM_COMMAND` (0x0111) with wParam 1 to press OK.

**Ctrl-modified keys cannot be posted.** `GetKeyState` reports the real keyboard
state, so a posted `WM_KEYDOWN` never looks like Ctrl+key. You need synthetic
input plus real focus:

```csharp
AttachThreadInput(myThread, GetWindowThreadProcessId(GetForegroundWindow()), true);
SetForegroundWindow(target);   // this fails without the attach
AttachThreadInput(myThread, fgThread, false);
keybd_event(VK_CONTROL, 0, 0, 0); keybd_event(vk, 0, 0, 0); ... keyup ...
```

Before the attach trick, Ctrl+O appeared broken while Ctrl+F passed — the
keypresses were going to another window entirely. **A failing shortcut test may
mean the window never had focus, not that the chord is broken.**

**Only one instance can run.** The single-instance mutex means a second launch
just shows a message box. Kill before launching, and don't try to run two test
flows in parallel.

**CPU.** Sample `Process.TotalProcessorTime` deltas over a few seconds; 3 s is
enough to see 1% differences. Values fluctuate ±3 points between runs, so take
two samples before drawing conclusions.

**Pixel probes.** Colours in the matrix are `panel` (gaps), `unlit` (off dots) and
`lit` (on dots) — and unlit button glyphs are drawn in `ghost`, which is *not*
the same as unlit. Probing with a "dark pixel" threshold silently misses ghost
icons; compare against the panel colour instead.

---

## 8. Soft data: how the work went

This is the part that isn't in the code.

**The human is hands-on and visually literate.** They run the app constantly and
spot misalignments immediately — a 3 px gap next to 10 px gaps, an icon 3 px
shorter than its neighbours, a tooltip-like label that doesn't match the rest.
Assume they will see anything you can see in a 4× zoom.

**Mock up visual changes first.** For the volume column they asked for a mockup
before implementation and approved it; the mockup caught the layout question
(does the transport narrow too?) before any code was written. Do the same for
any non-trivial visual change: render the proposal from a real screenshot, show
it, wait.

**"Subtle" is a trap.** Two attempts at a glass/reflection layer over the panel
were rejected: they were mathematically present (2–6 units of 255) and
completely invisible on a 3 px dot field. The human's words were "I cannot see
even what changed". If an effect is under ~10% contrast at 1×, it does not
exist. Build bold, then dial back.

**They care about uniformity.** Sizes, gaps and baselines should derive from one
constant, not be hand-tuned per element: all icons are `ICON_H` tall and sit on
one baseline; the volume stack is anchored on the mute button so its gap is the
same 10 px as the icon gaps.

**They care about CPU.** They asked directly how to reduce it and were happy with
pattern brushes and dirty regions; they explicitly accepted "static assets"
instead of per-pixel drawing. Keep the app light and be ready to explain where
the time goes.

**They ask scoping questions before big changes** ("what other controls do you
have, should we discuss?"). Answer with a short table of what exists, then
numbered questions — they reply to the numbers.

**They are fine with subagents** and said so ("spin up as many workers as you
need"). A read-only reviewer running in parallel with your own testing found six
real bugs on the dirty-region change, one of which (a frozen seek bar) would have
shipped.

**They will say it looks bad, flatly.** That is data about the artefact, not
about you. Revert cleanly, explain what you learned, and propose the next
approach.

**Clean up after yourself.** They noticed a file dialog left open by a test.
Close dialogs, kill processes, delete scratch screenshots.

---

## 9. History, briefly

| Version | What landed |
|---|---|
| v0.1 | 400×175 window with the word "vibeamp" |
| v0.2–0.3 | three size steps, LCD palette, size dots |
| v0.4–0.5 | dot-matrix marquee showing the file name, bezel, speed tuning |
| v0.6–0.7 | 16-row matrix (title + spectrum), icons row, LOAD controls |
| v0.8–0.9 | real playback, playlist block, highlight/click, wrap + auto-scroll |
| v0.10 | verified spectrum analyzer, idle sea/birds, 3 s pause delay |
| v0.11 | seek bar with drag-to-scrub |
| v0.12 | settings persistence, single instance |
| v0.13 | `LIGHT` button, four palettes, volume column, full-window spectrum mode |
| v1.0 | dirty-band painting, pattern brushes, volume-scaled bars |

---

## 10. Dead ends — don't re-run these experiments

**The glass cover.** Two full attempts:
1. Soft gradients over the panel (sheen + blob). Correct but invisible.
2. A bright specular bar with an inner shadow and rim. Visibly *something*, but
   it read as "a stripe painted on the screen", not glass. Rejected.

The panel's own bezel, green padding and dot texture already do the "hardware"
work. If someone wants glass again, the honest constraints are: the specular
needs more pixels than a 3 px dot field offers, or it needs a real reflection
image, and it must be *bold* to be seen at all.

**Font atlas.** Considered and not built: 1 `BitBlt` per character instead of
~10 run fills. It would take normal mode from ~7% to ~4%, but needs a monochrome
mask and the `SRCAND`/`SRCPAINT` dance. Only worth it if CPU matters again.

**Scripted line-range edits.** Two reverts were done by deleting line ranges with
PowerShell. Both times the ranges drifted and ate neighbouring code (a struct
field, a `case` label, a function's first line). Always edit by unique text
anchors — `edit` with `old_string` — never by line number.

---

## 11. Known gaps

- MP3 only; no ID3 tags (the title shows the file name).
- Non-ASCII filenames render `?`.
- No gapless playback: a track change reloads the stream.
- Volume and position are per-machine; there is no roaming.
- The spectrum is linear in amplitude, not dB, so quiet passages look flat at
  low volume. Deliberate for now.
- `tests/fft_test.odin` is a standalone program (`odin run tests/fft_test.odin
  -file`); it still builds, but it is not wired into any automated run.

---

## 12. Performance budget

Release build, one core, playing:

| View | 1× | 4× |
|---|---|---|
| Normal | ~7% | ~10% |
| Spectrum | ~2% | ~6% |
| Idle (sea animating) | ~7% | — |

Floor is ~2% (MP3 decode + FFT + blit). The rest is the matrix repainting at
30 fps. If you need it lower, in order of payoff:

1. Idle scene to 12 fps (~7% → ~4% while idle).
2. Blit only the dirty rectangle instead of the whole client (helps 4× most).
3. Font atlas (see §10).

Measure before and after with the sampling recipe in §7, and take two samples —
run-to-run noise is ±3 points.
