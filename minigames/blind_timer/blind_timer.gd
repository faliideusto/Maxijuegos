extends Minigame
## Crono a Ciegas (modelo HOST_AUTHORITATIVE): un cronómetro en el centro y todos los jugadores sentados
## alrededor. Hay un tiempo objetivo al azar (5-15 s, segundos enteros) que primero se ANUNCIA en grande (2,6 s);
## después el crono empieza a contar desde 0, pero
## al poco rato DESAPARECE: hay que seguir contando de cabeza y pulsar el botón de acción justo en el objetivo.
## Cada jugador solo puede parar una vez. Nadie ve el tiempo de nadie (ni el suyo) hasta que han parado todos;
## entonces se destapan y gana quien se quedó más cerca, por arriba o por abajo.
##
## Valores: el crono se ve durante el 40 % del objetivo (entre 2 y 5 s) y se desvanece en 0,6 s. Quien no pulse
## antes de objetivo + 4 s queda "sin parar" (último). Desempate: quien pulsó antes. Va SIN música (un ritmo de
## fondo serviría para contar).
##
## Sin código de red propio: el host simula (_simulate) y los clientes dibujan el estado que reciben
## (_apply_state) y los eventos (announce / go / hide / stop / reveal). Los tiempos de cada jugador no viajan a los clientes hasta
## el destape. Ver core/minigame.gd.

enum Phase { ANNOUNCE, RUN, REVEAL }

const CENTER := Vector2(640, 356)
const CLOCK_R := 138.0
const RING := Vector2(480, 250)       # semiejes de la elipse en la que se sientan los jugadores
const MIN_TARGET := 5
const MAX_TARGET := 15
const HIDE_FRACTION := 0.4            # parte del objetivo durante la que se ve el crono
const HIDE_MIN := 2.0
const HIDE_MAX := 5.0
const HIDE_FADE := 0.6
const ANNOUNCE_TIME := 2.6           # s que se anuncia el objetivo en grande antes de que arranque el crono
const GRACE := 1.0                    # las pulsaciones del primer segundo no cuentan (evita paradas por accidente)
const OVERTIME := 4.0                 # s tras el objetivo en los que aún se puede parar
const NO_STOP := -1.0
const REVEAL_LEAD := 0.9              # pausa antes de destapar el primer tiempo
const REVEAL_STEP := 0.45             # s entre un tiempo destapado y el siguiente (del peor al mejor)
const REVEAL_HOLD := 3.0              # s con todo destapado antes de terminar

var _phase: Phase = Phase.ANNOUNCE
var _announce_t: float = ANNOUNCE_TIME  # s que quedan de anuncio
var _target: float = 8.0
var _hide_at: float = 3.2
var _elapsed: float = 0.0
var _stops: Dictionary = {}           # id -> tiempo en el que paró (NO_STOP = aún no). Solo host hasta el destape
var _stopped: Dictionary = {}         # id -> bool (esto sí lo ven todos)
var _reveal_t: float = 0.0
var _order: Array[int] = []           # ranking (ids del mejor al peor), válido en REVEAL
var _bot_stop: Dictionary = {}        # id -> instante en el que parará un bot / el autopiloto
# Solo visual
var _time: float = 0.0
var _pop: Dictionary = {}             # id -> rebote del avatar al parar (1 → 0)
var _last_sec: int = 0
var _shown: int = 0                   # tiempos ya destapados (para el sonido)

# ----------------------------------------------------------------------------
# Preparación
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	_target = float(rng.randi_range(MIN_TARGET, MAX_TARGET))
	_hide_at = hide_time_for(_target)
	for p in players:
		_stops[p.id] = NO_STOP
		_stopped[p.id] = false
		_pop[p.id] = 0.0
		# Los bots clavan el objetivo con un error humano (más error cuanto más largo es el tiempo).
		var err := rng.randfn(0.0, 0.18 + 0.045 * _target)
		_bot_stop[p.id] = clampf(_target + err, _target * 0.6, _target + OVERTIME - 0.3)
	surface.draw_callback = _draw_game

