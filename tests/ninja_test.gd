extends SceneTree
## Prueba de Ninja Trepador (LOCAL_PARALLEL): física del salto (más vertical = más altura), la trayectoria de puntos es
## EXACTAMENTE el salto, oscilación del ángulo, deslizamiento, obstáculos y recorrido jugable, y partidas con el bot.
## Ejecutar:  godot --headless --path . --script res://tests/ninja_test.gd

var _began: bool = false
var _reported: Array = []

func _new_game(seed_value: int, bot: bool = false):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	var me = lobby.add_bot() if bot else lobby.add_player("kb1")
	lobby.add_bot()
	var meta = load("res://minigames/ninja_climb/meta.tres")
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
	var g = _new_game(2024)

	# --- Física: más vertical = más altura y más tiempo de vuelo; siempre llega a la otra pared ---
	var mono := true
	var prev := -1e9
	var a: float = g.ANGLE_MIN
	while a <= g.ANGLE_MAX:
		var gain: float = g.jump_gain(a)
		if gain <= prev:
			mono = false
		prev = gain
		a += 0.5
	var gmin: float = g.jump_gain(g.ANGLE_MIN)
	var gmax: float = g.jump_gain(g.ANGLE_MAX)
	_check(mono, "más vertical = más altura en todo el rango (%.0f px a %.0f° → %.0f px a %.0f°)" % [gmin, g.ANGLE_MIN, gmax, g.ANGLE_MAX], failures)
	_check(gmin > 5.0 and gmin < 60.0 and gmax > 250.0 and gmax < 400.0, "las ganancias van de un saltito a unos %.0f px por salto" % gmax, failures)
	_check(g.flight_time(g.ANGLE_MAX) > g.flight_time(g.ANGLE_MIN) and g.flight_time(g.ANGLE_MAX) < 1.0, "el salto más vertical dura más (%.2f s vs %.2f s)" % [g.flight_time(g.ANGLE_MAX), g.flight_time(g.ANGLE_MIN)], failures)
	var inv_ok := true
	for want in [40.0, 100.0, 180.0, 260.0]:
		var ang: float = g.angle_for_gain(want)
		if ang < 0.0 or absf(g.jump_gain(ang) - want) > 0.05:
			inv_ok = false
	_check(inv_ok and g.angle_for_gain(5.0) < 0.0 and g.angle_for_gain(900.0) < 0.0, "se puede calcular el ángulo para una altura (y se rechaza lo inalcanzable)", failures)
	var x_end_ok := true
	for ang in [20.0, 35.0, 50.0, 60.0]:
		var p0 := Vector2(g.wall_x(-1), 0.0)
		var end: Vector2 = g.pos_at(p0, 1.0, ang, g.flight_time(ang))
		if absf(end.x - g.wall_x(1)) > 0.01:
			x_end_ok = false
	_check(x_end_ok, "con cualquier ángulo el ninja llega a la pared de enfrente", failures)

	# --- Los puntos son exactamente el salto: la trayectoria dibujada = la que recorre el ninja ---
	var fidelity := true
	var worst := 0.0
	for ang in [20.0, 28.0, 41.0, 55.0, 60.0]:
		var f = _new_game(99)
		f.debug_reset()
		var start: Vector2 = f.debug_state()["pos"]
		var tr: Dictionary = f.trajectory(start, -1, ang, 0.01)
		f.debug_set_phase(asin((ang - (g.ANGLE_MIN + g.ANGLE_MAX) * 0.5) / ((g.ANGLE_MAX - g.ANGLE_MIN) * 0.5)))
		f.debug_jump()
		var steps := 0
		while f.debug_state()["mode"] == 1 and steps < 600:
			f.debug_advance(1.0 / 120.0)
			steps += 1
		var landed: Vector2 = f.debug_state()["pos"]
		var end: Vector2 = tr["end"]
		worst = maxf(worst, landed.distance_to(end))
		if landed.distance_to(end) > 0.6 or not bool(tr["landed"]):
			fidelity = false
	_check(fidelity, "los puntos acaban exactamente donde aterriza el ninja (error máx. %.2f px)" % worst, failures)

	# --- Oscilación: entre el mínimo y el máximo, sin pulsar, y más rápida con la altura ---
	var o = _new_game(5)
	o.debug_reset()
	var amin := 999.0
	var amax := -999.0
	for i in 600:
		o._phase += TAU / o.period_at(0.0) / 120.0
		o._update_angle()
		amin = minf(amin, o._angle)
		amax = maxf(amax, o._angle)
	_check(amin >= o.ANGLE_MIN - 0.01 and amax <= o.ANGLE_MAX + 0.01 and amin < o.ANGLE_MIN + 0.5 and amax > o.ANGLE_MAX - 0.5, "el ángulo oscila solo entre %.0f° y %.0f° (%.1f..%.1f)" % [o.ANGLE_MIN, o.ANGLE_MAX, amin, amax], failures)
	_check(o.period_at(0.0) > o.period_at(6000.0) and o.period_at(6000.0) > o.period_at(20000.0) and o.period_at(99999.0) >= o.PERIOD_END - 0.001, "la oscilación se acelera con la altura (%.2f → %.2f s)" % [o.period_at(0.0), o.period_at(20000.0)], failures)

	# --- Deslizamiento lento por la pared ---
	var sl = _new_game(5)
	sl.debug_reset()
	var y0: float = sl.debug_state()["pos"].y
	for i in 120:
		sl.debug_advance(1.0 / 120.0)
	var dy: float = y0 - sl.debug_state()["pos"].y
	_check(dy > 25.0 and dy < 50.0, "apoyado en la pared se desliza despacio (%.0f px en 1 s)" % dy, failures)

	# --- Recorrido: igual para todos, con huecos de aterrizaje que se estrechan y sin bloques dentro ---
	var c1 = _new_game(31)
	var c2 = _new_game(31)
	var c3 = _new_game(32)
	_check(c1.debug_signature() == c2.debug_signature() and c1.debug_signature() != c3.debug_signature(), "las paredes salen de la semilla: iguales con la misma, distintas con otra", failures)
	var course: Dictionary = c1.debug_course()
	var zones: Array = course["zones"]
	var blocks: Array = course["blocks"]
	var clear := true
	for z in zones:
		for b in blocks:
			if b.side == z["side"] and b.y2 > float(z["y"]) - float(z["sh"]) and b.y1 < float(z["y"]) + float(z["sh"]):
				clear = false
	_check(zones.size() > 100 and blocks.size() > 150, "el recorrido es larguísimo (%d zonas, %d bloques)" % [zones.size(), blocks.size()], failures)
	_check(clear, "ningún bloque invade un hueco de aterrizaje", failures)
	var sh_first: float = zones[3]["sh"]
	var sh_last: float = zones[zones.size() - 1]["sh"]
	_check(sh_last < sh_first * 0.75, "el hueco se estrecha con la altura (±%.0f → ±%.0f px)" % [sh_first, sh_last], failures)
	var reach_ok := true
	for i in range(1, zones.size()):
		var gain := float(zones[i]["y"]) - float(zones[i - 1]["y"])
		if int(zones[i]["side"]) == int(zones[i - 1]["side"]):
			continue
		if gain < gmin or gain > gmax:
			reach_ok = false
	_check(reach_ok, "cada zona es alcanzable desde la anterior con el rango de ángulos", failures)

	# --- Obstáculos: pinchos al deslizarse, al volar y al aterrizar ---
	var ob = _new_game(77)
	ob.debug_reset()
	var zb: Dictionary = ob.debug_course()
	var first_block = zb["blocks"][0]
	var st = ob.debug_state()
	# Deslizarse contra un bloque de su pared.
	ob._side = first_block.side
	ob._pos = Vector2(ob.wall_x(first_block.side), first_block.y2 + ob.NINJA_R + 8.0)
	var died_slide := false
	for i in 240:
		ob.debug_advance(1.0 / 120.0)
		if ob.debug_state()["mode"] == 2:
			died_slide = true
			break
	_check(died_slide, "deslizarse contra un bloque mata (pinchos)", failures)
	# Aterrizar sobre un bloque de la pared de enfrente.
	var ob2 = _new_game(77)
	ob2.debug_reset()
	var blk = ob2.debug_course()["blocks"][0]
	var land_side: int = blk.side
	var mid_y: float = (blk.y1 + blk.y2) * 0.5
	var g45: float = ob2.jump_gain(45.0)
	var tr_hit: Dictionary = ob2.trajectory(Vector2(ob2.wall_x(-land_side), mid_y - g45), -land_side, 45.0)
	var zone_free = null
	for z in ob2.debug_course()["zones"]:
		if z["side"] == land_side:
			zone_free = z
			break
	var tr_free: Dictionary = ob2.trajectory(Vector2(ob2.wall_x(-land_side), float(zone_free["y"]) - g45), -land_side, 45.0)
	_check(not bool(tr_hit["landed"]) and bool(tr_free["landed"]), "los puntos avisan: chocar contra un bloque (✕) o aterrizar libre (○)", failures)

	# --- El bot de referencia (apunta a la zona y pulsa en el ángulo justo) sube sin morir ---
	var bots := []
	for sd in [1, 2, 3]:
		var gb = _new_game(sd * 101)
		bots.append(gb.debug_run(gb.TIME_LIMIT, 1.0, 0.0))
	var ok_all := true
	var min_h := 1e9
	for r in bots:
		if bool(r["dead"]):
			ok_all = false
		min_h = minf(min_h, float(r["height_m"]))
	print("  · bot exacto: ", bots)
	_check(ok_all and min_h > 60.0, "un bot exacto no muere en 45 s y sube más de 60 m (mín. %.0f m)" % min_h, failures)
	var noisy = _new_game(101)
	var rn: Dictionary = noisy.debug_run(noisy.TIME_LIMIT, 4.0, 0.06)
	var sloppy = _new_game(101)
	var rs: Dictionary = sloppy.debug_run(sloppy.TIME_LIMIT, 20.0, 0.35)
	print("  · bot con error: ", rn, " | muy torpe: ", rs)
	_check(float(rn["height_m"]) > 20.0, "con ±4° y 0,06 s de retraso sigue subiendo (%.0f m)" % rn["height_m"], failures)
	_check(bool(rs["dead"]) or float(rs["height_m"]) < float(bots[0]["height_m"]), "con mucha torpeza se llega menos alto o se muere (%.0f m)" % rs["height_m"], failures)

	# --- Partida completa con el autopiloto: envía su altura ---
	var ga = _new_game(555, true)
	var steps2 := 0
	while ga.debug_state()["mode"] != 3 and ga.debug_state()["mode"] != 2 and steps2 < 60 * 60:
		ga._play(1.0 / 60.0)
		steps2 += 1
	for k in 150:
		ga._animate(1.0 / 30.0)
	_check(not _reported.is_empty() and float(_reported[0]) > 10.0, "el autopiloto termina y envía su altura (%s m, %.1f s)" % [str(_reported), steps2 / 60.0], failures)
	var gv = _new_game(1)
	_check(gv.validate_result(300.0, 0.0) and not gv.validate_result(5000.0, 0.0) and not gv.validate_result(-1.0, 0.0), "el host rechaza alturas imposibles", failures)

	print("")
	if failures.is_empty():
		print("NINJA TEST OK")
		quit(0)
	else:
		print("NINJA TEST FALLÓ")
		quit(1)
	return true

func _check(cond: bool, what: String, failures: Array[String]) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		failures.append(what)
		print("  ✗ " + what)
