extends SceneTree
## Prueba de Cuesta Arriba 3D (HOST_AUTHORITATIVE): el tráfico sale de la semilla, subir da puntos (metros, líneas de
## neón y meta), un coche te atropella y vuelves a la última línea, se puede saltar un coche pero no una furgoneta,
## una partida con bots acaba con un ranking por puntos, el estado llega completo a un "cliente" y la escena 3D tiene
## un personaje por jugador.
## Ejecutar:  godot --headless --path . --script res://tests/uphill_test.gd

var _began: bool = false

func _new_game(seed_value: int, bots: int = 4, authority: bool = true):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	var me = lobby.add_bot()
	for i in bots - 1:
		lobby.add_bot()
	var meta = load("res://minigames/uphill_rush/meta.tres")
	var mg = (meta.scene as PackedScene).instantiate()
	mg.is_authority = authority
	root.add_child(mg)
	mg.configure(0, seed_value, me)
	mg.prepare(lobby.players)
	mg.start(lobby.players)
	return mg

func _process(_delta: float) -> bool:
	if _began:
		return true
	_began = true
	var f: Array[String] = []
	var Kind = load("res://minigames/uphill_rush/uphill_rush.gd").Kind
	# 1) Tráfico determinista por semilla.
	var a = _new_game(51)
	var b = _new_game(51)
	var c = _new_game(52)
	var sa: String = a.debug_traffic_signature(20.0)
	_ck(f, sa == b.debug_traffic_signature(20.0), "mismo tráfico con la misma semilla")
	_ck(f, sa != c.debug_traffic_signature(20.0), "semillas distintas dan tráfico distinto")
	_ck(f, a.debug_cars() >= 8, "hay coches bajando (%d)" % a.debug_cars())
	for g in [a, b, c]:
		g.free()
	# 2) Subir da puntos: metros, líneas y meta.
	var g2 = _new_game(60, 2)
	var id: int = g2.players[0].id
	g2.debug_clear_cars()
	for i in 60 * 6:
		g2.debug_step(id, Vector2(0, -1), false)
	var r: Dictionary = g2.debug_runner(id)
	print("  tras 6 s subiendo: ", r)
	_ck(f, float(r.z) > 31.0 and float(r.z) < 40.0, "sube a ~6 m/s (%.1f m)" % float(r.z))
	_ck(f, int(r.lines) == 1 and int(r.score) == int(float(r.best_z)) + 10, "1 punto por metro y +10 por la primera línea (%d)" % int(r.score))
	# 3) Atropello: vuelve a la última línea sin perder puntos.
	g2.debug_add_car(Kind.SEDAN, float(r.x), float(r.z) + 6.0, -15.0)
	for i in 60:
		g2.debug_step(id, Vector2.ZERO, false)
	r = g2.debug_runner(id)
	_ck(f, not bool(r.alive) and int(r.hits) == 1, "el coche lo atropella")
	var before := int(r.score)
	for i in 90:
		g2.debug_step(id, Vector2.ZERO, false)
	r = g2.debug_runner(id)
	_ck(f, bool(r.alive) and is_equal_approx(float(r.z), 30.0) and float(r.inv) > 0.0, "vuelve a la última línea (z=%.1f) con invulnerabilidad" % float(r.z))
	_ck(f, int(r.score) == before, "no pierde puntos")
	# 4) Saltar un coche sí, una furgoneta no.
	g2.debug_clear_cars()
	for i in 120:
		g2.debug_step(id, Vector2.ZERO, false)          # que pase la invulnerabilidad
	r = g2.debug_runner(id)
	g2.debug_add_car(Kind.SEDAN, float(r.x), float(r.z) + 3.0 + 15.0 * 0.2, -15.0)
	var jumped := false
	for i in 60:
		g2.debug_step(id, Vector2.ZERO, i == 0)
	r = g2.debug_runner(id)
	jumped = bool(r.alive)
	_ck(f, jumped, "saltando a tiempo pasa por encima de un coche")
	g2.debug_clear_cars()
	g2.debug_add_car(Kind.VAN, float(r.x), float(r.z) + 3.0 + 15.0 * 0.2, -15.0)
	for i in 60:
		g2.debug_step(id, Vector2.ZERO, i == 0)
	r = g2.debug_runner(id)
	_ck(f, not bool(r.alive), "una furgoneta no se puede saltar")
	# 5) Meta: +30 y ya no se mueve.
	g2.debug_clear_cars()
	for i in 200:
		g2.debug_step(id, Vector2.ZERO, false)
	g2.debug_place(id, 0.0, 329.0)
	var s_before := int(g2.debug_runner(id).score)
	for i in 30:
		g2.debug_step(id, Vector2(0, -1), false)
	r = g2.debug_runner(id)
	_ck(f, bool(r.finished) and int(r.score) >= s_before + 30, "llegar al portal da +30 (%d → %d)" % [s_before, int(r.score)])
	g2.free()
	# 6) Partida completa con bots: acaba a los 60 s, ranking por puntos, alguno atropellado, suben bastante.
	for sd in [7, 8, 9]:
		var g = _new_game(sd, 6)
		var steps := 0
		while not g.debug_over() and steps < 60 * 70:
			g._simulate(1.0 / 60.0)
			g._animate(1.0 / 60.0)
			steps += 1
		var scores: Array[int] = []
		var hits := 0
		var best_z := 0.0
		for p in g.players:
			var rr: Dictionary = g.debug_runner(p.id)
			scores.append(int(rr.score))
			hits += int(rr.hits)
			best_z = maxf(best_z, float(rr.best_z))
		var rk: Array[int] = g._ranking_ids()
		var sorted_ok := true
		for i in rk.size() - 1:
			if int(g.debug_runner(rk[i]).score) < int(g.debug_runner(rk[i + 1]).score):
				sorted_ok = false
		print("  semilla %d: puntos %s, atropellos %d, el que más sube %.0f m, coches %d" % [sd, str(scores), hits, best_z, g.debug_cars()])
		_ck(f, g.debug_over() and absf(g.debug_time() - 60.0) < 0.5, "la partida acaba a los 60 s")
		_ck(f, sorted_ok and g.debug_winner() == rk[0], "ranking por puntos y el ganador es el primero")
		_ck(f, hits >= 1, "algún bot acaba atropellado (%d)" % hits)
		_ck(f, best_z > 90.0, "los bots suben bastante (%.0f m)" % best_z)
		# Estado → cliente.
		var cl = _new_game(sd, 6, false)
		cl._apply_state(g._serialize_state())
		var same := true
		for p in g.players:
			if int(cl.debug_runner(p.id).score) != int(g.debug_runner(p.id).score):
				same = false
		_ck(f, same and cl.debug_cars() == g.debug_cars(), "el cliente recibe jugadores y coches")
		_ck(f, cl._order.size() == 6 and cl._rs[cl._order[0]].node != null, "un personaje 3D por jugador")
		g.free()
		cl.free()
	if f.is_empty():
		print("UPHILL TEST OK")
	else:
		print("UPHILL TEST FALLÓ: ", f)
	quit(0 if f.is_empty() else 1)
	return true

func _ck(f: Array[String], cond: bool, label: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + label)
	if not cond:
		f.append(label)
