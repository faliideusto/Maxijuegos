class_name SynthMusic
extends RefCounted
## Generador de música por código (sin assets de terceros): renderiza un bucle de varios compases a
## partir de una descripción (tempo, escala, progresión de acordes y qué instrumentos suenan: bajo,
## arpegio, melodía, batería y colchón). No toca ningún nodo, así que se puede ejecutar en un hilo.
## Los bucles son EXACTOS (las notas que cruzan el final se enrollan al principio): no se oye el corte.
##
## Descripción (Dictionary):
##   bpm, bars (nº de compases), root (nota MIDI de la tónica), scale ("major", "minor", "penta_major",
##   "penta_minor", "dorian"), prog (grado de la escala que suena como acorde en cada compás, se repite),
##   bass ("root8", "offbeat", "pulse16", "half", "walk", "none"), arp ("up", "updown", "skip", "none"),
##   arp_rate (1 = cada semicorchea, 2 = cada corchea), arp_wave, lead ("motif", "none"), lead_wave,
##   drums ("four", "basic", "half", "march", "none"), pad (bool), swing (0-0.3), seed,
##   mix: {bass, arp, lead, drums, pad} volúmenes relativos.

const RATE := 22050

const SCALES := {
	"major": [0, 2, 4, 5, 7, 9, 11],
	"minor": [0, 2, 3, 5, 7, 8, 10],
	"dorian": [0, 2, 3, 5, 7, 9, 10],
	"penta_major": [0, 2, 4, 7, 9],
	"penta_minor": [0, 3, 5, 7, 10],
}

## Renderiza el bucle y devuelve las muestras (-1..1).
static func render(spec: Dictionary) -> PackedFloat32Array:
	var bpm: float = float(spec.get("bpm", 120.0))
	var bars: int = int(spec.get("bars", 8))
	var step_n := int(RATE * 60.0 / bpm / 4.0)
	var steps := bars * 16
	var n := step_n * steps
	var out := PackedFloat32Array()
	out.resize(n)
	var intervals: Array = SCALES.get(String(spec.get("scale", "major")), SCALES["major"])
	var root: int = int(spec.get("root", 57))
	var prog: Array = spec.get("prog", [0, 0, 0, 0])
	var rng := RandomNumberGenerator.new()
	rng.seed = int(spec.get("seed", 1))
	var mix: Dictionary = spec.get("mix", {})
	var swing := float(spec.get("swing", 0.0))
	var vb: float = float(mix.get("bass", 0.5))
	var va: float = float(mix.get("arp", 0.28))
	var vl: float = float(mix.get("lead", 0.3))
	var vd: float = float(mix.get("drums", 0.5))
	var vp: float = float(mix.get("pad", 0.16))

	# Motivos de melodía: A y B (cada uno dura 2 compases).
	var motif_a := _make_motif(rng, intervals.size())
	var motif_b := _make_motif(rng, intervals.size())

	for bar in bars:
		var chord_deg: int = int(prog[bar % prog.size()])
		var tones: Array[int] = [chord_deg, chord_deg + 2, chord_deg + 4, chord_deg + 7]
		var bar_start := bar * 16
		# --- Colchón ---
		if bool(spec.get("pad", false)):
			for k in 3:
				var f := _freq(_degree_midi(root, intervals, tones[k]) + 0)
				_note(out, n, bar_start * step_n, 16 * step_n, f, 3, vp, 0.12, 1.2, 0.0)
		# --- Bajo ---
		var bass_kind := String(spec.get("bass", "none"))
		if bass_kind != "none":
			var bnote := _degree_midi(root, intervals, chord_deg) - 12
			var fifth := _degree_midi(root, intervals, chord_deg + 4) - 12
			var third := _degree_midi(root, intervals, chord_deg + 2) - 12
			match bass_kind:
				"root8":
					for s in range(0, 16, 2):
						_bass_note(out, n, (bar_start + s) * step_n, step_n * 2, bnote, vb)
				"offbeat":
					for s in [2, 6, 10, 14]:
						_bass_note(out, n, (bar_start + s) * step_n, step_n * 2, bnote, vb)
				"pulse16":
					for s in 16:
						var m := bnote if s % 4 != 3 else fifth
						_bass_note(out, n, (bar_start + s) * step_n, step_n, m, vb * (1.0 if s % 4 == 0 else 0.7))
				"half":
					_bass_note(out, n, bar_start * step_n, step_n * 7, bnote, vb)
					_bass_note(out, n, (bar_start + 8) * step_n, step_n * 7, fifth, vb)
				"walk":
					var seq := [bnote, third, fifth, third]
					for k in 4:
						_bass_note(out, n, (bar_start + k * 4) * step_n, step_n * 3, seq[k], vb)
		# --- Arpegio ---
		var arp_kind := String(spec.get("arp", "none"))
		if arp_kind != "none":
			var rate: int = int(spec.get("arp_rate", 1))
			var pattern: Array = [0, 1, 2, 3]
			match arp_kind:
				"updown": pattern = [0, 1, 2, 3, 2, 1]
				"skip": pattern = [0, 2, 1, 3]
			var wave: int = int(spec.get("arp_wave", 0))
			var idx := 0
			for s in range(0, 16, rate):
				var off := _swing_offset(s, swing, step_n)
				var midi := _degree_midi(root, intervals, int(tones[pattern[idx % pattern.size()]])) + 12
				_note(out, n, (bar_start + s) * step_n + off, step_n * rate, _freq(midi), wave, va, 0.002, 14.0, 0.0)
				idx += 1
		# --- Melodía ---
		if String(spec.get("lead", "none")) == "motif":
			var phrase := (bar / 2) % 4
			var motif: Array = motif_b if phrase == 2 else motif_a
			var first_bar := bar % 2 == 0
			var wave_l: int = int(spec.get("lead_wave", 1))
			for ev in motif:
				# ev = [paso (0-31), grado, duración en pasos]
				var st: int = int(ev[0])
				if (st < 16) != first_bar:
					continue
				var deg: int = int(ev[1]) + (2 if phrase == 3 and st >= 24 else 0)
				var midi_l := _degree_midi(root, intervals, deg) + 12
				var local := st % 16
				_note(out, n, (bar_start + local) * step_n + _swing_offset(local, swing, step_n), step_n * int(ev[2]), _freq(midi_l), wave_l, vl, 0.004, 5.0, 0.0)
		# --- Batería ---
		_drums(out, n, bar_start, step_n, String(spec.get("drums", "none")), vd, rng, swing)

	# Normaliza y limita (sin saturar).
	var peak := 0.0001
	for i in n:
		peak = maxf(peak, absf(out[i]))
	var g := 0.82 / peak
	for i in n:
		out[i] = clampf(out[i] * g, -1.0, 1.0)
	return out

