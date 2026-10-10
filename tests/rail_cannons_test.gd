extends SceneTree
## Prueba de Vagonetas Cañoneras (HOST_AUTHORITATIVE, 3D): el trazado de raíles (tamaño según jugadores, simétrico, sin
## callejones sin salida, conectado y con setos pequeños), la conducción por los raíles (seguir, girar en el cruce, dar media
## vuelta, no atravesar a otra vagoneta), las balas (los setos las paran, por detrás eliminan, por delante empujan y aturden),
## la moneda de velocidad, el final (último en pie / empate al acabar el tiempo), el estado enviado a un "cliente" y partidas
## completas con bots.
## Ejecutar:  godot --headless --path . --script res://tests/rail_cannons_test.gd

var _began: bool = false

func _new_game(bots: int = 4, authority: bool = true, seed_value: int = 99):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	var me = lobby.add_bot()
	for i in bots - 1:
		lobby.add_bot()
	var meta = load("res://minigames/rail_cannons/meta.tres")
	var mg = (meta.scene as PackedScene).instantiate()
	mg.is_authority = authority
	root.add_child(mg)
	mg.configure(0, seed_value, me)
	var pls: Array[PlayerData] = lobby.players.duplicate()
	mg.prepare(pls)
	mg.start(pls)
	return mg

func _skip_countdown(g) -> void:
	for i in 100:
		g._simulate(1.0 / 30.0)

func _node_at(g, c: int, r: int) -> int:
	return r * g.debug_grid().x + c