func _on_start() -> void:
	_elapsed = 0.0
	_last_sec = 0
	if not is_authority:
		return
	_phase = Phase.ANNOUNCE
	_announce_t = ANNOUNCE_TIME
	send_event("announce")
	DevCli.log_event("blind_timer start target=%d hide=%.1f" % [int(_target), _hide_at])

## Segundo en el que el crono empieza a desvanecerse para un objetivo dado.
static func hide_time_for(target: float) -> float:
	return clampf(target * HIDE_FRACTION, HIDE_MIN, HIDE_MAX)

# ----------------------------------------------------------------------------
# Simulación (solo host)
# ----------------------------------------------------------------------------

func _simulate(delta: float) -> void:
	if _phase == Phase.REVEAL:
		_reveal_t += delta
		if _reveal_t >= reveal_duration():
			finish(_order)
		return
	if _phase == Phase.ANNOUNCE:
		# Primero se anuncia el objetivo; el crono aún no corre y las pulsaciones no cuentan.
		for p in players:
			action_presses(p)
		_announce_t -= delta
		if _announce_t <= 0.0:
			_phase = Phase.RUN
			_elapsed = 0.0
			send_event("go")
		return
	var before := _elapsed
	_elapsed += delta
	if before < _hide_at and _elapsed >= _hide_at:
		send_event("hide")
	# Se consumen las pulsaciones de todos; solo vale la primera de cada jugador.
	for p in players:
		var n := action_presses(p)
		if n > 0 and not _stopped[p.id] and _elapsed >= GRACE:
			_stop(p)
	if _all_stopped() or _elapsed >= _target + OVERTIME:
		_begin_reveal()

func _stop(p: PlayerData) -> void:
	_stops[p.id] = _elapsed
	_stopped[p.id] = true
	DevCli.log_event("blind_timer stop id=%d t=%.2f" % [p.id, _elapsed])
	send_event("stop", {"p": p.id})

func _all_stopped() -> bool:
	for p in players:
		if not _stopped[p.id]:
			return false
	return true

func _begin_reveal() -> void:
	_phase = Phase.REVEAL
	_reveal_t = 0.0
	_order = build_ranking()
	var times := PackedFloat32Array()
	for p in players:
		times.append(_stops[p.id])
	send_event("reveal", {"t": times, "o": PackedInt32Array(_order)})

## Error de un jugador respecto al objetivo (INF si no llegó a parar).
func error_of(id: int) -> float:
	var t: float = _stops.get(id, NO_STOP)
	return INF if t < 0.0 else absf(t - _target)

## Del más cercano al objetivo al más lejano; a igual error, quien pulsó antes. Los que no pararon, al final.
func build_ranking() -> Array[int]:
	var ids: Array[int] = []
	for p in players:
		ids.append(p.id)
	ids.sort_custom(func(a: int, b: int) -> bool:
		var ea := error_of(a)
		var eb := error_of(b)
		if ea != eb:
			return ea < eb
		if _stops[a] != _stops[b]:
			return _stops[a] < _stops[b]
		return a < b)
	return ids

func reveal_duration() -> float:
	return REVEAL_LEAD + REVEAL_STEP * players.size() + REVEAL_HOLD

# --- Bots y autopiloto: paran en el instante que se les sorteó ---
func _bot_action(player: PlayerData) -> int:
	if _phase == Phase.RUN and not _stopped[player.id] and _elapsed >= float(_bot_stop[player.id]):
		return 1
	return 0

