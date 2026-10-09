extends SceneTree
## Prueba de la PRÁCTICA jugable de la pantalla de presentación (MinigamePractice): cada minijuego arranca dentro del
## recuadro, corre sin errores y se reinicia al acabar; sale un solo recuadro (el tuyo en los de "cada uno
## en su pantalla", uno compartido en los demás); todos los minijuegos tienen su texto corto.
## Ejecutar:  godot --headless --path . --script res://tests/practice_test.gd   (los errores de script salen en la salida)

var _stage: int = 0
var _frame: int = 0
var _metas: Array = []
var _idx: int = 0
var _practice = null
var _failures: Array[String] = []
var _PR = null

func _process(_delta: float) -> bool:
	if _stage == 0:
		_PR = load("res://ui/components/minigame_practice.gd")
		_PR.force_in_headless = true
		var lobby = root.get_node("Lobby")
		for p in lobby.players.duplicate():
			lobby.remove_player(p.id)
		lobby.add_player("kb1")
		lobby.add_player("kb2")
		lobby.add_bot()
		_metas = root.get_node("MinigameRegistry").get_all().duplicate()
		_check(_metas.size() >= 13, "hay %d minijuegos registrados" % _metas.size())
		# Texto corto en todos y límite de longitud (es "un textito").
		var all_short := true
		for m in _metas:
			if m.short_text.strip_edges().is_empty() or m.short_text.length() > 90:
				all_short = false
				print("      sin texto corto válido: ", m.id)
		_check(all_short, "todos los minijuegos tienen un texto corto (≤ 90 letras)")
		# Recuadros: siempre uno solo (tu pantalla en LOCAL_PARALLEL, uno compartido en el resto).
		var par_ok := true
		var shared_ok := true
		for m in _metas:
			var plan: Array = _PR.plan(m)
			if m.execution_mode == MinigameMeta.ExecutionMode.LOCAL_PARALLEL:
				if plan.size() != 1 or plan[0]["local"] == null:
					par_ok = false
			else:
				if plan.size() != 1 or plan[0]["local"] != null:
					shared_ok = false
		_check(par_ok, "en los minijuegos de cada uno en su pantalla sale un solo recuadro: el tuyo (aunque haya 2 personas en el PC)")
		_check(shared_ok, "en los compartidos sale un solo recuadro")
		_stage = 1
		_idx = 0
		return false
	if _stage == 1:
		# Un minijuego cada vez: se crea la práctica, se deja correr ~3 s de juego y se comprueba.
		if _practice == null:
			if _idx >= _metas.size():
				_stage = 2
				return false
			var m: MinigameMeta = _metas[_idx]
			var plan: Array = _PR.plan(m)
			_practice = _PR.new()
			_practice.setup(m, plan[0]["local"], plan[0]["size"])
			root.add_child(_practice)
			_frame = 0
			return false
		_frame += 1
		var mg = _practice.debug_minigame()
		if mg != null and is_instance_valid(mg):
			mg._process(0.05)
		if _frame >= 70:
			var m2: MinigameMeta = _metas[_idx]
			var ok: bool = mg != null and is_instance_valid(mg) and mg.demo   # (puede haber acabado ya la partida de práctica)
			_check(ok, "la práctica de «%s» arranca y corre en el recuadro" % m2.display_name)
			_practice.queue_free()
			_practice = null
			_idx += 1
		return false
	if _stage == 2:
		# La práctica se reinicia sola al acabar (se fuerza el fin del minijuego).
		var m3: MinigameMeta = root.get_node("MinigameRegistry").get_by_id(&"button_mash")
		_practice = _PR.new()
		_practice.setup(m3, null, Vector2i(576, 324))
		root.add_child(_practice)
		_stage = 3
		_frame = 0
		return false
	if _stage == 3:
		_frame += 1
		var mg2 = _practice.debug_minigame()
		if _frame == 10 and mg2 != null:
			_practice.set_meta("first_id", mg2.get_instance_id())
			_practice.set_meta("t0", Time.get_ticks_msec())
			var none: Array[int] = []
			mg2.finish(none)
		if _frame > 10:
			var cur = _practice.debug_minigame()
			var waited: int = Time.get_ticks_msec() - int(_practice.get_meta("t0", 0))
			if cur != null and is_instance_valid(cur) and cur.get_instance_id() != int(_practice.get_meta("first_id", 0)):
				_check(true, "al terminar el minijuego, la práctica se reinicia sola con uno nuevo (%.1f s)" % (waited / 1000.0))
				_stage = 4
			elif waited > 4000:
				_check(false, "al terminar el minijuego, la práctica se reinicia sola con uno nuevo")
				_stage = 4
		return false
	print("")
	if _failures.is_empty():
		print("PRACTICE TEST OK")
		quit(0)
	else:
		print("PRACTICE TEST FALLÓ")
		quit(1)
	return true

func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		_failures.append(what)
		print("  ✗ " + what)
