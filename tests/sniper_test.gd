extends SceneTree
## Prueba de Francotiradores (HOST_AUTHORITATIVE, 3D en primera persona): mapa simétrico que se adapta al nº de jugadores,
## puntos de aparición libres y conectados (la IA llega a todos), un disparo con mira es una baja y las paredes la paran,
## protección de aparición, cerrojo, vallas que se saltan y paredes que no, mirada/disparo que llegan por texto desde el
## PC de cada persona, partidas de 2 minutos solo con bots (hay bajas, todos reaparecen, ranking por bajas) y estado
## completo para un "cliente".
## Ejecutar:  godot --headless --path . --script res://tests/sniper_test.gd

var _began: bool = false

func _new_game(seed_value: int, bots: int = 4, authority: bool = true, human: bool = false):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	var me = lobby.add_player("kb1") if human else lobby.add_bot()
	for i in bots - 1:
		lobby.add_bot()
	var meta = load("res://minigames/sniper_town/meta.tres")
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
	var Sniper = load("res://minigames/sniper_town/sniper_town.gd")
	# 1) Mapa: tamaño según jugadores, simetría y puntos de aparición libres.
	for n in [2, 4, 5, 8]:
		var g = _new_game(1, n)
		var big: bool = g.debug_big()
		_ck(f, big == (n >= 5), "%d jugadores → patios %s" % [n, "abiertos" if big else "cerrados"])
		var spawns: Array[Vector3] = g.debug_spawns()
		_ck(f, spawns.size() >= n + 2, "hay sitio para aparecer (%d puntos para %d)" % [spawns.size(), n])
		var free := true
		var sym := true
		for s in spawns:
			if g.debug_blocked(s.x, s.y) or absf(s.x) > g.debug_bounds().x or absf(s.y) > g.debug_bounds().y:
				free = false
			if not g.debug_blocked(-s.x, -s.y) == g.debug_blocked(s.x, s.y):
				sym = false
		_ck(f, free, "ningún punto de aparición dentro de una pared o fuera del mapa")
		# Todos los puntos conectados (la IA puede llegar a cualquier sitio).
		var connected := true
		for s in spawns:
			var path: PackedVector2Array = g.nav_path(Vector2(spawns[0].x, spawns[0].y), Vector2(s.x, s.y))
			if path.is_empty() or path[path.size() - 1].distance_to(Vector2(s.x, s.y)) > 1.0:
				connected = false
		_ck(f, connected, "hay camino entre todos los puntos de aparición")
		var sym_ok := true
		for x in range(-28, 29, 3):
			for z in range(-18, 19, 3):
				if g.debug_blocked(float(x) + 0.3, float(z) + 0.7) != g.debug_blocked(-float(x) - 0.3, -float(z) - 0.7):
					sym_ok = false
		_ck(f, sym and sym_ok, "el mapa es simétrico (las dos mitades iguales)")
		g.free()
	# 2) Disparos: con mira y a campo abierto es una baja; una pared la para; la protección de aparición también.
	var g2 = _new_game(3, 3)
	var a: int = g2.players[0].id
	var b: int = g2.players[1].id
	var c: int = g2.players[2].id
	g2.debug_place(c, 0.0, 18.0, 0.0)
	g2.debug_place(a, -9.0, -1.0, 0.0)
	g2.debug_place(b, -9.0, -12.0, 0.0)              # 11 m delante, por la calle
	g2.debug_aim_at(a, b)
	g2.debug_fire(a)
	_ck(f, not bool(g2.debug_sp(b).alive) and int(g2.debug_sp(a).kills) == 1 and int(g2.debug_sp(b).deaths) == 1, "un tiro con mira es una baja")
	_ck(f, float(g2.debug_sp(a).cd) > 1.0, "después hay que recargar el cerrojo")
	# Pared: a fuera de la casa oeste, b dentro detrás de la pared lateral.
	g2.debug_place(b, -23.0, 3.0, 0.0)
	g2.debug_place(a, -23.0, 13.0, PI)
	g2.debug_aim_at(a, b)
	g2.debug_fire(a)
	_ck(f, bool(g2.debug_sp(b).alive), "la pared del garaje para el tiro")
	# Por la ventana delantera sí.
	g2.debug_place(b, -18.0, 3.6, 0.0)
	g2.debug_place(a, -6.0, 3.6, 0.0)
	var hit: Dictionary = g2.debug_raycast(Vector3(-6.0, 1.6, 3.6), Sniper.aim_dir(Sniper.yaw_to(-12.0, 0.0), 0.0), a)
	_ck(f, int(hit.v) == b, "se puede disparar por la ventana (%s)" % str(hit))
	hit = g2.debug_raycast(Vector3(-6.0, 0.6, 3.6), Sniper.aim_dir(Sniper.yaw_to(-12.0, 0.0), 0.0), a)
	_ck(f, int(hit.v) == -1, "bajo la ventana la pared cubre")
	# Protección de aparición.
	g2.debug_place(b, -9.0, -12.0, 0.0)
	g2.debug_place(a, -9.0, -1.0, 0.0)
	g2._sp[b].inv_t = 1.0
	g2.debug_aim_at(a, b)
	g2.debug_fire(a)
	_ck(f, bool(g2.debug_sp(b).alive), "con protección de aparición no muere")
	# Sin mira el tiro se abre: de 60 tiros lejanos no aciertan todos.
	var hits := 0
	for i in 60:
		g2.debug_place(b, -7.0, -14.0, 0.0)
		g2.debug_place(a, -7.0, 13.0, 0.0)
		g2.debug_aim_at(a, b)
		g2.debug_fire(a, false)
		if not bool(g2.debug_sp(b).alive):
			hits += 1
	_ck(f, hits > 0 and hits < 45, "sin mira, a 27 m, se falla a menudo (%d/60)" % hits)
	g2.debug_place(b, -7.0, -14.0, 0.0)
	g2.debug_place(a, -7.0, 13.0, 0.0)
	g2.debug_aim_at(a, b)
	g2.debug_fire(a)
	_ck(f, not bool(g2.debug_sp(b).alive), "con mira, a 27 m, se acierta")
	# 3) Movimiento: las paredes paran, la valla blanca se salta, la reaparición llega.
	g2.debug_place(a, -14.0, 0.0, 0.0)
	for i in 120:
		g2.debug_step(a, Vector2(-1, 0))
	_ck(f, float(g2.debug_sp(a).x) < -16.0, "entra por la puerta de la casa (x=%.1f)" % float(g2.debug_sp(a).x))
	g2.debug_place(a, -14.0, -2.0, 0.0)
	for i in 120:
		g2.debug_step(a, Vector2(-1, 0))
	_ck(f, float(g2.debug_sp(a).x) > -15.7, "la pared delantera no se atraviesa (x=%.2f)" % float(g2.debug_sp(a).x))
	g2.debug_place(a, -12.0, -8.0, 0.0)
	for i in 90:
		g2.debug_step(a, Vector2(-1, 0))
	_ck(f, float(g2.debug_sp(a).x) > -13.0, "la valla blanca frena andando")
	g2.debug_place(a, -12.0, -8.0, 0.0)
	for i in 90:
		g2.debug_step(a, Vector2(-1, 0), i == 6)
	_ck(f, float(g2.debug_sp(a).x) < -13.5, "saltando se pasa la valla (x=%.1f)" % float(g2.debug_sp(a).x))
	g2.debug_place(b, -9.0, -12.0, 0.0)
	g2.debug_place(a, -9.0, -1.0, 0.0)
	g2.debug_aim_at(a, b)
	g2.debug_fire(a)
	for i in 60 * 3:
		g2.debug_step(b, Vector2.ZERO)
	_ck(f, bool(g2.debug_sp(b).alive) and float(g2.debug_sp(b).inv) > 0.0, "reaparece a los pocos segundos con protección")
	g2.free()
	# 4) Persona en este PC: la mirada y el disparo llegan por texto (como desde otro PC).
	var g3 = _new_game(4, 2, true, true)
	var hu: int = g3.players[0].id
	var bo: int = g3.players[1].id
	g3.debug_place(hu, -9.0, -1.0, 0.0)
	g3.debug_place(bo, -9.0, -12.0, 0.0)
	var want_y: float = Sniper.yaw_to(0.0, -11.0)
	var want_p: float = atan2(1.2 - 1.6, 11.0)
	g3._on_player_text(g3.players[0], "a:%.3f:%.3f:1:0:0" % [want_y, want_p], false)
	_ck(f, absf(float(g3.debug_sp(hu).yaw) - want_y) < 0.01 and bool(g3.debug_sp(hu).scoped), "la mirada y la mira llegan por texto")
	g3._sp[hu].scope_t = 1.0
	g3._on_player_text(g3.players[0], "f:%.4f:%.4f:1" % [want_y, want_p], true)
	g3._sim_step(g3._sp[hu], g3.players[0], 1.0 / 60.0)
	_ck(f, int(g3.debug_sp(hu).kills) == 1, "el disparo enviado por texto mata")
	g3._on_player_text(g3.players[0], "a:nan:0:1:0:0", false)
	g3._on_player_text(g3.players[0], "zz", false)
	_ck(f, is_finite(float(g3.debug_sp(hu).yaw)), "se ignoran mensajes rotos")
	g3.free()
	# 5) Partidas completas solo con bots.
	for cfg in [[2, 21], [4, 22], [8, 23]]:
		var n: int = cfg[0]
		var g = _new_game(cfg[1], n)
		var t0 := Time.get_ticks_msec()
		var steps := 0
		var moved := {}
		var last := {}
		for p in g.players:
			moved[p.id] = 0.0
			last[p.id] = Vector2(float(g.debug_sp(p.id).x), float(g.debug_sp(p.id).z))
		while not g.debug_over() and steps < 60 * 130:
			g._simulate(1.0 / 60.0)
			steps += 1
			if steps % 30 == 0:
				for p in g.players:
					var pos := Vector2(float(g.debug_sp(p.id).x), float(g.debug_sp(p.id).z))
					moved[p.id] = float(moved[p.id]) + pos.distance_to(last[p.id])
					last[p.id] = pos
		var ms := Time.get_ticks_msec() - t0
		var kills: Array[int] = []
		var total := 0
		var min_moved := INF
		for p in g.players:
			kills.append(int(g.debug_sp(p.id).kills))
			total += int(g.debug_sp(p.id).kills)
			min_moved = minf(min_moved, float(moved[p.id]))
		var rk: Array[int] = g.ranking_ids()
		var sorted_ok := true
		for i in rk.size() - 1:
			if int(g.debug_sp(rk[i]).kills) < int(g.debug_sp(rk[i + 1]).kills):
				sorted_ok = false
		print("  %d bots: bajas %s (total %d), el que menos anda %.0f m, %d ms de simulación" % [n, str(kills), total, min_moved, ms])
		_ck(f, g.debug_over() and absf(g.debug_time() - 120.0) < 0.5, "la partida dura 2 minutos")
		_ck(f, total >= n * 2, "hay bajas (%d)" % total)
		_ck(f, sorted_ok and g.debug_winner() == rk[0], "ranking por bajas y gana el primero")
		_ck(f, min_moved > 40.0, "ningún bot se queda atascado (%.0f m)" % min_moved)
		var cl = _new_game(cfg[1], n, false)
		cl._apply_state(g._serialize_state())
		var same := true
		for p in g.players:
			if int(cl.debug_sp(p.id).kills) != int(g.debug_sp(p.id).kills) or absf(float(cl.debug_sp(p.id).x) - float(g.debug_sp(p.id).x)) > 0.01:
				same = false
		_ck(f, same and cl._sp[cl._order[0]].node != null, "el cliente recibe el estado y tiene un personaje por jugador")
		g.free()
		cl.free()
	if f.is_empty():
		print("SNIPER TEST OK")
	else:
		print("SNIPER TEST FAILED:")
		for m in f:
			print("  - ", m)
	quit(0 if f.is_empty() else 1)
	return true

func _ck(f: Array[String], cond: bool, msg: String) -> void:
	print(("  ok  " if cond else "  FALLO  ") + msg)
	if not cond:
		f.append(msg)
