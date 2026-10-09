extends SceneTree
## Prueba de la Carrera de Obstáculos 3D (HOST_AUTHORITATIVE, todos a la vez): el circuito sale de la semilla, la IA lo
## completa, correr sin esquivar tropieza y es más lento, la carrera con varios corredores acaba con ranking correcto,
## el estado se envía/recibe por completo (cliente = host), la pantalla 3D se monta con todos los personajes.
## Ejecutar:  godot --headless --path . --script res://tests/obstacle_test.gd

var _began: bool = false
var _ended_ranking: Array = []

func _new_game(seed_value: int, bots: int = 3, authority: bool = true):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	var me = lobby.add_bot()
	for i in bots - 1:
		lobby.add_bot()
	var meta = load("res://minigames/obstacle_run/meta.tres")
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
	# 1) Determinista por semilla.
	var a = _new_game(77)
	var b = _new_game(77)
	var c = _new_game(78)
	_ck(f, a.debug_signature() == b.debug_signature(), "mismo circuito con la misma semilla")
	_ck(f, a.debug_signature() != c.debug_signature(), "semillas distintas dan circuitos distintos")
	_ck(f, a.debug_obstacles().size() > 25, "hay obstáculos suficientes (%d)" % a.debug_obstacles().size())
	for g in [a, b, c]:
		g.queue_free()
	# 2) Un corredor solo: la IA lo completa y es mucho mejor que correr recto.
	var fin := 0
	var bot_hits := 0
	var idle_hits := 0
	var bot_time := 0.0
	var idle_time := 0.0
	var seeds := 12
	for s in seeds:
		var g = _new_game(1000 + s * 13)
		var r1: Dictionary = g.debug_run("bot", 1.0)
		var r2: Dictionary = g.debug_run("idle")
		if r1.finished:
			fin += 1
			bot_time += r1.time
		bot_hits += int(r1.hits)
		idle_hits += int(r2.hits)
		idle_time += r2.time if r2.finished else 70.0
		g.queue_free()
	print("  bot: %d/%d llegan, tiempo medio %.1f s, choques medios %.1f | recto: choques %.1f, tiempo %.1f s" % [fin, seeds, bot_time / maxf(fin, 1), float(bot_hits) / seeds, float(idle_hits) / seeds, idle_time / seeds])
	_ck(f, fin >= seeds - 1, "la IA llega a la meta en casi todos los circuitos (%d/%d)" % [fin, seeds])
	_ck(f, float(bot_hits) / seeds <= 2.5, "la IA apenas choca (%.1f de media)" % (float(bot_hits) / seeds))
	_ck(f, float(idle_hits) / seeds >= 6.0, "correr recto sin esquivar choca muchas veces (%.1f)" % (float(idle_hits) / seeds))
	_ck(f, bot_time / maxf(fin, 1) < idle_time / seeds - 4.0, "la IA es bastante más rápida que correr recto")
	_ck(f, bot_time / maxf(fin, 1) > 480.0 / 22.0, "el tiempo es físicamente posible (no más rápido que V_MAX)")
	# 3) Carrera completa con 4 corredores a la vez (host) y un "cliente" que solo recibe el estado.
	var g2 = _new_game(31337, 4)
	g2.finished.connect(func(r: Array[int]) -> void: _ended_ranking = r)
	var ids: Array = []
	for p in g2.players:
		ids.append(p.id)
	var client = _new_game(31337, 4, false)
	var t := 0.0
	var snaps := 0
	var saw_apart := false
	while t < 100.0 and _ended_ranking.is_empty():
		g2._process(1.0 / 30.0)
		t += 1.0 / 30.0
		client.apply_state(g2.serialize_state())
		client._animate(1.0 / 30.0)
		snaps += 1
		if snaps % 60 == 0:
			var zs: Array = []
			for id in ids:
				zs.append(g2.debug_runner(id)["z"])
			if zs.max() - zs.min() > 0.5:
				saw_apart = true
	var snap_ok := true
	for id in ids:
		var hr: Dictionary = g2.debug_runner(id)
		var cr: Dictionary = client.debug_runner(id)
		if absf(float(hr.z) - float(cr.z)) > 3.0 or hr.finished != cr.finished:
			snap_ok = false
	print("  carrera con 4: terminó a los %.1f s, ranking %s" % [t, _ended_ranking])
	_ck(f, _ended_ranking.size() == 4, "la carrera con 4 corredores acaba y devuelve el ranking de los 4")
	_ck(f, t > 480.0 / 22.0 and t < 90.0, "dura un tiempo razonable (%.1f s)" % t)
	_ck(f, saw_apart, "los corredores avanzan a la vez y se separan")
	_ck(f, snap_ok, "el estado recibido por el cliente coincide con el del host")
	var finished_n := 0
	for id in ids:
		if g2.debug_runner(id)["finished"]:
			finished_n += 1
	_ck(f, finished_n >= 3, "casi todos llegan a la meta (%d/4)" % finished_n)
	if _ended_ranking.size() == 4:
		var best_id: int = -1
		var best_t: float = 1e9
		for id in ids:
			var rr: Dictionary = g2.debug_runner(id)
			if rr.finished and float(rr.ftime) < best_t:
				best_t = float(rr.ftime)
				best_id = id
		_ck(f, _ended_ranking[0] == best_id and g2.debug_winner() == best_id, "gana el que llega antes a la meta")
	# 4) La escena 3D se monta con un personaje por jugador.
	var nodes := 0
	for id in ids:
		if g2._rs[id].node != null:
			nodes += 1
	_ck(f, g2._built and g2._cam != null and nodes == 4, "la escena 3D (cámara, mundo propio y un personaje por jugador) se construye")
	# 5) Rezagados: el que va muy atrás recibe empujón de velocidad.
	var g3 = _new_game(5, 2)
	var ids3: Array = []
	for p in g3.players:
		ids3.append(p.id)
	g3.debug_set_runner(ids3[1], 100.0, 0.0)
	_ck(f, g3._target_speed(g3._rs[ids3[1]], 200.0) > g3._target_speed(g3._rs[ids3[1]], 100.0) * 1.05, "los rezagados reciben un empujón de velocidad")
	print("")
	if f.is_empty():
		print("OBSTACLE TEST OK")
		quit(0)
	else:
		print("OBSTACLE TEST FALLÓ: ", f)
		quit(1)
	return true

func _ck(f: Array[String], cond: bool, what: String) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		f.append(what)
		print("  ✗ " + what)
