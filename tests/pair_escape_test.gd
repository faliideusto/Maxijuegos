extends SceneTree
## Prueba de Fuga en Pareja (HOST_AUTHORITATIVE, 3D, por parejas): solo entra con número par de jugadores, el laberinto
## (superable, rejas que de verdad cortan el paso, igual para la misma semilla), tropezar al salirse, rejas que solo abren
## los dos a la vez, la columna y las rejas como paredes, escapar, el reparto en parejas, partidas enteras con bots
## (2, 4 y 8 jugadores), los puestos compartidos de cada pareja y el estado enviado a un "cliente".
## Ejecutar:  godot --headless --path . --script res://tests/pair_escape_test.gd

var _began: bool = false

func _new_game(count: int, authority: bool = true, seed_value: int = 77):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	var me = lobby.add_bot()
	for i in count - 1:
		lobby.add_bot()
	var meta = load("res://minigames/pair_escape/meta.tres")
	var mg = (meta.scene as PackedScene).instantiate()
	mg.meta = meta
	mg.is_authority = authority
	root.add_child(mg)
	mg.configure(0, seed_value, me)
	mg.prepare(lobby.players)
	mg.start(lobby.players)
	return mg

func _skip_countdown(g) -> void:
	for i in 100:
		g._simulate(1.0 / 30.0)

## Partida entera con bots; devuelve el ranking (o vacío si no acaba).
func _play_out(g, max_seconds: float = 75.0) -> Array:
	var got: Array = []
	g.finished.connect(func(r: Array[int]) -> void: got.assign(r))
	var t := 0.0
	while got.is_empty() and t < max_seconds:
		g._simulate(1.0 / 60.0)
		t += 1.0 / 60.0
	return got

