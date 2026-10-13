extends SceneTree
## Prueba de Karts Arcoíris 3D (HOST_AUTHORITATIVE): la pista es un circuito cerrado con puente (el de arriba y la recta
## de abajo no se confunden), el kart acelera y gira, las barandillas te paran y donde no hay te caes y la nube te
## devuelve, derrape con turbo, salto en la rampa con acrobacia, cajas de objetos, plátano, caparazones (verde, rojo y
## azul), champiñón, estrella y rayo, vueltas y meta, carreras completas con bots (de 2 a 8), estado para un "cliente"
## y pantalla partida (una cámara por persona del PC).
## Ejecutar:  godot --headless --path . --script res://tests/rainbow_kart_test.gd

const DT := 1.0 / 60.0
var _began: bool = false

func _new_game(seed_value: int, bots: int = 4, authority: bool = true, humans: Array = []):
	var lobby = root.get_node("Lobby")
	for p in lobby.players.duplicate():
		lobby.remove_player(p.id)
	var me = null
	for dev in humans:
		var h = lobby.add_player(dev)
		if me == null:
			me = h
	for i in bots:
		var b = lobby.add_bot()
		if me == null:
			me = b
	var meta = load("res://minigames/rainbow_kart/meta.tres")
	var mg = (meta.scene as PackedScene).instantiate()
	mg.is_authority = authority
	root.add_child(mg)
	mg.configure(0, seed_value, null if not humans.is_empty() else me)
	mg.prepare(lobby.players)
	mg.start(lobby.players)
	return mg

func _steps(g, id: int, n: int, steer: float = 0.0, vert: float = 0.0, held: int = -1) -> void:
	for i in n:
		g.debug_step(id, steer, vert, false, false, held)

