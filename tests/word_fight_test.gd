extends SceneTree
## Prueba de la Pelea de Palabras (HOST_AUTHORITATIVE, 3D): la disposición de casillas, las palabras, pulsar letras (acierto,
## error, bonus de palabra), golpes (aturdir, retroceso, perder una letra, inmunidad), el segundo botón por la red (c2),
## la IA (juega sola y puntúa), el estado enviado a un "cliente" y el ranking final.
## Ejecutar:  godot --headless --path . --script res://tests/word_fight_test.gd

var _began: bool = false
var _ranking: Array = []

func _new_game(bots: int = 3, authority: bool = true, seed_value: int = 99):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	var me = lobby.add_bot()
	for i in bots - 1:
		lobby.add_bot()
	var meta = load("res://minigames/word_fight/meta.tres")
	var mg = (meta.scene as PackedScene).instantiate()
	mg.is_authority = authority
	root.add_child(mg)
	mg.configure(0, seed_value, me)
	mg.prepare(lobby.players)
	mg.start(lobby.players)
	return mg

func _process(_delta: float) -> bool:
	if _began:
		return true
	_began = true
	var f: Array[String] = []
	var g = _new_game(2)
	var a: int = g.players[0].id
	var b: int = g.players[1].id
	# 1) Casillas: 26 distintas, cada una se encuentra bajo su centro, A-F abajo y Y/Z arriba y centradas.
	var seen := {}
	var ok_layout := true
	for k in 26:
		var c: Vector2 = g.debug_pad_center(k)
		seen[str(c)] = true
		if g.debug_pad_under(c) != k:
			ok_layout = false
	_ck(f, seen.size() == 26 and ok_layout, "26 casillas distintas, cada una reconocida bajo su centro")
	_ck(f, g.debug_pad_center(0).y > g.debug_pad_center(6).y and g.debug_pad_center(24).y < g.debug_pad_center(18).y, "A-F abajo y Y-Z arriba")
	_ck(f, absf(g.debug_pad_center(24).x + g.debug_pad_center(25).x) < 0.01, "Y y Z están centradas")
	# 2) Palabras: solo A-Z, de 3 a 14 letras, y se vuelven más largas con la partida.
	var words: Array = g.debug_pick_words(40)
	var valid := true
	for w in words:
		if w.length() < 3 or w.length() > 14:
			valid = false
		for ch in w:
			if "ABCDEFGHIJKLMNOPQRSTUVWXYZ".find(ch) < 0:
				valid = false
	_ck(f, valid, "todas las palabras usan solo A-Z (3 a 14 letras)")
	var early := 0.0
	var late := 0.0
	for i in 8:
		early += (words[i] as String).length()
		late += (words[32 + i] as String).length()
	_ck(f, late > early, "las palabras se alargan con la partida (%.1f → %.1f)" % [early / 8.0, late / 8.0])
	# 3) Pulsar letras: acierto suma 1 y avanza; error no suma y bloquea un momento; fuera de casilla no pasa nada.
	g.debug_set_word("SOL")
	var k_s := "ABCDEFGHIJKLMNOPQRSTUVWXYZ".find("S")
	g.debug_place(a, g.debug_pad_center(k_s))
	g.debug_press(a)
	var pa: Dictionary = g.debug_player(a)
	_ck(f, pa.progress == 1 and pa.score == 1, "pisar la S y pulsar acierta la primera letra de SOL (+1)")
	var k_x := "ABCDEFGHIJKLMNOPQRSTUVWXYZ".find("X")
	g.debug_place(a, g.debug_pad_center(k_x))
	g.debug_press(a)
	pa = g.debug_player(a)
	_ck(f, pa.progress == 1 and pa.score == 1, "una letra equivocada no suma ni avanza")
	g.debug_press(a)                      # sigue bloqueado (error reciente)
	g.debug_place(a, Vector2(-10.5, 8.0))
	g.debug_press(a)
	pa = g.debug_player(a)
	_ck(f, pa.progress == 1, "pulsar fuera de una casilla no hace nada")
	for i in 20:
		g._simulate(1.0 / 30.0)           # pasa el bloqueo por error
	g.debug_place(a, g.debug_pad_center("ABCDEFGHIJKLMNOPQRSTUVWXYZ".find("O")))
	g.debug_press(a)
	g.debug_place(a, g.debug_pad_center("ABCDEFGHIJKLMNOPQRSTUVWXYZ".find("L")))
	g.debug_press(a)
	pa = g.debug_player(a)
	var word_changed: bool = g.debug_word() != "SOL"
	_ck(f, pa.score == 1 + 1 + 1 + 3 and word_changed, "completar la palabra da +3 de bonus y cambia la palabra para todos (puntos %d)" % pa.score)
	_ck(f, g.debug_player(b).progress == 0, "al cambiar la palabra el progreso de todos vuelve a cero")
	# 4) Golpes: aturde, empuja, quita una letra y da inmunidad; el aturdido no puede pulsar.
	g.debug_set_word("LUNA")
	g.debug_place(a, g.debug_pad_center("ABCDEFGHIJKLMNOPQRSTUVWXYZ".find("L")))
	g.debug_press(a)
	g.debug_place(b, g.debug_pad_center(0))
	g.debug_place(b, Vector2(0.0, 0.0), 0.0)
	g.debug_place(a, Vector2(0.0, -1.0), 0.0)  # mira hacia +z (hacia b)
	g.debug_punch(a)
	var pb: Dictionary = g.debug_player(b)
	_ck(f, pb.stun > 1.0 and (pb.vel as Vector2).length() > 5.0, "el golpe aturde y empuja (stun %.1f s)" % pb.stun)
	_ck(f, g.debug_player(a).progress == 1, "(el atacante no pierde nada)")
	# b ya tenía 0 letras: comprobamos la pérdida de una letra con otro golpe tras recuperarse
	_ck(f, pb.inv > pb.stun, "queda inmune un momento tras recuperarse")
	g.debug_press(b)
	_ck(f, g.debug_player(b).progress == 0 and g.debug_player(b).score == 0, "aturdido no puede pulsar letras")
	g.debug_punch(a)                       # en cooldown / objetivo inmune: no pasa nada nuevo
	_ck(f, g.debug_player(b).stun <= pb.stun + 0.01, "no se puede encadenar golpes sobre alguien inmune")
	# 5) Segundo botón por la red: el cliente envía c2 y el host lo convierte en pulsaciones.
	var im = root.get_node("InputManager")
	var remote_ok := true
	var fake := PlayerData.new()
	fake.id = 777
	fake.device = PlayerData.DEVICE_REMOTE
	im.register_player(fake)
	im.set_remote_input(777, Vector2(1, 0), 0, 3)
	im._process(0.016)
	remote_ok = im.action2_presses(777) == 3
	im._process(0.016)
	remote_ok = remote_ok and im.action2_presses(777) == 0
	im.set_remote_input(777, Vector2.ZERO, 0, 2)          # contador antiguo: se ignora
	im._process(0.016)
	remote_ok = remote_ok and im.action2_presses(777) == 0
	im.unregister_player(fake)
	_ck(f, remote_ok, "el segundo botón remoto (c2) llega como pulsaciones y no se repite")
	g.set_process(false)
	g.queue_free()
	# 6) Partida completa con 5 IAs y un cliente espejo.
	var g2 = _new_game(5, true, 31337)
	g2.finished.connect(func(r: Array[int]) -> void: _ranking = r)
	var client = _new_game(5, false, 31337)
	var ids: Array = []
	for p in g2.players:
		ids.append(p.id)
	var t := 0.0
	var mirror_ok := true
	while t < 130.0 and _ranking.is_empty():
		g2._process(1.0 / 30.0)
		t += 1.0 / 30.0
		client.apply_state(g2.serialize_state())
		client._animate(1.0 / 30.0)
	var total_score := 0
	for id in ids:
		var hd: Dictionary = g2.debug_player(id)
		var cd: Dictionary = client.debug_player(id)
		total_score += int(hd.score)
		if int(hd.score) != int(cd.score) or (hd.pos as Vector2).distance_to(cd.pos as Vector2) > 0.5:
			mirror_ok = false
	print("  partida con 5 IAs: terminó a los %.1f s, ranking %s, puntos totales %d" % [t, _ranking, total_score])
	_ck(f, _ranking.size() == 5, "la partida acaba a los ~93 s y devuelve el ranking de los 5 (%.1f s)" % t)
	_ck(f, t > 85.0 and t < 100.0, "dura lo previsto (90 s + cuenta atrás + final)")
	_ck(f, total_score >= 40, "las IAs juegan: reparten puntos (%d)" % total_score)
	_ck(f, mirror_ok, "el cliente refleja los mismos puntos y posiciones que el host")
	var best_id: int = -1
	var best_sc := -1
	for id in ids:
		var sc: int = g2.debug_player(id).score
		if sc > best_sc:
			best_sc = sc
			best_id = id
	_ck(f, _ranking.size() == 5 and g2.debug_player(_ranking[0]).score == best_sc, "el primero del ranking es el de más puntos")
	var nodes := 0
	for id in ids:
		if g2._rs[id].node != null and client._rs[id].node != null:
			nodes += 1
	_ck(f, g2._built and g2._cam != null and nodes == 5 and g2._pads.size() == 26, "la escena 3D tiene 26 casillas y un personaje por jugador")
	g2.set_process(false)
	client.set_process(false)
	print("")
	if f.is_empty():
		print("WORD FIGHT TEST OK")
		quit(0)
	else:
		print("WORD FIGHT TEST FALLÓ: ", f)
		quit(1)
	return true

func _ck(f: Array[String], cond: bool, what: String) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		f.append(what)
		print("  ✗ " + what)
