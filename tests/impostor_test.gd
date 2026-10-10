extends SceneTree
## Prueba de Impostor a Bordo (HOST_AUTHORITATIVE, 3D en primera persona): la nave (salas conectadas, consolas pegadas a
## su pared, colisiones), el reparto de papeles y tareas, hacer tareas, eliminar (alcance, recarga, paredes), denunciar,
## votar y expulsar, el botón de emergencia, las condiciones de victoria, el giro con ratón por la red, el estado enviado
## a un "cliente" y partidas completas con bots.
## Ejecutar:  godot --headless --path . --script res://tests/impostor_test.gd

var _began: bool = false
var _ranking: Array = []

func _new_game(bots: int = 6, authority: bool = true, seed_value: int = 99, impostor_slot: int = -1):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	var me = lobby.add_bot()
	for i in bots - 1:
		lobby.add_bot()
	var meta = load("res://minigames/impostor/meta.tres")
	var mg = (meta.scene as PackedScene).instantiate()
	mg.is_authority = authority
	if impostor_slot >= 0:
		mg.debug_force_impostors = [lobby.players[impostor_slot].id]
	root.add_child(mg)
	mg.set_process(false)                # la prueba avanza la simulación a mano
	mg.configure(0, seed_value, me)
	mg.prepare(lobby.players)
	mg.start(lobby.players)
	return mg

func _close(g) -> void:
	g.queue_free()

func _run(g, seconds: float, until_phase: int = -1) -> float:
	var t := 0.0
	while t < seconds:
		g._simulate(1.0 / 30.0)
		t += 1.0 / 30.0
		if until_phase >= 0 and g.debug_phase() == until_phase:
			break
	return t

