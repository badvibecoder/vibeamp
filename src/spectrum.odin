package main

import "core:math"

//
// Spectrum analysis for the lower half of the matrix: take the newest window
// of audio, Hann-window it, FFT it, then fold the bins into one bar per matrix
// column on a log frequency axis.
//

FFT_N    :: 2048
FFT_BINS :: FFT_N/2

DB_FLOOR :: f32(-85) // level mapped to an empty bar
DB_CEIL  :: f32(-18) // level mapped to a full bar

// Music rolls off with frequency, so a flat mapping leaves the right half of
// the display dark. Analysers tilt the response up across the band to
// compensate; this is the total lift in dB from the lowest to the highest
// column (about +2.5 dB per octave over the ~8.6 octaves covered here).
SPEC_TILT_DB :: f32(21.0)

SPEC_FMIN :: f32(40)
SPEC_FMAX :: f32(16000)

spectrum: struct {
	re:     [FFT_N]f32,
	im:     [FFT_N]f32,
	window: [FFT_N]f32,
	levels: [MAX_COLS]f32, // 0..1, smoothed
	ready:  bool,
}

spectrum_init :: proc() {
	for i in 0 ..< FFT_N {
		spectrum.window[i] = 0.5 * (1 - f32(math.cos(2*math.PI*f64(i)/f64(FFT_N-1))))
	}
	spectrum.ready = true
}

// Iterative radix-2 FFT, in place.
fft :: proc (re, im: []f32) {
	n := len(re)

	j := 0
	for i in 1 ..< n {
		bit := n >> 1
		for j & bit != 0 {
			j ~= bit
			bit >>= 1
		}
		j ~= bit
		if i < j {
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		}
	}

	length := 2
	for length <= n {
		angle := -2.0 * f32(math.PI) / f32(length)
		wl_re := f32(math.cos(f64(angle)))
		wl_im := f32(math.sin(f64(angle)))

		i := 0
		for i < n {
			w_re := f32(1)
			w_im := f32(0)
			half := length / 2
			for k in 0 ..< half {
				a := i + k
				b := a + half

				br := re[b]
				bi := im[b]
				vr := br*w_re - bi*w_im
				vi := br*w_im + bi*w_re

				ar := re[a]
				ai := im[a]

				re[a] = ar + vr
				im[a] = ai + vi
				re[b] = ar - vr
				im[b] = ai - vi

				nw_re := w_re*wl_re - w_im*wl_im
				nw_im := w_re*wl_im + w_im*wl_re
				w_re = nw_re
				w_im = nw_im
			}
			i += length
		}
		length <<= 1
	}
}

// Updates `spectrum.levels` for `cols` columns. `dt` drives the falloff.
spectrum_update :: proc (cols_in: int, dt: f32, playing: bool) {
	if !spectrum.ready || cols_in < 1 {
		return
	}
	cols := cols_in
	if cols > MAX_COLS {
		cols = MAX_COLS
	}

	if playing {
		audio_read_tap(spectrum.re[:])
		for i in 0 ..< FFT_N {
			spectrum.re[i] *= spectrum.window[i]
			spectrum.im[i] = 0
		}
		fft(spectrum.re[:], spectrum.im[:])
	}

	bin_hz := f64(SAMPLE_RATE) / f64(FFT_N)
	ratio  := f64(SPEC_FMAX) / f64(SPEC_FMIN)
	scale  := f32(FFT_N/2)

	for c in 0 ..< cols {
		level := f32(0)

		if playing {
			// Log-spaced band for this column.
			f0 := f64(SPEC_FMIN) * math.pow(ratio, f64(c)/f64(cols))
			f1 := f64(SPEC_FMIN) * math.pow(ratio, f64(c+1)/f64(cols))

			b0 := int(f0 / bin_hz)
			b1 := int(f1 / bin_hz)
			if b1 <= b0 {
				b1 = b0 + 1
			}
			if b0 < 1 {
				b0 = 1
			}
			if b1 > FFT_BINS {
				b1 = FFT_BINS
			}

			peak := f32(0)
			for b in b0 ..< b1 {
				re := spectrum.re[b]
				im := spectrum.im[b]
				m := f32(math.sqrt(f64(re*re + im*im))) / scale
				if m > peak {
					peak = m
				}
			}

			db := 20 * f32(math.log10(f64(peak) + 1e-9))
			db += SPEC_TILT_DB * f32(c) / f32(cols - 1)
			level = (db - DB_FLOOR) / (DB_CEIL - DB_FLOOR)
			if level < 0 {
				level = 0
			}
			if level > 1 {
				level = 1
			}

			// The bars follow the output level, so the display behaves like an
			// output meter: quiet at low volume, flat when muted.
			if g.muted {
				level = 0
			} else {
				level *= g.volume
			}
		}

		prev := spectrum.levels[c]
		if level >= prev {
			spectrum.levels[c] = level // instant attack
		} else {
			next := prev - dt*1.6 // gentle fall
			if next < level {
				next = level
			}
			if next < 0 {
				next = 0
			}
			spectrum.levels[c] = next
		}
	}
}
