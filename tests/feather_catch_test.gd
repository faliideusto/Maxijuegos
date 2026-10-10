extends SceneTree
## Prueba de Plumas al Vuelo (sin red): manos repartidas según el nº de jugadores, más plumas cuantos más jugadores,
## atrapar rosa/dorada/marrón (+1/+3/-3, sin bajar de 0), una pluma por cierre y espera entre cierres, ratón,
## plumas que caen y se pierden en el suelo, réplica en un cliente y partidas completas con bots.
## Ejecutar:  godot --headless --path . --script res://tests/feather_catch_test.gd

var _began: bool = false
var _ranking: Array = []
var _events: Array = []

func _new_game(n_bots: int, game_seed: int = 1, humans: Array = []):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	for d in humans:
		lobby.add_player(d)
	for i in n_bots:
		lobby.add_bot()
	var meta = load("res://minigames/feather_catch/meta.tres")
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
	var FC = load("res://minigames/feather_catch/feather_catch.gd")

	# --- Manos repartidas y dentro de la zona; más plumas cuantos más jugadores ---
	var layout_ok := true
	for n in range(2, 9):
		var xs: Array[float] = []
		for i in n:
			var p: Vector2 = FC.start_pos(i, n)
			if not FC.PLAY_AREA.has_point(p):
				layout_ok = false
			xs.append(p.x)
		for i in range(1, n):
			if xs[i] - xs[i - 1] < 100.0:
				layout_ok = false
	_check(layout_ok, "de 2 a 8 jugadores: las manos empiezan repartidas a lo ancho y dentro de la zona", failures)
	_check(FC.max_feathers(8) > FC.max_feathers(2) and FC.spawn_interval(8) < FC.spawn_interval(2),
			"con más jugadores caen más plumas (%d → %d a la vez)" % [FC.max_feathers(2), FC.max_feathers(8)], failures)

	# --- Atrapar: rosa +1, dorada +3, marrón -3 sin bajar de 0; una por cierre; espera entre cierres ---
	var g = _new_game(3)
	g._feathers.clear()
	var h = g.hand(0)
	var p0 = h.player
	h.pos = Vector2(400, 300)
	var f1 = g._spawn_feather(100.0)
	f1.kind = FC.Kind.PINK
	f1.pos = h.pos + Vector2(10, 0)
	var f2 = g._spawn_feather(100.0)
	f2.kind = FC.Kind.PINK
	f2.pos = h.pos + Vector2(-25, 5)
	_check(g.try_grab(h) == f1 and g.score_of(p0) == 1 and g.feathers().size() == 1, "cerrar la mano atrapa la pluma más cercana (+1) y solo una", failures)
	_check(g.try_grab(h) == null and g.feathers().size() == 1 and h.grab_t > 0.0, "justo después de cerrar, la mano necesita un momento", failures)
	h.cool = 0.0
	f2.kind = FC.Kind.GOLD
	_check(g.try_grab(h) == f2 and g.score_of(p0) == 4, "la dorada vale +3", failures)
	h.cool = 0.0
	var f3 = g._spawn_feather(100.0)
	f3.kind = FC.Kind.BROWN
	f3.pos = h.pos
	_check(g.try_grab(h) == f3 and g.score_of(p0) == 1, "la marrón quita 3", failures)
	h.cool = 0.0
	var f4 = g._spawn_feather(100.0)
	f4.kind = FC.Kind.BROWN
	f4.pos = h.pos
	_check(g.try_grab(h) == f4 and g.score_of(p0) == 0, "los puntos no bajan de 0", failures)
	h.cool = 0.0
	var f5 = g._spawn_feather(100.0)
	f5.kind = FC.Kind.PINK
	f5.pos = h.pos + Vector2(FC.GRAB_RADIUS + 20.0, 0)
	_check(g.try_grab(h) == null and g.feathers().has(f5), "una pluma lejos de la mano no se atrapa", failures)
	g.free()

	# --- Las plumas caen meciéndose y se pierden al llegar al suelo ---
	g = _new_game(2, 3)
	g._feathers.clear()
	var f = g._spawn_feather(0.0)
	var y0: float = f.pos.y
	var xs_seen: Array[float] = []
	var lost := false
	for i in 60 * 20:
		g._update_feathers(1.0 / 60.0)
		if not g.feathers().has(f):
			lost = true
			break
		xs_seen.append(f.pos.x)
	var sway: float = xs_seen.max() - xs_seen.min() if not xs_seen.is_empty() else 0.0
	_check(lost and sway > 30.0, "una pluma baja meciéndose (%.0f px de lado a lado) y se pierde en el suelo" % sway, failures)
	_check(g.feathers().size() > 0 and g.feathers().size() <= FC.max_feathers(2), "siguen saliendo plumas, sin pasar del máximo", failures)
	var brown_ok := true
	for i in 60 * 30:
		g._update_feathers(1.0 / 60.0)
		var browns := 0
		for o in g.feathers():
			if o.kind == FC.Kind.BROWN:
				browns += 1
		if browns > FC.max_browns(2):
			brown_ok = false
	_check(brown_ok, "las marrones nunca llenan el cielo (como mucho %d a la vez)" % FC.max_browns(2), failures)
	g.free()

	# --- Ratón: la mano va al puntero; textos raros no hacen nada ---
	g = _new_game(1, 5, ["kb1"])
	var hm = g.hand(0)
	g.deliver_player_text(null, "m:900,200", false)
	for i in 30:
		g._update_hands(1.0 / 60.0)
	_check(hm.pos.distance_to(Vector2(900, 200)) < 1.0, "con el ratón la mano va al puntero", failures)
	g.deliver_player_text(null, "m:hola", false)
	g.deliver_player_text(null, "m:5000,-300", false)
	for i in 30:
		g._update_hands(1.0 / 60.0)
	_check(FC.PLAY_AREA.grow(1.0).has_point(hm.pos), "un puntero fuera de la pantalla no saca la mano de la zona", failures)
	var bot_hand = g.hand(1)
	var bot_before: Vector2 = bot_hand.mouse_target
	g.deliver_player_text(bot_hand.player, "m:100,100", false)
	_check(bot_hand.mouse_target == bot_before, "el ratón no mueve la mano de un bot", failures)
	g.free()

	# --- Un cliente ve lo mismo que el host con el estado y los eventos ---
	g = _new_game(4, 21)
	var cl = (load("res://minigames/feather_catch/meta.tres").scene as PackedScene).instantiate()
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
	for i in 60 * 12:
		g._simulate(1.0 / 60.0)
	cl.apply_state(g.serialize_state())
	cl.apply_state(g.serialize_state())
	var same: bool = cl.feathers().size() == g.feathers().size() and absf(cl._time_left - g._time_left) < 0.01
	for i in g.hand_count():
		if cl.score_of(g.hand(i).player) != g.score_of(g.hand(i).player) or cl.hand(i).pos.distance_to(g.hand(i).pos) > 0.5:
			same = false
	for i in g.feathers().size():
		if cl.feathers()[i].pos.distance_to(g.feathers()[i].pos) > 0.5 or cl.feathers()[i].kind != g.feathers()[i].kind:
			same = false
	var catches := 0
	for e in _events:
		if e[0] == "catch":
			catches += 1
			cl.deliver_event(e[0], e[1])
	_check(same and catches > 0, "un cliente ve las mismas manos, plumas y puntos que el host (%d plumas atrapadas)" % catches, failures)
	g.set_session(null)
	fake.free()
	cl.free()
	g.free()

	# --- Partidas completas con bots ---
	for n in [2, 3, 5, 8]:
		var gm = _new_game(n, 40 + n)
		var steps := 0
		var min_score := 0
		while _ranking.is_empty() and steps < 60 * 60:
			gm._simulate(1.0 / 60.0)
			gm._animate(1.0 / 60.0)
			for i in gm.hand_count():
				min_score = mini(min_score, gm.score_of(gm.hand(i).player))
			steps += 1
		var seen := {}
		for id in _ranking:
			seen[id] = true
		var sorted_ok := true
		for i in range(1, _ranking.size()):
			if gm._scores[_ranking[i]] > gm._scores[_ranking[i - 1]]:
				sorted_ok = false
		var total := 0
		var scorers := 0
		for p in gm.players:
			total += int(gm._scores[p.id])
			if int(gm._scores[p.id]) > 0:
				scorers += 1
		var dur: float = steps / 60.0
		_check(_ranking.size() == n and seen.size() == n and sorted_ok and scorers >= n - 1 and min_score >= 0
				and absf(dur - FC.DURATION) < 0.1,
				"partida de %d bots: termina a los %.1f s, ranking por puntos (ganador %d, total %d)" % [n, dur,
				gm._scores[_ranking[0]] if not _ranking.is_empty() else -1, total], failures)
		gm.free()

	print("")
	if failures.is_empty():
		print("FEATHER CATCH TEST OK")
		quit(0)
	else:
		print("FEATHER CATCH TEST FALLÓ")
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
