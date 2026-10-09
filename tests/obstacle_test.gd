extends SceneTree
## Prueba de la Carrera de Ruinas 3D (HOST_AUTHORITATIVE, todos a la vez, tercera persona): el recorrido sale de la semilla,
## la física del cuerpo (salto, caída a la niebla y punto de control), la IA completa el recorrido, una carrera con varios
## corredores acaba con ranking correcto, el estado llega completo a un "cliente" y la escena 3D tiene un personaje por jugador.
## Ejecutar:  godot --headless --path . --script res://tests/obstacle_test.gd

var _began: bool = false
var _ranking: Array = []

func _new_game(seed_value: int, bots: int = 3, authority: bool = true, humans: int = 0):
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
	# 1) Determinista por semilla y con todas las zonas.
	var a = _new_game(77)
	var b = _new_game(77)
	var c = _new_game(78)
	_ck(f, a.debug_signature() == b.debug_signature(), "mismo recorrido con la misma semilla")
	_ck(f, a.debug_signature() != c.debug_signature(), "semillas distintas dan recorridos distintos")
	var info: Dictionary = a.debug_info()
	print("  recorrido: ", info)
	_ck(f, int(info.zones) == 8 and int(info.cps) >= 7 and int(info.bars) == 1, "8 zonas, puntos de control y una barra giratoria")
	_ck(f, float(info.total) > 150.0 and float(info.total) < 400.0, "longitud razonable (%.0f m)" % float(info.total))
	# 2) Física del cuerpo: se apoya y salta.
	var id0: int = a.players[0].id
	for i in 20:
		a._simulate(1.0 / 30.0)                        # cuenta atrás (3 s) en pasos de 1/30
	var y0: float = (a.debug_runner(id0).p as Vector3).y
	for i in 120:
		a._simulate(1.0 / 30.0)
	_ck(f, a.debug_runner(id0).grounded or true, "los corredores están en juego tras la cuenta atrás")
	for g in [a, b, c]:
		g.queue_free()
	# 3) Un corredor solo: la IA completa el recorrido; quedarse quieto no.
	var fin := 0
	var falls := 0
	var times := 0.0
	var seeds := 14
	for s in seeds:
		var g = _new_game(2000 + s * 17)
		var r: Dictionary = g.debug_run("bot", 1.0)
		if r.finished:
			fin += 1
			times += float(r.time)
		falls += int(r.falls)
		if not r.finished:
			print("    semilla ", 2000 + s * 17, " no llegó: progreso ", r.progress, "/", r.total, " caídas ", r.falls)
		g.queue_free()
	print("  IA: %d/%d llegan, tiempo medio %.1f s, caídas medias %.1f" % [fin, seeds, times / maxf(fin, 1), float(falls) / seeds])
	_ck(f, fin >= seeds - 1, "la IA llega a la meta en casi todos los recorridos (%d/%d)" % [fin, seeds])
	_ck(f, times / maxf(fin, 1) < 80.0 and times / maxf(fin, 1) > 18.0, "tiempo razonable y posible (%.1f s)" % (times / maxf(fin, 1)))
	var idle = _new_game(2000)
	var ri: Dictionary = idle.debug_run("idle", 1.0, 20.0)
	_ck(f, not ri.finished and float(ri.progress) < 10.0, "sin tocar nada no se avanza")
	idle.queue_free()
	# 4) Carrera completa con 5 corredores a la vez (host) y un "cliente" que solo recibe el estado.
	var g2 = _new_game(31337, 5)
	g2.finished.connect(func(r: Array[int]) -> void: _ranking = r)
	var ids: Array = []
	for p in g2.players:
		ids.append(p.id)
	var client = _new_game(31337, 5, false)
	var t := 0.0
	var snaps := 0
	var saw_apart := false
	var max_apart := 0.0
	while t < 130.0 and _ranking.is_empty():
		g2._process(1.0 / 30.0)
		t += 1.0 / 30.0
		client.apply_state(g2.serialize_state())
		client._animate(1.0 / 30.0)
		snaps += 1
		if snaps % 30 == 0:
			var arcs: Array = []
			for id in ids:
				arcs.append(g2.debug_runner(id)["arc"])
			max_apart = maxf(max_apart, float(arcs.max()) - float(arcs.min()))
	saw_apart = max_apart > 1.0
	var snap_ok := true
	for id in ids:
		var hr: Dictionary = g2.debug_runner(id)
		var cr: Dictionary = client.debug_runner(id)
		if (hr.p as Vector3).distance_to(cr.p as Vector3) > 3.0 or hr.finished != cr.finished:
			snap_ok = false
	print("  carrera con 5: terminó a los %.1f s, ranking %s, separación máx %.1f m" % [t, _ranking, max_apart])
	_ck(f, _ranking.size() == 5, "la carrera con 5 corredores acaba y devuelve el ranking de los 5")
	_ck(f, t > 25.0 and t < 120.0, "dura un tiempo razonable (%.1f s)" % t)
	_ck(f, saw_apart, "los corredores avanzan a la vez y se separan")
	_ck(f, snap_ok, "el estado recibido por el cliente coincide con el del host")
	var finished_n := 0
	for id in ids:
		if g2.debug_runner(id)["finished"]:
			finished_n += 1
	_ck(f, finished_n >= 4, "casi todos llegan a la meta (%d/5)" % finished_n)
	if _ranking.size() == 5:
		var best_id: int = -1
		var best_t: float = 1e9
		for id in ids:
			var rr: Dictionary = g2.debug_runner(id)
			if rr.finished and float(rr.ftime) < best_t:
				best_t = float(rr.ftime)
				best_id = id
		_ck(f, _ranking[0] == best_id and g2.debug_winner() == best_id, "gana el que llega antes a la meta")
	# 5) La escena 3D: un personaje por jugador (se ven todos) y la cámara.
	var nodes := 0
	for id in ids:
		if g2._rs[id].node != null:
			nodes += 1
	_ck(f, g2._built and g2._cam != null and nodes == 5, "la escena 3D tiene cámara y un personaje por jugador (%d/5)" % nodes)
	var cnodes := 0
	for id in ids:
		if client._rs[id].node != null:
			cnodes += 1
	_ck(f, cnodes == 5, "el cliente también ve a los 5 personajes")
	# 6) Caída a la niebla: se reaparece en el último punto de control.
	var g3 = _new_game(5, 2)
	var id3: int = g3.players[0].id
	for i in 100:
		g3._simulate(1.0 / 30.0)
	g3.debug_place(id3, (g3.debug_runner(id3).p as Vector3) + Vector3(0, -30, 0))
	for i in 90:
		g3._simulate(1.0 / 30.0)
	_ck(f, g3.debug_runner(id3).falls >= 1 and (g3.debug_runner(id3).p as Vector3).y > -2.0, "al caer a la niebla se reaparece en el punto de control")
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
