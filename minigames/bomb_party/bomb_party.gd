extends Minigame
## Bomba de Palabras (modelo HOST_AUTHORITATIVE, inspirado en BombParty): una bomba pasa de jugador en
## jugador. En cada turno aparece una combinación de 2-4 letras (p. ej. «CAS») y quien la tiene debe
## escribir una palabra española que la contenga (CASA, CASCO, ESCASO...). Sin repetir palabras (en toda la
## partida). Si acierta, la bomba pasa al siguiente jugador VIVO y sale otra combinación. La mecha es OCULTA
## (10-30 s al azar) y NO se reinicia al acertar; si quedan menos de 5 s al pasarla, el siguiente recibe 5 s.
## Cuando la bomba EXPLOTA, el jugador que la tenía queda ELIMINADO; se sortea otra bomba (mecha nueva) y se
## sigue con los que quedan. La partida termina cuando solo queda UNO: gana, y el ranking sigue el orden de
## eliminación (el último eliminado es 2.º, el penúltimo 3.º...).
##
## Sin código de red propio: el host decide y valida (_on_player_text, _simulate) y los clientes dibujan
## el estado que reciben (_apply_state) y los eventos (ok / bad / boom). El texto de cada jugador viaja
## por el canal genérico del minijuego (Minigame.submit_text), también el borrador en vivo.
## Las palabras se validan con SpanishDictionary (data/es_words.txt). Los bots y el autopiloto escriben
## palabras de ejemplo del propio diccionario.
##
## Entrada: hace falta teclado. En partida local (varios humanos en un PC) el texto es del jugador al
## que le toca; los mandos no pueden escribir.
##
## DIFICULTAD (sube con las palabras acertadas entre todos): 5 niveles de combinaciones, de «AR»/«ER» (muy
## fácil) a «PSIC»/«XCEP» (experto), 15 por nivel (data/es_tiers.txt; se reparten cada 5 aciertos). Además
## la mecha corre cada vez más deprisa: +4 % por palabra acertada, hasta el doble y algo más.
##
## Sin código de red propio: el host decide y valida (_on_player_text, _simulate) y los clientes dibujan
## el estado que reciben (_apply_state) y los eventos (ok / bad / boom). El texto de cada jugador viaja
## por el canal genérico del minijuego (Minigame.submit_text), también el borrador en vivo.
## Las palabras se validan con SpanishDictionary (data/es_words.txt). Los bots y el autopiloto escriben
## palabras de ejemplo del propio diccionario.
##
## Entrada: hace falta teclado. En partida local (varios humanos en un PC) el texto es del jugador al
## que le toca; los mandos no pueden escribir.

const MIN_FUSE := 10.0
const MAX_FUSE := 30.0
const MIN_PASS_FUSE := 5.0            # al pasar la bomba, el siguiente recibe al menos esto
const BOOM_DURATION := 2.4            # s de explosión antes de seguir con los que quedan
const BOOM_FINAL_DURATION := 3.6      # ... y antes de cerrar el minijuego (la última explosión)
const MAX_DRAFT := 24
const RECENT_SYLLABLES := 8           # no se repite una combinación hasta pasados estos turnos
const WORDS_PER_TIER := 5             # aciertos acumulados para subir de nivel (0-4 → nivel 1, 5-9 → nivel 2...)
const FUSE_SPEEDUP := 0.04            # la mecha corre un 4 % más deprisa por palabra acertada
const FUSE_MAX_RATE := 2.2            # ... hasta este tope
const FEED_SIZE := 7
const BOT_THINK_MIN := 1.8
const BOT_THINK_MAX := 5.0
const BOT_FAIL_BASE := 0.10           # a veces el bot "no se sabe ninguna" y deja que explote (más en niveles altos)
const BOT_FAIL_PER_TIER := 0.05

# --- Geometría de la escena ---
const CENTER := Vector2(640, 305)
const SEAT_RX := 470.0
const SEAT_RY := 215.0
const SEAT_RADIUS := 36.0
const BOMB_RADIUS := 98.0

class Particle:
	var pos: Vector2
	var vel: Vector2
	var life: float
	var max_life: float
	var color: Color
	var size: float

# --- Estado compartido (el host lo decide; los clientes lo reciben en _apply_state) ---
var _cur_id: int = -1
var _syl: String = ""
var _draft: String = ""
var _feed: Array = []                 # [[id, PALABRA], ...] la más reciente al final
var _counts: Dictionary = {}          # id → palabras acertadas
var _boom: bool = false
var _tier: int = 0                    # nivel actual (0 = muy fácil ... 4 = experto)
var _eliminated: Array = []           # ids eliminados, por orden de eliminación