func _process(_delta: float) -> bool:
	if _began:
		return true
	_began = true
	var f: Array[String] = []
	# 1) Solo con número par.
	var meta: MinigameMeta = load("res://minigames/pair_escape/meta.tres")
	_ck(f, meta.supports(2) and meta.supports(4) and meta.supports(6) and meta.supports(8), "admite 2, 4, 6 y 8 jugadores")
	_ck(f, not meta.supports(3) and not meta.supports(5) and not meta.supports(7), "no admite 3, 5 ni 7 (impares)")
	var reg = root.get_node("MinigameRegistry")
	var in3 := false
	for m in reg.get_compatible(3):
		if m.id == &"pair_escape":
			in3 = true
	_ck(f, not in3, "con 3 jugadores no está entre los compatibles de la rotación")
	var in4 := false
	for m in reg.get_compatible(4):
		if m.id == &"pair_escape":
			in4 = true
	_ck(f, in4, "con 4 jugadores sí está en la rotación")
	# 2) Laberinto: superable con las rejas abiertas, imposible con ellas cerradas; misma semilla → mismo laberinto.
	var bad_seeds := 0
	for sd in 40:
		var gg = _new_game(2, true, 1000 + sd)
		if gg.debug_shortest(true) <= 0 or gg.debug_shortest(false) > 0:
			bad_seeds += 1
		gg.free()
	_ck(f, bad_seeds == 0, "40 laberintos: todos superables con las rejas abiertas y cerrados sin abrirlas (fallos: %d)" % bad_seeds)
	var g1 = _new_game(4, true, 5)
	var g2 = _new_game(4, true, 5)
	var same := true
	for row in 41:
		for col in 5:
			if g1.debug_kind(row, col) != g2.debug_kind(row, col):
				same = false
	_ck(f, same, "misma semilla → mismo laberinto (todos los PC ven lo mismo)")
	g2.free()
	_ck(f, g1.debug_gate_rows().size() == 3, "3 rejas en el recorrido")
	# 3) Parejas: 4 jugadores → 2 parejas de 2, cada uno a un lado de la columna.
	var pairs: Array = g1.debug_pairs()
	var all_ids := {}
	var ok_pairs := pairs.size() == 2
	for pa in pairs:
		if pa.members.size() != 2:
			ok_pairs = false
		for m in pa.members:
			all_ids[m] = true
		if ok_pairs and g1.debug_player(pa.members[0]).side == g1.debug_player(pa.members[1]).side:
			ok_pairs = false
	_ck(f, ok_pairs and all_ids.size() == 4, "4 jugadores → 2 parejas, cada miembro a un lado de la columna")
	# 4) Tropezar al salirse del camino y volver a la baldosa segura.
	_skip_countdown(g1)
	var a: int = pairs[0].members[0]
	var b: int = pairs[0].members[1]
	g1.debug_place(a, Vector2i(0, 4))
	g1.debug_step(a, Vector2(1, 0), 0.8)                  # hacia fuera: no hay suelo más allá de la columna 4
	var pa_a: Dictionary = g1.debug_player(a)
	_ck(f, pa_a.stun > 0.0 and pa_a.tile == Vector2i(0, 4), "salirse del camino → tropieza y vuelve a la última baldosa segura")
	g1.debug_place(a, Vector2i(0, 0))
	g1.debug_step(a, Vector2(-1, 0), 0.6)                 # hacia la columna: es pared, no se tropieza
	pa_a = g1.debug_player(a)
	_ck(f, pa_a.stun <= 0.0 and pa_a.pos.x >= 0.0, "la columna central es pared: se choca sin tropezar")
	# 5) Rejas: cerrada = pared; una sola persona en la baldosa roja no abre; las dos a la vez, sí.
	var gr: int = g1.debug_gate_rows()[0]
	g1.debug_place(a, Vector2i(gr - 1, 0))
	g1.debug_step(a, Vector2(0, 1), 0.8)
	pa_a = g1.debug_player(a)
	_ck(f, pa_a.tile.x == gr - 1 and pa_a.stun <= 0.0 and not g1.debug_pairs()[0].open[0], "la reja cerrada para el paso y uno solo en la baldosa roja no la abre")
	g1.debug_place(b, Vector2i(gr - 1, 0))
	g1.debug_step(b, Vector2.ZERO, 0.05)
	_ck(f, g1.debug_pairs()[0].open[0], "los dos a la vez en su baldosa roja → se abre la reja")
	_ck(f, not g1.debug_pairs()[1].open[0], "la reja de la otra pareja sigue cerrada")
	g1.debug_step(a, Vector2(0, 1), 0.7)
	_ck(f, g1.debug_player(a).tile.x >= gr, "con la reja abierta se pasa")
	# 6) Escapar: los dos en la salida → la pareja escapa.
	g1.debug_place(a, Vector2i(39, 2))
	g1.debug_step(a, Vector2(0, 1), 0.5)
	_ck(f, g1.debug_player(a).escaped and not g1.debug_pairs()[0].escaped, "uno en la salida: escapa él, la pareja aún no")
	g1.debug_place(b, Vector2i(39, 2))
	g1.debug_step(b, Vector2(0, 1), 0.5)
	_ck(f, g1.debug_pairs()[0].escaped, "los dos fuera → la pareja escapa")
	g1.free()
	# 7) Partidas enteras con bots.
	for n in [2, 4, 8]:
		var g = _new_game(n, true, 300 + n)
		var rk: Array = _play_out(g)
		var esc := 0
		for pa in g.debug_pairs():
			if pa.escaped:
				esc += 1
		_ck(f, rk.size() == n, "%d jugadores: la partida termina con todos en el ranking" % n)
		_ck(f, esc >= maxi(1, (n / 2) - 1), "%d jugadores: los bots escapan (%d de %d parejas)" % [n, esc, n / 2])
		# Las parejas quedan juntas en el ranking y comparten puesto.
		var groups: Array = g.result_groups()
		var together: bool = groups.size() == n / 2
		for gp in groups:
			var i0: int = rk.find(gp[0])
			var i1: int = rk.find(gp[1])
			if absi(i0 - i1) != 1:
				together = false
		_ck(f, together, "%d jugadores: cada pareja va seguida en el ranking y es un grupo de puesto compartido" % n)
		if n == 2:
			var pts: Dictionary = g.result_points()
			var expect: int = 2 if g.debug_pairs()[0].escaped else 1
			_ck(f, pts.size() == 2 and int(pts.values()[0]) == expect, "2 jugadores: puntos fijos según escapen (%d)" % expect)
		else:
			_ck(f, g.result_points().is_empty(), "%d jugadores: puntos por puesto normal" % n)
		g.free()
	# 8) Estado al "cliente": posiciones, rejas y escapes.
	var host = _new_game(4, true, 9)
	var client = _new_game(4, false, 9)
	_skip_countdown(host)
	for i in 600:
		host._simulate(1.0 / 60.0)
	client.apply_state(host.serialize_state())
	var match_ok: bool = true
	for pa in host.debug_pairs():
		for m in pa.members:
			if client.debug_player(m).pos.distance_to(host.debug_player(m).pos) > 0.001:
				match_ok = false
	for i in host.debug_pairs().size():
		if host.debug_pairs()[i].open != client.debug_pairs()[i].open:
			match_ok = false
	_ck(f, match_ok, "el cliente recibe posiciones y rejas igual que el host")
	host.free()
	client.free()
	if f.is_empty():
		print("pair_escape_test: OK")
	else:
		print("pair_escape_test: FALLOS")
		for x in f:
			print("  - ", x)
	quit(0 if f.is_empty() else 1)
	return true

func _ck(f: Array[String], cond: bool, what: String) -> void:
	print(("  ok  " if cond else "  FALLO  ") + what)
	if not cond:
		f.append(what)
