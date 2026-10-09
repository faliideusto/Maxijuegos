extends SceneTree
## Prueba de Salto Lunar (LOCAL_PARALLEL): terreno igual para todos y jugable, física (ganar al bajar, perder al
## subir, aterrizar), políticas de juego y partida completa con el autopiloto.
## Ejecutar:  godot --headless --path . --script res://tests/moon_test.gd

var _began: bool = false
var _reported: Array = []

func _new_game(seed_value: int, bot: bool = false):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	var me = lobby.add_bot() if bot else lobby.add_player("kb1")
	lobby.add_bot()
	var meta = load("res://minigames/moon_hop/meta.tres")
	var mg = (meta.scene as PackedScene).instantiate()
	root.add_child(mg)
	mg.configure(1, seed_value, me)
	mg.prepare(lobby.players)
	_reported = []
	mg.result_reported.connect(func(score: float, tiebreak: float) -> void: _reported = [score, tiebreak])
	mg.start(lobby.players)
	return mg

func _process(_delta: float) -> bool:
	if _began:
		return true
	_began = true
	var failures: Array[String] = []

	# --- Terreno: igual con la misma semilla, distinto con otra, largo y jugable ---
	var a = _new_game(1234)
	var b = _new_game(1234)
	var c = _new_game(1235)
	_check(a.debug_signature() == b.debug_signature() and a.debug_signature() != c.debug_signature(), "el terreno sale de la semilla: igual con la misma, distinto con otra", failures)
	var ter: Dictionary = a.debug_terrain()
	var tx: PackedFloat64Array = ter["x"]
	var ty: PackedFloat64Array = ter["y"]
	_check(tx[tx.size() - 1] >= a.LEVEL_LEN, "el terreno es larguísimo (%.0f px = %.0f m)" % [tx[tx.size() - 1], tx[tx.size() - 1] / a.PX_PER_M], failures)
	var max_slope := 0.0
	var alternates := true
	var mono_x := true
	for i in range(1, tx.size() - 1):
		var w := tx[i + 1] - tx[i]
		var amp := absf(ty[i + 1] - ty[i])
		max_slope = maxf(max_slope, amp * PI * 0.5 / w)
		if tx[i + 1] <= tx[i]:
			mono_x = false
		if i >= 2 and (ty[i] - ty[i - 1]) * (ty[i + 1] - ty[i]) > 0.0:
			alternates = false
	_check(mono_x and alternates, "cimas y valles se alternan", failures)
	_check(max_slope <= 1.7, "ninguna pendiente supera ~60° (máx. %.2f)" % max_slope, failures)
	var amp_first := 0.0
	var amp_last := 0.0
	var n_amp := tx.size() / 4
	for i in range(1, n_amp):
		amp_first += absf(ty[i + 1] - ty[i])
	for i in range(tx.size() - 1 - n_amp, tx.size() - 2):
		amp_last += absf(ty[i + 1] - ty[i])
	_check(amp_last > amp_first * 1.1, "las montañas crecen con la distancia (desnivel medio %.0f → %.0f px)" % [amp_first / n_amp, amp_last / n_amp], failures)
	# Pendiente analítica coherente con la altura.
	var slope_ok := true
	for x in [137.0, 800.0, 3333.0, 20000.0, 90000.0]:
		var num: float = (a.height_at(x + 0.5) - a.height_at(x - 0.5))
		if absf(num - a.slope_at(x)) > 0.01:
			slope_ok = false
	_check(slope_ok, "la pendiente analítica coincide con la altura del terreno", failures)

	# --- Física: bajar la montaña gana velocidad; mantener el botón la gana más; subir la pierde ---
	var g = _new_game(1234)
	var v_free := _speed_at_valley(g, false, tx[1])
	var v_hold := _speed_at_valley(g, true, tx[1])
	var v0: float = g.START_SPEED
	_check(v_free > v0 * 2.0 and v_hold > v_free * 1.15, "bajar la montaña da velocidad (%.0f → %.0f en el valle; manteniendo el botón %.0f)" % [v0, v_free, v_hold], failures)
	# Subida: con velocidad moderada y sin mantener, se pierde.
	g.debug_reset()
	var st = g.debug_state()
	var up_x := 0.0
	for i in range(1, tx.size() - 1):
		if ty[i + 1] > ty[i]:
			up_x = (tx[i] + tx[i + 1]) * 0.5
			break
	st.x = up_x
	st.y = g.height_at(up_x)
	st.speed = 700.0
	st.grounded = true
	for i in 30:
		g.debug_step(false)
	var v_up_free: float = g.debug_state().speed
	st.x = up_x
	st.y = g.height_at(up_x)
	st.speed = 700.0
	st.grounded = true
	for i in 30:
		g.debug_step(true)
	var v_up_hold: float = g.debug_state().speed
	_check(v_up_free < 700.0 and v_up_hold < v_up_free, "subir pierde velocidad, y mantener el botón al subir la pierde más (%.0f vs %.0f)" % [v_up_free, v_up_hold], failures)

	# --- Aterrizaje: paralelo a la ladera = no se pierde nada; contra ella, mucho ---
	var down_x := 0.0
	for i in range(1, tx.size() - 1):
		if ty[i + 1] < ty[i] - 100.0:
			down_x = (tx[i] + tx[i + 1]) * 0.5
			break
	var sl: float = g.slope_at(down_x)
	var tang := Vector2(1.0, sl).normalized()
	g.debug_reset()
	var sa = g.debug_state()
	sa.grounded = false
	sa.x = down_x
	sa.y = g.height_at(down_x) + 0.5
	sa.vx = tang.x * 900.0
	sa.vy = tang.y * 900.0
	for i in 8:
		g.debug_step(false)
		if sa.grounded:
			break
	_check(sa.grounded and sa.speed > 800.0 and sa.land_cos > 0.95, "aterrizar paralelo a la ladera conserva la velocidad (%.0f de 900, cos %.2f)" % [sa.speed, sa.land_cos], failures)
	g.debug_reset()
	var sb = g.debug_state()
	sb.grounded = false
	var flat_x: float = tx[1]               # fondo del primer valle: suelo llano
	sb.x = flat_x
	sb.y = g.height_at(flat_x) + 0.5
	sb.vx = 100.0
	sb.vy = -900.0
	for i in 8:
		g.debug_step(false)
		if sb.grounded:
			break
	_check(sb.grounded and sb.speed < 500.0 and sb.land_cos < 0.35, "caer en vertical contra suelo llano frena en seco (%.0f de 906, cos %.2f)" % [sb.speed, sb.land_cos], failures)

	# --- Políticas: la IA que mantiene al bajar y suelta al subir gana a las ingenuas ---
	var never: Dictionary = g.debug_run("never")
	var always: Dictionary = g.debug_run("always")
	var bot: Dictionary = g.debug_run("bot", 1.0)
	var clumsy: Dictionary = g.debug_run("bot", 0.2)
	print("  · nunca: %.0f m (%.1f s) | siempre: %.0f m (%.1f s) | IA: %.0f m (%.0f perfectos, %.0f porrazos, vel. máx. %.0f) | IA torpe: %.0f m" % [
			never["distance_m"], never["time"], always["distance_m"], always["time"], bot["distance_m"], bot["perfect"], bot["bad"], bot["max_speed"], clumsy["distance_m"]])
	_check(bot["distance_m"] > never["distance_m"] * 1.4 and bot["distance_m"] > always["distance_m"] * 1.2, "saber cuándo mantener y soltar gana a no hacerlo (IA %.0f m vs nunca %.0f / siempre %.0f)" % [bot["distance_m"], never["distance_m"], always["distance_m"]], failures)
	_check(never["min_speed"] >= g.MIN_SPEED - 1.0 and always["min_speed"] >= g.MIN_SPEED - 1.0 and bot["min_speed"] >= g.MIN_SPEED - 1.0 and clumsy["min_speed"] >= g.MIN_SPEED - 1.0, "el astronauta NUNCA se para (velocidad mínima %.0f px/s en todas las políticas)" % [minf(never["min_speed"], minf(always["min_speed"], bot["min_speed"]))], failures)
	_check(absf(never["time"] - g.TIME_LIMIT) < 0.05 and absf(bot["time"] - g.TIME_LIMIT) < 0.05 and absf(clumsy["time"] - g.TIME_LIMIT) < 0.05, "la partida dura siempre %.0f s (nadie acaba antes)" % g.TIME_LIMIT, failures)
	_check(bot["max_air"] > 800.0, "con poca gravedad se vuela alto (hasta %.0f px sobre el suelo)" % bot["max_air"], failures)
	_check(bot["distance_m"] > clumsy["distance_m"], "el nivel de habilidad importa (%.0f m vs %.0f m)" % [bot["distance_m"], clumsy["distance_m"]], failures)
	_check(int(bot["perfect"]) >= 1, "hay aterrizajes perfectos (%d) y porrazos (%d)" % [int(bot["perfect"]), int(bot["bad"])], failures)
	_check(bot["max_speed"] <= g.V_AIR_MAX + 1.0 and bot["distance_m"] < 1500.0, "la velocidad está acotada (máx. %.0f px/s)" % bot["max_speed"], failures)
	_check(g.validate_result(bot["distance_m"], 0.0) and not g.validate_result(99999.0, 0.0) and not g.validate_result(-1.0, 0.0), "el host rechaza distancias imposibles", failures)

	# --- Partida completa con el autopiloto ---
	var ga = _new_game(777, true)
	var steps := 0
	while not ga._done and steps < 60 * 80:
		ga._play(1.0 / 60.0)
		steps += 1
	for k in 120:
		ga._animate(1.0 / 30.0)
	_check(ga._done and not _reported.is_empty() and float(_reported[0]) > 100.0 and absf(steps / 60.0 - g.TIME_LIMIT) < 0.5, "el autopiloto juega los %.0f s y envía su distancia (%s m, %.1f s)" % [g.TIME_LIMIT, str(_reported), steps / 60.0], failures)

	print("")
	if failures.is_empty():
		print("MOON TEST OK")
		quit(0)
	else:
		print("MOON TEST FALLÓ")
		quit(1)
	return true

## Velocidad al llegar al fondo del primer valle bajando desde la cima de salida.
func _speed_at_valley(g, hold: bool, valley_x: float) -> float:
	g.debug_reset()
	var st = g.debug_state()
	var n := 0
	while st.x < valley_x and n < 2000:
		g.debug_step(hold)
		n += 1
	return st.speed if st.grounded else Vector2(st.vx, st.vy).length()

func _check(cond: bool, what: String, failures: Array[String]) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		failures.append(what)
		print("  ✗ " + what)
