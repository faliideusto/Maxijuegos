extends SceneTree
## Prueba de Puente Personal (sin red): puentes según jugadores, premios, puentes compartidos que se rompen,
## elección con clic (texto) y con dirección, secreto en el estado y partidas completas con bots.
## Ejecutar:  godot --headless --path . --script res://tests/personal_bridge_test.gd

var _began: bool = false
var _ranking: Array = []

func _new_game(n_bots: int, game_seed: int = 1, humans: int = 0):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	if humans > 0:
		lobby.add_player("kb1")
	for i in n_bots:
		lobby.add_bot()
	var meta = load("res://minigames/personal_bridge/meta.tres")
	var mg = (meta.scene as PackedScene).instantiate()
	root.add_child(mg)
	mg.configure(0, game_seed, null)
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
	var PB = load("res://minigames/personal_bridge/personal_bridge.gd")

	# --- Se adapta al nº de jugadores ---
	var counts_ok := true
	for n in range(2, 9):
		var g0 = _new_game(n)
		if g0.bridge_count() != clampi(n + 1, 3, 9) or g0._prizes.size() != g0.bridge_count():
			counts_ok = false
		g0.free()
	_check(counts_ok, "hay jugadores + 1 puentes (2 jugadores → 3, 8 → 9), cada uno con su premio", failures)

	# --- Premios: un único oro; +2 solo con 4 puentes o más; cambian de sitio ---
	var prize_ok := true
	var gold_spots := {}
	for sd in range(1, 40):
		var r := RandomNumberGenerator.new()
		r.seed = sd
		for c in range(3, 10):
			var pz: PackedByteArray = PB.prizes_for(c, r)
			var golds := Array(pz).count(PB.GOLD)
			var twos := Array(pz).count(2)
			if pz.size() != c or golds != 1 or twos != (1 if c >= 4 else 0):
				prize_ok = false
			if c == 5:
				gold_spots[Array(pz).find(PB.GOLD)] = true
	_check(prize_ok and gold_spots.size() == 5, "un oro por ronda, un +2 desde 4 puentes y el oro cambia de sitio", failures)

	# --- Reglas: compartido = se rompe y nadie cobra; solo = premio; sin elegir = 0 ---
	var g = _new_game(4)
	for id in g._bot_plan:
		g._bot_plan[id].at = 999.0
	g._prizes = PackedByteArray([3, 2, 1, 1, 1])
	var ids: Array[int] = []
	for p in g.players:
		ids.append(p.id)
	g._set_pick(g.players[0], 0)
	g._set_pick(g.players[1], 0)
	g._set_pick(g.players[2], 1)
	var st: Dictionary = g._serialize_state()
	_check(not st.has("pk") and Array(st.ch) == [1, 1, 1, 0], "mientras se elige, el estado dice quién eligió pero no qué", failures)
	g._t = PB.CHOOSE_TIME - 0.01
	g._simulate(0.02)
	_check(g._phase == PB.Phase.CROSS and g._broken[0] == 1 and g._broken[1] == 0, "al acabar el tiempo se rompe el puente compartido", failures)
	_check(g._scores[ids[0]] == 0 and g._scores[ids[1]] == 0 and g._falls[ids[0]] == 1, "los que compartían puente se caen sin premio", failures)
	_check(g._scores[ids[2]] == 2 and g._scores[ids[3]] == 0, "el que cruza solo cobra su +2; quien no eligió, nada", failures)
	_check(g._serialize_state().has("pk"), "tras el destape el estado ya lleva las elecciones", failures)
	g.free()

	# --- Clic (texto "b:n"): en local va al jugador del ratón; se valida; se puede cambiar ---
	g = _new_game(2, 3, 1)
	var me = g.players[0]
	g._on_player_text(null, "b:2", true)
	_check(g._picks[me.id] == 2 and g._chosen[me.id], "un clic (sin dueño, partida local) elige para el jugador del ratón", failures)
	g._on_player_text(null, "b:1", true)
	_check(g._picks[me.id] == 1, "se puede cambiar de puente mientras dura el tiempo", failures)
	g._on_player_text(null, "b:99", true)
	g._on_player_text(null, "b:x", true)
	g._on_player_text(null, "hola", true)
	_check(g._picks[me.id] == 1, "se ignoran clics a puentes que no existen o mal formados", failures)
	_check(g.bridge_at(g.tower_pos(2)) == 2 and g.bridge_at((g.bridge_start(1) + g.bridge_end(1)) * 0.5) == 1
			and g.bridge_at(g.CENTER) == PB.NO_PICK, "el clic acierta la torre o el puente; en el centro no elige nada", failures)
	var dir_ok := true
	for b in g.bridge_count():
		if g._bridge_from_dir((g.tower_pos(b) - g.CENTER).normalized()) != b:
			dir_ok = false
	_check(dir_ok and g._bridge_from_dir(Vector2(0.1, 0)) == PB.NO_PICK, "apuntar con la dirección elige el puente de ese lado (con zona muerta)", failures)
	g._t = PB.CHOOSE_TIME + 0.1
	g._simulate(0.01)
	g._on_player_text(null, "b:2", true)
	_check(g._picks[me.id] == 1, "acabado el tiempo, los clics ya no cambian nada", failures)
	g.free()

	# --- Cliente: con estado + eventos ve lo mismo que el host ---
	g = _new_game(4, 7)
	var client = (load("res://minigames/personal_bridge/meta.tres").scene as PackedScene).instantiate()
	root.add_child(client)
	client.is_authority = false
	client.configure(0, 7, null)
	client.prepare(g.players)
	client.start(g.players)
	var steps := 0
	while not g._finished and steps < 60 * 90:
		g._simulate(1.0 / 60.0)
		if steps % 2 == 0:
			client.apply_state(g.serialize_state())
		steps += 1
	client.apply_state(g.serialize_state())
	var same := true
	for p in g.players:
		if client._scores[p.id] != g._scores[p.id]:
			same = false
	_check(same and client._prizes == g._prizes, "un cliente ve los mismos premios y puntos que el host", failures)
	client.free()
	g.free()

	# --- Partidas completas con bots ---
	for n in [2, 3, 5, 8]:
		g = _new_game(n, n * 11)
		var t := 0.0
		while _ranking.is_empty() and t < 120.0:
			g._simulate(1.0 / 60.0)
			t += 1.0 / 60.0
		var total := 0
		for p in g.players:
			total += g._scores[p.id]
		var expect_t: float = PB.ROUNDS * (PB.CHOOSE_TIME + PB.CROSS_TIME + PB.RESULT_TIME) + PB.END_TIME
		_check(_ranking.size() == n and absf(t - expect_t) < 0.5 and g._round == PB.ROUNDS - 1,
				"partida de %d bots: %d rondas, ranking completo, %.0f s (puntos repartidos: %d)" % [n, PB.ROUNDS, t, total], failures)
		g.free()

	print("")
	if failures.is_empty():
		print("PERSONAL BRIDGE TEST OK")
		quit(0)
	else:
		print("PERSONAL BRIDGE TEST FALLÓ: ", failures)
		quit(1)
	return true

func _check(ok: bool, what: String, failures: Array[String]) -> void:
	print("  %s %s" % ["✓" if ok else "✗", what])
	if not ok:
		failures.append(what)