# --- Estado solo del host ---
var _turn: int = 0
var _fuse: float = 20.0
var _used: Dictionary = {}
var _syl_history: Array[String] = []
var _passes: int = 0
var _boom_t: float = 0.0
var _boom_who: int = -1
var _bot_id: int = -2                 # jugador cuyo bot está armado
var _bot_t: float = 0.0
var _bot_total: float = 1.0
var _bot_word: String = ""

## ¿Es la última explosión? (solo queda un jugador vivo)
var _over: bool:
	get: return _boom and players.size() - _eliminated.size() <= 1

# --- Solo visual (todos los PC) ---
var _shown_id: int = -2
var _token_pos: Vector2 = CENTER
var _ptr_ang: float = 0.0
var _time: float = 0.0
var _shake: float = 0.0
var _flash: float = 0.0
var _toast: String = ""
var _toast_t: float = 0.0
var _toast_color: Color = Palette.CORAL
var _popups: Array = []               # {pos, text, color, age}
var _particles: Array[Particle] = []
var _rings: Array = []                # {r, a}
var _syl_pop: float = 0.0             # latido al cambiar de combinación
var _boom_examples: Array = []
var _boom_age: float = 0.0
var _seen_words: Dictionary = {}      # (autopiloto de cliente) palabras vistas
var _tier_shown: int = 0              # nivel ya anunciado en pantalla
var _tier_flash: float = 0.0

# --- Interfaz y audio ---
var _input: LineEdit
var _input_mine: bool = false
var _ap_t: float = -1.0               # (autopiloto de cliente) cuenta atrás para escribir
var _sfx_tick: AudioStreamPlayer
var _sfx_key: AudioStreamPlayer
var _sfx_good: AudioStreamPlayer
var _sfx_bad: AudioStreamPlayer
var _sfx_pass: AudioStreamPlayer
var _sfx_boom: AudioStreamPlayer
var _sfx_fuse: AudioStreamPlayer
var _tick_t: float = 0.0

# ----------------------------------------------------------------------------
# Preparación
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	SpanishDictionary.ensure_loaded()
	surface.draw_callback = _draw_game
	for p in players:
		_counts[p.id] = 0
	_build_input()
	_build_audio()

func _build_input() -> void:
	_input = LineEdit.new()
	_input.position = Vector2(300, 612)
	_input.size = Vector2(680, 74)
	_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_input.max_length = MAX_DRAFT
	_input.context_menu_enabled = false
	_input.add_theme_font_size_override("font_size", 40)
	_input.text_changed.connect(_on_input_changed)
	_input.text_submitted.connect(_on_input_submitted)
	surface.add_child(_input)
	_set_input_mine(false)

func _build_audio() -> void:
	_sfx_tick = _make_player(SynthSfx.tick(), -14.0)
	_sfx_key = _make_player(SynthSfx.key(), -18.0)
	_sfx_good = _make_player(SynthSfx.good(), -8.0)
	_sfx_bad = _make_player(SynthSfx.bad(), -9.0)
	_sfx_pass = _make_player(SynthSfx.pass_bomb(), -10.0)
	_sfx_boom = _make_player(SynthSfx.boom(), -3.0)
	_sfx_fuse = _make_player(SynthSfx.fuse_loop(), -26.0)

