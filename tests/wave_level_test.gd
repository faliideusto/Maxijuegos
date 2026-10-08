extends SceneTree
## Prueba del pasillo de Onda Neón (wave_dash):
##   1. Es siempre el mismo pasillo y es larguísimo.
##   2. Se estrecha, los tramos se acortan y la velocidad sube.
##   3. Es SUPERABLE: un bot que sigue la línea central recorre TODO el pasillo, también girando con el
##      error máximo que el diseño garantiza (tarde, pronto y alternando).
##   4. Controles negativos: no tocar nada, mantener siempre o girar con un error enorme → muere.
## Ejecutar:  godot --headless --path . --script res://tests/wave_level_test.gd

const SCRIPT_PATH := "res://minigames/wave_dash/wave_dash.gd"
const MIN_LEVEL := 1300.0

var _began: bool = false

func _new_level():
	return (load(SCRIPT_PATH) as GDScript).new()

func _process(_delta: float) -> bool:
	if _began:
		return true
	_began = true
	var failures: Array[String] = []

	var a = _new_level()
	var b = _new_level()
	var sig_a: String = a.debug_signature()
	_check(sig_a == b.debug_signature() and sig_a.length() > 1000, "el pasillo es siempre el mismo (%d giros)" % a.debug_corner_count(), failures)
	var level_end: float = a.debug_level_end()
	_check(level_end >= MIN_LEVEL, "el pasillo es larguísimo: %.0f bloques (mínimo %.0f)" % [level_end, MIN_LEVEL], failures)
	_check(a.speed_at(level_end) > a.speed_at(0.0) * 1.3, "la velocidad sube de %.1f a %.1f bloques/s" % [a.speed_at(0.0), a.speed_at(level_end)], failures)
	_check(a.half_at(level_end) < a.half_at(0.0) * 0.6, "el pasillo se estrecha: medio ancho %.2f → %.2f" % [a.half_at(0.0), a.half_at(level_end)], failures)
	for row in a.debug_timeline():
		print("  %-8s x=%5.0f  t=%5.1f s  v=%.1f  medio ancho=%.2f" % [row[0], row[1], row[2], row[3], row[4]])
	var seg_early: float = a.debug_avg_segment(0.0, 200.0)
	var seg_late: float = a.debug_avg_segment(700.0, 1300.0)
	_check(seg_late < seg_early * 0.8, "los giros se hacen más seguidos: tramo medio %.1f → %.1f bloques" % [seg_early, seg_late], failures)
	var rng_late: Vector2 = a.debug_segment_range(700.0, 1300.0)
	_check(rng_late.x >= 1.5, "ningún tramo es imposible de girar (el más corto: %.1f bloques)" % rng_late.x, failures)
	_check(float(a.debug_min_clearance()) > 1.0, "la línea central siempre queda dentro con holgura (%.2f)" % a.debug_min_clearance(), failures)

	# Superabilidad: sin error y con el error máximo garantizado.
	var tol: float = a.debug_guaranteed_tol()
	print("  margen de giro garantizado por el diseño: ±%.3f s" % tol)
	_check(tol >= 0.04, "el margen garantizado es humano (≥ 0,04 s): %.3f" % tol, failures)
	for pattern in [0, 1, 4]:
		var mg = _new_level()
		mg.debug_pattern = pattern
		mg.debug_tol = tol * (0.3 if pattern != 4 else 0.8)
		mg.debug_closed_loop = pattern == 4
		var t0 := Time.get_ticks_msec()
		var res: Dictionary = mg.debug_bot_run()
		var secs := (Time.get_ticks_msec() - t0) / 1000.0
		if not res["alive"]:
			print("      " + str(res["info"]))
		_check(res["alive"], "el bot recorre TODO el pasillo (patrón %d, error ±%.3f s: %.0f/%.0f bloques, %.1f s de CPU)" % [
				pattern, mg.debug_tol, res["distance"], res["end"], secs], failures)
		mg.free()

	# Controles negativos.
	var idle = _new_level()
	idle.debug_never_hold = true
	var r1: Dictionary = idle.debug_bot_run()
	_check(not r1["alive"] and r1["distance"] < 20.0, "control: sin pulsar muere pronto (%.0f bloques)" % r1["distance"], failures)
	var held = _new_level()
	held.debug_always_hold = true
	var r2: Dictionary = held.debug_bot_run()
	_check(not r2["alive"] and r2["distance"] < 30.0, "control: mantener siempre muere pronto (%.0f bloques)" % r2["distance"], failures)
	var sloppy = _new_level()
	sloppy.debug_pattern = 1
	sloppy.debug_tol = 0.2
	var r3: Dictionary = sloppy.debug_bot_run()
	_check(not r3["alive"], "control: con ±0,2 s de error el pasillo sí castiga (muere en %.0f bloques)" % r3["distance"], failures)
	var slow = _new_level()
	slow.debug_closed_loop = true
	slow.debug_tol = 0.15
	var r5: Dictionary = slow.debug_bot_run()
	_check(not r5["alive"], "control: un reflejo de 0,15 s no basta (muere en %.0f bloques)" % r5["distance"], failures)
	# El estrechamiento importa: con el mismo error el bot aguanta más al principio que al final.
	var mid = _new_level()
	mid.debug_pattern = 1
	mid.debug_tol = 0.08
	var r4: Dictionary = mid.debug_bot_run()
	_check(not r4["alive"] and r4["distance"] > 40.0, "control: con ±0,08 s aguanta el pasillo ancho y muere al estrecharse (%.0f bloques)" % r4["distance"], failures)

	print("")
	if failures.is_empty():
		print("WAVE LEVEL TEST OK")
		quit(0)
	else:
		print("WAVE LEVEL TEST FALLÓ")
		quit(1)
	return true

func _check(cond: bool, what: String, failures: Array[String]) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		failures.append(what)
		print("  ✗ " + what)
