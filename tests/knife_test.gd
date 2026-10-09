extends SceneTree
## Prueba de Tronco de Dagas (sin red): colisión de dagas, turnos, salida aleatoria, dificultad y partidas
## completas con bots.
## Ejecutar:  godot --headless --path . --script res://tests/knife_test.gd

var _began: bool = false
var _ranking: Array = []

func _new_game(n_bots: int):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	for i in n_bots:
		lobby.add_bot()
	var meta = load("res://minigames/knife_log/meta.tres")
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
	var KL = load("res://minigames/knife_log/knife_log.gd")

	# --- Dificultad: la velocidad sube con las dagas y tiene tope ---
	var mono := true
	for n in range(1, 30):
		if KL.speed_for(n) < KL.speed_for(n - 1):
			mono = false
	_check(mono and KL.speed_for(0) < KL.speed_for(10) and KL.speed_for(100) == KL.MAX_SPEED, "el giro acelera con cada daga (%.2f → %.2f rad/s, tope %.1f)" % [KL.speed_for(0), KL.speed_for(15), KL.MAX_SPEED], failures)
	_check(KL.MAX_SPEED <= KL.BASE_SPEED * 3.0, "la velocidad máxima sigue siendo jugable (×%.1f)" % (KL.MAX_SPEED / KL.BASE_SPEED), failures)

	# --- Inicio: dagas iniciales separadas y primer jugador al azar ---
	var g = _new_game(5)
	var gaps_ok := true
	for i in g._daggers.size():
		for j in range(i + 1, g._daggers.size()):
			if absf(g._wrap(g._daggers[i].ang - g._daggers[j].ang)) < g.MIN_START_GAP - 0.001:
				gaps_ok = false
	_check(g._daggers.size() == g.START_DAGGERS and gaps_ok, "empieza con %d dagas separadas entre sí" % g._daggers.size(), failures)
	var starters := {}
	for i in 600:
		g._on_start()
		starters[g._cur_id] = int(starters.get(g._cur_id, 0)) + 1
	var min_share := 1.0
	for id in starters:
		min_share = minf(min_share, float(starters[id]) / 600.0)
	_check(starters.size() == 5 and min_share > 0.12, "el jugador que empieza es aleatorio (reparto mínimo %.0f %%)" % [min_share * 100.0], failures)

	# --- Choque: encima de otra daga eliminas; en un hueco, se clava ---
	g._on_start()
	g._daggers.clear()
	var base = Dagger_new(g, 0.0)
	g._daggers.append(base)
	g._elim_order.clear()
	g._phase = g.Phase.FLY
	g._rot = PI * 0.5                      # el punto de impacto (abajo) cae en el ángulo local 0
	g._impact()
	_check(g._elim_order.size() == 1 and g._daggers.size() == 1, "caer justo encima de otra daga elimina al jugador", failures)
	g._elim_order.clear()
	g._phase = g.Phase.FLY
	g._rot = PI * 0.5 - 0.19               # dentro del ancho de la daga (0,2 rad)
	g._impact()
	_check(g._elim_order.size() == 1, "rozando una daga (0,19 rad) también choca", failures)
	g._elim_order.clear()
	g._phase = g.Phase.FLY
	g._rot = PI * 0.5 - 0.21               # justo fuera
	var before: int = g._count
	g._impact()
	_check(g._elim_order.is_empty() and g._daggers.size() == 2 and g._count == before + 1 and g._daggers[1].owner_id == g._current_player().id, "en un hueco (0,21 rad) la daga se clava y es del jugador", failures)

	# --- Turnos: se salta a los eliminados ---
	g._elim_order = [g.players[1].id]
	_check(g._next_alive(0) == 2 and g._next_alive(4) == 0, "el turno salta a los eliminados", failures)
	g._elim_order.clear()

	# --- Si no lanzas en 6 s, la daga sale sola ---
	g._on_start()
	g._phase = g.Phase.WAIT
	g._turn_left = 0.02
	g._simulate(0.05)
	_check(g._phase == g.Phase.FLY, "pasado el tiempo del turno la daga sale sola", failures)

	# --- Sentido: cada 5 dagas se invierte (despacio) ---
	g._on_start()
	g._daggers.clear()
	g._count = 4
	g._dir_target = 1.0
	g._dir_cur = 1.0
	g._phase = g.Phase.FLY
	g._rot = PI * 0.5 - 1.5
	g._impact()
	_check(g._count == 5 and g._dir_target == -1.0, "a la 5.ª daga el tronco invierte el sentido", failures)
	g._update_log(0.1)
	_check(g._dir_cur < 1.0 and g._dir_cur > -1.0, "el cambio de sentido es progresivo (frena antes de girar)", failures)

	# --- Partidas completas con bots ---
	for n in [2, 3, 5, 8]:
		var gm = _new_game(n)
		var steps := 0
		var max_count := 0
		while _ranking.is_empty() and steps < 60 * 900:
			gm._simulate(1.0 / 60.0)
			steps += 1
			max_count = maxi(max_count, gm._count)
		var seen := {}
		for id in _ranking:
			seen[id] = true
		var survivors := 0
		for p in gm.players:
			if gm._is_alive(p.id):
				survivors += 1
		var order_ok := true
		for i in range(gm._elim_order.size()):
			if _ranking[_ranking.size() - 1 - i] != gm._elim_order[i]:
				order_ok = false
		_check(_ranking.size() == n and seen.size() == n and survivors == 1 and gm._is_alive(_ranking[0]) and order_ok, "partida de %d bots: termina con 1 superviviente y ranking por orden de eliminación (%d dagas, %.0f s)" % [n, max_count, steps / 60.0], failures)
		_check(steps / 60.0 < 400.0, "partida de %d bots: duración razonable" % n, failures)

	print("")
	if failures.is_empty():
		print("KNIFE TEST OK")
		quit(0)
	else:
		print("KNIFE TEST FALLÓ")
		quit(1)
	return true

func Dagger_new(g, ang: float):
	var d = g.Dagger.new()
	d.ang = ang
	d.pop = 1.0
	return d

func _check(cond: bool, what: String, failures: Array[String]) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		failures.append(what)
		print("  ✗ " + what)
