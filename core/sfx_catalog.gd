class_name SfxCatalog
extends RefCounted
## Catálogo de efectos de sonido del juego, sintetizados por código (sin assets de terceros).
## SfxCatalog.get_sfx(&"ui_click") devuelve un AudioStreamWAV mono de 16 bits (se genera la primera vez
## que se pide y se cachea). El autoload Audio los reproduce; los minijuegos los piden por nombre.
##
## Nombres:
##   Interfaz     ui_click ui_hover ui_back ui_confirm join leave error swoosh
##   Partida      stinger beep beep_go score_tick score_pop fanfare_small fanfare_big confetti
##   Minijuegos   coin coin_gold jump land crash zap milestone flip_up flip_down dash thud plat_crack
##                plat_fall splash pop tongue_shoot tongue_attach release snap fog_growl reaction_ok
##                claim unclaim lock shot hit hit_gold miss gold_spawn combo throw stick clang dive perfect launch swish wall
##                good bad tick key pass_bomb boom   (los últimos 6, de Bomba de Palabras: ver SynthSfx)

const RATE := 22050

static var _cache: Dictionary = {}

static func get_sfx(sfx_name: StringName) -> AudioStreamWAV:
	if _cache.has(sfx_name):
		return _cache[sfx_name]
	var samples := _make(sfx_name)
	if samples.is_empty():
		return null
	var s := _to_stream(samples)
	_cache[sfx_name] = s
	return s

## true si existe el efecto.
static func has_sfx(sfx_name: StringName) -> bool:
	return ALL_NAMES.has(sfx_name)

const ALL_NAMES: Array[StringName] = [&"ui_click", &"ui_hover", &"ui_back", &"ui_confirm", &"join", &"leave",
		&"error", &"swoosh", &"stinger", &"beep", &"beep_go", &"score_tick", &"score_pop", &"fanfare_small",
		&"fanfare_big", &"confetti", &"coin", &"coin_gold", &"jump", &"land", &"crash", &"zap", &"milestone",
		&"flip_up", &"flip_down", &"dash", &"thud", &"plat_crack", &"plat_fall", &"splash", &"pop",
		&"tongue_shoot", &"tongue_attach", &"release", &"snap", &"fog_growl", &"reaction_ok", &"claim", &"unclaim", &"lock", &"shot", &"hit", &"hit_gold", &"miss", &"gold_spawn", &"combo", &"throw", &"stick", &"clang", &"dive", &"perfect", &"launch", &"swish", &"wall"]

