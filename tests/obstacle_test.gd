extends SceneTree
## Prueba de la Carrera de Ruinas 3D (LOCAL_PARALLEL, tercera persona): el recorrido sale de la semilla, la física del
## cuerpo (salto, escalones, caída a la niebla y punto de control), la IA completa el recorrido, quedarse quieto no
## llega, el resultado se reporta y valida, y la escena 3D se monta.
## Ejecutar:  godot --headless --path . --script res://tests/obstacle_test.gd

var _began: bool = false
var _reported: Array = []

func _new_game(seed_value: int, bot: bool = true):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	var me = lobby.add_bot() if bot else lobby.add_player("kb1")
	lobby.add_bot()
	var meta = load("res://minigames/obstacle_run/meta.tres")
	var mg = (meta.scene as PackedScene).instantiate()
	root.add_child(mg)
	mg.configure(1, seed_value, me)
	mg.prepare(lobby.players)
	_reported = []
	mg.result_reported.connect(func(score: float, tiebreak: float) -> void: _reported = [score, tiebreak])
	mg.start(lobby.players)
	return mg

func _process(_delta: float) -> bool:
	if _began:
		return true
	_began = true
	var f: Array[String] = []
	# 1) Determinista por semilla y con todas las zonas.
	var a = _new_game(77)
	var b = _new_game(77)
	var c = _new_game(78)
	_ck(f, a.debug_signature() == b.debug_signature(), "mismo recorrido con la misma semilla")
	_ck(f, a.debug_signature() != c.debug_signature(), "semillas distintas dan recorridos distintos")
	var info: Dictionary = a.debug_info()
	print("  recorrido: ", info)
	_ck(f, int(info.zones) == 8 and int(info.cps) >= 7 and int(info.bars) == 1, "8 zonas, puntos de control y una barra giratoria")
	_ck(f, float(info.total) > 150.0 and float(info.total) < 400.0, "longitud razonable (%.0f m)" % float(info.total))
	# 2) Física del cuerpo sobre la salida.
	var p0: Vector3 = a.debug_state().p
	for i in 60:
		a._sim_step(1.0 / 60.0, Vector3.ZERO, false)
	var st: Dictionary = a.debug_state()
	_ck(f, st.grounded and absf((st.p as Vector3).y - p0.y) < 0.05, "se apoya en el suelo de la salida")
	# Salto: sube ~1.6 m y vuelve a caer en el sitio.
	var peak := 0.0
	var y0: float = (a.debug_state().p as Vector3).y
	a._sim_step(1.0 / 60.0, Vector3.ZERO, true)
	for i in 80:
		a._sim_step(1.0 / 60.0, Vector3.ZERO, false)
		peak = maxf(peak, (a.debug_state().p as Vector3).y - y0)
	_ck(f, peak > 1.3 and peak < 2.0, "el salto alcanza %.2f m" % peak)
	_ck(f, a.debug_state().grounded, "aterriza tras el salto")
	# Caída a la niebla: se vuelve al punto de control tras un momento.
	a.debug_place((a.debug_state().p as Vector3) + Vector3(0, -30, 0))
	for i in 120:
		a._sim_step(1.0 / 60.0, Vector3.ZERO, false)
	_ck(f, a.debug_state().falls == 1 and (a.debug_state().p as Vector3).y > -2.0, "al caer a la niebla se reaparece en el punto de control")
	for g in [a, b, c]:
		g.queue_free()
	# 3) La IA completa el recorrido; quedarse quieto no.
	var fin := 0
	var falls := 0
	var times := 0.0
	var seeds := 16
	for s in seeds:
		var g = _new_game(2000 + s * 17)
		var r: Dictionary = g.debug_run("bot", 1.0)
		if r.finished:
			fin += 1
			times += float(r.time)
		falls += int(r.falls)
		if not r.finished:
			print("    semilla ", 2000 + s * 17, " no llegó: progreso ", r.progress, "/", r.total, " caídas ", r.falls, " estado ", g.debug_state())
		g.queue_free()
	print("  IA: %d/%d llegan, tiempo medio %.1f s, caídas medias %.1f" % [fin, seeds, times / maxf(fin, 1), float(falls) / seeds])
	_ck(f, fin >= seeds - 1, "la IA llega a la meta en casi todos los recorridos (%d/%d)" % [fin, seeds])
	_ck(f, times / maxf(fin, 1) < 80.0, "tarda un tiempo razonable (%.1f s)" % (times / maxf(fin, 1)))
	_ck(f, times / maxf(fin, 1) > 480.0 / 22.0 * 0.0 + 18.0, "no es físicamente imposible (%.1f s)" % (times / maxf(fin, 1)))
	var idle = _new_game(2000)
	var ri: Dictionary = idle.debug_run("idle", 1.0, 20.0)
	_ck(f, not ri.finished and float(ri.progress) < 10.0, "sin tocar nada no se avanza")
	idle.queue_free()
	# 4) Partida real con la IA: se reporta el resultado, plausible.
	var g2 = _new_game(31337)
	var t := 0.0
	while t < 150.0 and _reported.is_empty():
		g2._play(0.05)
		g2._animate(0.05)
		t += 0.05
	print("  partida real: ", _reported, " a los %.0f s" % t)
	_ck(f, not _reported.is_empty(), "la partida con IA reporta resultado")
	if not _reported.is_empty():
		_ck(f, g2.validate_result(_reported[0], _reported[1]), "el resultado de la IA es plausible")
	_ck(f, not g2.validate_result(float(g2.debug_info().total), 4.0), "llegar a la meta en 4 s es imposible")
	_ck(f, not g2.validate_result(9999.0, 30.0), "pasarse del recorrido es imposible")
	_ck(f, g2.validate_result(float(g2.debug_info().total), 45.0), "llegar a la meta en 45 s es válido")
	var ranked = g2.rank_results({g2.players[0].id: {"score": 200.0, "tiebreak": 100.0}, g2.players[1].id: {"score": 250.0, "tiebreak": 100.0}})
	_ck(f, ranked[0] == g2.players[1].id, "ranking: más lejos primero")
	# 5) La escena 3D se monta.
	_ck(f, g2._built and g2._cam != null and g2._pl != null, "la escena 3D (cámara, mundo propio y personaje) se construye")
	print("")
	if f.is_empty():
		print("OBSTACLE TEST OK")
		quit(0)
	else:
		print("OBSTACLE TEST FALLÓ: ", f)
		quit(1)
	return true

func _ck(f: Array[String], cond: bool, what: String) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		f.append(what)
		print("  ✗ " + what)
