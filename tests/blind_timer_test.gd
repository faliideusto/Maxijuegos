extends SceneTree
## Prueba de Crono a Ciegas (sin red): objetivo, desaparición del crono, una sola parada por jugador,
## clasificación por cercanía y partidas completas con bots.
## Ejecutar:  godot --headless --path . --script res://tests/blind_timer_test.gd

var _began: bool = false
var _ranking: Array = []
var _events: Array = []

func _new_game(n_bots: int, game_seed: int = 1):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	for i in n_bots:
		lobby.add_bot()
	var meta = load("res://minigames/blind_timer/meta.tres")
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
	var BT = load("res://minigames/blind_timer/blind_timer.gd")

	# --- Objetivo al azar: entero, entre 5 y 15 s, y varía con la semilla ---
	var targets := {}
	var range_ok := true
	for sd in range(1, 80):
		var g0 = _new_game(2, sd)
		targets[g0._target] = true
		if g0._target < BT.MIN_TARGET or g0._target > BT.MAX_TARGET or g0._target != floorf(g0._target):
			range_ok = false
		g0.free()
	_check(range_ok and targets.size() >= 8, "el objetivo es un entero de %d a %d s y cambia con la semilla (%d distintos)" % [BT.MIN_TARGET, BT.MAX_TARGET, targets.size()], failures)

	# --- El crono desaparece antes del objetivo ---
	var hide_ok := true
	for t in range(BT.MIN_TARGET, BT.MAX_TARGET + 1):
		var h: float = BT.hide_time_for(float(t))
		if h < BT.HIDE_MIN or h > BT.HIDE_MAX or h + BT.HIDE_FADE > float(t) - 1.5:
			hide_ok = false
	_check(hide_ok, "el crono se esconde entre %.0f y %.0f s y siempre bastante antes del objetivo" % [BT.HIDE_MIN, BT.HIDE_MAX], failures)
	var g = _new_game(4)
	g._elapsed = g._hide_at - 0.01
	_check(g.clock_alpha() == 1.0, "antes de esconderse el crono se ve entero", failures)
	g._elapsed = g._hide_at + BT.HIDE_FADE + 0.01
	_check(g.clock_alpha() == 0.0, "después ya no se ve", failures)

	# --- Clasificación: gana el más cercano (por arriba o por abajo); sin parar = último ---
	g._target = 8.0
	var ids: Array[int] = []
	for p in g.players:
		ids.append(p.id)
	g._stops[ids[0]] = 9.0       # +1,00
	g._stops[ids[1]] = 7.7       # -0,30
	g._stops[ids[2]] = BT.NO_STOP
	g._stops[ids[3]] = 8.1       # +0,10
	var want: Array[int] = [ids[3], ids[1], ids[0], ids[2]]
	_check(g.build_ranking() == want, "gana el más cercano por arriba o por abajo; quien no para queda último", failures)
	g._stops[ids[0]] = 8.5
	g._stops[ids[1]] = 7.5
	_check(g.build_ranking().find(ids[1]) < g.build_ranking().find(ids[0]), "a igual error, gana quien pulsó antes", failures)
	g.free()

	# --- Una sola parada por jugador y el primer segundo no cuenta ---
	g = _new_game(3)
	var pid: int = g.players[0].id
	for id in g._bot_stop:
		g._bot_stop[id] = 999.0
	g._bot_stop[pid] = 0.2
	while g._elapsed < BT.GRACE - 0.1:
		g._simulate(1.0 / 60.0)
	_check(not g._stopped[pid], "una pulsación en el primer segundo no para el crono", failures)
	while g._elapsed < 3.0:
		g._simulate(1.0 / 60.0)
	var first: float = g._stops[pid]
	_check(g._stopped[pid] and absf(first - BT.GRACE) < 0.05, "la primera pulsación válida para el crono del jugador (%.2f s)" % first, failures)
	while g._elapsed < 5.0:
		g._simulate(1.0 / 60.0)
	_check(g._stops[pid] == first, "pulsar otra vez no cambia el tiempo", failures)
	# Los tiempos no viajan en el estado mientras se juega (nadie puede verlos antes del destape).
	var st: Dictionary = g._serialize_state()
	_check(st.keys() == ["ph", "t", "tg", "st", "rv"], "el estado que va a los clientes no lleva los tiempos de nadie", failures)
	# Nadie más pulsa: se cierra al pasar objetivo + margen.
	while g._phase == BT.Phase.RUN and g._elapsed < 60.0:
		g._simulate(1.0 / 60.0)
	_check(g._phase == BT.Phase.REVEAL and absf(g._elapsed - (g._target + BT.OVERTIME)) < 0.05, "si alguien no pulsa, se cierra %.0f s después del objetivo" % BT.OVERTIME, failures)
	while _ranking.is_empty() and g._reveal_t < 60.0:
		g._simulate(1.0 / 60.0)
	_check(_ranking.size() == 3 and _ranking[0] == pid, "el único que paró gana y el ranking está completo", failures)
	g.free()

	# --- Un cliente reproduce el destape con el estado y los eventos del host ---
	g = _new_game(4)
	var cl = (load("res://minigames/blind_timer/meta.tres").scene as PackedScene).instantiate()
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
	while g._phase == BT.Phase.RUN and g._elapsed < 60.0:
		g._simulate(1.0 / 60.0)
		cl.apply_state(g.serialize_state())
	for e in _events:
		cl.deliver_event(e[0], e[1])
	var same: bool = cl._order == g._order and cl._target == g._target and cl._phase == BT.Phase.REVEAL
	for p in g.players:
		if absf(float(cl._stops[p.id]) - float(g._stops[p.id])) > 0.001 or not cl._stopped[p.id]:
			same = false
	_check(same and _events.size() == 6, "un cliente ve el mismo objetivo, tiempos y orden que el host (%d eventos: hide + 4 stop + reveal)" % _events.size(), failures)
	g.set_session(null)
	fake.free()
	cl.free()
	g.free()

	# --- Partidas completas con bots ---
	for n in [2, 3, 5, 8]:
		var gm = _new_game(n, 40 + n)
		var steps := 0
		while _ranking.is_empty() and steps < 60 * 120:
			gm._simulate(1.0 / 60.0)
			gm._animate(1.0 / 60.0)
			steps += 1
		var seen := {}
		for id in _ranking:
			seen[id] = true
		var sorted_ok := true
		for i in range(1, _ranking.size()):
			if gm.error_of(_ranking[i]) < gm.error_of(_ranking[i - 1]):
				sorted_ok = false
		var worst: float = gm.error_of(_ranking[_ranking.size() - 1]) if not _ranking.is_empty() else INF
		_check(_ranking.size() == n and seen.size() == n and sorted_ok and worst < INF, "partida de %d bots: todos paran, ranking por cercanía (objetivo %d s, ganador a %.2f s, último a %.2f s, %.0f s de partida)" % [n, int(gm._target), gm.error_of(_ranking[0]) if not _ranking.is_empty() else -1.0, worst, steps / 60.0], failures)
		gm.free()

	print("")
	if failures.is_empty():
		print("BLIND TIMER TEST OK")
		quit(0)
	else:
		print("BLIND TIMER TEST FALLÓ")
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
