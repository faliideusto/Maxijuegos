extends SceneTree
## Prueba del nivel de Salto Neón (cube_dash):
##   1. Determinismo: la misma semilla da exactamente el mismo nivel; otra semilla, uno distinto.
##   2. Superabilidad: un bot que simula la física corre el nivel con varias semillas. Si muere pronto
##      siempre en el mismo patrón, ese patrón es imposible o está mal definido.
## Ejecutar:  godot --headless --path . --script res://tests/cube_level_test.gd -- [semillas]

const SCRIPT_PATH := "res://minigames/cube_dash/cube_dash.gd"
## Distancia mínima (bloques) que el bot debe alcanzar en TODAS las semillas (100 s a 9→14,5 b/s).
const MIN_DISTANCE := 1000.0

var _began: bool = false

func _process(_delta: float) -> bool:
	if _began:
		return true
	_began = true
	var seeds := 6
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		seeds = int(args[0])
	var failures: Array[String] = []

	var a = (load(SCRIPT_PATH) as GDScript).new()
	var b = (load(SCRIPT_PATH) as GDScript).new()
	var sig_a = a.debug_level_signature(1234, 700.0)
	var sig_b = b.debug_level_signature(1234, 700.0)
	var sig_c = b.debug_level_signature(4321, 700.0)
	_check(sig_a == sig_b and sig_a.length() > 100, "misma semilla → mismo nivel (%d caracteres)" % sig_a.length(), failures)
	_check(sig_a != sig_c, "otra semilla → otro nivel", failures)
	# Determinismo con generación perezosa a distintas velocidades (como harían dos jugadores).
	var lazy = (load(SCRIPT_PATH) as GDScript).new()
	lazy.configure(MinigameMeta.ExecutionMode.LOCAL_PARALLEL, 1234, null)
	lazy._reset_level()
	for x in range(0, 700, 7):
		lazy._ensure_level(float(x))
	lazy._ensure_level(700.0)
	var parts: PackedStringArray = []
	for o in lazy._objs:
		if o.x <= 700.0:
			parts.append("%d:%s:%s:%s:%s" % [o.kind, o.x, o.y, o.w, o.h])
	_check("|".join(parts) == sig_a, "generación perezosa = generación de golpe", failures)

	# Controles negativos: sin saltar o saltando fuera de la ventana el cubo TIENE que morir.
	var never = (load(SCRIPT_PATH) as GDScript).new()
	never.debug_never_jump = true
	var res_never = never.debug_bot_run(1000)
	_check(not res_never["alive"] and res_never["distance"] < 60.0,
			"control: sin saltar muere pronto (%.0f bloques, '%s')" % [res_never["distance"], res_never["where"]], failures)
	var late = (load(SCRIPT_PATH) as GDScript).new()
	late.debug_jump_offset = 6.0
	var res_late = late.debug_bot_run(1000)
	_check(not res_late["alive"], "control: saltando 6 bloques tarde muere (%.0f bloques)" % res_late["distance"], failures)
	var early = (load(SCRIPT_PATH) as GDScript).new()
	early.debug_jump_offset = -6.0
	var res_early = early.debug_bot_run(1000)
	_check(not res_early["alive"], "control: saltando 6 bloques pronto muere (%.0f bloques)" % res_early["distance"], failures)
	# Ventana de tiempo realista: saltar con ±0,08 s de error sigue funcionando a baja velocidad.
	var ok_off = (load(SCRIPT_PATH) as GDScript).new()
	ok_off.debug_jump_offset = 0.6
	var res_ok = ok_off.debug_bot_run(1000)
	print("  (con 0,6 bloques de retraso: %.0f bloques, %s)" % [res_ok["distance"], "vivo" if res_ok["alive"] else "murió en '%s'" % res_ok["where"]])

	var worst := INF
	var all_alive := true
	for sd in seeds:
		var mg = (load(SCRIPT_PATH) as GDScript).new()
		var t0 := Time.get_ticks_msec()
		var res = mg.debug_bot_run(1000 + sd * 77)
		var secs := (Time.get_ticks_msec() - t0) / 1000.0
		print("  semilla %d: %.0f bloques, %s%s (%.1f s de CPU)" % [1000 + sd * 77, res["distance"],
				"vivo al terminar" if res["alive"] else "murió en '%s'" % res["where"], "", secs])
		worst = minf(worst, float(res["distance"]))
		all_alive = all_alive and bool(res["alive"])
		mg.free()
	_check(all_alive, "el bot (solución de referencia) sobrevive hasta el tope de tiempo en TODAS las semillas", failures)
	_check(worst >= MIN_DISTANCE, "el bot llega al menos a %d bloques en todas las semillas (peor: %.0f)" % [int(MIN_DISTANCE), worst], failures)

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