func _make_player(stream: AudioStream, volume_db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = volume_db
	add_child(p)
	return p

func _on_start() -> void:
	_time = 0.0
	if is_authority:
		_turn = randi() % players.size()
		_cur_id = players[_turn].id
		_fuse = randf_range(MIN_FUSE, MAX_FUSE)
		_passes = 0
		_syl_history.clear()
		_eliminated.clear()
		_boom = false
		DevCli.log_event("bomb fuse=%.1f first=%d" % [_fuse, _cur_id])
		_new_syllable()
		_arm_bot()
	_token_pos = _seat_pos(_seat_index(_cur_id)) + Vector2(46, -18) if _cur_id >= 0 else CENTER
	_sfx_fuse.play()

# ----------------------------------------------------------------------------
# Lógica (solo host)
# ----------------------------------------------------------------------------

func _simulate(delta: float) -> void:
	if _boom:
		_boom_t += delta
		var last := _alive_count() <= 1
		if _boom_t >= (BOOM_FINAL_DURATION if last else BOOM_DURATION):
			if last:
				_finish_round()
			else:
				_next_bomb()
		return
	_fuse -= delta * fuse_rate(_passes)
	if _fuse <= 0.0:
		_explode()
		return
	_bot_tick(delta)

## Nivel (0-4) que corresponde a las palabras acertadas entre todos.
static func tier_for(passes: int) -> int:
	return clampi(passes / WORDS_PER_TIER, 0, 4)

## Velocidad a la que corre la mecha: crece con las palabras acertadas.
static func fuse_rate(passes: int) -> float:
	return minf(1.0 + FUSE_SPEEDUP * float(passes), FUSE_MAX_RATE)

## Elige una combinación del nivel actual, sin repetir las últimas.
func _new_syllable() -> void:
	_tier = tier_for(_passes)
	var tiers := SpanishDictionary.tiers
	if tiers.is_empty():
		_syl = "ca"
		return
	var list: Array = tiers[mini(_tier, tiers.size() - 1)]
	for attempt in 40:
		_syl = String(list[randi() % list.size()])
		if not _syl_history.has(_syl):
			break
	_syl_history.append(_syl)
	if _syl_history.size() > RECENT_SYLLABLES:
		_syl_history.pop_front()

func _current_player() -> PlayerData:
	return players[_turn]

func _alive_count() -> int:
	return players.size() - _eliminated.size()

## Índice del siguiente jugador vivo después de `from`.
func _next_alive(from: int) -> int:
	var i := from
	for k in players.size():
		i = (i + 1) % players.size()
		if not _eliminated.has(players[i].id):
			return i
	return from

## Motivo por el que la palabra (ya normalizada) no vale, o "" si vale.
func _check_word(norm: String) -> String:
	if norm.length() < 2 or not SpanishDictionary.is_letters(norm):
		return "solo letras"
	if not norm.contains(_syl):
		return "no contiene «%s»" % _syl.to_upper()
	if _used.has(norm):
		return "¡ya se usó!"
	if not SpanishDictionary.has_word(norm):
		return "no existe"
	return ""

func _on_player_text(player: PlayerData, text: String, final: bool) -> void:
	if _boom or players.is_empty():
		return
	var cur := _current_player()
	if NetworkManager.is_online:
		if player == null or player.id != cur.id:
			return
	if InputManager.is_simulated(cur.id) and not cur.is_remote:
		return                        # los bots escriben solos
	if not final:
		_draft = text.to_upper()
		return
	_try_word(cur, text)

func _try_word(cur: PlayerData, text: String) -> void:
	var norm := SpanishDictionary.normalize(text)
	var reason := _check_word(norm)
	_draft = ""
	if reason != "":
		send_event("bad", {"p": cur.id, "r": reason})
		return
	_used[norm] = true
	_counts[cur.id] = int(_counts.get(cur.id, 0)) + 1
	_feed.append([cur.id, text.to_upper()])
	if _feed.size() > FEED_SIZE:
		_feed.pop_front()
	_passes += 1
	# El siguiente recibe al menos 5 s REALES aunque la mecha vaya acelerada.
	var min_fuse := MIN_PASS_FUSE * fuse_rate(_passes)
	if _fuse < min_fuse:
		_fuse = min_fuse
	_turn = _next_alive(_turn)
	_cur_id = players[_turn].id
	_new_syllable()
	_arm_bot()
	send_event("ok", {"p": cur.id, "w": text.to_upper(), "n": _cur_id, "s": _syl, "l": _tier})

func _explode() -> void:
	_boom = true
	_boom_t = 0.0
	_boom_who = _cur_id
	_eliminated.append(_boom_who)
	_draft = ""
	var ex: Array = []
	for w in SpanishDictionary.samples_for(_syl):
		if ex.size() < 3:
			ex.append(String(w).to_upper())
	DevCli.log_event("bomb exploded on=%d passes=%d left=%d" % [_boom_who, _passes, _alive_count()])
	send_event("boom", {"p": _boom_who, "ex": ex, "left": _alive_count()})

## Tras una explosión (quedan 2 o más): bomba nueva con mecha nueva para el siguiente jugador vivo.
func _next_bomb() -> void:
	_boom = false
	_turn = _next_alive(_turn)
	_cur_id = players[_turn].id
	_fuse = randf_range(MIN_FUSE, MAX_FUSE)
	_draft = ""
	DevCli.log_event("bomb new fuse=%.1f for=%d left=%d" % [_fuse, _cur_id, _alive_count()])
	_new_syllable()
	_arm_bot()
	send_event("next", {"p": _cur_id, "s": _syl})

## Fin de la partida: gana el único que queda; después, los eliminados del último al primero.
func _finish_round() -> void:
	var ranking: Array[int] = []
	for p in players:
		if not _eliminated.has(p.id):
			ranking.append(p.id)
	for i in range(_eliminated.size() - 1, -1, -1):
		ranking.append(int(_eliminated[i]))
	finish(ranking)

# --- Bots (y desconectados): escriben palabras de ejemplo del diccionario ---

func _arm_bot() -> void:
	_bot_id = -2
	_bot_word = ""
	var cur := _current_player()
	if not InputManager.is_simulated(cur.id) or cur.is_remote:
		return
	_bot_id = cur.id
	_bot_total = randf_range(BOT_THINK_MIN, BOT_THINK_MAX)
	_bot_t = _bot_total
	if randf() < BOT_FAIL_BASE + BOT_FAIL_PER_TIER * float(_tier):
		_bot_total = 99.0
		_bot_t = 99.0
		return
	_bot_word = _pick_sample_word()
	if _bot_word == "":
		_bot_total = 99.0
		_bot_t = 99.0

func _pick_sample_word() -> String:
	var samples := SpanishDictionary.samples_for(_syl)
	var options: Array = []
	for w in samples:
		if not _used.has(String(w)):
			options.append(String(w))
	return options[randi() % options.size()] if not options.is_empty() else ""

func _bot_tick(delta: float) -> void:
	var cur := _current_player()
	if _bot_id != cur.id:
		if InputManager.is_simulated(cur.id) and not cur.is_remote:
			_arm_bot()      # p. ej. un jugador se desconectó y ahora es un bot
		return
	_bot_t -= delta
	if _bot_word != "":
		# Simula que va escribiendo la palabra letra a letra.
		var frac := clampf(1.0 - _bot_t / _bot_total, 0.0, 1.0)
		_draft = _bot_word.substr(0, int(ceil(frac * _bot_word.length()))).to_upper()
		if _bot_t <= 0.0:
			_try_word(cur, _bot_word)

# ----------------------------------------------------------------------------
# Estado de red (snapshots y eventos)
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	return {"t": _cur_id, "s": _syl, "d": _draft, "f": _feed, "n": _counts, "b": _boom, "l": _tier, "x": _eliminated}

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	var st: Dictionary = state
	_cur_id = int(st.get("t", _cur_id))
	_syl = String(st.get("s", _syl))
	_draft = String(st.get("d", ""))
	_feed = st.get("f", _feed)
	_counts = st.get("n", _counts)
	_boom = bool(st.get("b", _boom))
	_tier = int(st.get("l", _tier))
	_eliminated = st.get("x", _eliminated)

func _on_event(event_name: String, data: Variant) -> void:
	if not data is Dictionary:
		return
	var d: Dictionary = data
	match event_name:
		"ok":
			_seen_words[SpanishDictionary.normalize(String(d.get("w", "")))] = true
			_sfx_good.play()
			_sfx_pass.play()
			_syl_pop = 1.0
			var seat := _seat_pos(_seat_index(int(d.get("p", -1))))
			_popups.append({"pos": seat + Vector2(0, -SEAT_RADIUS - 24), "text": String(d.get("w", "")), "color": Palette.MINT, "age": 0.0})
			for i in 10:
				_spawn_particle(seat, Palette.MINT, 90.0, 0.6)
			if not is_authority:
				_syl = String(d.get("s", _syl))
			_tier = int(d.get("l", _tier))
			if _tier > _tier_shown:
				_tier_shown = _tier
				_tier_flash = 2.0
				_toast = "¡NIVEL %d!" % (_tier + 1)
				_toast_t = 1.8
				_toast_color = Palette.YELLOW
		"bad":
			_sfx_bad.play()
			_shake = maxf(_shake, 0.6)
			_toast = String(d.get("r", "no vale")).to_upper()
			_toast_t = 1.4
			_toast_color = Palette.CORAL
			if _input_mine:
				_input.clear()
		"boom":
			_start_explosion(int(d.get("p", -1)), d.get("ex", []))
		"next":
			_sfx_pass.play()
			_sfx_fuse.play()
			_syl_pop = 1.0

func _start_explosion(who: int, examples: Array) -> void:
	_boom = true
	_boom_who = who
	_boom_examples = examples
	_boom_age = 0.0
	_flash = 1.0
	_shake = 2.0
	_sfx_fuse.stop()
	_sfx_boom.play()
	_rings.append({"r": 20.0, "a": 1.0})
	_rings.append({"r": 0.0, "a": 0.8})
	for i in 90:
		var palette: Array[Color] = [Color("FFC81E"), Color("FA7473"), Color("FF9F1C"), Color.WHITE]
		var col: Color = palette[randi() % 4]
		_spawn_particle(CENTER, col, 520.0, 1.3)
	_set_input_mine(false)
	if not _eliminated.has(who):
		_eliminated.append(who)

func _spawn_particle(pos: Vector2, color: Color, speed: float, life: float) -> void:
	var p := Particle.new()
	p.pos = pos
	p.vel = Vector2.from_angle(randf() * TAU) * randf_range(speed * 0.25, speed)
	p.life = life * randf_range(0.6, 1.0)
	p.max_life = p.life
	p.color = color
	p.size = randf_range(4.0, 11.0)
	_particles.append(p)

# ----------------------------------------------------------------------------
# Entrada local
# ----------------------------------------------------------------------------

func _on_input_changed(text: String) -> void:
	_sfx_key.play()
	if _input_mine:
		submit_text(text, false)

func _on_input_submitted(text: String) -> void:
	if not _input_mine:
		return
	submit_text(text, true)
	_input.clear()
	submit_text("", false)

## ¿Escribe este PC ahora? Online: cuando es el turno del jugador local. En partida local: cuando le toca a
## un humano (el teclado es de todos).
func _is_my_turn() -> bool:
	if _boom or _cur_id < 0:
		return false
	if NetworkManager.is_online:
		return local_player != null and local_player.id == _cur_id and not InputManager.is_simulated(_cur_id)
	return not InputManager.is_simulated(_cur_id)

func _set_input_mine(mine: bool) -> void:
	_input_mine = mine
	if _input == null:
		return
	_input.editable = mine
	_input.modulate.a = 1.0 if mine else 0.45
	_input.placeholder_text = "Escribe una palabra con «%s»" % _syl.to_upper() if mine else "Espera tu turno..."
	if mine:
		_input.clear()
		_input.grab_focus()
	else:
		_input.release_focus()

# ----------------------------------------------------------------------------
# Animación (todos los PC)
# ----------------------------------------------------------------------------

func _animate(delta: float) -> void:
	_time += delta
	_syl_pop = maxf(0.0, _syl_pop - delta * 3.0)
	_shake = maxf(0.0, _shake - delta * 2.2)
	_flash = maxf(0.0, _flash - delta * 2.0)
	_toast_t = maxf(0.0, _toast_t - delta)
	_tier_flash = maxf(0.0, _tier_flash - delta)
	if _boom:
		_boom_age += delta
	# La bomba (mini) y la flecha siguen al jugador al que le toca.
	if _cur_id != _shown_id:
		_shown_id = _cur_id
		_syl_pop = 1.0
	if _cur_id >= 0:
		var seat := _seat_pos(_seat_index(_cur_id))
		var target := seat + Vector2(46, -18)
		_token_pos = _token_pos.lerp(target, 1.0 - exp(-9.0 * delta))
		var want := (seat - CENTER).angle()
		_ptr_ang = lerp_angle(_ptr_ang, want, 1.0 - exp(-10.0 * delta))
	# Entrada del jugador local.
	var mine := is_running and _is_my_turn()
	if mine != _input_mine or (mine and _input.placeholder_text.find(_syl.to_upper()) < 0):
		_set_input_mine(mine)
	# Tic-tac cosmético (no depende de la mecha, que es secreta).
	if is_running and not _boom:
		_tick_t -= delta
		if _tick_t <= 0.0:
			# Cosmético: late más deprisa en los niveles altos (sin revelar cuánto queda de mecha).
			_tick_t = lerpf(0.55, 0.28, float(_tier) / 4.0)
			_sfx_tick.play()
	_autopilot_client(delta)
	for p in _particles:
		p.pos += p.vel * delta
		p.vel *= (1.0 - 1.8 * delta)
		p.vel.y += 120.0 * delta
		p.life -= delta
	_particles = _particles.filter(func(x: Particle) -> bool: return x.life > 0.0)
	for r in _rings:
		r.r += 700.0 * delta
		r.a -= delta * 1.1
	_rings = _rings.filter(func(x: Dictionary) -> bool: return x.a > 0.0)
	for pp in _popups:
		pp.age += delta
	_popups = _popups.filter(func(x: Dictionary) -> bool: return x.age < 1.3)

## Autopiloto (solo pruebas) en un CLIENTE: escribe palabras de ejemplo por la misma vía que una persona.
func _autopilot_client(delta: float) -> void:
	if is_authority or not is_running or _boom or not InputManager.autopilot or local_player == null:
		return
	if _cur_id != local_player.id:
		_ap_t = -1.0
		return
	if _ap_t < 0.0:
		_ap_t = randf_range(1.5, 3.8)
		return
	_ap_t -= delta
	if _ap_t <= 0.0:
		_ap_t = randf_range(1.5, 3.8)
		var options: Array = []
		for w in SpanishDictionary.samples_for(_syl):
			if not _seen_words.has(String(w)):
				options.append(String(w))
		if not options.is_empty():
			submit_text(String(options[randi() % options.size()]), true)

# ----------------------------------------------------------------------------
# Geometría
# ----------------------------------------------------------------------------

func _seat_index(id: int) -> int:
	for i in players.size():
		if players[i].id == id:
			return i
	return 0

func _seat_pos(i: int) -> Vector2:
	var a := PI * 0.5 + TAU * float(i) / float(maxi(players.size(), 1))
	return CENTER + Vector2(cos(a) * SEAT_RX, sin(a) * SEAT_RY)

# ----------------------------------------------------------------------------
# Dibujo
# ----------------------------------------------------------------------------

func _draw_game() -> void:
	var s := surface
	var shake_off := Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * _shake * 7.0
	s.draw_set_transform(shake_off, 0.0, Vector2.ONE)
	_draw_table()
	_draw_seats()
	if not _boom:
		_draw_pointer()
		_draw_bomb()
		_draw_draft()
	_draw_feed()
	_draw_tier()
	_draw_alive()
	for r in _rings:
		s.draw_arc(CENTER, float(r.r), 0.0, TAU, 64, Color(1, 0.85, 0.4, clampf(float(r.a), 0.0, 1.0)), 10.0, true)
	for p in _particles:
		var a := clampf(p.life / p.max_life, 0.0, 1.0)
		s.draw_circle(p.pos, p.size * (0.4 + 0.6 * a), Color(p.color.r, p.color.g, p.color.b, a))
	for pp in _popups:
		var k := float(pp.age) / 1.3
		s.text_centered(Vector2(pp.pos.x, pp.pos.y - 40.0 * k), String(pp.text), 28, Color(pp.color.r, pp.color.g, pp.color.b, 1.0 - k * k), 5)
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if _toast_t > 0.0:
		var ta := clampf(_toast_t / 0.4, 0.0, 1.0)
		s.text_centered(Vector2(640, 520), _toast, 44, Color(_toast_color.r, _toast_color.g, _toast_color.b, ta), 8)
	if _boom:
		_draw_boom_text()
	if _flash > 0.0:
		s.draw_rect(Rect2(0, 0, 1280, 720), Color(1, 1, 1, clampf(_flash, 0.0, 1.0) * 0.8))

func _draw_table() -> void:
	var s := surface
	# Mesa: óvalo translúcido bajo los jugadores.
	s.draw_set_transform(CENTER + Vector2(0, 14), 0.0, Vector2(1.0, SEAT_RY / SEAT_RX * 0.98))
	s.draw_circle(Vector2.ZERO, SEAT_RX * 0.98, Color(0, 0, 0, 0.16))
	s.draw_set_transform(CENTER, 0.0, Vector2(1.0, SEAT_RY / SEAT_RX * 0.98))
	s.draw_circle(Vector2.ZERO, SEAT_RX * 0.98, Color(1, 1, 1, 0.07))
	s.draw_arc(Vector2.ZERO, SEAT_RX * 0.98, 0.0, TAU, 96, Color(1, 1, 1, 0.16), 5.0, true)
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_seats() -> void:
	var s := surface
	for i in players.size():
		var p := players[i]
		var pos := _seat_pos(i)
		var is_cur := p.id == _cur_id and not _boom
		var is_loser := _boom and p.id == _boom_who
		var is_dead := _eliminated.has(p.id)
		var is_winner := _over and not is_dead
		var r := SEAT_RADIUS * (1.22 if is_cur else 1.0)
		var bob := Vector2(0, sin(_time * 5.0) * 4.0) if is_cur else Vector2.ZERO
		if is_loser:
			bob = Vector2(randf_range(-4.0, 4.0), randf_range(-4.0, 4.0))
		if is_cur:
			s.draw_circle(pos + bob, r + 16.0 + 4.0 * sin(_time * 8.0), Color(1, 0.78, 0.12, 0.35))
		var col: Color = p.color
		if is_dead:
			col = col.darkened(0.7)
		AvatarPainter.paint(s, pos + bob, r, col, Vector2.ZERO)
		if is_winner:
			s.draw_circle(pos + bob, r + 14.0 + 4.0 * sin(_time * 8.0), Color(1, 0.78, 0.12, 0.4))
			AvatarPainter.paint_crown(s, pos + bob, r)
		if is_dead:
			# Ojos de X y cara chamuscada.
			for side in [-1.0, 1.0]:
				var e: Vector2 = pos + bob + Vector2(side * r * 0.33, -r * 0.08)
				s.draw_line(e + Vector2(-6, -6), e + Vector2(6, 6), Palette.WHITE, 4.0)
				s.draw_line(e + Vector2(-6, 6), e + Vector2(6, -6), Palette.WHITE, 4.0)
		if is_local_player(p) and NetworkManager.is_online:
			draw_local_marker(pos + bob + Vector2(0, -r - 4.0), r)
		s.text_centered(pos + Vector2(0, r + 20.0), p.display_name, 22, Palette.WHITE, 6)
		# Palabras acertadas.
		var n := int(_counts.get(p.id, 0))
		if n > 0:
			var bp := pos + Vector2(r * 0.8, -r * 0.8)
			s.draw_circle(bp, 15.0, Palette.PURPLE_DARK)
			s.draw_circle(bp, 12.5, Palette.MINT)
			s.text_centered(bp, str(n), 18, Palette.PURPLE_DARK, 0)
		# Mini bomba en las manos del jugador al que le toca.
		if is_cur:
			_draw_mini_bomb(_token_pos)

func _draw_mini_bomb(c: Vector2) -> void:
	var s := surface
	var wob := sin(_time * 9.0) * 0.08
	s.draw_set_transform(c, wob, Vector2.ONE)
	s.draw_circle(Vector2(0, 3), 24.0, Palette.PURPLE_DARK)
	s.draw_circle(Vector2.ZERO, 22.0, Color("2A2142"))
	s.draw_circle(Vector2(-7, -8), 6.0, Color(1, 1, 1, 0.35))
	s.draw_rect(Rect2(-6, -30, 12, 10), Color("8A7BE8"))
	s.draw_polyline(PackedVector2Array([Vector2(0, -30), Vector2(7, -38), Vector2(16, -36)]), Color("E1DAFF"), 3.0, true)
	var flick := 0.7 + 0.3 * sin(_time * 30.0)
	s.draw_circle(Vector2(17, -37), 6.0 * flick, Color("FFC81E"))
	s.draw_circle(Vector2(17, -37), 3.0, Color.WHITE)
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_pointer() -> void:
	var s := surface
	# Flecha chunky desde la bomba hacia el jugador que la tiene.
	var dir := Vector2.from_angle(_ptr_ang)
	var base := CENTER + dir * (BOMB_RADIUS + 22.0)
	var tip := CENTER + dir * (BOMB_RADIUS + 86.0 + 6.0 * sin(_time * 8.0))
	var perp := dir.orthogonal()
	var tri := PackedVector2Array([tip, base + perp * 26.0, base - perp * 26.0])
	s.draw_colored_polygon(tri, Palette.YELLOW)
	s.draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]), Palette.YELLOW_DARK, 4.0, true)