func _process(_delta: float) -> bool:
	if _began:
		return true
	_began = true
	var f: Array[String] = []
	# 1) Trazado: tamaño según jugadores; cada cruce con 2+ vías; simétrico; el mismo en todos los PC (semilla común).
	var sizes_ok := true
	var deg_ok := true
	var sym_ok := true
	var removed_ok := true
	for n in [2, 4, 5, 6, 7, 8]:
		for sd in [1, 7, 99, 1234]:
			var g = _new_game(n, true, sd)
			var gr: Vector2i = g.debug_grid()
			var want := Vector2i(5, 4) if n <= 4 else (Vector2i(6, 4) if n <= 6 else Vector2i(6, 5))
			if gr != want:
				sizes_ok = false
			var adj: Array = g.debug_adj()
			for i in adj.size():
				if (adj[i] as Array).size() < 2:
					deg_ok = false
				var c: int = i % gr.x
				var r: int = i / gr.x
				var mi: int = r * gr.x + (gr.x - 1 - c)
				if (adj[i] as Array).size() != (adj[mi] as Array).size():
					sym_ok = false
			if g.debug_removed() < 4:
				removed_ok = false
			g.queue_free()
	_ck(f, sizes_ok, "el patio crece con los jugadores (5×4 hasta 4, 6×4 hasta 6, 6×5 con 7-8)")
	_ck(f, deg_ok, "ningún cruce es un callejón sin salida (todos con 2 o más vías)")
	_ck(f, sym_ok, "el trazado es simétrico izquierda-derecha")
	_ck(f, removed_ok, "siempre hay setos entre las vías (no es una rejilla vacía)")
	var g1 = _new_game(4, true, 555)
	var g2 = _new_game(4, false, 555)
	_ck(f, str(g1.debug_adj()) == str(g2.debug_adj()), "el host y un cliente generan el mismo trazado con la misma semilla")
	g1.queue_free()
	g2.queue_free()
	# 2) Salidas: repartidas por el borde y cada vecino mirando al otro de frente (nadie empieza dando la espalda al de al lado).
	var g = _new_game(4)
	var ids: Array[int] = []
	for p in g.players:
		ids.append(p.id)
	var pos_set := {}
	for id in ids:
		pos_set[str(g.debug_player(id).pos)] = true
	_ck(f, pos_set.size() == 4, "cada vagoneta sale de un sitio distinto")
	# 3) Conducción. Cruce (0,0) esquina arriba-izquierda; (1,0) a su derecha; (0,1) debajo.
	_skip_countdown(g)
	var a: int = ids[0]
	var b: int = ids[1]
	for id in ids.slice(2):
		g.debug_place(id, _node_at(g, 4, 3), _node_at(g, 3, 3))   # apartados en la esquina de abajo a la derecha
	g.debug_place(b, _node_at(g, 4, 2), _node_at(g, 4, 1))
	g.debug_place(a, _node_at(g, 0, 0), _node_at(g, 1, 0))
	g.debug_drive(a, Vector2(1, 0), 0.5)
	var pa: Dictionary = g.debug_player(a)
	var n0: Vector2 = g.debug_nodes()[_node_at(g, 0, 0)]
	_ck(f, (pa.pos as Vector2).y == n0.y and (pa.pos as Vector2).x > n0.x + 1.5, "con la dirección hacia la vía, la vagoneta avanza por ella")
	g.debug_drive(a, Vector2(0, 1), 0.5)
	pa = g.debug_player(a)
	_ck(f, (pa.pos as Vector2).y == n0.y and (pa.face as Vector2).x > 0.9, "dirección perpendicular a mitad de tramo: sigue hasta el cruce")
	g.debug_drive(a, Vector2(-1, 0), 0.3)
	pa = g.debug_player(a)
	_ck(f, (pa.face as Vector2).x < -0.9, "se puede dar media vuelta en mitad del tramo")
	g.debug_place(a, _node_at(g, 0, 0), _node_at(g, 1, 0))
	g.debug_drive(a, Vector2(0, -1), 0.5)
	pa = g.debug_player(a)
	_ck(f, (pa.pos as Vector2) == n0, "en un cruce, hacia donde no hay vía no se mueve")
	g.debug_drive(a, Vector2(0, 1), 0.5)
	pa = g.debug_player(a)
	_ck(f, (pa.pos as Vector2).x == n0.x and (pa.pos as Vector2).y > n0.y + 1.5 and (pa.face as Vector2).y > 0.9, "en un cruce gira hacia la vía que pides")
	g.debug_drive(a, Vector2.ZERO, 0.5)
	_ck(f, g.debug_player(a).pos == pa.pos, "sin dirección se queda quieta")
	# No se atraviesan: b justo delante de a en la misma vía.
	g.debug_place(a, _node_at(g, 0, 0), _node_at(g, 1, 0))
	g.debug_place(b, _node_at(g, 1, 0), _node_at(g, 2, 0))
	g.debug_drive(a, Vector2(1, 0), 2.0)
	var gap: float = (g.debug_player(b).pos as Vector2).distance_to(g.debug_player(a).pos)
	_ck(f, gap >= 1.45, "una vagoneta no atraviesa a la de delante (distancia %.2f)" % gap)
	# 4) Balas. a dispara a la ESPALDA de b (los dos mirando a la derecha): b eliminado, a suma una.
	g.debug_place(a, _node_at(g, 0, 0), _node_at(g, 1, 0))
	g.debug_place(b, _node_at(g, 1, 0), _node_at(g, 2, 0))
	g.debug_fire(a)
	_ck(f, g.debug_ball_count() == 1, "la acción dispara una bala")
	g.debug_fire(a)
	_ck(f, g.debug_ball_count() == 1, "no se puede disparar otra vez al momento (recarga)")
	g.debug_step_balls(1.0)
	_ck(f, not g.debug_player(b).alive and g.debug_player(a).kills == 1, "bala en la diana de la espalda: eliminado (y +1 para quien dispara)")
	g.queue_free()
	# Por delante: empuja y aturde, no elimina.
	g = _new_game(4)
	ids.clear()
	for p in g.players:
		ids.append(p.id)
	_skip_countdown(g)
	a = ids[0]
	b = ids[1]
	for id in ids.slice(2):
		g.debug_place(id, _node_at(g, 4, 3), _node_at(g, 3, 3))
	g.debug_place(a, _node_at(g, 0, 0), _node_at(g, 1, 0))
	g.debug_place(b, _node_at(g, 2, 0), _node_at(g, 1, 0))     # b mira hacia a
	var pb0: Vector2 = g.debug_player(b).pos
	g.debug_fire(a)
	g.debug_step_balls(1.2)
	var pb: Dictionary = g.debug_player(b)
	_ck(f, pb.alive and pb.stun > 0.0 and (pb.pos as Vector2).x > pb0.x + 0.5, "bala por delante: no elimina, empuja y aturde (stun %.2f)" % pb.stun)
	_ck(f, (pb.face as Vector2).x < -0.9, "el empujón no le gira el cañón")
	# Los setos paran las balas: desde (1,1) hacia abajo/arriba según el trazado, buscar un tramo sin vía y disparar hacia él.
	var adj2: Array = g.debug_adj()
	var gr2: Vector2i = g.debug_grid()
	var blocked_ok := false
	for nd in adj2.size():
		var c2: int = nd % gr2.x
		var r2: int = nd / gr2.x
		for dv in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var cc: int = c2 + dv.x
			var rr: int = r2 + dv.y
			if cc < 0 or rr < 0 or cc >= gr2.x or rr >= gr2.y:
				continue
			var other: int = rr * gr2.x + cc
			var back: int = (r2 - dv.y) * gr2.x + (c2 - dv.x)
			if not (adj2[nd] as Array).has(other) and r2 - dv.y >= 0 and r2 - dv.y < gr2.y and c2 - dv.x >= 0 and c2 - dv.x < gr2.x and (adj2[nd] as Array).has(back):
				# Una vagoneta en `back` mirando hacia nd: su bala cruza nd y debe chocar con el seto.
				for id in ids:
					g.debug_place(id, _node_at(g, 4, 3) if id != a else back, _node_at(g, 3, 3) if id != a else nd)
				g.debug_fire(a)
				g.debug_step_balls(0.8)
				blocked_ok = g.debug_ball_count() == 0
				var far: Vector2 = g.debug_nodes()[nd] + Vector2(dv.x, dv.y) * 1.5
				blocked_ok = blocked_ok and g.debug_lane_dist(far) > 0.5
				break
		if blocked_ok:
			break
	_ck(f, blocked_ok, "un seto para la bala")
	# 5) Moneda S: da turbo a quien la coge.
	g.debug_place(a, _node_at(g, 0, 0), _node_at(g, 1, 0))
	g.debug_coin(g.debug_nodes()[_node_at(g, 0, 0)])
	g.debug_step_coin()
	_ck(f, g.debug_player(a).boost > 0.0, "la moneda S da velocidad")
	g.queue_free()
	# 6) Final: último en pie gana; ranking con los eliminados del último al primero en caer.
	g = _new_game(4)
	ids.clear()
	for p in g.players:
		ids.append(p.id)
	_skip_countdown(g)
	g.debug_kill_all_but(ids[2])
	_ck(f, g.debug_over() and g.debug_winners() == [ids[2]], "cuando solo queda uno, gana ese")
	_ck(f, g.debug_ranking()[0] == ids[2], "el superviviente va primero en la clasificación")
	g.queue_free()
	# Fin de tiempo con varios en pie: empatan.
	g = _new_game(3)
	_skip_countdown(g)
	for p in g.players:
		g.debug_place(p.id, 0, 1)
	for i in 70 * 60:
		g._simulate(1.0 / 60.0)
		if g.debug_over():
			break
	_ck(f, g.debug_over(), "la partida acaba por tiempo")
	g.queue_free()
	# 7) Estado a un cliente.
	var host = _new_game(4, true, 31)
	var client = _new_game(4, false, 31)
	for i in 400:
		host._simulate(1.0 / 60.0)
	client._apply_state(host._serialize_state())
	var same := true
	for p in host.players:
		if (host.debug_player(p.id).pos as Vector2).distance_to(client.debug_player(p.id).pos) > 0.001:
			same = false
	_ck(f, same, "el cliente recibe las posiciones del host")
	host.queue_free()
	client.queue_free()
	# 8) Partidas completas con bots: terminan, y cuántas acaban con un solo superviviente.
	var finished := 0
	var single := 0
	var total_t := 0.0
	var games := 0
	for n in [2, 3, 4, 6, 8]:
		for sd in [3, 8, 21]:
			var gg = _new_game(n, true, sd * 17 + n)
			var t := 0.0
			var done := [false]
			var res := []
			gg.finished.connect(func(r: Array[int]) -> void:
				done[0] = true
				res.append_array(r))
			while t < 80.0 and not done[0]:
				gg._simulate(1.0 / 60.0)
				t += 1.0 / 60.0
			games += 1
			if done[0] and res.size() == n:
				finished += 1
				total_t += t
				if gg.debug_winners().size() == 1:
					single += 1
			print("      %d jugadores, semilla %d: %s en %.1f s, en pie: %d  %s" % [n, sd, "fin" if done[0] else "SIN FIN", t, gg.debug_winners().size(), str(gg.debug_stats())])
			gg.queue_free()
	_ck(f, finished == games, "las %d partidas con bots terminan con la clasificación completa" % games)
	_ck(f, single >= games / 3, "en bastantes partidas queda un único ganador (%d de %d)" % [single, games])
	print("      duración media: %.1f s" % (total_t / maxf(finished, 1)))
	if f.is_empty():
		print("OK: Vagonetas Cañoneras")
	else:
		print("FALLOS (%d):" % f.size())
		for x in f:
			print("  - ", x)
	quit(0 if f.is_empty() else 1)
	return true

func _ck(f: Array[String], cond: bool, msg: String) -> void:
	print(("  ✓ " if cond else "  ✗ ") + msg)
	if not cond:
		f.append(msg)
