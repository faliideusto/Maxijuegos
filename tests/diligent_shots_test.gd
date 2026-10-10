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

	# --- Huecos según el nº de jugadores; cada jugador delante de su tramo y todo dentro de la pantalla ---
	var layout_ok := true
	for n in range(2, 9):
		var g0 = _new_game(n)
		var want: int = DS.slots_per_player(n) * n
		if g0.slot_count() != want or g0._kind.size() != want:
			layout_ok = false
		if g0.row_left() < 40.0 or g0.row_right() > 1240.0:
			layout_ok = false
		for i in n:
			var per: int = DS.slots_per_player(n)
			if g0.slot_owner(i * per) != i or g0.slot_owner(i * per + per - 1) != i:
				layout_ok = false
			if g0.player_x(i) < g0.slot_x(i * per) or g0.player_x(i) > g0.slot_x(i * per + per - 1):
				layout_ok = false
		for s in g0.slot_count():
			if g0.slot_at(g0.slot_x(s)) != s:
				layout_ok = false
		if g0.slot_at(g0.slot_x(0) - g0.slot_radius() - 2.0) != DS.NO_SLOT:
			layout_ok = false
		g0.free()
	_check(layout_ok, "de 2 a 8 jugadores: 4/3/2 huecos por jugador, cada uno delante de su tramo y la fila cabe en pantalla", failures)

	# --- Puntos por rapidez ---
	_check(DS.result_for_age(0.2) == DS.Result.EXCELLENT and DS.result_for_age(0.7) == DS.Result.GOOD
			and DS.result_for_age(1.6) == DS.Result.SLOW, "+7 antes de 0,5 s, +5 antes de 1 s y +2 después", failures)

	# --- Disparos: diana, bomba (aturde), hueco vacío (resta y encasquilla), nunca por debajo de 0 ---
	var g = _new_game(4)
	var a = g.players[0]
	var b = g.players[1]
	g._wave = DS.Wave.TARGETS
	g._wave_t = 99.0
	g._kind.fill(DS.EMPTY)
	g._kind[2] = DS.TARGET
	g._born[2] = g._clock - 0.2
	g._kind[5] = DS.BOMB
	g._aim[a.id] = g.slot_x(2)
	_check(g._fire(a) == DS.Result.EXCELLENT and g._scores[a.id] == 7 and g._kind[2] == DS.EMPTY, "acertar una diana recién salida da +7 y la quita", failures)
	_check(g._fire(a) == -1, "justo después de disparar el arma necesita un momento", failures)
	g._cool[a.id] = 0.0
	_check(g._fire(a) == DS.Result.MISS and g._scores[a.id] == 5, "disparar a un hueco vacío quita 2", failures)
	g._cool[a.id] = 0.0
	g._aim[a.id] = g.slot_x(5)
	_check(g._fire(a) == DS.Result.BANG and g._scores[a.id] == 0 and g._stun[a.id] > 0.0 and g._bombs_hit[a.id] == 1, "darle a una bomba quita 5 (sin bajar de 0) y aturde", failures)
	g._cool[a.id] = 0.0
	g._kind[3] = DS.TARGET
	g._born[3] = g._clock
	g._aim[a.id] = g.slot_x(3)
	_check(g._fire(a) == -1 and g._kind[3] == DS.TARGET, "aturdido no se puede disparar", failures)
	g.free()

	# --- Dos a la vez en la misma diana: solo uno se la lleva ---
	g = _new_game(2)
	a = g.players[0]
	b = g.players[1]
	g._wave = DS.Wave.TARGETS
	g._wave_t = 99.0
	g._kind.fill(DS.EMPTY)
	g._kind[1] = DS.TARGET
	g._born[1] = g._clock
	g._aim[a.id] = g.slot_x(1)
	g._aim[b.id] = g.slot_x(1)
	var ra: int = g._fire(a)
	var rb: int = g._fire(b)
	_check(ra == DS.Result.EXCELLENT and rb == DS.Result.MISS and g._scores[a.id] == 7, "si dos disparan a la misma diana, se la lleva el primero", failures)
	g.free()

	# --- Clic del ratón: apunta al hueco y dispara (en partida local, sin dueño = el jugador del ratón) ---
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
	g._kind.fill(DS.EMPTY)
	g._kind[6] = DS.TARGET
	g._born[6] = g._clock - 0.7
	g.deliver_player_text(null, "s:6", true)
	_check(g._scores[human.id] == 5 and is_equal_approx(g._aim[human.id], g.slot_x(6)), "clic en un hueco: la mira va ahí y dispara (+5 a los 0,7 s)", failures)
	g.deliver_player_text(null, "s:99", true)
	g.deliver_player_text(null, "hola", true)
	_check(g._scores[human.id] == 5, "un clic con texto raro no hace nada", failures)
	g.free()

	# --- Oleadas: salen dianas y bombas, y las bombas acaban cambiándose por dianas ---
	g = _new_game(4, 11)
	var saw_bombs := false
	var saw_targets := false
	var bombs_then_targets := false
	var mixed := false
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
			if g._kind.has(DS.BOMB):
				mixed = true
		prev_wave = g._wave
		steps += 1
	_check(saw_bombs and saw_targets and bombs_then_targets, "salen dianas y bombas, y las bombas se cambian por dianas", failures)
	_check(mixed, "en la segunda mitad hay oleadas de dianas con alguna bomba mezclada", failures)
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