## Convierte muestras en un stream en bucle (loop_end = nº de muestras).
static func to_stream(samples: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(samples[i] * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = data
	s.loop_mode = AudioStreamWAV.LOOP_FORWARD
	s.loop_begin = 0
	s.loop_end = samples.size()
	return s

# ----------------------------------------------------------------------------
# Piezas
# ----------------------------------------------------------------------------

static func _freq(midi: int) -> float:
	return 440.0 * pow(2.0, (float(midi) - 69.0) / 12.0)

## Nota MIDI del grado `degree` de la escala (puede salirse de la octava).
static func _degree_midi(root: int, intervals: Array, degree: int) -> int:
	var size := intervals.size()
	var octave := floori(float(degree) / float(size))
	return root + 12 * octave + int(intervals[posmod(degree, size)])

static func _swing_offset(step: int, swing: float, step_n: int) -> int:
	return int(float(step_n) * swing) if step % 2 == 1 else 0

## Motivo de 2 compases (32 pasos): [[paso, grado, duración], ...] con notas del acorde y de paso.
static func _make_motif(rng: RandomNumberGenerator, scale_size: int) -> Array:
	var rhythms: Array = [
		[0, 3, 6, 8, 11, 14], [0, 2, 4, 8, 10, 12], [0, 4, 6, 8, 12, 14], [0, 3, 8, 10, 12, 15]]
	var out: Array = []
	var deg := rng.randi_range(scale_size, scale_size + 4)
	for bar in 2:
		var rh: Array = rhythms[rng.randi() % rhythms.size()]
		for i in rh.size():
			var st: int = int(rh[i]) + bar * 16
			var next: int = int(rh[i + 1]) + bar * 16 if i + 1 < rh.size() else (bar + 1) * 16
			deg = clampi(deg + rng.randi_range(-2, 2), scale_size - 1, scale_size * 2)
			out.append([st, deg, maxi(1, mini(next - st, 4))])
	return out

## Onda: 0 senoidal, 1 cuadrada (ciclo 50 %), 2 diente de sierra, 3 triangular, 4 cuadrada estrecha (25 %).
static func _osc(wave: int, phase: float) -> float:
	match wave:
		1: return 1.0 if phase < 0.5 else -1.0
		2: return phase * 2.0 - 1.0
		3: return 1.0 - 4.0 * absf(phase - 0.5)
		4: return 1.0 if phase < 0.25 else -1.0
	return sin(TAU * phase)

## Suma una nota en `out` (enrollando al principio si cruza el final del bucle). La nota se corta cuando su
## envolvente ya no se oye, para no gastar CPU.
static func _note(out: PackedFloat32Array, n: int, start: int, dur: int, freq: float, wave: int, vol: float,
		attack: float, decay: float, _unused: float) -> void:
	var max_len := mini(dur, int(RATE * (6.0 / maxf(decay, 0.5))))   # exp(-6) ≈ 0.0025
	var release := int(RATE * 0.008)
	for i in max_len:
		var t := float(i) / RATE
		var env := minf(t / attack, 1.0) * exp(-t * decay)
		var tail := max_len - i
		if tail < release:
			env *= float(tail) / float(release)
		var phase := fposmod(freq * t, 1.0)
		out[(start + i) % n] += _osc(wave, phase) * env * vol

static func _bass_note(out: PackedFloat32Array, n: int, start: int, dur: int, midi: int, vol: float) -> void:
	# Bajo: triangular + un poco de cuadrada para que se oiga en altavoces pequeños.
	var f := _freq(midi)
	_note(out, n, start, dur, f, 3, vol, 0.004, 3.0, 0.0)
	_note(out, n, start, dur, f * 2.0, 4, vol * 0.18, 0.004, 9.0, 0.0)

static func _drums(out: PackedFloat32Array, n: int, bar_start: int, step_n: int, kind: String, vol: float,
		rng: RandomNumberGenerator, swing: float) -> void:
	if kind == "none":
		return
	var kicks: Array = []
	var snares: Array = []
	var hats: Array = []
	match kind:
		"four":
			kicks = [0, 4, 8, 12]
			snares = [4, 12]
			hats = [2, 6, 10, 14]
		"basic":
			kicks = [0, 8, 10]
			snares = [4, 12]
			hats = [0, 2, 4, 6, 8, 10, 12, 14]
		"half":
			kicks = [0, 8]
			snares = [12]
			hats = [4, 12]
		"march":
			kicks = [0, 4, 8, 12]
			snares = [2, 6, 10, 14]
			hats = []
	for s in kicks:
		_kick(out, n, (bar_start + int(s)) * step_n, vol)
	for s in snares:
		_snare(out, n, (bar_start + int(s)) * step_n, vol * 0.7, rng)
	for s in hats:
		_hat(out, n, (bar_start + int(s)) * step_n + _swing_offset(int(s), swing, step_n), vol * 0.28, rng)

static func _kick(out: PackedFloat32Array, n: int, start: int, vol: float) -> void:
	var len := int(RATE * 0.16)
	var ph := 0.0
	for i in len:
		var t := float(i) / RATE
		ph += TAU * lerpf(150.0, 45.0, minf(t / 0.1, 1.0)) / RATE
		out[(start + i) % n] += sin(ph) * exp(-t * 22.0) * vol * 1.1

static func _snare(out: PackedFloat32Array, n: int, start: int, vol: float, rng: RandomNumberGenerator) -> void:
	var len := int(RATE * 0.16)
	var lp := 0.0
	for i in len:
		var t := float(i) / RATE
		lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.7
		out[(start + i) % n] += (lp * 0.8 + sin(TAU * 190.0 * t) * 0.5) * exp(-t * 26.0) * vol

static func _hat(out: PackedFloat32Array, n: int, start: int, vol: float, rng: RandomNumberGenerator) -> void:
	var len := int(RATE * 0.05)
	var prev := 0.0
	for i in len:
		var t := float(i) / RATE
		var x := rng.randf_range(-1.0, 1.0)
		out[(start + i) % n] += (x - prev) * 0.5 * exp(-t * 70.0) * vol   # diferencia: ruido agudo
		prev = x
