extends SceneTree
## Prueba de Disparos Diligentes (sin red): huecos según el nº de jugadores, puntos por rapidez, bombas que aturden,
## fallos que restan, primero que acierta se lleva la diana, clic del ratón, réplica en un cliente y partidas con bots.
## Ejecutar:  godot --headless --path . --script res://tests/diligent_shots_test.gd

var _began: bool = false
var _ranking: Array = []
var _events: Array = []

func _new_game(n_bots: int, game_seed: int = 1):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	for i in n_bots:
		lobby.add_bot()
	var meta = load("res://minigames/diligent_shots/meta.tres")
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
	var DS = load("res://minigames/diligent_shots/diligent_shots.gd")

	# --- Tres huecos por jugador, cada uno delante de los suyos, sin solaparse y dentro de la pantalla ---
	var layout_ok := true
	for n in range(2, 9):
		var g0 = _new_game(n)
		if g0.slot_count() != 3 * n or g0._kind.size() != 3 * n:
			layout_ok = false
		for i in n:
			if g0.slot_owner(i * 3) != i or g0.slot_owner(i * 3 + 2) != i:
				layout_ok = false
			if not (g0.slot_x(i * 3) < g0.player_x(i) and g0.player_x(i) < g0.slot_x(i * 3 + 2)):
				layout_ok = false
		for s in range(1, g0.slot_count()):
			if g0.slot_x(s) - g0.slot_x(s - 1) < 2.0 * g0.slot_radius():
				layout_ok = false
		if g0.slot_x(0) - g0.slot_radius() < 40.0 or g0.slot_x(g0.slot_count() - 1) + g0.slot_radius() > 1240.0:
			layout_ok = false
		g0.free()
	_check(layout_ok, "de 2 a 8 jugadores: 3 huecos cada uno, delante de su jugador, sin solaparse y dentro de la pantalla", failures)

	# --- A / S / D apuntan a izquierda / centro / derecha ---
	_check(DS.slot_from_dir(Vector2.LEFT) == DS.LEFT and DS.slot_from_dir(Vector2.DOWN) == DS.CENTER
			and DS.slot_from_dir(Vector2.RIGHT) == DS.RIGHT and DS.slot_from_dir(Vector2.ZERO) == DS.NO_SLOT
			and DS.slot_from_dir(Vector2.UP) == DS.NO_SLOT, "A = izquierda, S = centro, D = derecha (arriba o nada no cambia la mira)", failures)

	# --- Puntos por rapidez ---
	_check(DS.result_for_age(0.2) == DS.Result.EXCELLENT and DS.result_for_age(0.7) == DS.Result.GOOD
			and DS.result_for_age(1.6) == DS.Result.SLOW, "+7 rápido, +5 algo después y +2 lento", failures)

	# --- Cada vez más rápido ---
	var gr = _new_game(2)
	gr._t_left = DS.DURATION
	var life0: float = gr.target_life()
	gr._t_left = DS.DURATION * 0.5
	var life1: float = gr.target_life()
	gr._t_left = 0.01
	var life2: float = gr.target_life()
	_check(life0 > life1 and life1 > life2 and absf(life0 - DS.LIFE_START) < 0.01 and life2 < DS.LIFE_START * 0.5,
			"las dianas duran cada vez menos (%.2f s → %.2f s → %.2f s)" % [life0, life1, life2], failures)
	gr.free()

	# --- Disparos a tus huecos: diana, bomba (aturde), hueco vacío (resta), nunca por debajo de 0 ---
	var g = _new_game(4)
	var a = g.players[0]
	var b = g.players[1]
	g._wave = DS.Wave.TARGETS
	g._wave_t = 99.0
	g._apply_pattern(PackedByteArray([DS.TARGET, DS.EMPTY, DS.BOMB]))
	g._born = g._clock - 0.2
	g._aim[a.id] = DS.LEFT
	_check(g._fire(a) == DS.Result.EXCELLENT and g._scores[a.id] == 7 and g._kind[0] == DS.EMPTY, "acertar tu diana recién salida da +7 y la quita", failures)
	_check(g._kind[3] == DS.TARGET, "la diana del mismo sitio de otro jugador sigue ahí (cada uno dispara a las suyas)", failures)
	_check(g._fire(a) == -1, "justo después de disparar el arma necesita un momento", failures)
	g._cool[a.id] = 0.0
	g._aim[a.id] = DS.CENTER
	_check(g._fire(a) == DS.Result.MISS and g._scores[a.id] == 5, "disparar a un hueco vacío quita 2", failures)
	g._cool[a.id] = 0.0
	g._aim[a.id] = DS.RIGHT
	_check(g._fire(a) == DS.Result.BANG and g._scores[a.id] == 0 and g._stun[a.id] > 0.0 and g._bombs_hit[a.id] == 1, "darle a una bomba quita 5 (sin bajar de 0) y aturde", failures)
	g._cool[a.id] = 0.0
	g._aim[b.id] = DS.LEFT
	_check(g._fire(a) == -1 and g._fire(b) == DS.Result.EXCELLENT, "aturdido no se puede disparar; el otro sí acierta la suya", failures)
	g.free()

	# --- Clic del ratón: solo en tus huecos ---
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	lobby.add_player("kb1")
	lobby.add_bot()
	var meta = load("res://minigames/diligent_shots/meta.tres")
	g = (meta.scene as PackedScene).instantiate()
	root.add_child(g)
	g.configure(0, 5, null)
	g.prepare(lobby.players)
	g.start(lobby.players)
	var human = g.players[0]
	g._wave = DS.Wave.TARGETS
	g._wave_t = 99.0
	g._apply_pattern(PackedByteArray([DS.EMPTY, DS.EMPTY, DS.TARGET]))
	g._born = g._clock - 0.7
	var own: int = g.own_slot_at(0, Vector2(g.slot_x(2), DS.ROW_Y))
	var other: int = g.own_slot_at(0, Vector2(g.slot_x(5), DS.ROW_Y))
	_check(own == DS.RIGHT and other == DS.NO_SLOT, "con el ratón solo cuentan tus huecos", failures)
	g.deliver_player_text(null, "s:2", true)
	_check(g._scores[human.id] == 5 and g._aim[human.id] == DS.RIGHT, "clic en tu hueco: apunta ahí y dispara (+5 a los 0,7 s)", failures)
	g.deliver_player_text(null, "s:9", true)
	g.deliver_player_text(null, "hola", true)
	_check(g._scores[human.id] == 5, "un clic con texto raro no hace nada", failures)
	g.free()

	# --- Oleadas: salen dianas y bombas, y las bombas acaban cambiándose por dianas ---
	g = _new_game(4, 11)
	var saw_bombs := false
	var saw_targets := false
	var bombs_then_targets := false
	var mixed := false
	var same_pat := true
	var prev_wave: int = g._wave
	var steps := 0
	while steps < 60 * 44:
		# Nadie dispara: solo se mira cómo salen las oleadas.
		g._clock += 1.0 / 60.0
		g._t_left -= 1.0 / 60.0
		g._update_wave(1.0 / 60.0)
		if g._wave == DS.Wave.BOMBS:
			saw_bombs = true
		if g._wave == DS.Wave.TARGETS:
			saw_targets = true
			if prev_wave == DS.Wave.BOMBS:
				bombs_then_targets = true
			if prev_wave != DS.Wave.TARGETS:
				for i in range(1, g.players.size()):
					for k in 3:
						if g._kind[i * 3 + k] != g._kind[k]:
							same_pat = false
			if g._kind.has(DS.BOMB):
				mixed = true
		prev_wave = g._wave
		steps += 1
	_check(saw_bombs and saw_targets and bombs_then_targets, "salen dianas y bombas, y las bombas se cambian por dianas", failures)
	_check(mixed, "a partir de cierto punto hay oleadas de dianas con alguna bomba mezclada", failures)
	_check(same_pat, "todos tienen el mismo patrón en sus huecos", failures)
	g.free()

	# --- Un cliente ve lo mismo que el host con el estado y los eventos ---
	g = _new_game(4, 21)
	var cl = (load("res://minigames/diligent_shots/meta.tres").scene as PackedScene).instantiate()
	root.add_child(cl)
	cl.is_authority = false
	cl.configure(0, 99, null)
	cl.prepare(g.players)
	cl.start(g.players)
	_events = []
	var fake := FakeSession.new()
	fake.events = _events
	root.add_child(fake)
	g.set_session(fake)
	steps = 0
	while steps < 60 * 15:
		g._simulate(1.0 / 60.0)
		steps += 1
	cl.apply_state(g.serialize_state())
	var same: bool = cl._kind == g._kind and absf(cl._t_left - g._t_left) < 0.01
	for p in g.players:
		if cl._scores[p.id] != g._scores[p.id] or absf(float(cl._aim[p.id]) - float(g._aim[p.id])) > 0.01:
			same = false
	var shots := 0
	for e in _events:
		if e[0] == "shot":
			shots += 1
			cl.deliver_event(e[0], e[1])
	_check(same and shots > 0, "un cliente ve los mismos huecos, miras y puntos que el host (%d disparos)" % shots, failures)
	g.set_session(null)
	fake.free()
	cl.free()
	g.free()

	# --- Partidas completas con bots ---
	for n in [2, 3, 5, 8]:
		var gm = _new_game(n, 40 + n)
		steps = 0
		while _ranking.is_empty() and steps < 60 * 80:
			gm._simulate(1.0 / 60.0)
			gm._animate(1.0 / 60.0)
			steps += 1
		var seen := {}
		for id in _ranking:
			seen[id] = true
		var sorted_ok := true
		for i in range(1, _ranking.size()):
			if gm._scores[_ranking[i]] > gm._scores[_ranking[i - 1]]:
				sorted_ok = false
		var total := 0
		for p in gm.players:
			total += int(gm._scores[p.id])
		var dur: float = steps / 60.0
		_check(_ranking.size() == n and seen.size() == n and sorted_ok and total > 0 and absf(dur - (DS.DURATION + DS.END_TIME)) < 0.2,
				"partida de %d bots: termina a los %.1f s, ranking por puntos (ganador %d, total %d)" % [n, dur, gm._scores[_ranking[0]] if not _ranking.is_empty() else -1, total], failures)
		gm.free()

	print("")
	if failures.is_empty():
		print("DILIGENT SHOTS TEST OK")
		quit(0)
	else:
		print("DILIGENT SHOTS TEST FALLÓ")
		quit(1)
	return true

## Hace de sesión de red del host: guarda los eventos que se enviarían a los clientes.
class FakeSession extends Node:
	var events: Array
	func send_event(event_name: String, data: Variant) -> void:
		events.append([event_name, data])

func _check(cond: bool, what: String, failures: Array[String]) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		failures.append(what)
		print("  ✗ " + what)
