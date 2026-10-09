extends SceneTree
## Prueba de Caza del Foco (sin red): reglas de focos, reclamar/soltar, eliminación, ranking y partidas
## completas con bots.
## Ejecutar:  godot --headless --path . --script res://tests/spotlight_test.gd

var _began: bool = false
var _ranking: Array = []

func _new_game(n_bots: int):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	for i in n_bots:
		lobby.add_bot()
	var meta = load("res://minigames/spotlight/meta.tres")
	var mg = (meta.scene as PackedScene).instantiate()
	root.add_child(mg)
	mg.configure(0, 1, null)
	mg.prepare(lobby.players)
	_ranking = []
	mg.finished.connect(func(r: Array) -> void: _ranking = r)
	mg.start(lobby.players)
	return mg

func _process(_delta: float) -> bool:
	if _began:
		return true
	_began = true
	var failures: Array[String] = []
	var SL = load("res://minigames/spotlight/spotlight.gd")

	# --- Dificultad por ronda ---
	var prev_r: float = 1e9
	var prev_s: float = 0.0
	var prev_t: float = 1e9
	var mono := true
	for r in range(1, 30):
		if SL.radius_for(r) > prev_r or SL.speed_for(r) < prev_s or SL.time_for(r) > prev_t:
			mono = false
		prev_r = SL.radius_for(r)
		prev_s = SL.speed_for(r)
		prev_t = SL.time_for(r)
	_check(mono and SL.speed_for(1) < 260.0 and SL.speed_for(30) >= 360.0 and SL.speed_for(30) <= 400.0 and SL.speed_for(30) < SL.ACCEL / SL.DRAG * 0.9, "los focos van cada vez más rápido (%.0f → %.0f) y más pequeños (%.0f → %.0f)" % [SL.speed_for(1), SL.speed_for(30), SL.radius_for(1), SL.radius_for(30)], failures)
	_check(SL.time_for(1) > SL.time_for(10) and SL.time_for(30) >= 5.0, "las rondas duran cada vez menos (%.1f → %.1f s)" % [SL.time_for(1), SL.time_for(30)], failures)

	# --- Un foco menos que jugadores ---
	var mg = _new_game(5)
	_check(mg._spots.size() == 4 and mg._alive_count() == 5, "con 5 jugadores hay 4 focos", failures)

	# --- Reclamar: el primero que entra (el más cercano) se queda el foco; los demás no lo roban ---
	mg._phase = mg.Phase.PLAY
	var sp = mg._spots[0]
	var ta = mg._tokens[0]
	var tb = mg._tokens[1]
	for t in mg._tokens:
		t.pos = Vector2(100, 130)   # lejos de todos los focos
		t.vel = Vector2.ZERO
	var far_spots := [Vector2(1000, 160), Vector2(1100, 560), Vector2(200, 560), Vector2(400, 160)]
	for i in mg._spots.size():
		mg._spots[i].pos = far_spots[i]
		mg._spots[i].owner_id = -1
		mg._spots[i].vel = Vector2.ZERO
	mg._speed = 0.0
	sp.pos = Vector2(640, 360)
	ta.pos = sp.pos + Vector2(10, 0)
	tb.pos = sp.pos + Vector2(40, 0)
	mg._update_claims(0.016)
	_check(sp.owner_id == ta.player.id and ta.spot == 0 and tb.spot == -1, "el más cercano reclama el foco y el otro no", failures)
	ta.pos = sp.pos + Vector2(20, 0)
	tb.pos = sp.pos + Vector2(5, 0)
	mg._update_claims(0.016)
	_check(sp.owner_id == ta.player.id, "un foco ocupado no se puede robar entrando a él", failures)
	# --- Soltar: al salirse (tras el margen) el foco queda libre ---
	ta.pos = sp.pos + Vector2(400, 0)
	mg._update_claims(0.1)
	_check(sp.owner_id == ta.player.id, "se conserva un momento al salirse (margen)", failures)
	mg._update_claims(0.3)
	_check(sp.owner_id == tb.player.id or sp.owner_id == -1, "pasado el margen el foco se libera (y lo coge quien está dentro)", failures)
	_check(ta.spot == -1, "quien se sale pierde su foco", failures)

	# --- Fin de ronda: queda fuera quien no tiene foco y desaparece un foco ---
	mg = _new_game(4)
	mg._phase = mg.Phase.PLAY
	for i in 3:
		mg._spots[i].owner_id = mg._tokens[i].player.id
		mg._tokens[i].spot = i
	for t in mg._tokens:
		t.pos = Vector2(300, 300)
	mg._lock_round()
	_check(not mg._tokens[3].alive and mg._tokens[0].alive and mg._tokens[1].alive and mg._tokens[2].alive, "al acabar la ronda queda eliminado el que no tiene foco", failures)
	_check(mg._elim_order == [mg._tokens[3].player.id], "se anota el orden de eliminación", failures)
	mg._after_lock()
	_check(mg._phase == mg.Phase.READY and mg._spots.size() == 2 and mg._round == 2, "siguiente ronda: 3 vivos → 2 focos", failures)
	# --- Si nadie tiene foco, siempre queda un superviviente ---
	for t in mg._tokens:
		t.spot = -1
	mg._phase = mg.Phase.PLAY
	mg._lock_round()
	_check(mg._alive_count() >= 1, "nunca se elimina a todos (quedan %d)" % mg._alive_count(), failures)

	# --- Partidas completas con bots (2, 3, 6 y 8 jugadores) ---
	for n in [2, 3, 6, 8]:
		var g = _new_game(n)
		var rounds_seen := 0
		var last_alive: int = g._alive_count()
		var ok_spots := true
		var ok_alive := true
		var steps := 0
		var last_round := 0
		var speed_ok := true
		var last_speed := 0.0
		while _ranking.is_empty() and steps < 60 * 600:
			g._simulate(1.0 / 60.0)
			steps += 1
			if g._round != last_round:
				last_round = g._round
				rounds_seen += 1
				var alive: int = g._alive_count()
				if g._spots.size() != maxi(alive - 1, 1):
					ok_spots = false
				if rounds_seen > 1 and alive >= last_alive:
					ok_alive = false      # cada ronda tiene que eliminar al menos a uno
				last_alive = alive
				if g._speed < last_speed:
					speed_ok = false
				last_speed = g._speed
		var survivors := 0
		for t in g._tokens:
			if t.alive:
				survivors += 1
		var ids_unique: bool = _ranking.size() == n
		var seen := {}
		for id in _ranking:
			seen[id] = true
		_check(not _ranking.is_empty() and survivors == 1 and seen.size() == n and ids_unique, "partida de %d bots: termina con 1 superviviente y ranking completo (%d rondas, %.0f s)" % [n, rounds_seen, steps / 60.0], failures)
		_check(ok_spots and ok_alive and speed_ok, "partida de %d bots: focos = vivos − 1, cada ronda elimina y los focos aceleran" % n, failures)
		var winner_ok := false
		for t in g._tokens:
			if t.alive and not _ranking.is_empty() and _ranking[0] == t.player.id:
				winner_ok = true
		var order_ok := true
		for i in range(g._elim_order.size()):
			if _ranking[_ranking.size() - 1 - i] != g._elim_order[i]:
				order_ok = false
		_check(winner_ok and order_ok, "partida de %d bots: gana el superviviente y el ranking sigue el orden de eliminación" % n, failures)

	print("")
	if failures.is_empty():
		print("SPOTLIGHT TEST OK")
		quit(0)
	else:
		print("SPOTLIGHT TEST FALLÓ")
		quit(1)
	return true

func _check(cond: bool, what: String, failures: Array[String]) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		failures.append(what)
		print("  ✗ " + what)
