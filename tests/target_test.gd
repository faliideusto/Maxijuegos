extends SceneTree
## Prueba de Puntería (LOCAL_PARALLEL): dianas idénticas para todos, dificultad creciente, puntuación
## (precisión, doradas, racha, fallos) y partidas completas con el autopiloto.
## Ejecutar:  godot --headless --path . --script res://tests/target_test.gd

var _began: bool = false
var _reported: Array = []

func _new_game(seed_value: int, bot: bool = false):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	var me = lobby.add_bot() if bot else lobby.add_player("kb1")
	lobby.add_bot()
	var meta = load("res://minigames/target_range/meta.tres")
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

	# --- Mismas dianas con la misma semilla; otras con otra ---
	var a = _new_game(777)
	var b = _new_game(777)
	var c = _new_game(778)
	var sa := _sig(a)
	_check(sa == _sig(b) and sa != _sig(c) and a.debug_schedule().size() > 40, "las dianas salen de la semilla: iguales con la misma (%d dianas), distintas con otra" % a.debug_schedule().size(), failures)

	# --- Dificultad creciente ---
	var sched: Array = a.debug_schedule()
	var third: int = sched.size() / 3
	var iv_first: float = (sched[third].t0 - sched[0].t0) / float(third)
	var iv_last: float = (sched[sched.size() - 1].t0 - sched[sched.size() - 1 - third].t0) / float(third)
	var first_normals: Array = sched.slice(0, third).filter(func(t) -> bool: return not t.gold)
	var last_normals: Array = sched.slice(sched.size() - third).filter(func(t) -> bool: return not t.gold)
	var life_first := _avg(first_normals, "life")
	var life_last := _avg(last_normals, "life")
	var rad_first := _avg(first_normals, "radius")
	var rad_last := _avg(last_normals, "radius")
	_check(iv_last < iv_first * 0.7, "aparecen cada vez más deprisa (%.2f → %.2f s entre dianas)" % [iv_first, iv_last], failures)
	_check(life_last < life_first * 0.75, "duran cada vez menos (%.2f → %.2f s)" % [life_first, life_last], failures)
	_check(rad_last < rad_first * 0.8, "son cada vez más pequeñas (radio %.0f → %.0f)" % [rad_first, rad_last], failures)

	# --- Doradas: duran menos y son más pequeñas; proporción razonable ---
	var golds: Array = sched.filter(func(t) -> bool: return t.gold)
	var frac := float(golds.size()) / float(sched.size())
	_check(frac > 0.08 and frac < 0.30, "hay dianas doradas (%.0f %% del total)" % [frac * 100.0], failures)
	var gold_shorter := true
	for g in golds:
		var d: float = g.t0 / a.DURATION
		var normal_life: float = lerpf(1.9, 1.0, d)
		if g.life > normal_life * 0.6 or g.radius > lerpf(46.0, 29.0, d):
			gold_shorter = false
	_check(gold_shorter, "las doradas duran la mitad y son más pequeñas que una normal del mismo momento", failures)
	_check(a.GOLD_POINTS == a.NORMAL_POINTS * 3.0, "valen el triple (%d vs %d)" % [a.GOLD_POINTS, a.NORMAL_POINTS], failures)

	# --- Colocación: dentro de la pista y sin solaparse las que coinciden en pantalla ---
	var inside := true
	var overlaps := 0
	var max_visible := 0
	for i in sched.size():
		var t = sched[i]
		if not a.FIELD.grow(-t.radius).has_point(t.pos):
			inside = false
		var vis := 0
		for j in sched.size():
			var o = sched[j]
			if o.t0 <= t.t0 and o.t0 + o.life > t.t0:
				vis += 1
			if j > i and o.t0 < t.t0 + t.life and o.t0 + o.life > t.t0 and t.pos.distance_to(o.pos) < t.radius + o.radius:
				overlaps += 1
		max_visible = maxi(max_visible, vis)
	_check(inside and overlaps == 0, "todas dentro de la pista y sin solaparse (solapes: %d)" % overlaps, failures)
	_check(max_visible <= 7, "nunca hay más de %d dianas a la vez" % max_visible, failures)

	# --- Puntuación ---
	var g1 = _new_game(5)
	var first_normal = _first(g1.debug_schedule(), false)
	g1.debug_set_time(first_normal.t0 + 0.1)
	var ok_center: bool = g1.debug_fire(first_normal.pos)
	_check(ok_center and g1.debug_state()["score"] == 100, "acertar el centro de una normal da 100 (%d)" % g1.debug_state()["score"], failures)
	var g2 = _new_game(5)
	var edge_t = _first(g2.debug_schedule(), false)
	g2.debug_set_time(edge_t.t0 + 0.1)
	g2.debug_fire(edge_t.pos + Vector2(edge_t.radius * 0.95, 0))
	var edge_score: int = g2.debug_state()["score"]
	_check(edge_score >= 50 and edge_score <= 65, "acertar por el borde da menos (%d)" % edge_score, failures)
	var g3 = _new_game(9)
	var gold_t = _first(g3.debug_schedule(), true)
	g3.debug_set_time(gold_t.t0 + 0.05)
	g3.debug_fire(gold_t.pos)
	_check(g3.debug_state()["score"] == 300, "una dorada en el centro da 300 (%d)" % g3.debug_state()["score"], failures)
	# Fallo: -25 (no baja de 0), rompe la racha y bloquea el siguiente disparo.
	var g4 = _new_game(5)
	var t4: Array = g4.debug_schedule()
	g4.debug_set_time(t4[0].t0 + 0.1)
	g4.debug_fire(t4[0].pos)
	g4.debug_set_time(t4[0].t0 + 0.12)
	g4.debug_fire(Vector2(5, 5))
	var st4: Dictionary = g4.debug_state()
	_check(st4["score"] == 75 and st4["misses"] == 1 and st4["combo"] == 0, "fallar quita 25 y rompe la racha (%d puntos)" % st4["score"], failures)
	var g5 = _new_game(5)
	g5.debug_set_time(0.0)
	g5.debug_fire(Vector2(5, 5))
	_check(g5.debug_state()["score"] == 0, "los puntos no bajan de 0", failures)
	_check(not g5.debug_fire(g5.debug_schedule()[0].pos), "tras fallar hay un bloqueo breve del disparo", failures)
	# Racha: cada 5 aciertos seguidos sube el multiplicador (×1, ×2, ×3).
	var g6 = _new_game(5)
	var s6: Array = g6.debug_schedule()
	var mults: Array[int] = []
	for i in 11:
		g6.debug_set_time(s6[i].t0 + 0.05)
		g6.debug_fire(s6[i].pos)
		mults.append(g6.debug_state()["mult"])
	_check(mults[3] == 1 and mults[4] == 2 and mults[8] == 2 and mults[9] == 3 and mults[10] == 3, "la racha sube el multiplicador cada 5 aciertos (%s)" % [mults], failures)

	# --- Tirador perfecto: sin pasarse de la cota de validación ---
	var gp = _new_game(31)
	for t in gp.debug_schedule():
		gp.debug_set_time(t.t0 + 0.05)
		gp.debug_fire(t.pos)
	var perfect: int = gp.debug_state()["score"]
	var sum_base: float = gp.debug_sum_base()
	_check(perfect > sum_base and perfect <= sum_base * 3.0, "un tirador perfecto hace %d (base %.0f; tope %.0f)" % [perfect, sum_base, sum_base * 3.0], failures)
	_check(gp.validate_result(float(perfect), 0.0) and not gp.validate_result(sum_base * 3.0 + 500.0, 0.0) and not gp.validate_result(-5.0, 0.0), "el host rechaza resultados imposibles", failures)
	var br: Dictionary = gp.bot_result(gp.players[1])
	_check(br["score"] >= 0.0 and br["score"] <= sum_base * 1.3, "los bots puntúan algo razonable (%.0f)" % br["score"], failures)

	# --- Autopiloto: partida completa con IA buena y con IA torpe ---
	var results := {}
	for skill in [1.0, 0.35]:
		var ga = _new_game(42, true)
		ga.debug_ai_skill = skill
		var steps := 0
		while not ga.debug_state()["done"] and steps < 60 * 40:
			ga.debug_advance(1.0 / 60.0)
			steps += 1
		for k in 120:
			ga._animate(1.0 / 30.0)
		results[skill] = ga.debug_state()
		_check(not _reported.is_empty() and float(_reported[0]) == float(ga.debug_state()["score"]), "el autopiloto (nivel %.2f) termina y envía su resultado: %d puntos, %d aciertos, %d fallos" % [skill, ga.debug_state()["score"], ga.debug_state()["hits"], ga.debug_state()["misses"]], failures)
	_check(int(results[1.0]["score"]) > int(results[0.35]["score"]) and int(results[1.0]["hits"]) > 20, "mejor puntería → más puntos (%d vs %d)" % [results[1.0]["score"], results[0.35]["score"]], failures)

	print("")
	if failures.is_empty():
		print("TARGET TEST OK")
		quit(0)
	else:
		print("TARGET TEST FALLÓ")
		quit(1)
	return true

func _first(sched: Array, gold: bool):
	for t in sched:
		if t.gold == gold:
			return t
	return null

func _sig(mg) -> String:
	var parts: PackedStringArray = []
	for t in mg.debug_schedule():
		parts.append("%.3f:%.1f:%.1f:%s" % [t.t0, t.pos.x, t.pos.y, t.gold])
	return "|".join(parts)

func _avg(arr: Array, field: String) -> float:
	var total := 0.0
	for t in arr:
		total += float(t.get(field))
	return total / maxf(float(arr.size()), 1.0)

func _check(cond: bool, what: String, failures: Array[String]) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		failures.append(what)
		print("  ✗ " + what)