static func _make(n: StringName) -> PackedFloat32Array:
	match n:
		# --- Interfaz ---
		&"ui_click": return _sweep(520.0, 820.0, 0.07, 45.0, 0.5)
		&"ui_hover": return _sweep(1250.0, 1250.0, 0.03, 110.0, 0.22)
		&"ui_back": return _sweep(720.0, 430.0, 0.09, 38.0, 0.5)
		&"ui_confirm": return _timed([[660.0, 0.0, 0.07], [990.0, 0.07, 0.12]], 0.5, 12.0)
		&"join": return _timed([[523.0, 0.0, 0.07], [659.0, 0.07, 0.07], [784.0, 0.14, 0.14]], 0.5, 10.0)
		&"leave": return _timed([[659.0, 0.0, 0.08], [494.0, 0.08, 0.08], [392.0, 0.16, 0.14]], 0.5, 10.0)
		&"error": return _sweep(190.0, 110.0, 0.28, 4.0, 0.3, 1)
		&"swoosh": return _noise(0.32, 5.0, 0.04, 0.55, 0.6, true)
		# --- Partida ---
		&"stinger": return _mix(_timed([[392.0, 0.0, 0.08], [494.0, 0.08, 0.08], [587.0, 0.16, 0.08], [784.0, 0.24, 0.3]], 0.5, 8.0), _noise(0.5, 6.0, 0.05, 0.4, 0.22, true))
		&"beep": return _sweep(880.0, 880.0, 0.14, 12.0, 0.4, 1)
		&"beep_go": return _timed([[1175.0, 0.0, 0.16], [1568.0, 0.1, 0.34]], 0.5, 8.0)
		&"score_tick": return _sweep(1568.0, 1568.0, 0.035, 90.0, 0.35)
		&"score_pop": return _timed([[1319.0, 0.0, 0.05], [1760.0, 0.045, 0.05], [2093.0, 0.09, 0.1]], 0.45, 14.0)
		&"fanfare_small": return _timed([[523.0, 0.0, 0.12], [659.0, 0.1, 0.12], [784.0, 0.2, 0.12], [1047.0, 0.3, 0.55]], 0.4, 5.0)
		&"fanfare_big": return _fanfare()
		&"confetti": return _mix(_noise(0.25, 14.0, 0.5, 0.08, 0.5, false), _sweep(300.0, 900.0, 0.06, 30.0, 0.4))
		# --- Minijuegos ---
		&"coin": return _timed([[988.0, 0.0, 0.06], [1319.0, 0.06, 0.12]], 0.5, 14.0)
		&"coin_gold": return _timed([[1319.0, 0.0, 0.05], [1760.0, 0.05, 0.05], [2349.0, 0.1, 0.16]], 0.5, 11.0)
		&"jump": return _sweep(330.0, 700.0, 0.1, 18.0, 0.4, 1)
		&"land": return _mix(_sweep(170.0, 90.0, 0.06, 40.0, 0.5), _noise(0.05, 40.0, 0.2, 0.2, 0.15, false))
		&"crash": return _mix(_noise(0.55, 6.0, 0.7, 0.06, 0.8, false), _sweep(200.0, 45.0, 0.5, 5.0, 0.8))
		&"zap": return _mix(_sweep(900.0, 80.0, 0.38, 6.0, 0.45, 2), _noise(0.3, 9.0, 0.6, 0.1, 0.4, false))
		&"milestone": return _timed([[784.0, 0.0, 0.08], [1047.0, 0.08, 0.16]], 0.45, 12.0)
		&"flip_up": return _sweep(560.0, 720.0, 0.025, 70.0, 0.16)
		&"flip_down": return _sweep(470.0, 360.0, 0.025, 70.0, 0.16)
		&"dash": return _mix(_noise(0.18, 12.0, 0.15, 0.6, 0.5, true), _sweep(260.0, 520.0, 0.12, 20.0, 0.25))
		&"thud": return _sweep(130.0, 55.0, 0.11, 30.0, 0.8)
		&"plat_crack": return _noise(0.35, 7.0, 0.5, 0.3, 0.6, false)
		&"plat_fall": return _sweep(650.0, 90.0, 0.65, 3.0, 0.45, 1)
		&"splash": return _noise(0.55, 5.0, 0.65, 0.12, 0.7, true)
		&"pop": return _sweep(280.0, 900.0, 0.05, 50.0, 0.5)
		&"tongue_shoot": return _mix(_sweep(300.0, 1500.0, 0.07, 30.0, 0.35, 2), _noise(0.07, 30.0, 0.7, 0.4, 0.2, false))
		&"tongue_attach": return _mix(_sweep(190.0, 120.0, 0.07, 35.0, 0.7), _sweep(560.0, 320.0, 0.18, 14.0, 0.3))
		&"release": return _noise(0.14, 14.0, 0.15, 0.55, 0.4, true)
		&"snap": return _mix(_noise(0.07, 40.0, 0.8, 0.5, 0.6, false), _sweep(260.0, 90.0, 0.12, 25.0, 0.6))
		&"fog_growl": return _growl()
		&"claim": return _timed([[880.0, 0.0, 0.05], [1319.0, 0.05, 0.14]], 0.5, 13.0)
		&"unclaim": return _sweep(520.0, 260.0, 0.14, 16.0, 0.4, 1)
		&"lock": return _mix(_sweep(240.0, 70.0, 0.45, 5.0, 0.7), _mix(_noise(0.4, 7.0, 0.5, 0.1, 0.55, false), _timed([[196.0, 0.0, 0.3], [233.0, 0.0, 0.3], [294.0, 0.0, 0.3]], 0.35, 6.0)))
		&"shot": return _mix(_noise(0.05, 40.0, 0.8, 0.6, 0.45, false), _sweep(220.0, 80.0, 0.07, 40.0, 0.5))
		&"hit": return _timed([[1047.0, 0.0, 0.05], [1568.0, 0.04, 0.14]], 0.5, 15.0)
		&"hit_gold": return _timed([[1319.0, 0.0, 0.04], [1760.0, 0.04, 0.04], [2349.0, 0.08, 0.04], [3136.0, 0.12, 0.22]], 0.45, 9.0)
		&"miss": return _sweep(240.0, 150.0, 0.11, 24.0, 0.4, 1)
		&"gold_spawn": return _timed([[2093.0, 0.0, 0.03], [2637.0, 0.03, 0.14]], 0.22, 12.0)
		&"combo": return _timed([[659.0, 0.0, 0.06], [880.0, 0.06, 0.06], [1319.0, 0.12, 0.18]], 0.5, 10.0)
		&"throw": return _mix(_noise(0.14, 12.0, 0.12, 0.6, 0.5, true), _sweep(380.0, 1100.0, 0.1, 20.0, 0.22, 2))
		&"stick": return _mix(_sweep(170.0, 70.0, 0.09, 28.0, 0.8), _noise(0.05, 45.0, 0.5, 0.15, 0.4, false))
		&"clang": return _mix(_timed([[1760.0, 0.0, 0.3], [2349.0, 0.0, 0.25], [3322.0, 0.0, 0.2], [987.0, 0.0, 0.3]], 0.4, 9.0), _noise(0.06, 40.0, 0.8, 0.6, 0.5, false))
		&"dive": return _mix(_sweep(700.0, 180.0, 0.16, 12.0, 0.3), _noise(0.14, 14.0, 0.1, 0.5, 0.25, true))
		&"perfect": return _mix(_timed([[659.0, 0.0, 0.06], [988.0, 0.05, 0.06], [1319.0, 0.1, 0.06], [1976.0, 0.15, 0.3]], 0.45, 8.0), _noise(0.25, 8.0, 0.05, 0.5, 0.25, true))
		&"launch": return _mix(_sweep(240.0, 760.0, 0.22, 7.0, 0.35), _noise(0.2, 10.0, 0.05, 0.4, 0.3, true))
		&"swish": return _mix(_noise(0.13, 18.0, 0.55, 0.08, 0.45, true), _sweep(1500.0, 420.0, 0.1, 22.0, 0.22, 2))
		&"wall": return _mix(_sweep(210.0, 95.0, 0.07, 32.0, 0.75), _noise(0.05, 45.0, 0.45, 0.12, 0.35, false))
		&"reaction_ok": return _timed([[784.0, 0.0, 0.07], [1175.0, 0.07, 0.14]], 0.5, 12.0)
	return PackedFloat32Array()