func _process(_delta: float) -> bool:
	if _began:
		return true
	_began = true
	var f: Array[String] = []
	var PH = load("res://minigames/impostor/impostor.gd").Phase

	# 1) La nave.
	var g = _new_game(6, true, 99, 0)
	var ids: Array = []
	for p in g.players:
		ids.append(p.id)
	var imp: int = ids[0]
	var a: int = ids[1]
	var b: int = ids[2]
	var stations_ok := true
	for s in g.STATIONS.size():
		if not g.debug_station_wall_ok(s):
			stations_ok = false
	_ck(f, g.STATIONS.size() == 16 and stations_ok, "16 consolas, cada una en su sala y pegada a una pared")
	var cells: Array = g.debug_floor_cells()
	var reach := true
	for c in cells:
		if g.debug_path_dist(g.debug_table_pos() + Vector2(0, 2.7), c) >= 9999:
			reach = false
	_ck(f, cells.size() > 150 and reach, "toda la nave está conectada (%d celdas pisables)" % cells.size())
	var inside: Vector2 = g.debug_collide(g.debug_station_pos(0) + Vector2(0.0, -0.95))
	_ck(f, inside.distance_to(g.debug_station_pos(0) + Vector2(0.0, -0.95)) > 0.2, "las paredes y las consolas no se atraviesan")
	_ck(f, not g.debug_los(g.debug_station_pos(14), g.debug_station_pos(10)) and g.debug_los(g.debug_station_pos(0), g.debug_station_pos(1)), "las paredes tapan la vista; dentro de una sala se ve")

	# 2) Papeles y tareas.
	var n_imp := 0
	var tasks_ok := true
	for id in ids:
		var d: Dictionary = g.debug_player(id)
		if d.role == 1:
			n_imp += 1
		var seen := {}
		for t in d.tasks:
			seen[t] = true
		if seen.size() != g.TASKS_PER:
			tasks_ok = false
	_ck(f, n_imp == 1 and g.debug_player(imp).role == 1, "con 6 jugadores hay 1 impostor")
	_ck(f, tasks_ok, "cada jugador tiene %d tareas distintas" % g.TASKS_PER)
	_ck(f, g.debug_info().total == 5 * g.TASKS_PER, "la barra de tareas cuenta las de los 5 tripulantes")
	_ck(f, g.debug_phase() == PH.INTRO, "empieza con la presentación del papel")
	g.debug_skip_intro()

	# 3) Tareas.
	var st: int = g.debug_player(a).tasks[0]
	g.debug_place(a, g.debug_station_pos(st))
	g.debug_use(a)
	_ck(f, g.debug_player(a).station == st, "ESPACIO junto a una consola con tarea pendiente la empieza")
	g.debug_task_hit(a, false)
	_ck(f, g.debug_player(a).hits == 0, "fallar el marcador no cuenta")
	for i in 3:
		g.debug_task_hit(a, true)
	var da: Dictionary = g.debug_player(a)
	_ck(f, da.station == -1 and da.left == g.TASKS_PER - 1 and da.score == 1 and g.debug_info().done == 1, "tres aciertos completan la tarea (+1 punto y sube la barra)")
	g.debug_use(a)
	_ck(f, g.debug_player(a).station == -1, "una tarea hecha no se repite")
	var st2: int = g.debug_player(a).tasks[1]
	g.debug_place(a, g.debug_station_pos(st2))
	g.debug_use(a)
	g.debug_place(a, g.debug_station_pos(st2) + Vector2(3.0, 3.0))
	g._simulate(1.0 / 30.0)
	_ck(f, g.debug_player(a).station == -1, "alejarse de la consola cancela la tarea")
	var fake: int = g.debug_player(imp).tasks[0]
	g.debug_place(imp, g.debug_station_pos(fake))
	g.debug_use(imp)
	for i in 3:
		g.debug_task_hit(imp, true)
	_ck(f, g.debug_info().done == 1 and g.debug_player(imp).score == 0, "el impostor finge tareas: no suman")

	# 4) Eliminar.
	var spot: Vector2 = g.debug_station_pos(4)            # Navegación
	g.debug_place(a, spot)
	g.debug_place(imp, spot + Vector2(0.0, 1.2), 0.0)     # mira hacia -z, hacia a... (a está en -z)
	g.debug_place(a, spot + Vector2(0.0, 0.0))
	g.debug_set_cd(imp, 5.0)
	g.debug_secondary(imp)
	_ck(f, g.debug_player(a).alive, "con la recarga activa no se puede eliminar")
	g.debug_set_cd(imp, 0.0)
	g.debug_place(a, g.debug_station_pos(14))             # Motores: lejos
	g.debug_secondary(imp)
	_ck(f, g.debug_player(a).alive, "fuera de alcance no se puede eliminar")
	g.debug_place(a, spot)
	g.debug_place(imp, spot + Vector2(0.0, 1.2), PI)      # de espaldas
	g.debug_secondary(imp)
	_ck(f, g.debug_player(a).alive, "hay que tener a la víctima delante")
	g.debug_place(imp, spot + Vector2(0.0, 1.2), 0.0)
	g.debug_secondary(imp)
	var di: Dictionary = g.debug_player(imp)
	_ck(f, not g.debug_player(a).alive and g.debug_info().bodies == 1, "E elimina al tripulante de delante y deja un cadáver")
	_ck(f, di.kill_cd > 10.0 and di.score == 2 and (di.pos as Vector2).distance_to(spot) < 0.1, "el impostor recarga, suma 2 puntos y queda sobre la víctima")
	g.debug_secondary(a)
	g.debug_use(a)
	_ck(f, g.debug_phase() == PH.PLAY, "un fantasma no puede denunciar")

	# 5) Denunciar, votar y expulsar al impostor.
	g.debug_place(b, spot + Vector2(-1.0, 0.5))
	g.debug_use(b)
	var info: Dictionary = g.debug_info()
	_ck(f, info.phase == PH.SPLASH and info.by == b and info.victim == a and info.bodies == 0, "denunciar el cadáver abre la reunión y lo retira")
	_run(g, 4.0, PH.VOTE)
	_ck(f, g.debug_phase() == PH.VOTE and (g.debug_player(b).pos as Vector2).distance_to(g.debug_table_pos()) < 3.0, "todos van a la mesa de la cafetería a votar")
	g.debug_cast(a, imp)
	_ck(f, g.debug_player(a).vote == -2, "los fantasmas no votan")
	for id in ids:
		if id != imp and id != a:
			g.debug_cast(id, imp)
	g.debug_cast(imp, -1)
	_run(g, 3.0, PH.REVEAL)
	_ck(f, g.debug_phase() == PH.REVEAL and g.debug_info().ejected == imp, "el más votado es el expulsado (termina antes si todos han votado)")
	_run(g, 12.0, PH.END)
	info = g.debug_info()
	_ck(f, info.phase == PH.END and info.winner == 0 and info.reason == 0, "expulsar al impostor da la victoria a la tripulación")
	_ck(f, g.debug_player(b).score == 2 + 10 + 2, "votar al impostor da 2 puntos; ganar 10 y sobrevivir 2 (%d)" % g.debug_player(b).score)
	g.finished.connect(func(r: Array[int]) -> void: _ranking = r)
	_run(g, 8.0)
	_ck(f, _ranking.size() == 6 and _ranking[5] == imp, "el ranking incluye a los 6 y el impostor derrotado queda último")
	var groups: Array = g.result_groups()
	_ck(f, groups.size() == 2 and (groups[0] as Array).size() == 5 and groups[1] == [imp], "los 5 tripulantes ganadores forman un grupo empatado y el impostor, otro")
	# El reparto de puntos de la partida: todos los de un bando reciben lo mismo.
	var gm = root.get_node("GameManager")
	var lob = root.get_node("Lobby")
	for p in lob.players:
		p.score = 0
	var typed: Array[int] = []
	for id in _ranking:
		typed.append(int(id))
	gm.report_results(typed, groups)
	var crew_pts := {}
	for p in lob.players:
		if p.id != imp:
			crew_pts[p.score] = true
	_ck(f, crew_pts.size() == 1 and crew_pts.has(6) and lob.get_player(imp).score == 1, "en la partida, los 5 ganadores reciben los mismos puntos (6) y el impostor 1")
	for p in lob.players:
		p.score = 0
	_close(g)

	# 6) Empate o saltar: nadie sale. Botón de emergencia: una vez por jugador y con recarga.
	g = _new_game(6, true, 7, 0)
	ids.clear()
	for p in g.players:
		ids.append(p.id)
	imp = ids[0]
	a = ids[1]
	b = ids[2]
	g.debug_skip_intro()
	g.debug_place(a, g.debug_table_pos() + Vector2(0.0, 1.6))
	g.debug_use(a)
	_ck(f, g.debug_phase() == PH.PLAY, "el botón de emergencia tiene recarga al empezar")
	g.debug_set_cd(imp, 5.0, 0.0)
	g.debug_use(a)
	_ck(f, g.debug_phase() == PH.SPLASH and g.debug_info().victim == -1, "el botón de emergencia convoca la reunión")
	_run(g, 4.0, PH.VOTE)
	g.debug_cast(a, imp)
	g.debug_cast(b, ids[3])
	for id in ids:
		g.debug_cast(id, -1)
	_run(g, 3.0, PH.REVEAL)
	_ck(f, g.debug_info().ejected == -1, "con empate (o más votos en blanco) no se expulsa a nadie")
	_run(g, 12.0, PH.PLAY)
	_ck(f, g.debug_phase() == PH.PLAY and g.debug_player(imp).alive, "tras la reunión la partida sigue")
	_ck(f, g.debug_player(a).score == 2, "votar al impostor puntúa aunque no salga")
	g.debug_set_cd(imp, 5.0, 0.0)
	g.debug_place(a, g.debug_table_pos() + Vector2(0.0, 1.6))
	g.debug_use(a)
	_ck(f, g.debug_phase() == PH.PLAY and g.debug_player(a).meetings == 0, "cada jugador solo puede pulsar el botón una vez")

	# 7) Victoria del impostor: por número y por oxígeno.
	var crew: Array = ids.slice(1)
	for i in 4:
		g.debug_place(crew[i], g.debug_station_pos(12))
		g.debug_place(imp, g.debug_station_pos(12) + Vector2(0.0, 1.0), 0.0)
		g.debug_set_cd(imp, 0.0)
		g.debug_secondary(imp)
		g.debug_place(crew[i], Vector2(0, 0))
	info = g.debug_info()
	_ck(f, info.phase == PH.END and info.winner == 1 and info.reason == 1, "si queda un tripulante por impostor, gana el impostor")
	_ck(f, g.debug_player(imp).score == 4 * 2 + 10 + 2, "el impostor suma 2 por eliminación, 10 por ganar y 2 por sobrevivir")
	_close(g)
	g = _new_game(5, true, 3, 0)
	g.debug_skip_intro()
	g._time_left = 0.5
	_run(g, 2.0, PH.END)
	_ck(f, g.debug_info().winner == 1 and g.debug_info().reason == 3, "si se acaba el oxígeno gana el impostor")
	_close(g)

	# 8) Con 8 jugadores hay 2 impostores; el giro con ratón llega por el canal de texto.
	g = _new_game(8, true, 12345)
	n_imp = 0
	for p in g.players:
		if g.debug_player(p.id).role == 1:
			n_imp += 1
	_ck(f, n_imp == 2, "con 8 jugadores hay 2 impostores")
	_close(g)
	g = _new_game(7, true, 4321)
	n_imp = 0
	for p in g.players:
		if g.debug_player(p.id).role == 1:
			n_imp += 1
	_ck(f, n_imp == 1, "con 7 jugadores hay un solo impostor")
	var kinds := {}
	for st_def in g.STATIONS:
		kinds[st_def["type"]] = true
	_ck(f, kinds.size() == 5, "hay 5 tipos de misión distintos repartidos por las consolas")
	g.debug_skip_intro()
	var pid: int = g.players[0].id
	var yaw0: float = g.debug_player(pid).yaw
	g.deliver_player_text(g.players[0], "y1.25", false)
	_ck(f, absf(angle_difference(g.debug_player(pid).yaw, yaw0 + 1.25)) < 0.001, "el giro del ratón (y<ángulo>) se suma al del jugador")
	g.deliver_player_text(g.players[0], "hola", false)
	g.deliver_player_text(g.players[0], "ynan", false)
	_ck(f, absf(angle_difference(g.debug_player(pid).yaw, yaw0 + 1.25)) < 0.001, "texto que no es un giro válido se ignora")
	_close(g)

	# 8b) Controles de una persona (teclado 1): sin ratón gira con izq./der.; con ratón, izq./der. es paso lateral.
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	var human = lobby.add_player(PlayerData.DEVICE_KB1)
	for i in 4:
		lobby.add_bot()
	g = (load("res://minigames/impostor/meta.tres").scene as PackedScene).instantiate()
	g.debug_force_impostors = [lobby.players[1].id]
	root.add_child(g)
	g.set_process(false)
	g.configure(0, 5, null)
	g.prepare(lobby.players)
	g.start(lobby.players)
	g.debug_skip_intro()
	var hid: int = human.id
	var open_spot: Vector2 = g.debug_station_pos(8) + Vector2(4.0, -2.0)      # zona despejada del almacén
	g.debug_place(hid, open_spot, 0.0)
	Input.action_press("p%d_up" % hid)
	_run(g, 0.5)
	Input.action_release("p%d_up" % hid)
	var moved: Vector2 = (g.debug_player(hid).pos as Vector2) - open_spot
	_ck(f, g._view_id == hid and moved.y < -1.0 and absf(moved.x) < 0.05, "la vista es la de la persona de este PC; adelante avanza hacia donde mira")
	Input.action_press("p%d_right" % hid)
	_run(g, 0.5)
	var turned: float = g.debug_player(hid).yaw
	_ck(f, turned < -1.0, "sin ratón, derecha gira a la derecha (%.2f rad)" % turned)
	g.debug_place(hid, open_spot, 0.0)
	g._ps[hid].look = true
	_run(g, 0.5)
	Input.action_release("p%d_right" % hid)
	moved = (g.debug_player(hid).pos as Vector2) - open_spot
	_ck(f, moved.x > 1.0 and absf(g.debug_player(hid).yaw) < 0.001, "con ratón, derecha es paso lateral y no gira")
	# Misiones de flechas y de memoria con las teclas de una persona.
	var names := ["up", "right", "down", "left"]
	for kind in [g.T_ARROWS, g.T_MEMORY]:
		var sx: int = -1
		for cand in g.STATIONS.size():
			if g.STATIONS[cand]["type"] == kind:
				sx = cand
				break
		g._ps[hid].tasks[0] = sx
		g._ps[hid].done_mask = 0
		g.debug_place(hid, g.debug_station_pos(sx), 0.0)
		g.debug_use(hid)
		var before: int = g.debug_player(hid).left
		var here: Vector2 = g.debug_player(hid).pos
		if kind == g.T_MEMORY:
			Input.action_press("p%d_up" % hid)
			_run(g, 0.3)
			Input.action_release("p%d_up" % hid)
			_run(g, 0.1)
			_ck(f, g.debug_player(hid).hits == 0 and g.debug_player(hid).station == sx, "memoria: mientras se enseña la secuencia no se puede contestar")
			_run(g, 2.4)
		var wrong: int = (int(g.debug_seq(hid)[0]) + 2) % 4
		Input.action_press("p%d_%s" % [hid, names[wrong]])
		_run(g, 0.1)
		Input.action_release("p%d_%s" % [hid, names[wrong]])
		_ck(f, g.debug_player(hid).hits == 0, "una flecha equivocada no avanza")
		_run(g, 0.7 if kind == g.T_ARROWS else 3.2)
		for d in g.debug_seq(hid):
			Input.action_press("p%d_%s" % [hid, names[int(d)]])
			_run(g, 0.1)
			Input.action_release("p%d_%s" % [hid, names[int(d)]])
			_run(g, 0.3)
		var dh: Dictionary = g.debug_player(hid)
		_ck(f, dh.station == -1 and dh.left == before - 1, "%s: pulsar la secuencia correcta completa la misión" % ("flechas" if kind == g.T_ARROWS else "memoria"))
		_ck(f, (dh.pos as Vector2).distance_to(here) < 0.05, "durante una misión de flechas el jugador no se mueve")
	# Machacar y esperar.
	for kind in [g.T_MASH, g.T_WAIT]:
		var sy: int = -1
		for cand in g.STATIONS.size():
			if g.STATIONS[cand]["type"] == kind:
				sy = cand
				break
		g._ps[hid].tasks[1] = sy
		g._ps[hid].done_mask = 0
		g.debug_place(hid, g.debug_station_pos(sy), 0.0)
		g.debug_use(hid)
		if kind == g.T_MASH:
			_run(g, 0.4)
			for i in 13:
				g.debug_use(hid)
			_ck(f, g.debug_player(hid).station == sy, "machacar: con 13 pulsaciones aún no está")
			g.debug_use(hid)
			_ck(f, g.debug_player(hid).station == -1, "machacar: 14 pulsaciones completan la misión")
		else:
			_run(g, 5.0)
			_ck(f, g.debug_player(hid).station == sy, "esperar: a los 5 s aún no ha terminado")
			_run(g, 1.3)
			_ck(f, g.debug_player(hid).station == -1, "esperar: a los 6 s la misión se completa sola")
	g._use_look = true
	g._local_myaw = 0.8
	g._animate(1.0 / 60.0)
	_ck(f, absf(g.debug_player(hid).yaw - 0.8) < 0.001, "el giro local del ratón se aplica al jugador en el host")
	_close(g)

	# 9) Partida completa con 6 IAs y un cliente espejo.
	_ranking = []
	var g2 = _new_game(6, true, 31337)
	g2.finished.connect(func(r: Array[int]) -> void: _ranking = r)
	var host_players: Array = g2.players.duplicate()
	var client = _new_game(6, false, 31337)
	g2.players = client.players             # mismo reparto (los ids coinciden: se recrean en el mismo orden)
	var t := 0.0
	while t < 600.0 and _ranking.is_empty():
		g2._simulate(1.0 / 30.0)
		g2._animate(1.0 / 30.0)
		t += 1.0 / 30.0
		client.apply_state(g2.serialize_state())
		client._animate(1.0 / 30.0)
	var mirror_ok := true
	var roles_ok := true
	for p in client.players:
		var hd: Dictionary = g2.debug_player(p.id)
		var cd: Dictionary = client.debug_player(p.id)
		if hd.is_empty() or cd.is_empty():
			mirror_ok = false
			continue
		if int(hd.score) != int(cd.score) or hd.alive != cd.alive or (hd.pos as Vector2).distance_to(cd.pos as Vector2) > 0.01:
			mirror_ok = false
		if hd.role != cd.role or hd.tasks != cd.tasks:
			roles_ok = false
	var gi: Dictionary = g2.debug_info()
	print("  partida con 6 IAs: %.0f s, gana %s (%s), %d reuniones, tareas %d/%d, ranking %s" % [t, "tripulación" if gi.winner == 0 else "impostor",
			g2.REASONS[gi.reason], gi.meetings, gi.done, gi.total, _ranking])
	_ck(f, _ranking.size() == 6, "la partida termina sola y devuelve el ranking de los 6 (%.0f s)" % t)
	_ck(f, roles_ok, "host y cliente reparten los mismos papeles y tareas a partir de la semilla")
	_ck(f, mirror_ok and client.debug_phase() == PH.END, "el cliente refleja posiciones, vivos, puntos y fase del host")
	_ck(f, g2._built and g2._cam != null and client._built and g2._station_marks.size() == 16, "la escena 3D se construye (cámara, 16 consolas)")
	_ck(f, host_players.size() == 6, "(reparto del host intacto)")
	_close(g2)
	_close(client)

	# 10) Equilibrio: varias partidas de bots; ganan los dos bandos y ninguna se eterniza.
	var wins := [0, 0]
	var longest := 0.0
	var total_meet := 0
	var games := 0
	for count in [4, 5, 6, 7, 8]:
		var cw := 0
		for sd in 10:
			var gg = _new_game(count, true, 1000 + sd * 77 + count)
			var tt := 0.0
			while tt < 900.0 and gg.debug_phase() != PH.END:
				gg._simulate(1.0 / 20.0)
				tt += 1.0 / 20.0
			var inf: Dictionary = gg.debug_info()
			if inf.phase == PH.END:
				wins[inf.winner] += 1
				cw += 1 if inf.winner == 0 else 0
			longest = maxf(longest, tt)
			total_meet += int(inf.meetings)
			games += 1
			_close(gg)
		print("    con %d jugadores: tripulación %d de 10" % [count, cw])
	print("  %d partidas de bots: tripulación %d, impostor %d, la más larga %.0f s, %.1f reuniones de media" % [games, wins[0], wins[1], longest, float(total_meet) / games])
	_ck(f, wins[0] + wins[1] == games, "todas las partidas de bots terminan")
	_ck(f, wins[0] >= 10 and wins[1] >= 10, "ganan los dos bandos (tripulación %d, impostor %d)" % [wins[0], wins[1]])
	_ck(f, longest < 480.0, "ninguna partida se eterniza (%.0f s la más larga)" % longest)
	print("")
	if f.is_empty():
		print("IMPOSTOR TEST OK")
		quit(0)
	else:
		print("IMPOSTOR TEST FALLÓ: ", f)
		quit(1)
	return true

func _ck(f: Array[String], cond: bool, what: String) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		f.append(what)
		print("  ✗ " + what)
