package main

// Isolated check for the FFT used by the analyzer: feed a known sine, expect a
// single strong bin. Run with: odin run tests/fft_test.odin -file

import "core:fmt"
import "core:math"

FFT_N :: 2048

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

main :: proc() {
	re: [FFT_N]f32
	im: [FFT_N]f32
	window: [FFT_N]f32

	amp := f32(0.17)
	freq := f32(1000)
	sr := f32(48000)

	for i in 0 ..< FFT_N {
		window[i] = 0.5 * (1 - f32(math.cos(2*math.PI*f64(i)/f64(FFT_N-1))))
		s := amp * f32(math.sin(2*math.PI*f64(freq)*f64(i)/f64(sr)))
		re[i] = s * window[i]
		im[i] = 0
	}

	fft(re[:], im[:])

	peak_bin := 0
	peak := f32(0)
	total := f32(0)
	for b in 1 ..< FFT_N/2 {
		m := f32(math.sqrt(f64(re[b]*re[b] + im[b]*im[b])))
		total += m
		if m > peak {
			peak = m
			peak_bin = b
		}
	}

	fmt.printf("peak bin=%d (expected ~%d)\n", peak_bin, int(freq/(sr/f32(FFT_N))))
	fmt.printf("peak magnitude=%.2f  (expected ~%.2f)\n", peak, f64(amp)*f64(FFT_N)/4.0)
	fmt.printf("sum of all bin magnitudes=%.2f\n", total)
	fmt.printf("peak after /(N/2) = %.5f  -> %.1f dB\n", peak/f32(FFT_N/2), 20*math.log10(f64(peak/f32(FFT_N/2))))
}