# ----------------------------------------------------------------------------
# Bloques de síntesis
# ----------------------------------------------------------------------------

## Barrido de frecuencia f0 → f1 con caída exponencial. wave: 0 senoidal, 1 cuadrada, 2 diente de sierra.
static func _sweep(f0: float, f1: float, dur: float, decay: float, vol: float, wave: int = 0) -> PackedFloat32Array:
	var n := int(RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		ph += TAU * lerpf(f0, f1, t / dur) / RATE
		var s: float
		match wave:
			1: s = 1.0 if sin(ph) > 0.0 else -1.0
			2: s = fposmod(ph / TAU, 1.0) * 2.0 - 1.0
			_: s = sin(ph)
		out[i] = s * vol * minf(t / 0.003, 1.0) * exp(-t * decay)
	return out

## Ruido con paso bajo que va de lp0 a lp1 (0-1; más alto = más agudo). `bell` = entrada y salida suaves.
static func _noise(dur: float, decay: float, lp0: float, lp1: float, vol: float, bell: bool) -> PackedFloat32Array:
	var n := int(RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var rnd := RandomNumberGenerator.new()
	rnd.seed = int(dur * 1000.0) + int(decay)
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		lp += (rnd.randf_range(-1.0, 1.0) - lp) * lerpf(lp0, lp1, t / dur)
		var env := sin(PI * t / dur) if bell else exp(-t * decay)
		out[i] = lp * vol * env * 1.6
	return out

## Suma dos sonidos (dura lo del más largo).
static func _mix(a: PackedFloat32Array, b: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(maxi(a.size(), b.size()))
	for i in out.size():
		var v := 0.0
		if i < a.size():
			v += a[i]
		if i < b.size():
			v += b[i]
		out[i] = clampf(v, -1.0, 1.0)
	return out

## Notas [frecuencia, inicio (s), duración (s)] con timbre de campanita (senoidal + armónicos).
static func _timed(notes: Array, vol: float, decay: float) -> PackedFloat32Array:
	var end := 0.0
	for nt in notes:
		end = maxf(end, float(nt[1]) + float(nt[2]))
	var out := PackedFloat32Array()
	out.resize(int(RATE * (end + 0.15)))
	for nt in notes:
		var f := float(nt[0])
		var start := int(RATE * float(nt[1]))
		var len := int(RATE * (float(nt[2]) + 0.15))
		for i in len:
			var idx := start + i
			if idx >= out.size():
				break
			var t := float(i) / RATE
			var env := minf(t / 0.004, 1.0) * exp(-t * decay)
			out[idx] += (sin(TAU * f * t) + 0.35 * sin(TAU * f * 2.0 * t) + 0.12 * sin(TAU * f * 3.0 * t)) * env * vol * 0.55
	for i in out.size():
		out[i] = clampf(out[i], -1.0, 1.0)
	return out

## Fanfarria final: tres notas rápidas, subida y acorde sostenido (Do mayor).
static func _fanfare() -> PackedFloat32Array:
	var notes: Array = [
		[523.0, 0.0, 0.14], [523.0, 0.16, 0.14], [523.0, 0.32, 0.14], [659.0, 0.5, 0.28],
		[523.0, 0.84, 0.14], [659.0, 1.0, 0.14], [784.0, 1.16, 0.7],
		[1047.0, 1.16, 0.9], [659.0, 1.16, 0.9], [523.0, 1.16, 0.9]]
	return _timed(notes, 0.55, 3.0)

## Gruñido grave (la niebla que se acerca).
static func _growl() -> PackedFloat32Array:
	var n := int(RATE * 0.9)
	var out := PackedFloat32Array()
	out.resize(n)
	var rnd := RandomNumberGenerator.new()
	rnd.seed = 17
	var lp := 0.0
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		lp += (rnd.randf_range(-1.0, 1.0) - lp) * 0.06
		ph += TAU * (62.0 + 18.0 * sin(t * 9.0)) / RATE
		out[i] = (lp * 1.4 + sin(ph) * 0.6) * sin(PI * t / 0.9) * 0.6
	return out

static func _to_stream(samples: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = data
	return s