# ----------------------------------------------------------------------------
# Estado hacia los clientes
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var st := PackedByteArray()
	for p in players:
		st.append(1 if _stopped[p.id] else 0)
	return {"ph": int(_phase), "t": _elapsed, "tg": _target, "st": st, "rv": _reveal_t, "an": _announce_t}

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	var d: Dictionary = state
	_phase = int(d.get("ph", _phase)) as Phase
	_target = float(d.get("tg", _target))
	_hide_at = hide_time_for(_target)
	_reveal_t = float(d.get("rv", _reveal_t))
	_announce_t = float(d.get("an", _announce_t))
	# El crono avanza solo entre snapshots (_animate); solo se corrige si se ha desviado de verdad.
	var t := float(d.get("t", _elapsed))
	if absf(t - _elapsed) > 0.1:
		_elapsed = t
	var st: Variant = d.get("st")
	if st is PackedByteArray:
		for i in mini(st.size(), players.size()):
			_stopped[players[i].id] = st[i] != 0

func _on_event(event_name: String, data: Variant) -> void:
	match event_name:
		"announce":
			_phase = Phase.ANNOUNCE
			_announce_t = ANNOUNCE_TIME
			Audio.sfx(&"stinger", -4.0)
		"go":
			_phase = Phase.RUN
			_elapsed = 0.0
			Audio.sfx(&"beep_go", -3.0)
		"hide":
			Audio.sfx(&"swoosh", -6.0)
		"stop":
			var who := _player_by_id(int(data.get("p", -1))) if data is Dictionary else null
			if who == null:
				return
			_stopped[who.id] = true
			_pop[who.id] = 1.0
			if is_audible(who):
				Audio.sfx(&"claim", -2.0)
			else:
				Audio.sfx(&"ui_hover", -8.0)
		"reveal":
			if not data is Dictionary:
				return
			_phase = Phase.REVEAL
			_reveal_t = 0.0
			_shown = 0
			var times: Variant = data.get("t")
			if times is PackedFloat32Array:
				for i in mini(times.size(), players.size()):
					_stops[players[i].id] = times[i]
			var order: Variant = data.get("o")
			if order is PackedInt32Array:
				_order.clear()
				for id in order:
					_order.append(id)
			Audio.sfx(&"stinger", -4.0)

func _player_by_id(id: int) -> PlayerData:
	for p in players:
		if p.id == id:
			return p
	return null

# ----------------------------------------------------------------------------
# Animación (todos los PC)
# ----------------------------------------------------------------------------

func _animate(delta: float) -> void:
	_time += delta
	for p in players:
		_pop[p.id] = maxf(0.0, float(_pop[p.id]) - delta * 3.5)
	if not is_authority and is_running:
		match _phase:
			Phase.ANNOUNCE: _announce_t = maxf(0.0, _announce_t - delta)
			Phase.RUN: _elapsed += delta
			Phase.REVEAL: _reveal_t += delta
	if not is_running:
		return
	if _phase == Phase.ANNOUNCE:
		pass
	elif _phase == Phase.RUN:
		# Tic por segundo mientras el crono se ve: ayuda a coger el ritmo antes de que desaparezca.
		var sec := floori(_elapsed)
		if sec != _last_sec and sec >= 1 and _elapsed < _hide_at:
			Audio.sfx(&"score_tick", -4.0)
		_last_sec = sec
	else:
		var n := revealed_count()
		if n > _shown:
			Audio.sfx(&"score_pop" if n >= players.size() else &"pop", -4.0)
		_shown = n

## Cuántos tiempos se han destapado ya (se destapan del último clasificado al primero).
func revealed_count() -> int:
	if _phase != Phase.REVEAL:
		return 0
	return clampi(floori((_reveal_t - REVEAL_LEAD) / REVEAL_STEP) + 1, 0, players.size())

## Opacidad del crono: 1 mientras se ve, baja a 0 al desaparecer.
func clock_alpha() -> float:
	return clampf(1.0 - (_elapsed - _hide_at) / HIDE_FADE, 0.0, 1.0)

# ----------------------------------------------------------------------------
# Dibujo
# ----------------------------------------------------------------------------

