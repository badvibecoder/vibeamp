package main

import "core:math"

//
// Idle animation for the spectrum rows, shown until something is loaded:
// a rolling sea with a few birds crossing it. Everything is procedural, so it
// costs a sine or two per dot and needs no assets.
//

IDLE_BIRDS :: 3

idle_lit :: proc "contextless" (x, row, cols: int, now: f64) -> bool {
	t := f32(now)

	// Sea: two out-of-phase waves give the surface an irregular roll.
	w1 := f32(math.sin(f64(f32(x)*0.21 + t*1.7)))
	w2 := f32(math.sin(f64(f32(x)*0.09 - t*0.9)))
	surface := f32(5.1) + 1.15*w1 + 0.60*w2
	if f32(row) >= surface {
		return true
	}

	// Birds above the water.
	for i in 0 ..< IDLE_BIRDS {
		bx := idle_bird_x(i, cols, t)
		by := idle_bird_y(i, t)
		if bird_pixel(int(f32(x) - bx), row - by, i, t) {
			return true
		}
	}
	return false
}

idle_bird_x :: proc "contextless" (i, cols: int, t: f32) -> f32 {
	span := f32(cols + 24)
	speed := f32(2.4) + f32(i)*0.9
	start := f32(i)*(f32(cols)/f32(IDLE_BIRDS)) + t*speed
	x := start - f32(int(start/span))*span
	return x - 8
}

idle_bird_y :: proc "contextless" (i: int, t: f32) -> int {
	return int(0.9 + 1.0*f32(math.sin(f64(t*1.3 + f32(i)*1.9))))
}

// A 7x3 bird: wings up is a "^", wings down is a "v".
bird_pixel :: proc "contextless" (dx, dy, i: int, t: f32) -> bool {
	if dx < 0 || dx > 6 || dy < 0 || dy > 2 {
		return false
	}
	wings_up := int(t*4.5 + f32(i)*1.7) % 2 == 0
	if wings_up {
		return (dy == 0 && (dx == 0 || dx == 6)) ||
		       (dy == 1 && (dx == 1 || dx == 5)) ||
		       (dy == 2 && dx >= 2 && dx <= 4)
	}
	return (dy == 2 && (dx == 0 || dx == 6)) ||
	       (dy == 1 && (dx == 1 || dx == 5)) ||
	       (dy == 0 && dx >= 2 && dx <= 4)
}