func _draw_bomb() -> void:
	var s := surface
	var pulse := 1.0 + 0.035 * sin(_time * 6.0) + 0.09 * _syl_pop
	var wob := Vector2(sin(_time * 17.0), cos(_time * 13.0)) * 2.2
	var c := CENTER + wob
	s.draw_set_transform(c, 0.0, Vector2.ONE * pulse)
	# Sombra dura y cuerpo.
	s.draw_circle(Vector2(0, 10), BOMB_RADIUS, Palette.PURPLE_DARK)
	s.draw_circle(Vector2.ZERO, BOMB_RADIUS, Color("231B3D"))
	s.draw_circle(Vector2.ZERO, BOMB_RADIUS - 8.0, Color("30264F"))
	s.draw_arc(Vector2.ZERO, BOMB_RADIUS - 4.0, PI * 1.05, PI * 1.55, 24, Color(1, 1, 1, 0.22), 8.0, true)
	s.draw_circle(Vector2(-BOMB_RADIUS * 0.45, -BOMB_RADIUS * 0.48), 15.0, Color(1, 1, 1, 0.28))
	# Tapón y mecha con chispas.
	s.draw_rect(Rect2(-22, -BOMB_RADIUS - 18, 44, 28), Color("8A7BE8"))
	s.draw_rect(Rect2(-22, -BOMB_RADIUS - 18, 44, 28), Palette.CARD_LIGHT, false, 3.0)
	var fuse_pts := PackedVector2Array([Vector2(0, -BOMB_RADIUS - 18), Vector2(12, -BOMB_RADIUS - 34),
			Vector2(32, -BOMB_RADIUS - 40), Vector2(48, -BOMB_RADIUS - 30)])
	s.draw_polyline(fuse_pts, Palette.PURPLE_DARK, 9.0, true)
	s.draw_polyline(fuse_pts, Palette.CARD_LIGHT, 5.0, true)
	var tip := fuse_pts[3]
	var fl := 0.75 + 0.25 * sin(_time * 40.0)
	s.draw_circle(tip, 17.0 * fl, Color(1.0, 0.6, 0.1, 0.45))
	s.draw_circle(tip, 10.0 * fl, Palette.YELLOW)
	s.draw_circle(tip, 5.0, Color.WHITE)
	for k in 5:
		var a := _time * 7.0 + k * 1.26
		var d := 12.0 + fposmod(_time * 40.0 + k * 9.0, 26.0)
		s.draw_circle(tip + Vector2(cos(a), sin(a) - 0.6) * d, 2.4, Color(1, 0.85, 0.3, 0.8 - d / 50.0))
	# Cara de la bomba: disco claro con la combinación en grande.
	s.draw_circle(Vector2(0, 8), BOMB_RADIUS * 0.77, Palette.PURPLE_DARK)
	s.draw_circle(Vector2(0, 4), BOMB_RADIUS * 0.77, Palette.CARD_LIGHT)
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var size := 84 if _syl.length() <= 2 else 68
	s.text_centered(c + Vector2(0, 4) * pulse, _syl.to_upper(), int(size * pulse), Palette.PURPLE_DARK, 0)