## Asiento del jugador i: repartidos alrededor del crono, empezando por arriba.
func seat(i: int) -> Vector2:
	var a := -PI * 0.5 + TAU * float(i) / float(maxi(players.size(), 1))
	if players.size() == 2:
		a = PI * float(i)             # con dos, uno a cada lado
	return CENTER + Vector2(cos(a) * RING.x, sin(a) * RING.y)

func _draw_game() -> void:
	_draw_clock()
	for i in players.size():
		_draw_player(i)
	_draw_hud()
	if is_running and _phase == Phase.ANNOUNCE:
		_draw_announce()

## Anuncio del objetivo a pantalla completa, antes de que arranque el crono.
func _draw_announce() -> void:
	var s := surface
	var k := clampf((ANNOUNCE_TIME - _announce_t) / 0.35, 0.0, 1.0)      # entrada con rebote
	var out := clampf(_announce_t / 0.25, 0.0, 1.0)                     # salida rápida
	var scale := (1.0 + 0.35 * sin(k * PI) * (1.0 - k) + 0.03 * sin(_time * 7.0)) * lerpf(0.4, 1.0, k)
	s.draw_rect(Rect2(-2000, -2000, 5280, 4720), Color(Palette.PURPLE_DARK, 0.82 * k * out))
	s.draw_set_transform(Vector2(640, 350), 0.0, Vector2.ONE * scale)
	s.text_centered(Vector2(0, -150), "PÁRALO EN", 64, Color(1, 1, 1, out), 12)
	s.text_centered(Vector2(0, 0), "%d" % int(_target), 260, Color(Palette.YELLOW, out), 26)
	s.text_centered(Vector2(0, 150), "SEGUNDOS", 64, Color(1, 1, 1, out), 12)
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_clock() -> void:
	var s := surface
	var reveal := _phase == Phase.REVEAL
	s.draw_circle(CENTER + Vector2(0, 12), CLOCK_R + 10.0, Color(0, 0, 0, 0.28))
	s.draw_circle(CENTER, CLOCK_R + 10.0, Palette.PURPLE_DARK)
	s.draw_circle(CENTER, CLOCK_R, Palette.CARD)
	# Marcas de las horas.
	for k in 12:
		var dir := Vector2.from_angle(TAU * k / 12.0)
		s.draw_line(CENTER + dir * (CLOCK_R - 16.0), CENTER + dir * (CLOCK_R - 6.0), Color(1, 1, 1, 0.3), 4.0)
	# Objetivo, siempre a la vista.
	s.text_centered(CENTER + Vector2(0, -78), "OBJETIVO", 22, Color(1, 1, 1, 0.8), 5)
	s.text_centered(CENTER + Vector2(0, -40), "%d s" % int(_target) if is_running or _phase != Phase.ANNOUNCE else "?", 50, Palette.YELLOW, 10)
	if reveal:
		s.draw_arc(CENTER, CLOCK_R - 3.0, 0.0, TAU, 64, Palette.YELLOW, 7.0, true)
		s.text_centered(CENTER + Vector2(0, 36), "¡TIEMPO!", 46, Palette.WHITE, 10)
		return
	var a := clock_alpha()
	if a > 0.0:
		# Aro que se llena hasta el objetivo y cifras del crono.
		var frac := clampf(_elapsed / _target, 0.0, 1.0)
		s.draw_arc(CENTER, CLOCK_R - 3.0, -PI * 0.5, -PI * 0.5 + TAU * frac, 64, Color(Palette.MINT, a), 7.0, true)
		s.text_centered(CENTER + Vector2(0, 40), "%.2f" % _elapsed, 68, Color(1, 1, 1, a), 12 if a > 0.6 else 0)
	if a < 1.0:
		# Ya no se ve: interrogaciones que laten (sin ritmo de segundos, para no dar pistas).
		var pulse := 1.0 + 0.06 * sin(_time * 5.3)
		s.draw_set_transform(CENTER + Vector2(0, 40), 0.0, Vector2.ONE * pulse)
		s.text_centered(Vector2.ZERO, "?.??", 68, Color(1, 1, 1, (1.0 - a) * 0.55), 0)
		s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_player(i: int) -> void:
	var s := surface
	var p := players[i]
	var c := seat(i)
	var r := 36.0 if players.size() <= 6 else 31.0
	var stopped: bool = _stopped[p.id]
	var look := (CENTER - c).normalized()
	var rank := _order.find(p.id)
	# En el destape, cada jugador se descubre cuando le toca (del último al primero).
	var shown := _phase == Phase.REVEAL and rank >= 0 and rank >= players.size() - revealed_count()
	var winner := shown and rank == 0 and error_of(p.id) < INF
	if winner:
		s.draw_circle(c, r + 14.0, Color(Palette.YELLOW, 0.4 + 0.15 * sin(_time * 6.0)))
	var b: float = _pop[p.id]
	s.draw_set_transform(c, 0.0, Vector2(1.0 + 0.25 * b, 1.0 - 0.25 * b))
	AvatarPainter.paint(s, Vector2.ZERO, r, p.color, look)
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if winner:
		AvatarPainter.paint_crown(s, c, r)
	elif is_local_player(p) and NetworkManager.is_online:
		draw_local_marker(c, r)
	s.text_centered(c + Vector2(0, r + 16.0), p.label(), 20, Palette.WHITE, 5)
	var tag := c + Vector2(0, r + 44.0)
	if shown:
		var t: float = _stops[p.id]
		if t < 0.0:
			_pill(tag, "SIN PARAR", Palette.CORAL_DARK, Palette.WHITE)
		else:
			var diff := t - _target
			_pill(tag, "%.2f  (%s%.2f)" % [t, "+" if diff >= 0.0 else "-", absf(diff)],
					Palette.YELLOW if rank == 0 else Palette.PURPLE_DARK,
					Palette.PURPLE_DARK if rank == 0 else Palette.WHITE)
		s.text_centered(c + Vector2(-r - 16.0, -r + 6.0), "%dº" % (rank + 1), 26,
				Palette.YELLOW if rank == 0 else Palette.WHITE, 6)
	elif stopped:
		_pill(tag, "¡PARADO!", Palette.MINT, Palette.PURPLE_DARK)

