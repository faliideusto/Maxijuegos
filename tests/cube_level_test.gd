extends SceneTree
## Prueba del nivel (diseñado a mano) de Salto Neón (cube_dash):
##   1. Es siempre el mismo nivel y es larguísimo.
##   2. Tiene variedad (plataformas, escaleras, pinchos sobre plataformas, techo, huecos...).
##   3. Es SUPERABLE: un bot que sigue la solución de referencia recorre TODO el nivel, también con
##      ±0,07 s de error en cada salto (el margen humano mínimo garantizado). Si falla, indica la
##      pieza del guion exacta donde muere.
##   4. Controles negativos: sin saltar, o saltando 6 bloques tarde/pronto, el cubo muere.
## Ejecutar:  godot --headless --path . --script res://tests/cube_level_test.gd

const SCRIPT_PATH := "res://minigames/cube_dash/cube_dash.gd"
## Longitud mínima del nivel: inalcanzable en el tiempo límite (100 s).
const MIN_LEVEL := 2300.0
## Signo del margen humano de cada zona (tol_at): 0 = salto exacto, +1 = tarde, -1 = pronto.
const TOL_SIGNS: Array[int] = [0, 1, -1]

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
	var sig_b: String = b.debug_signature()
	_check(sig_a == sig_b and sig_a.length() > 1000, "el nivel es siempre el mismo (%d piezas, %d caracteres de firma)" % [a.debug_piece_count(), sig_a.length()], failures)
	var level_end: float = a.debug_level_end()
	_check(level_end >= MIN_LEVEL, "el nivel es larguísimo: %.0f bloques (mínimo %.0f)" % [level_end, MIN_LEVEL], failures)
	var speed_end: float = a.speed_at(level_end)
	var speed_start: float = a.speed_at(0.0)
	_check(speed_end > speed_start * 1.6, "la velocidad sube de %.1f a %.1f bloques/s" % [speed_start, speed_end], failures)

	# Variedad de piezas.
	for row in a.debug_timeline():
		print("  sección %-10s x=%5.0f  t=%5.1f s  v=%.1f" % [row[0], row[1], row[2], row[3]])
	var tags: Dictionary = a.debug_tag_counts()
	print("  piezas por tipo: ", tags)
	for needed in ["S1", "S2", "S3", "B1", "B2", "G2", "G3", "G4", "hop", "stairs", "plat_spike", "ceiling", "run"]:
		_check(tags.has(needed), "el nivel contiene '%s'" % needed, failures)

	# Superabilidad: todo el nivel, con y sin error de tiempo.
	for sign in TOL_SIGNS:
		var mg = _new_level()
		mg.debug_tol_sign = sign
		var t0 := Time.get_ticks_msec()
		var res: Dictionary = mg.debug_bot_run()
		var secs := (Time.get_ticks_msec() - t0) / 1000.0
		if not res["alive"]:
			print("      " + str(res["info"]))
		_check(res["alive"], "el bot recorre TODO el nivel con el margen humano de cada zona (%+d: %.0f/%.0f bloques%s, %.1f s de CPU)" % [
				sign, res["distance"], res["end"], "" if res["alive"] else "; muere en %s" % res["piece"], secs], failures)
		mg.free()

	# Controles negativos.
	var never = _new_level()
	never.debug_never_jump = true
	var r1: Dictionary = never.debug_bot_run()
	_check(not r1["alive"] and r1["distance"] < 60.0, "control: sin saltar muere pronto (%.0f bloques en %s)" % [r1["distance"], r1["piece"]], failures)
	for off in [6.0, -6.0]:
		var wrong = _new_level()
		wrong.debug_jump_offset = off
		var r2: Dictionary = wrong.debug_bot_run()
		_check(not r2["alive"], "control: saltos desplazados %+.0f bloques → muere (%.0f bloques)" % [off, r2["distance"]], failures)
	# CONTROL CLAVE: los techos obligan a saltar antes o después. Si el bot ignora el sesgo y salta
	# "centrado" (el momento natural), tiene que chocar con un techo en alguna pieza con sesgo.
	var centered = _new_level()
	centered.debug_ignore_bias = true
	var r4: Dictionary = centered.debug_bot_run()
	_check(not r4["alive"], "control: saltar 'centrado' ignorando el sesgo CHOCA con un techo (muere en %.0f bloques, %s)" % [r4["distance"], r4["piece"]], failures)
	print("      " + str(r4["info"]).replace("\n", "\n      "))
	# Cuántas piezas con techo y sesgo hay, y que el sesgo no es decorativo: con el sesgo se pasan todas.
	var level_text = a.debug_pieces_with_bias()
	var weak: Array = a.debug_ineffective_gates()
	_check(weak.is_empty(), "todas las puertas obligan a saltar pronto o tarde (ineficaces: %s)" % [weak], failures)
	_check(level_text >= 20, "hay %d piezas con sesgo de timing" % level_text, failures)
	# Un error de ±0,25 s ya debe ser demasiado en algún punto (el nivel no es trivial).
	var sloppy = _new_level()
	sloppy.debug_tol = 0.25
	var r3: Dictionary = sloppy.debug_bot_run()
	_check(not r3["alive"], "control: con ±0,25 s de error el nivel sí castiga (muere en %.0f bloques)" % r3["distance"], failures)

	print("")
	if failures.is_empty():
		print("CUBE LEVEL TEST OK")
		quit(0)
	else:
		print("CUBE LEVEL TEST FALLÓ")
		quit(1)
	return true

func _check(cond: bool, what: String, failures: Array[String]) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		failures.append(what)
		print("  ✗ " + what)