func _draw_draft() -> void:
	var s := surface
	if _cur_id < 0:
		return
	# Lo que está escribiendo el jugador (en vivo para todos), con la combinación resaltada.
	var cur_name := ""
	for p in players:
		if p.id == _cur_id:
			cur_name = p.display_name
	var pill := Rect2(CENTER.x - 250, CENTER.y + BOMB_RADIUS + 18.0, 500, 48)
	s.rounded_rect(pill.grow(4), 34, Palette.PURPLE_DARK)
	s.rounded_rect(pill, 31, Color(0.15, 0.1, 0.35, 0.82))
	var font := s.get_theme_default_font()
	var fs := 34
	if _draft.is_empty():
		s.text_centered(pill.get_center(), "%s está pensando..." % cur_name, 24, Color(1, 1, 1, 0.55), 0)
		return
	var low := SpanishDictionary.normalize(_draft)
	var at := low.find(_syl)
	var pre := _draft.substr(0, at) if at >= 0 else _draft
	var mid := _draft.substr(at, _syl.length()) if at >= 0 else ""
	var post := _draft.substr(at + _syl.length()) if at >= 0 else ""
	var total := font.get_string_size(_draft, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var x := pill.get_center().x - total * 0.5
	var y := pill.get_center().y + font.get_ascent(fs) * 0.5 - 4.0
	for seg in [[pre, Palette.WHITE], [mid, Palette.YELLOW], [post, Palette.WHITE]]:
		var txt: String = seg[0]
		if txt.is_empty():
			continue
		s.draw_string(font, Vector2(x, y), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, seg[1])
		x += font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x

func _draw_tier() -> void:
	var s := surface
	# Cinco puntos: el nivel actual en amarillo y los superados en blanco.
	var base := Vector2(1130, 44)
	s.text_centered(base + Vector2(0, -2), "NIVEL %d" % (_tier + 1), 30, Palette.YELLOW if _tier_flash > 0.0 else Palette.WHITE, 6)
	for i in 5:
		var c := base + Vector2((i - 2) * 30.0, 36.0)
		var r := 10.0 + (3.0 * sin(_time * 10.0) if i == _tier and _tier_flash > 0.0 else 0.0)
		s.draw_circle(c, r + 3.0, Palette.PURPLE_DARK)
		s.draw_circle(c, r, Palette.YELLOW if i == _tier else (Palette.WHITE if i < _tier else Color(1, 1, 1, 0.25)))

func _draw_alive() -> void:
	surface.text_centered(Vector2(1130, 118), "VIVOS %d/%d" % [players.size() - _eliminated.size(), players.size()], 24, Color(1, 1, 1, 0.85), 5)

func _draw_feed() -> void:
	var s := surface
	var font := s.get_theme_default_font()
	var y := 40.0
	s.text_centered(Vector2(110, y), "PALABRAS", 22, Color(1, 1, 1, 0.6), 4)
	for i in range(_feed.size() - 1, -1, -1):
		y += 34.0
		var row: Array = _feed[i]
		var col := Palette.WHITE
		for p in players:
			if p.id == int(row[0]):
				col = p.color
		var a := 1.0 - 0.1 * float(_feed.size() - 1 - i)
		s.draw_circle(Vector2(30, y - 8), 8.0, Color(col.r, col.g, col.b, a))
		s.draw_string_outline(font, Vector2(48, y), String(row[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 24, 5, Color(Palette.PURPLE_DARK.r, Palette.PURPLE_DARK.g, Palette.PURPLE_DARK.b, a))
		s.draw_string(font, Vector2(48, y), String(row[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color(1, 1, 1, a))

func _draw_boom_text() -> void:
	var s := surface
	var k := clampf(_boom_age / 0.35, 0.0, 1.0)
	var scale := 1.0 + (1.0 - k) * 1.2
	var who := ""
	var winner := ""
	for p in players:
		if p.id == _boom_who:
			who = p.display_name
		elif _over and not _eliminated.has(p.id):
			winner = p.display_name
	s.draw_set_transform(Vector2(640, 250), 0.0, Vector2.ONE * scale)
	s.text_centered(Vector2.ZERO, "¡BOOM!", 150, Palette.YELLOW, 16)
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if _boom_age > 0.4:
		var left := players.size() - _eliminated.size()
		var line := "¡%s sale de la partida!" % who
		if not _over:
			line += "  Quedan %d" % left
		s.text_centered(Vector2(640, 380), line, 42, Palette.WHITE, 8)
	if _boom_age > 0.8 and not _boom_examples.is_empty() and not _over:
		s.text_centered(Vector2(640, 438), "Valía: %s" % ", ".join(PackedStringArray(_boom_examples)), 28, Color(1, 1, 1, 0.8), 6)
	if _over and _boom_age > 1.2 and winner != "":
		s.text_centered(Vector2(640, 440), "¡%s GANA!" % winner, 60, Palette.YELLOW, 12)