func _process(_delta: float) -> bool:
	if _began:
		return true
	_began = true
	var f: Array[String] = []
	var Item = load("res://minigames/rainbow_kart/rainbow_kart.gd").Item
	# 1) Pista cerrada, con el puente por encima de la recta de salida.
	var g = _new_game(5, 2)
	var tr: Dictionary = g.debug_track()
	var n: int = tr.n
	print("  pista: %d puntos, %.0f m, rampa %s, %d cajas, %d monedas" % [n, float(tr.len), str(tr.ramp), int(tr.boxes), int(tr.coins)])
	_ck(f, float(tr.len) > 650.0 and float(tr.len) < 850.0, "la vuelta mide %.0f m" % float(tr.len))
	var closed := true
	for i in n:
		if g.debug_point(i).distance_to(g.debug_point(i + 1)) > 1.3:
			closed = false
	_ck(f, closed, "circuito cerrado y continuo")
	var low := -1
	var high := -1
	for i in n:
		var p: Vector3 = g.debug_point(i)
		if Vector2(p.x, p.z).distance_to(Vector2(0.0, 30.4)) < 2.0:
			if p.y < 2.0 and low < 0:
				low = i
			elif p.y > 10.0 and high < 0:
				high = i
	_ck(f, low >= 0 and high >= 0, "el puente cruza por encima de la recta de salida")
	if low >= 0 and high >= 0:
		var q := Vector3(0.0, 5.0, 30.4)
		_ck(f, g.debug_ground(q, low) < 2.0 and g.debug_ground(q, high) > 10.0, "abajo y arriba no se confunden en el cruce")
	_ck(f, not g.debug_rail(int(0.38 * n)) and g.debug_rail(int(0.2 * n)), "el puente no tiene barandilla y las curvas sí")
	var id: int = g.players[0].id
	var other: int = g.players[1].id
	g.debug_place(other, int(0.5 * n), 0.0)
	# 2) Acelera solo y gira.
	g.debug_place(id, 2, 0.0)
	_steps(g, id, 60 * 3)
	var k: Dictionary = g.debug_kart(id)
	_ck(f, absf(float(k.speed) - 27.0) < 1.5, "acelera solo hasta la punta (%.1f m/s)" % float(k.speed))
	_ck(f, int(k.seg) > 50 and int(k.state) == 0, "avanza por la recta (punto %d)" % int(k.seg))
	g.debug_place(id, 5, 0.0, 20.0)
	_steps(g, id, 30, 1.0)
	_ck(f, float(g.debug_kart(id).d) > 1.0, "a la derecha gira a la derecha (lateral %.1f)" % float(g.debug_kart(id).d))
	g.debug_place(id, 5, 0.0, 20.0)
	_steps(g, id, 40, 0.0, 1.0)
	_ck(f, float(g.debug_kart(id).speed) < 1.0, "abajo frena (%.1f m/s)" % float(g.debug_kart(id).speed))
	# 3) Barandilla: no te deja salir.
	g.debug_place(id, int(0.2 * n), 0.0, 25.0)
	_steps(g, id, 60 * 2, 1.0)
	k = g.debug_kart(id)
	_ck(f, int(k.state) == 0 and absf(float(k.d)) <= g.debug_width(int(k.seg)) * 0.5, "la barandilla te mantiene en la pista")
	# 4) Sin barandilla: te caes y la nube te devuelve.
	g.debug_set(id, "coins", 5)
	g.debug_place(id, int(0.38 * n), 0.0, 25.0)
	var fell := false
	for i in 60 * 5:
		g.debug_step(id, 1.0 if i < 60 else 0.0)
		if int(g.debug_kart(id).state) != 0:
			fell = true
	k = g.debug_kart(id)
	_ck(f, fell and int(k.falls) == 1, "sin barandilla te caes")
	_ck(f, int(k.state) == 0 and absf(float(k.d)) < 4.0 and float(k.y) > 10.0, "la nube te deja otra vez en el puente (lateral %.1f, altura %.1f)" % [float(k.d), float(k.y)])
	_ck(f, int(k.coins) == 3, "caerte cuesta 2 monedas")
	# 5) Derrape: mantener al girar y soltar = turbo.
	g.debug_place(id, int(0.2 * n), 0.0, 24.0)
	g.debug_step(id, 1.0, 0.0, true, false, 1)
	_ck(f, int(g.debug_kart(id).drift) == 1, "pulsar al girar empieza el derrape")
	var lvl_t := 0.0
	for i in 60 * 2:
		g.debug_step(id, 0.6, 0.0, false, false, 1)
		if i % 10 == 9:
			g.debug_place(id, int(0.2 * n), 0.0, 24.0)       # que no llegue a la barandilla
	lvl_t = float(g.debug_kart(id).drift_t)
	g.debug_step(id, 0.6, 0.0, false, false, 0)
	k = g.debug_kart(id)
	_ck(f, lvl_t >= 1.55 and int(k.drift) == 0 and float(k.boost) > 0.8, "al soltar tras %.1f s sale el turbo naranja (%.2f s)" % [lvl_t, float(k.boost)])
	_steps(g, id, 20, 0.0)
	_ck(f, float(g.debug_kart(id).speed) > 30.0, "con el turbo supera la punta (%.1f m/s)" % float(g.debug_kart(id).speed))
	g.debug_place(id, int(0.2 * n), 0.0, 24.0)
	g.debug_step(id, 0.0, 0.0, true, false, 1)
	_ck(f, bool(g.debug_kart(id).air) and int(g.debug_kart(id).drift) == 0, "sin girar es solo un saltito")
	_steps(g, id, 30, 0.0, 0.0, 0)
	_ck(f, not bool(g.debug_kart(id).air), "y vuelve al suelo")
	# 6) Rampa: salto y acrobacia con turbo al caer.
	var ramp: Vector2i = tr.ramp
	g.debug_place(id, ramp.x - 25, 0.0, 27.0)
	var flew := false
	var tricked := false
	var boost_land := 0.0
	for i in 60 * 3:
		var dk: Dictionary = g.debug_kart(id)
		var press: bool = bool(dk.air) and not tricked and int(dk.seg) > ramp.y
		if press:
			tricked = true
		var was_air := bool(dk.air)
		g.debug_step(id, 0.0, 0.0, press, false, 0)
		dk = g.debug_kart(id)
		if bool(dk.air) and int(dk.seg) > ramp.y + 3:
			flew = true
		if was_air and not bool(dk.air) and tricked:
			boost_land = maxf(boost_land, float(dk.boost))
	_ck(f, flew, "la rampa te hace volar")
	_ck(f, boost_land > 0.3, "la acrobacia da turbo al aterrizar")
	# 7) Cajas de objetos.
	g.debug_place(id, int(0.074 * n) - 20, 0.0, 25.0)
	g.debug_give(id, Item.NONE, 0)
	_steps(g, id, 50)
	k = g.debug_kart(id)
	_ck(f, float(k.roulette) > 0.0 and int(k.item) != Item.NONE, "romper una caja da un objeto (ruleta)")
	_steps(g, id, 80)
	_ck(f, float(g.debug_kart(id).roulette) <= 0.0, "la ruleta se para")
	# 8) Plátano detrás: el de atrás hace un trompo.
	g.debug_clear_objs()
	g.debug_place(id, 300, 0.0, 0.0)
	g.debug_give(id, Item.BANANA)
	g.debug_step(id, 0.0, 0.0, false, true, 0)
	var objs: Array = g.debug_objs()
	_ck(f, objs.size() == 1 and int(objs[0].kind) == 0, "el plátano se suelta detrás")
	g.debug_place(id, 330, 0.0, 0.0)
	g.debug_place(other, 285, 0.0, 22.0)
	g.debug_set(other, "inv_t", 0.0)
	for i in 60:
		g.debug_step(other, 0.0)
	_ck(f, int(g.debug_kart(other).hits) == 1 and g.debug_objs().is_empty(), "pisar el plátano te hace un trompo")
	# 9) Caparazón verde recto y rojo que persigue.
	g.debug_set(other, "inv_t", 0.0)
	g.debug_set(other, "spin_t", 0.0)
	g.debug_place(other, 256, 0.0, 0.0)
	g.debug_place(id, 240, 0.0, 0.0)
	g.debug_give(id, Item.GREEN)
	g.debug_step(id, 0.0, 0.0, false, true, 0)
	for i in 60:
		g.debug_step(id, 0.0, 1.0)
	_ck(f, int(g.debug_kart(other).hits) == 2, "el caparazón verde da al de delante")
	g.debug_set(other, "inv_t", 0.0)
	g.debug_set(other, "spin_t", 0.0)
	g.debug_place(other, 150, 4.5, 0.0)
	g.debug_place(id, 110, -4.0, 0.0)
	g.debug_set(id, "place", 2)
	g.debug_set(other, "place", 1)
	g.debug_give(id, Item.RED)
	g.debug_step(id, 0.0, 0.0, false, true, 0)
	var red_target: int = int(g.debug_objs()[0].target) if not g.debug_objs().is_empty() else -2
	for i in 90:
		g.debug_step(id, 0.0, 1.0)
	_ck(f, red_target == other and int(g.debug_kart(other).hits) == 3, "el caparazón rojo persigue al de delante y le da")
	# 10) Champiñón, estrella y rayo.
	g.debug_place(id, 200, 0.0, 20.0)
	g.debug_give(id, Item.MUSHROOM, 3)
	g.debug_step(id, 0.0, 0.0, false, true, 0)
	_steps(g, id, 20)
	k = g.debug_kart(id)
	_ck(f, float(k.speed) > 30.0 and int(k.item_n) == 2, "champiñón: turbo y quedan 2")
	g.debug_give(id, Item.STAR)
	g.debug_step(id, 0.0, 0.0, false, true, 0)
	_ck(f, float(g.debug_kart(id).star) > 6.0, "la estrella te hace invencible")
	g.debug_clear_objs()
	g.debug_place(other, 400, 0.0, 0.0)
	g.debug_give(other, Item.BANANA)
	g.debug_step(other, 0.0, 0.0, false, true, 0)
	g.debug_place(other, 430, 3.0, 0.0)
	g.debug_place(id, 385, 0.0, 25.0)
	var hits_before := int(g.debug_kart(id).hits)
	_steps(g, id, 60)
	_ck(f, int(g.debug_kart(id).hits) == hits_before and g.debug_objs().is_empty(), "con estrella el plátano no te hace nada")
	g.debug_give(id, Item.BOLT)
	g.debug_set(other, "star_t", 0.0)
	g.debug_step(id, 0.0, 0.0, false, true, 0)
	_ck(f, float(g.debug_kart(other).shrink) > 3.0 and float(g.debug_kart(id).shrink) <= 0.0, "el rayo encoge a los demás")
	g.free()
	# 11) Caparazón azul: va a por el primero.
	var g3 = _new_game(21, 4)
	var ids: Array[int] = []
	for p in g3.players:
		ids.append(p.id)
	for i in ids.size():
		g3.debug_place(ids[i], 100 + 40 * i, 0.0, 0.0)
	g3.debug_step(ids[0], 0.0)
	var leader: int = ids[ids.size() - 1]
	_ck(f, int(g3.debug_kart(leader).place) == 1, "el que va más adelante es el primero")
	g3.debug_give(ids[0], Item.BLUE)
	g3.debug_step(ids[0], 0.0, 0.0, false, true, 0)
	var blue_hit := false
	for i in 60 * 5:
		g3.debug_step(ids[0], 0.0, 1.0)
		if int(g3.debug_kart(leader).hits) > 0:
			blue_hit = true
			break
	_ck(f, blue_hit, "el caparazón azul alcanza al primero")
	g3.free()
	# 12) Carreras completas con bots: acaban, ranking coherente, vueltas razonables.
	for cfg in [[7, 8], [8, 8], [9, 5], [10, 2]]:
		var sd: int = cfg[0]
		var count: int = cfg[1]
		var gr = _new_game(sd, count)
		var steps := 0
		while not gr.debug_over() and steps < 60 * 230:
			gr._simulate(DT)
			gr._animate(DT)
			steps += 1
		var rk: Array[int] = gr._ranking_ids()
		var finishers := 0
		var falls := 0
		var hits := 0
		var best := INF
		var first_t := INF
		var order_ok := true
		var prev_fin := true
		var prev_t := -1.0
		for rid in rk:
			var kk: Dictionary = gr.debug_kart(rid)
			if bool(kk.finished):
				finishers += 1
				first_t = minf(first_t, float(kk.fin_time))
				if not prev_fin or float(kk.fin_time) < prev_t:
					order_ok = false
				prev_t = float(kk.fin_time)
				if float(kk.best_lap) > 0.0:
					best = minf(best, float(kk.best_lap))
			prev_fin = bool(kk.finished)
			falls += int(kk.falls)
			hits += int(kk.hits)
		print("  semilla %d (%d karts): acaban %d, primero en %.1f s, mejor vuelta %.1f s, caídas %d, golpes %d, fin a %.1f s" % [
				sd, count, finishers, first_t, best, falls, hits, gr.debug_time()])
		_ck(f, gr.debug_over() and gr.debug_winner() == rk[0], "la carrera acaba y gana el primero del ranking")
		_ck(f, order_ok, "los que acaban van delante y por orden de llegada")
		_ck(f, finishers >= maxi(2, count - 2), "casi todos los bots terminan las 3 vueltas (%d de %d)" % [finishers, count])
		_ck(f, first_t > 60.0 and first_t < 110.0, "una carrera dura lo que debe (%.1f s)" % first_t)
		_ck(f, best > 18.0 and best < 34.0, "vueltas de %.1f s" % best)
		_ck(f, falls <= count * 2, "los bots apenas se caen (%d)" % falls)
		if count >= 5:
			_ck(f, hits >= 1, "los objetos dan a alguien (%d golpes)" % hits)
		# Estado → cliente.
		var cl = _new_game(sd, count, false)
		cl._apply_state(gr._serialize_state())
		var same := true
		for p in gr.players:
			var a: Dictionary = gr.debug_kart(p.id)
			var b: Dictionary = cl.debug_kart(p.id)
			if int(a.place) != int(b.place) or absf(float(a.prog) - float(b.prog)) > 0.01 or Vector3(a.x, a.y, a.z).distance_to(Vector3(b.x, b.y, b.z)) > 0.01:
				same = false
		_ck(f, same and cl.debug_objs().size() == gr.debug_objs().size(), "el cliente recibe karts y objetos")
		_ck(f, cl._order.size() == count and cl._karts[cl._order[0]].node != null, "un kart 3D por jugador")
		gr.free()
		cl.free()
	# 13) Online: el derrape mantenido de un jugador remoto llega con "h:1"/"h:0" por el canal de texto.
	var gn = _new_game(4, 2)
	var rp = gn.players[1]
	var im = root.get_node("InputManager")
	rp.device = "remote"
	im.register_player(rp)
	gn.debug_place(rp.id, int(0.2 * gn.debug_track().n), 0.0, 24.0)
	gn._on_player_text(rp, "h:1", true)
	im.set_remote_input(rp.id, Vector2(1.0, 0.0), 1)
	im._process(DT)
	gn._simulate(DT * 1.01)
	var drifting_start := int(gn.debug_kart(rp.id).drift) == 1
	im._process(DT)
	for i in 30:
		gn._simulate(DT)
		im._process(DT)
	var still := int(gn.debug_kart(rp.id).drift) == 1
	gn._on_player_text(rp, "h:0", true)
	gn._simulate(DT * 1.01)
	_ck(f, drifting_start and still and int(gn.debug_kart(rp.id).drift) == 0, "derrape online: empieza al pulsar, sigue con «h:1» y se suelta con «h:0»")
	gn.free()
	# 14) Pantalla partida: una cámara por persona de este PC.
	var gv = _new_game(3, 6)
	_ck(f, gv.debug_views() == 1, "con un jugador en el PC, una cámara")
	gv.free()
	var g2 = _new_game(3, 4, true, ["kb1", "kb2"])
	_ck(f, g2.debug_views() == 2, "dos personas en el PC: pantalla partida en 2")
	g2.free()
	var g4 = _new_game(3, 2, true, ["kb1", "kb2", "joy:0", "joy:1"])
	_ck(f, g4.debug_views() == 4, "cuatro personas: pantalla partida en 4")
	g4.free()
	if f.is_empty():
		print("RAINBOW KART TEST OK")
	else:
		print("RAINBOW KART TEST FALLÓ: ", f)
	quit(0 if f.is_empty() else 1)
	return true

func _ck(f: Array[String], cond: bool, label: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + label)
	if not cond:
		f.append(label)
