extends SceneTree
## Prueba del recorrido de Columpio de Lengua (tongue_swing):
##   1. Es siempre el mismo y es largo (inalcanzable en el tiempo límite).
##   2. La dificultad sube: ganchos más separados, más ganchos frágiles.
##   3. Es SUPERABLE: el bot-planificador lo recorre entero (física real + niebla); con errores de suelta
##      aleatorios de ±0,02 s en cada gancho llega muy lejos (el recorrido tolera pequeños fallos).
##   4. Controles negativos: no soltar nunca o soltar al instante muere; un error grande de tiempo muere.
## Ejecutar:  godot --headless --path . --script res://tests/tongue_level_test.gd

const SCRIPT_PATH := "res://minigames/tongue_swing/tongue_swing.gd"
const MIN_END := 880.0

var _began: bool = false

func _new_level():
	var mg = (load(SCRIPT_PATH) as GDScript).new()
	mg.debug_load()
	return mg

func _process(_delta: float) -> bool:
	if _began:
		return true
	_began = true
	var failures: Array[String] = []

	var a = _new_level()
	var b = _new_level()
	var sig: String = a.debug_signature()
	_check(sig == b.debug_signature() and a.debug_anchor_count() > 100, "el recorrido es siempre el mismo (%d ganchos)" % a.debug_anchor_count(), failures)
	var end_x: float = a.debug_level_end()
	_check(end_x >= MIN_END, "el recorrido es largo: %.0f bloques (mínimo %.0f)" % [end_x, MIN_END], failures)
	var sp_early: float = a.debug_avg_spacing(0.0, 200.0)
	var sp_late: float = a.debug_avg_spacing(500.0, 900.0)
	_check(sp_late > sp_early * 1.4, "los ganchos se separan: %.1f → %.1f bloques" % [sp_early, sp_late], failures)
	var fr_early: int = a.debug_fragile_count(0.0, 200.0)
	var fr_late: int = a.debug_fragile_count(500.0, 900.0)
	_check(fr_late > fr_early + 4, "hay más ganchos frágiles al final: %d → %d" % [fr_early, fr_late], failures)

	# Superabilidad: el bot sin error recorre TODO el recorrido.
	var mg0 = _new_level()
	var res0: Dictionary = mg0.debug_bot_run()
	if not res0["alive"]:
		print("      " + str(res0["info"]))
	_check(res0["alive"], "el bot recorre TODO el recorrido (%.0f m, %.0f s de juego)" % [res0["distance"], res0["time"]], failures)
	# Con errores de suelta aleatorios de ±0,02 s en cada gancho (≈ 1 fotograma) llega muy lejos.
	for sd in [1, 2, 3, 4]:
		var mg = _new_level()
		mg.debug_delay_random = 0.02
		mg.debug_seed = sd
		var res: Dictionary = mg.debug_bot_run()
		_check(res["distance"] >= 300.0, "con errores de suelta de ±0,02 s (semilla %d) llega a %.0f m (mínimo 300; muere por %s)" % [sd, res["distance"], res["cause"] if res["cause"] != "" else "nada"], failures)
		mg.free()

	# Controles negativos.
	var never = _new_level()
	never.debug_never_release = true
	var r1: Dictionary = never.debug_bot_run()
	_check(not r1["alive"] and r1["distance"] < 40.0, "control: no soltar nunca muere pronto (%.0f m, %s)" % [r1["distance"], r1["cause"]], failures)
	var now = _new_level()
	now.debug_release_now = true
	var r2: Dictionary = now.debug_bot_run()
	_check(not r2["alive"] and r2["distance"] < 10.0, "control: soltar al instante muere (%.0f m, %s)" % [r2["distance"], r2["cause"]], failures)
	var late = _new_level()
	late.debug_release_delay = 0.45
	var r3: Dictionary = late.debug_bot_run()
	_check(not r3["alive"], "control: soltar 0,45 s tarde en cada gancho muere (%.0f m)" % r3["distance"], failures)

	print("")
	if failures.is_empty():
		print("TONGUE LEVEL TEST OK")
		quit(0)
	else:
		print("TONGUE LEVEL TEST FALLÓ")
		quit(1)
	return true

func _check(cond: bool, what: String, failures: Array[String]) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		failures.append(what)
		print("  ✗ " + what)
