extends SceneTree
## Prueba de Mecha Corta (sin red): tablero según jugadores, explosiones, cadenas, mejoras, paso por petardos,
## cierre final, empates, cliente y partidas completas con bots.
## Ejecutar:  godot --headless --path . --script res://tests/short_fuse_test.gd

var _began: bool = false
var _ranking: Array = []

func _new_game(n_bots: int, game_seed: int = 1):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	for i in n_bots:
		lobby.add_bot()
	var meta = load("res://minigames/short_fuse/meta.tres")
	var mg = (meta.scene as PackedScene).instantiate()
	root.add_child(mg)
	mg.set_process(false)
	mg.configure(0, game_seed, null)
	mg.prepare(lobby.players)
	_ranking = []
	mg.finished.connect(func(r: Array) -> void: _ranking = r)
	mg.start(lobby.players)
	return mg

# Deja el tablero sin cajas y a los bots quietos, para montar situaciones a mano.
func _clear(g) -> void:
	for i in g._grid.size():
		if g._grid[i] == g.CRATE:
			g._grid[i] = g.EMPTY
	for t in g._tokens:
		t.bot_timer = 9999.0
		t.bot_path.clear()

func _process(_delta: float) -> bool:
	if _began:
		return true
	_began = true
	var failures: Array[String] = []
	var SF = load("res://minigames/short_fuse/short_fuse.gd")

	# --- Se adapta al nº de jugadores ---
	var ok := true
	var sizes := {}
	for n in range(2, 9):
		var g0 = _new_game(n, n)
		sizes[Vector2i(g0.cols, g0.rows)] = true
		var seen := {}
		for t in g0._tokens:
			var c: Vector2i = g0._cell_of(t.pos)
			if g0.cell_at(c) != SF.EMPTY or seen.has(c):
				ok = false
			seen[c] = true
			# Cada salida tiene sitio libre para poder huir de su primer petardo.
			if g0._reach(t, c, {}, false).size() < 4:
				ok = false
		if g0.cols % 2 == 0 or g0.rows % 2 == 0 or absf(g0._time_left - SF.match_time(n)) > 0.01:
			ok = false
		if Array(g0._grid).count(SF.CRATE) < 20:
			ok = false
		g0.free()
	_check(ok and sizes.size() == 4, "tablero y tiempo según jugadores (11×9 a 17×11), salidas libres y distintas", failures)

	# --- Explosión: en cruz, la paran los muros, revienta una caja por brazo, elimina ---
	var g = _new_game(3)
	_clear(g)
	g._tokens[0].pos = Vector2(0, 0)
	g._tokens[1].pos = Vector2(2, 0)
	g._tokens[2].pos = Vector2(8, 8)
	g._tokens[0].fire = 3
	g._grid[g._gi(Vector2i(0, 2))] = SF.CRATE
	g._grid[g._gi(Vector2i(0, 3))] = SF.CRATE
	var cells: Array = g.blast_cells(Vector2i(0, 0), 3)
	_check(cells.has(Vector2i(3, 0)) and not cells.has(Vector2i(4, 0)) and cells.has(Vector2i(0, 2))
			and not cells.has(Vector2i(0, 3)), "la llamarada llega a su alcance y se para en la primera caja", failures)
	_check(not g.blast_cells(Vector2i(1, 0), 3).has(Vector2i(1, 1)), "los muros fijos paran la llamarada", failures)
	_check(g._place_bomb(g._tokens[0]) and not g._place_bomb(g._tokens[0]), "solo un petardo a la vez al empezar", failures)
	for i in int(SF.BOMB_FUSE * 60.0) + 3:
		g._simulate(1.0 / 60.0)
	_check(not g._tokens[0].alive and not g._tokens[1].alive and g._tokens[2].alive, "elimina a quien pilla, dueño incluido", failures)
	_check(g.cell_at(Vector2i(0, 2)) != SF.CRATE and g.cell_at(Vector2i(0, 3)) == SF.CRATE, "revienta solo la primera caja", failures)
	_check(g._over and g._winner == 2 and g.result_groups().size() == 1, "queda uno: gana; los dos caídos a la vez empatan", failures)
	for i in int(SF.END_TIME * 60.0) + 3:
		g._simulate(1.0 / 60.0)
	_check(_ranking.size() == 3 and _ranking[0] == g._tokens[2].player.id, "ranking completo con el superviviente primero", failures)
	g.free()

	# --- Cadena, paso por petardos y mejoras ---
	g = _new_game(2)
	_clear(g)
	var a = g._tokens[0]
	var b = g._tokens[1]
	a.pos = Vector2(0, 0)
	b.pos = Vector2(4, 0)
	a.max_bombs = 2
	g._place_bomb(a)
	var first = g._bombs[0]
	_check(g._passable(Vector2i(0, 0), a) and not g._passable(Vector2i(0, 0), b), "el petardo corta el paso a los demás, no a quien está encima", failures)
	for i in 40:
		g._move_token(a, Vector2.RIGHT, 1.0 / 60.0)
		g._update_bombs(0.0)
	_check(a.pos.x > 1.5 and not g._passable(Vector2i(0, 0), a), "al salir de encima ya no se puede volver a pisarlo", failures)
	a.pos = Vector2(2, 0)
	g._place_bomb(a)
	first.fuse = 0.01
	a.pos = Vector2(10, 8)
	b.pos = Vector2(10, 6)
	g._simulate(1.0 / 60.0)
	_check(g._bombs.size() == 1 and g._bombs[0].fuse <= SF.CHAIN_DELAY, "un petardo alcanzado por otro estalla en cadena", failures)
	for i in 12:
		g._simulate(1.0 / 60.0)
	_check(g._bombs.is_empty() and g._flames.has(Vector2i(4, 0)), "la cadena prolonga la llamarada", failures)
	g._grid[g._gi(Vector2i(10, 7))] = SF.PU_FIRE
	a.pos = Vector2(10, 7)
	g._pick_up(a)
	_check(a.fire == SF.START_FIRE + 1 and g.cell_at(Vector2i(10, 7)) == SF.EMPTY, "recoger una mejora amarilla da +1 de alcance", failures)
	# Movimiento: no atraviesa muros y la ayuda de esquina centra en el pasillo.
	a.pos = Vector2(0, 0.4)
	for i in 30:
		g._move_token(a, Vector2.RIGHT, 1.0 / 60.0)
	_check(is_equal_approx(a.pos.y, 0.0) and a.pos.x > 0.5, "la ayuda de esquina te centra en el pasillo al girar", failures)
	a.pos = Vector2(1, 0)
	for i in 60:
		g._move_token(a, Vector2.DOWN, 1.0 / 60.0)
	_check(a.pos == Vector2(1, 0), "no se atraviesan los muros", failures)
	g.free()

	# --- Cierre final: tapa en espiral y elimina ---
	g = _new_game(2)
	_clear(g)
	g._tokens[0].pos = Vector2(0, 0)
	g._tokens[1].pos = Vector2(4, 4)
	g._time_left = 0.01
	var t := 0.0
	while not g._over and t < 60.0:
		g._simulate(1.0 / 60.0)
		t += 1.0 / 60.0
	_check(g._closing and g.cell_at(Vector2i(0, 0)) == SF.BLOCK and g._over and g._winner == 1 and t < 3.0,
			"sin tiempo, el tablero se cierra desde la esquina y aplasta", failures)
	_check(g._close_order.size() == g.cols * g.rows - Array(g._grid).count(SF.PILLAR) - Array(g._grid).count(SF.BLOCK) + g._close_i,
			"la espiral del cierre recorre todas las celdas que no son muro", failures)
	g.free()

	# --- Cliente: con estado + eventos ve lo mismo que el host ---
	g = _new_game(4, 7)
	var client = (load("res://minigames/short_fuse/meta.tres").scene as PackedScene).instantiate()
	root.add_child(client)
	client.set_process(false)
	client.is_authority = false
	client.configure(0, 7, null)
	client.prepare(g.players)
	_check(client._grid == g._grid, "todos los PC generan el mismo tablero con la semilla común", failures)
	client.start(g.players)
	var steps := 0
	var same_mid := true
	while not g._finished and steps < 60 * 200:
		g._simulate(1.0 / 60.0)
		if steps % 2 == 0:
			client.apply_state(g.serialize_state())
			if client._bombs.size() != g._bombs.size() or client._flames.size() != g._flames.size():
				same_mid = false
		steps += 1
	client.apply_state(g.serialize_state())
	var same: bool = client._grid == g._grid and client._winner == g._winner and client._over
	for i in g._tokens.size():
		if client._tokens[i].alive != g._tokens[i].alive or client._tokens[i].fire != g._tokens[i].fire:
			same = false
	_check(same and same_mid, "un cliente ve el mismo tablero, petardos, llamaradas y ganador que el host", failures)
	client.free()
	g.free()

	# --- Partidas completas con bots ---
	var before_close := 0
	var games := 0
	var early := 0
	for n in [2, 3, 4, 6, 8]:
		for sd in [1, 2, 3]:
			g = _new_game(n, n * 11 + sd)
			t = 0.0
			var limit: float = SF.match_time(n) + 60.0
			var crates0: int = Array(g._grid).count(SF.CRATE)
			var checked := false
			while _ranking.is_empty() and t < limit:
				g._simulate(1.0 / 60.0)
				t += 1.0 / 60.0
				if not checked and t >= 6.0:
					checked = true
					early += n - g.alive_count()
			games += 1
			if not g._closing:
				before_close += 1
			var crates1: int = Array(g._grid).count(SF.CRATE)
			_check(_ranking.size() == n and crates1 < crates0, "partida de %d bots: acaba en %.0f s%s, %d cajas reventadas"
					% [n, t, " (con cierre)" if g._closing else "", crates0 - crates1], failures)
			g.free()
	print("  · %d de %d partidas se decidieron antes del cierre; bots caídos en los 6 primeros segundos: %d" % [before_close, games, early])
	_check(early <= 3, "los bots no se inmolan nada más empezar", failures)

	print("")
	if failures.is_empty():
		print("SHORT FUSE TEST OK")
		quit(0)
	else:
		print("SHORT FUSE TEST FALLÓ: ", failures)
		quit(1)
	return true

func _check(ok: bool, what: String, failures: Array[String]) -> void:
	print("  %s %s" % ["✓" if ok else "✗", what])
	if not ok:
		failures.append(what)
