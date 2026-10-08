extends SceneTree
## Prueba de Bomba de Palabras: diccionario, combinaciones de letras y reglas del juego (sin red).
## Ejecutar:  godot --headless --path . --script res://tests/bomb_party_test.gd

var _began: bool = false
var _ranking: Array = []

func _process(_delta: float) -> bool:
	if _began:
		return true
	_began = true
	var failures: Array[String] = []
	var D = load("res://core/spanish_dictionary.gd")

	# --- Diccionario ---
	_check(D.word_count() > 400000, "el diccionario tiene %d formas" % D.word_count(), failures)
	_check(D.normalize("CAMIÓN") == "camion" and D.normalize("Niño") == "niño" and D.normalize("pingüino") == "pinguino",
			"normalizar quita tildes y conserva la ñ", failures)
	for w in ["casa", "casco", "escaso", "camion", "cantaron", "comiendo", "canciones", "murcielago", "niño"]:
		_check(D.has_word(w), "existe «%s»" % w, failures)
	for w in ["xyzq", "casaa", "holaquetal", ""]:
		_check(not D.has_word(w), "no existe «%s»" % w, failures)

	# --- Niveles: 5 niveles; todas las combinaciones tienen ejemplos válidos ---
	var expected_tiers := [
		"ar er ir en es la de ra re ro ta te co an or",
		"cas con est ent ado ada era ero par por res men tra ter sol",
		"bra bre cri gre ple clo nte ndo rta rto mbr str fra dra tro",
		"xpr xtr gni cni pti nqu squ cti lqu dmi mpl ngr rqu rni bst",
		"psic xcep zqui xpri gnit ptim bstr nstr lqui yect umbr scen cept ctua ctiv"]
	_check(D.tiers.size() == 5, "hay 5 niveles de combinaciones", failures)
	for i in 5:
		var want: PackedStringArray = String(expected_tiers[i]).split(" ")
		var got: Array = D.tiers[i] if i < D.tiers.size() else []
		_check(got.size() == 15 and PackedStringArray(got) == want, "nivel %d: las 15 combinaciones pedidas" % (i + 1), failures)
	var bad_samples := 0
	for tier in D.tiers:
		for syl in tier:
			var samples: Array = D.samples_for(syl)
			if samples.size() < 8:
				bad_samples += 1
				continue
			for w in samples:
				if not D.has_word(String(w)) or not String(w).contains(syl):
					bad_samples += 1
					break
	_check(bad_samples == 0, "todas las combinaciones tienen ejemplos válidos (fallos: %d)" % bad_samples, failures)
	for ex in [["psic", "psicologia"], ["xcep", "excepcion"], ["zqui", "izquierda"], ["xpri", "exprimir"], ["gnit", "magnitud"],
			["ptim", "optimo"], ["bstr", "abstracto"], ["nstr", "construir"], ["lqui", "alquilar"], ["yect", "proyecto"],
			["umbr", "costumbre"], ["scen", "escenario"]]:
		_check(D.has_word(ex[1]) and String(ex[1]).contains(ex[0]), "«%s» vale con %s" % [ex[1], String(ex[0]).to_upper()], failures)

	# --- Reglas del juego ---
	var meta = load("res://minigames/bomb_party/meta.tres")
	var mg = (meta.scene as PackedScene).instantiate()
	root.add_child(mg)
	var plist: Array[PlayerData] = []
	for i in 3:
		var p := PlayerData.new()
		p.id = i
		p.display_name = "J%d" % i
		p.color_index = i
		plist.append(p)
	mg.configure(0, 1, plist[0])
	mg.prepare(plist)
	mg.finished.connect(func(r: Array) -> void: _ranking = r)
	mg.start(plist)
	# El minijuego dura entre 10 y 30 s la mecha (repetimos el sorteo).
	var fuses: Array[float] = []
	for i in 300:
		mg._on_start()
		fuses.append(mg._fuse)
	_check(fuses.min() >= 10.0 and fuses.max() <= 30.0 and fuses.max() - fuses.min() > 10.0, "la mecha se sortea entre 10 y 30 s (%.1f..%.1f)" % [fuses.min(), fuses.max()], failures)

	mg._turn = 0
	mg._cur_id = plist[0].id
	mg._syl = "cas"
	mg._draft = ""
	_check(mg._check_word("casa") == "", "«casa» vale con CAS", failures)
	_check(mg._check_word("escaso") == "", "«escaso» vale con CAS (la combinación puede estar en medio)", failures)
	_check(mg._check_word("perro").begins_with("no contiene"), "«perro» no contiene CAS", failures)
	_check(mg._check_word("casaa") == "no existe", "«casaa» no existe", failures)
	_check(mg._check_word("c4sa") == "solo letras", "los números no valen", failures)
	# Acierto: la bomba pasa, sin reiniciar la mecha.
	mg._fuse = 22.0
	mg._on_player_text(null, "Cása", true)       # sin red el texto es del jugador al que le toca; con tilde
	_check(mg._turn == 1 and mg._cur_id == plist[1].id, "al acertar la bomba pasa al siguiente jugador", failures)
	_check(is_equal_approx(mg._fuse, 22.0), "la mecha NO se reinicia al acertar (%.1f)" % mg._fuse, failures)
	_check(int(mg._counts[0]) == 1 and mg._feed.size() == 1, "se anota la palabra acertada", failures)
	mg._syl = "cas"
	_check(mg._check_word("casa") == "¡ya se usó!", "no se pueden repetir palabras (ni con otra tilde)", failures)
	# Mecha mínima al pasar.
	mg._fuse = 1.5
	mg._on_player_text(null, "casco", true)
	_check(mg._fuse >= 5.0 and mg._turn == 2, "si quedaban < 5 s el siguiente recibe al menos 5 s (%.1f)" % mg._fuse, failures)
	# Palabra incorrecta: sigue el mismo jugador y se borra el borrador.
	mg._syl = "cas"
	var turn_before: int = mg._turn
	mg._on_player_text(null, "ca", false)
	_check(mg._draft == "CA", "el borrador se ve en vivo", failures)
	mg._on_player_text(null, "perro", true)
	_check(mg._turn == turn_before and mg._draft == "", "una palabra mala no pasa la bomba", failures)
	# Dificultad: el nivel sube cada 5 aciertos acumulados y la mecha corre más deprisa.
	var tier_ok := true
	for passes in [0, 4, 5, 9, 10, 14, 15, 19, 20, 60]:
		var want_tier: int = mini(passes / 5, 4)
		mg._passes = passes
		mg._syl_history.clear()
		for i in 25:
			mg._new_syllable()
			if mg._tier != want_tier or not D.tiers[want_tier].has(mg._syl):
				tier_ok = false
	_check(tier_ok, "niveles por aciertos: 0-4 → 1, 5-9 → 2, 10-14 → 3, 15-19 → 4, 20+ → 5", failures)
	_check(is_equal_approx(mg.fuse_rate(0), 1.0) and mg.fuse_rate(10) > mg.fuse_rate(5) and mg.fuse_rate(500) <= 2.2 + 0.001,
			"la mecha corre cada vez más deprisa (×%.2f a los 10 aciertos, tope ×%.1f)" % [mg.fuse_rate(10), mg.fuse_rate(500)], failures)
	mg._passes = 12
	mg._fuse = 3.0
	mg._turn = 0
	mg._cur_id = plist[0].id
	mg._syl = "ar"
	mg._used.clear()
	mg._on_player_text(null, "arbol", true)
	_check(mg._fuse >= 5.0 * mg.fuse_rate(13) - 0.001, "al pasar, el siguiente tiene al menos 5 s reales aunque vaya acelerada (%.1f)" % mg._fuse, failures)
	# Explosión 1: queda ELIMINADO quien tenía la bomba y la partida sigue con los demás (bomba nueva).
	mg._eliminated.clear()
	mg._boom = false
	mg._used.clear()
	mg._passes = 7
	mg._counts = {0: 1, 1: 4, 2: 2}
	mg._cur_id = 2
	mg._turn = 2
	mg._explode()
	_check(mg._boom and mg._boom_who == 2 and mg._eliminated == [2] and not mg._over, "al explotar queda eliminado quien tenía la bomba (quedan 2)", failures)
	_ranking = []
	mg._simulate(mg.BOOM_DURATION + 0.1)
	_check(_ranking.is_empty() and not mg._boom and mg._cur_id == 0 and mg._turn == 0, "tras la explosión sigue la partida con el siguiente jugador vivo", failures)
	_check(mg._fuse >= 10.0 and mg._fuse <= 30.0, "la bomba nueva trae una mecha nueva de 10-30 s (%.1f)" % mg._fuse, failures)
	_check(mg._passes == 7, "el nivel y la aceleración de la mecha se conservan", failures)
	# Los eliminados no reciben la bomba al acertar.
	mg._syl = "cas"
	mg._on_player_text(null, "casa", true)
	_check(mg._cur_id == 1, "la bomba pasa al siguiente VIVO (se salta al eliminado)", failures)
	mg._syl = "cas"
	mg._on_player_text(null, "casco", true)
	_check(mg._cur_id == 0, "... y vuelve al primero saltándose al eliminado", failures)
	# Explosión 2: solo queda uno → termina el minijuego. Ranking: ganador, luego eliminados del último al primero.
	mg._cur_id = 1
	mg._turn = 1
	mg._explode()
	_check(mg._over and mg._eliminated == [2, 1], "con un solo superviviente es la última explosión", failures)
	mg._simulate(mg.BOOM_FINAL_DURATION + 0.1)
	_check(_ranking == [0, 1, 2], "ranking por orden de eliminación: gana el superviviente, el último eliminado es 2.º (%s)" % [_ranking], failures)
	# Tras terminar ya no se acepta texto.
	var used_before: int = mg._used.size()
	mg._on_player_text(null, "casa", true)
	_check(mg._used.size() == used_before, "tras la última explosión no se acepta más texto", failures)

	print("")
	if failures.is_empty():
		print("BOMB PARTY TEST OK")
		quit(0)
	else:
		print("BOMB PARTY TEST FALLÓ")
		quit(1)
	return true

func _check(cond: bool, what: String, failures: Array[String]) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		failures.append(what)
		print("  ✗ " + what)