## Etiqueta tipo píldora centrada en `center`.
func _pill(center: Vector2, text: String, bg: Color, fg: Color) -> void:
	var s := surface
	var w := s.get_theme_default_font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x + 24.0
	s.rounded_rect(Rect2(center.x - w * 0.5, center.y - 13.0, w, 26.0), 13, bg)
	s.text_centered(center, text, 18, fg, 0)

func _draw_hud() -> void:
	var s := surface
	if _phase == Phase.REVEAL:
		if revealed_count() >= players.size() and not _order.is_empty() and error_of(_order[0]) < INF:
			var w := _player_by_id(_order[0])
			if w != null:
				s.text_centered(Vector2(640, 40), "¡%s GANA!" % w.display_name.to_upper(), 44, Palette.YELLOW, 10)
		return
	if _phase == Phase.ANNOUNCE:
		return
	var me := _hud_player()
	var hint := "Cuenta de cabeza y pulsa en el objetivo"
	if me != null and _stopped[me.id]:
		hint = "¡Parado! Esperando a los demás…"
	elif _elapsed < _hide_at:
		hint = "El crono desaparece en %d…" % ceili(_hide_at - _elapsed)
	s.text_centered(Vector2(640, 40), hint, 30, Palette.WHITE, 7)

## Jugador al que se le habla en el texto de ayuda: el de este PC (online) o ninguno (varios en un PC).
func _hud_player() -> PlayerData:
	if local_player != null:
		return local_player
	for p in players:
		if p.device == PlayerData.DEVICE_LOCAL:
			return p
	return null
