class_name SynthSfx
extends RefCounted
## Efectos de sonido sintetizados por código (sin assets de terceros): cada función devuelve un
## AudioStreamWAV mono de 16 bits listo para un AudioStreamPlayer. Los sonidos se cachean.

const RATE := 22050

static var _cache: Dictionary = {}

## Tictac / chasquido corto de la mecha.
static func tick() -> AudioStreamWAV:
	return _cached("tick", func() -> PackedFloat32Array:
		var n := int(RATE * 0.06)
		var out := PackedFloat32Array()
		out.resize(n)
		var rnd := RandomNumberGenerator.new()
		rnd.seed = 11
		for i in n:
			var t := float(i) / RATE
			var env := exp(-t * 90.0)
			out[i] = (sin(TAU * 1500.0 * t) * 0.6 + rnd.randf_range(-1.0, 1.0) * 0.4) * env * 0.5
		return out)

## Tecla pulsada (muy suave).
static func key() -> AudioStreamWAV:
	return _cached("key", func() -> PackedFloat32Array:
		var n := int(RATE * 0.03)
		var out := PackedFloat32Array()
		out.resize(n)
		for i in n:
			var t := float(i) / RATE
			out[i] = sin(TAU * 820.0 * t) * exp(-t * 140.0) * 0.35
		return out)

## Palabra correcta: arpegio ascendente alegre.
static func good() -> AudioStreamWAV:
	return _cached("good", func() -> PackedFloat32Array:
		return _notes([660.0, 880.0, 1320.0], 0.09, 0.0))

## Palabra incorrecta: zumbido grave descendente.
static func bad() -> AudioStreamWAV:
	return _cached("bad", func() -> PackedFloat32Array:
		var n := int(RATE * 0.28)
		var out := PackedFloat32Array()
		out.resize(n)
		var ph := 0.0
		for i in n:
			var t := float(i) / RATE
			ph += TAU * lerpf(190.0, 110.0, t / 0.28) / RATE
			var sq := 1.0 if sin(ph) > 0.0 else -1.0
			out[i] = sq * 0.28 * exp(-t * 4.0)
		return out)

## La bomba pasa a otro jugador: barrido de aire.
static func pass_bomb() -> AudioStreamWAV:
	return _cached("pass", func() -> PackedFloat32Array:
		var n := int(RATE * 0.22)
		var out := PackedFloat32Array()
		out.resize(n)
		var rnd := RandomNumberGenerator.new()
		rnd.seed = 5
		var lp := 0.0
		for i in n:
			var t := float(i) / RATE
			var k := lerpf(0.05, 0.5, t / 0.22)
			lp += (rnd.randf_range(-1.0, 1.0) - lp) * k
			out[i] = lp * sin(PI * t / 0.22) * 0.55
		return out)

## Explosión: estallido de ruido + golpe grave que cae.
static func boom() -> AudioStreamWAV:
	return _cached("boom", func() -> PackedFloat32Array:
		var n := int(RATE * 1.3)
		var out := PackedFloat32Array()
		out.resize(n)
		var rnd := RandomNumberGenerator.new()
		rnd.seed = 99
		var lp := 0.0
		var ph := 0.0
		for i in n:
			var t := float(i) / RATE
			lp += (rnd.randf_range(-1.0, 1.0) - lp) * lerpf(0.9, 0.08, minf(t / 0.8, 1.0))
			ph += TAU * lerpf(110.0, 28.0, minf(t / 0.6, 1.0)) / RATE
			out[i] = clampf((lp * exp(-t * 3.2) * 1.2 + sin(ph) * exp(-t * 4.0) * 0.9) * 0.9, -1.0, 1.0)
		return out)

## Siseo de la mecha (se reproduce en bucle, muy bajito).
static func fuse_loop() -> AudioStreamWAV:
	var s := _cached("fuse", func() -> PackedFloat32Array:
		var n := RATE
		var out := PackedFloat32Array()
		out.resize(n)
		var rnd := RandomNumberGenerator.new()
		rnd.seed = 3
		var lp := 0.0
		for i in n:
			lp += (rnd.randf_range(-1.0, 1.0) - lp) * 0.35
			out[i] = (lp - 0.2 * rnd.randf_range(-1.0, 1.0)) * 0.22
		return out)
	s.loop_mode = AudioStreamWAV.LOOP_FORWARD
	s.loop_begin = 0
	s.loop_end = RATE
	return s

# ----------------------------------------------------------------------------

static func _notes(freqs: Array, dur: float, gap: float) -> PackedFloat32Array:
	var per := int(RATE * dur)
	var out := PackedFloat32Array()
	out.resize(per * freqs.size() + int(RATE * 0.1))
	for k in freqs.size():
		for i in per:
			var t := float(i) / RATE
			var env := minf(t / 0.004, 1.0) * exp(-t * 14.0)
			var idx: int = k * per + i
			out[idx] += (sin(TAU * float(freqs[k]) * t) + 0.3 * sin(TAU * float(freqs[k]) * 2.0 * t)) * env * 0.3
	for i in int(RATE * 0.1):
		var t2 := float(i) / RATE
		var idx2: int = per * freqs.size() + i
		out[idx2] = sin(TAU * float(freqs[freqs.size() - 1]) * t2) * exp(-t2 * 20.0) * 0.18
	return out

static func _cached(key_name: String, make: Callable) -> AudioStreamWAV:
	if _cache.has(key_name):
		return _cache[key_name]
	var samples: PackedFloat32Array = make.call()
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = data
	_cache[key_name] = s
	return s
