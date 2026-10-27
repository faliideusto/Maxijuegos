extends Minigame
## Puntería (modelo LOCAL_PARALLEL): un juego de precisión en el que cada jugador juega en su pantalla y
## compara después. Aparecen dianas que se esfuman si no las aciertas a tiempo, y DIANAS DORADAS que duran
## bastante menos pero valen el triple. Gana quien más puntos consigue en 30 s; no verás a los demás.
##
## Puntos: diana normal 100, dorada 300, por la precisión (el centro da el 100 %, el borde el 55 %) y por la
## racha (cada 5 aciertos seguidos suben el multiplicador: ×1, ×2, ×3). Fallar quita 25 puntos, rompe la racha
## y bloquea el disparo 0,2 s: disparar a lo loco no compensa. Desempate: menos fallos.
##
## Todos los jugadores reciben EXACTAMENTE las mismas dianas (mismas posiciones y tiempos), salen de la semilla
## común (Minigame.seed_value): es justo aunque cada PC juegue por su cuenta. La dificultad sube durante la
## partida: aparecen más deprisa, duran menos y son más pequeñas.
##
## Controles: ratón (apuntar y clic), o con teclado/mando: mover la mirilla y la acción para disparar.
## No hay nada de red aquí: report_result(puntos, fallos). Ver core/minigame.gd.

const DURATION := 30.0
const FIELD := Rect2(50, 112, 1180, 550)
const FIRST_SPAWN := 0.9
const NORMAL_POINTS := 100.0
const GOLD_POINTS := 300.0
const MISS_PENALTY := 25
const MISS_LOCKOUT := 0.2
const ACCURACY_FLOOR := 0.55          # fracción de puntos en el borde de la diana
const COMBO_STEP := 5                 # aciertos seguidos por cada +1 de multiplicador
const MAX_MULT := 3
const CURSOR_SPEED := 650.0           # mirilla con teclado/mando (px/s)
const DONE_DELAY := 1.4
const POP_TIME := 0.12                # animación de aparición

class Target:
	var t0: float                     # instante en que aparece
	var pos: Vector2
	var radius: float
	var life: float                   # cuánto dura en pantalla
	var gold: bool = false
	# Estado de juego (por PC)
	var hit: bool = false
	var hit_time: float = 0.0
	var announced: bool = false       # (oro) ya sonó el aviso de aparición

class ScorePop:
	var pos: Vector2
	var text: String
	var color: Color
	var age: float = 0.0

class Ring:
	var pos: Vector2
	var radius: float
	var color: Color
	var age: float = 0.0

var _schedule: Array[Target] = []
var _schedule_ready: bool = false
var _sum_base: float = 0.0            # suma de los puntos base de todas las dianas (tope para validar y para los bots)

var _time: float = 0.0
var _score: int = 0
var _hits: int = 0
var _misses: int = 0
var _combo: int = 0
var _best_combo: int = 0
var _lockout: float = 0.0
var _done: bool = false
var _done_t: float = 0.0
var _cursor: Vector2 = FIELD.get_center()
var _mouse_recent: float = 0.0
var _pending_clicks: Array[Vector2] = []
var _popups: Array[ScorePop] = []
var _rings: Array[Ring] = []
var _last_sec: int = 99
var _miss_flash: float = 0.0
var _mouse_hidden: bool = false
# IA del autopiloto / pruebas
var _ai_target: Target = null
var _ai_aim: Vector2 = Vector2.ZERO
var _ai_cooldown: float = 0.0
var debug_ai_skill: float = 1.0       # 1 = tira bien; <1 = más torpe

# ----------------------------------------------------------------------------
# Las dianas (iguales para todos los jugadores)
# ----------------------------------------------------------------------------

func _ensure_schedule() -> void:
	if _schedule_ready:
		return
	_schedule_ready = true
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	var t := FIRST_SPAWN
	while t < DURATION - 0.5:
		var d := clampf(t / DURATION, 0.0, 1.0)
		var tg := Target.new()
		tg.t0 = t
		tg.gold = r.randf() < lerpf(0.10, 0.22, d)
		var life := lerpf(1.9, 1.0, d)
		var radius := lerpf(46.0, 29.0, d)
		if tg.gold:
			life *= 0.52                  # las doradas duran la mitad...
			radius *= 0.82                # ...y son más pequeñas
		tg.life = life
		tg.radius = radius
		tg.pos = _free_position(r, tg)
		_schedule.append(tg)
		_sum_base += GOLD_POINTS if tg.gold else NORMAL_POINTS
		t += lerpf(0.78, 0.30, d) * r.randf_range(0.8, 1.2)

## Posición que no solape con otras dianas visibles al mismo tiempo.
func _free_position(r: RandomNumberGenerator, tg: Target) -> Vector2:
	var inner := FIELD.grow(-(tg.radius + 14.0))
	var pos := Vector2.ZERO
	for attempt in 30:
		pos = Vector2(r.randf_range(inner.position.x, inner.end.x), r.randf_range(inner.position.y, inner.end.y))
		var ok := true
		for o in _schedule:
			if o.t0 + o.life > tg.t0 and pos.distance_to(o.pos) < o.radius + tg.radius + 16.0:
				ok = false
				break
		if ok:
			return pos
	return pos

# ----------------------------------------------------------------------------
# Preparación y ciclo
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	_ensure_schedule()
	surface.draw_callback = _draw_game

func _on_start() -> void:
	_time = 0.0
	_score = 0
	_hits = 0
	_misses = 0
	_combo = 0
	_best_combo = 0
	_done = false
	_cursor = FIELD.get_center()
	for t in _schedule:
		t.hit = false
		t.announced = false
	# El cursor del sistema se oculta: la mirilla la dibuja el juego (solo si juega una persona con ratón).
	if local_player != null and not demo and not InputManager.is_simulated(local_player.id):
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		_mouse_hidden = true

func _exit_tree() -> void:
	_restore_mouse()

func _restore_mouse() -> void:
	if _mouse_hidden:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_mouse_hidden = false

func _unhandled_input(event: InputEvent) -> void:
	if not is_running or _done:
		return
	if event is InputEventMouseMotion:
		_mouse_recent = 1.5
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_mouse_recent = 1.5      # el disparo lo hace la acción (el clic es la acción del jugador)

# ----------------------------------------------------------------------------
# Jugador local (LOCAL_PARALLEL)
# ----------------------------------------------------------------------------

func _play(delta: float) -> void:
	if _done or local_player == null:
		return
	_time += delta
	_lockout = maxf(0.0, _lockout - delta)
	_mouse_recent = maxf(0.0, _mouse_recent - delta)
	if InputManager.is_simulated(local_player.id):
		_ai_step(delta)
	else:
		_human_step(delta)
	# Avisos: dorada que aparece y pitidos finales.
	for t in _schedule:
		if t.gold and not t.announced and _time >= t.t0:
			t.announced = true
			Audio.sfx(&"gold_spawn", -8.0)
	var sec := ceili(DURATION - _time)
	if sec != _last_sec and sec <= 3 and sec > 0:
		Audio.sfx(&"beep", -7.0)
	_last_sec = sec
	if _time >= DURATION:
		_finish_play()

func _human_step(delta: float) -> void:
	if _mouse_recent > 0.0:
		_cursor = surface.get_local_mouse_position()
	else:
		var v := InputManager.get_vector(local_player.id)
		_cursor += v * CURSOR_SPEED * delta
	_cursor = _cursor.clamp(Vector2.ZERO, Vector2(1280, 720))
	for c in _pending_clicks:
		_fire(c)
	_pending_clicks.clear()
	if action_presses(local_player) > 0:
		_fire(_cursor)

## Un disparo en `pos`. Devuelve true si acierta.
func _fire(pos: Vector2) -> bool:
	if _lockout > 0.0 or _done:
		return false
	var tgt := _target_at(pos)
	if tgt == null:
		_miss(pos)
		return false
	var d := pos.distance_to(tgt.pos)
	var acc := clampf(1.0 - d / tgt.radius, 0.0, 1.0)
	var base := GOLD_POINTS if tgt.gold else NORMAL_POINTS
	var pts := int(round(base * (ACCURACY_FLOOR + (1.0 - ACCURACY_FLOOR) * acc) / 5.0)) * 5
	var old_mult := _multiplier()
	_combo += 1
	_best_combo = maxi(_best_combo, _combo)
	var mult := _multiplier()
	var gain := pts * mult
	_score += gain
	_hits += 1
	tgt.hit = true
	tgt.hit_time = _time
	var col := Color("FFC81E") if tgt.gold else Color("FFFFFF")
	_popups.append(_make_popup(tgt.pos + Vector2(0, -tgt.radius - 10.0), "+%d" % gain, col))
	var ring := Ring.new()
	ring.pos = tgt.pos
	ring.radius = tgt.radius
	ring.color = col
	_rings.append(ring)
	Audio.sfx(&"shot", -8.0)
	Audio.sfx(&"hit_gold" if tgt.gold else &"hit", -3.0)
	if mult > old_mult:
		Audio.sfx(&"combo", -3.0)
		_popups.append(_make_popup(Vector2(640, 150), "¡RACHA ×%d!" % mult, Palette.MINT))
	return true

func _miss(pos: Vector2) -> void:
	_misses += 1
	_combo = 0
	_score = maxi(0, _score - MISS_PENALTY)
	_lockout = MISS_LOCKOUT
	_miss_flash = 1.0
	_popups.append(_make_popup(pos + Vector2(0, -26.0), "-%d" % MISS_PENALTY, Palette.CORAL))
	Audio.sfx(&"shot", -8.0)
	Audio.sfx(&"miss", -4.0)

func _make_popup(pos: Vector2, text: String, color: Color) -> ScorePop:
	var p := ScorePop.new()
	p.pos = pos
	p.text = text
	p.color = color
	return p

func _multiplier() -> int:
	return mini(1 + _combo / COMBO_STEP, MAX_MULT)

## ¿Está visible esa diana ahora?
func _active(t: Target) -> bool:
	return not t.hit and _time >= t.t0 and _time < t.t0 + t.life

## Diana alcanzada por un disparo en `pos` (la dorada tiene prioridad; luego la más reciente).
func _target_at(pos: Vector2) -> Target:
	var best: Target = null
	for t in _schedule:
		if not _active(t):
			continue
		if pos.distance_to(t.pos) <= t.radius:
			if best == null or (t.gold and not best.gold) or (t.gold == best.gold and t.t0 > best.t0):
				best = t
	return best

func _finish_play() -> void:
	_done = true
	_done_t = 0.0
	_restore_mouse()
	DevCli.log_event("target score=%d hits=%d misses=%d combo=%d" % [_score, _hits, _misses, _best_combo])

func _animate(delta: float) -> void:
	_miss_flash = maxf(0.0, _miss_flash - delta * 4.0)
	for p in _popups:
		p.age += delta
	_popups = _popups.filter(func(x: ScorePop) -> bool: return x.age < 0.9)
	for r in _rings:
		r.age += delta
	_rings = _rings.filter(func(x: Ring) -> bool: return x.age < 0.35)
	if _done:
		_done_t += delta
		if _done_t >= DONE_DELAY and not _reported:
			report_result(float(_score), float(_misses))   # más puntos = mejor; desempate: menos fallos

# ----------------------------------------------------------------------------
# IA del autopiloto: apunta con algo de torpeza y reacción humana
# ----------------------------------------------------------------------------

func _ai_step(delta: float) -> void:
	_ai_cooldown = maxf(0.0, _ai_cooldown - delta)
	if _ai_target == null or not _active(_ai_target):
		_ai_target = _ai_pick()
		if _ai_target != null:
			var err := _ai_target.radius * lerpf(1.1, 0.3, clampf(debug_ai_skill, 0.0, 1.0))
			_ai_aim = _ai_target.pos + Vector2(randf_range(-err, err), randf_range(-err, err)) * 0.6
	if _ai_target != null:
		var step := 1500.0 * delta * clampf(debug_ai_skill, 0.2, 1.0)
		_cursor = _aim_toward(_cursor, _ai_aim, step)
		if _cursor.distance_to(_ai_aim) < 5.0 and _ai_cooldown <= 0.0 and _lockout <= 0.0:
			_ai_cooldown = lerpf(0.35, 0.12, clampf(debug_ai_skill, 0.0, 1.0))
			_fire(_cursor)
			_ai_target = null

func _aim_toward(from: Vector2, to: Vector2, step: float) -> Vector2:
	var d := to - from
	return to if d.length() <= step else from + d.normalized() * step

## Elige qué diana perseguir: las doradas primero, y entre las normales, la que va a desaparecer antes. Solo
## las que llevan ya un rato (tiempo de reacción humano).
func _ai_pick() -> Target:
	var best: Target = null
	var best_key := INF
	var reaction := lerpf(0.55, 0.16, clampf(debug_ai_skill, 0.0, 1.0))
	for t in _schedule:
		if not _active(t) or _time < t.t0 + reaction:
			continue
		var key := (t.t0 + t.life) - (1000.0 if t.gold else 0.0)
		if key < best_key:
			best_key = key
			best = t
	return best

# --- Resultado simulado de un bot / desconectado (lo calcula el host) ---
func _bot_result(_player: PlayerData, r: RandomNumberGenerator) -> Dictionary:
	_ensure_schedule()
	var skill := r.randf_range(0.22, 0.75)
	return {"score": roundf(_sum_base * skill * 1.15), "tiebreak": float(r.randi_range(2, 14))}

# --- Plausibilidad: no se puede pasar de todas las dianas, con la racha máxima ---
func _validate_result(score: float, tiebreak: float) -> bool:
	_ensure_schedule()
	return score >= 0.0 and score <= _sum_base * float(MAX_MULT) + 1.0 and tiebreak >= 0.0 and tiebreak <= 1000.0

# ----------------------------------------------------------------------------
# Utilidades de depuración / pruebas (tests/target_test.gd)
# ----------------------------------------------------------------------------

func debug_schedule() -> Array[Target]:
	_ensure_schedule()
	return _schedule

func debug_sum_base() -> float:
	_ensure_schedule()
	return _sum_base

func debug_state() -> Dictionary:
	return {"score": _score, "hits": _hits, "misses": _misses, "combo": _combo, "best_combo": _best_combo,
			"mult": _multiplier(), "done": _done, "time": _time}

## Fija el reloj (pruebas).
func debug_set_time(t: float) -> void:
	_time = t

func debug_fire(pos: Vector2) -> bool:
	return _fire(pos)

func debug_advance(delta: float) -> void:
	_play(delta)

# ----------------------------------------------------------------------------
# Dibujo
# ----------------------------------------------------------------------------

func _draw_game() -> void:
	var s := surface
	# Pista: panel oscuro con rejilla de puntos y borde.
	s.rounded_rect(Rect2(FIELD.position + Vector2(0, 8), FIELD.size).grow(8), 30, Color(0, 0, 0, 0.3))
	s.rounded_rect(FIELD.grow(8), 30, Color("2DC7D9").darkened(0.35))
	s.rounded_rect(FIELD.grow(4), 27, Color(0.07, 0.10, 0.20))
	s.rounded_rect(FIELD, 24, Color(0.10, 0.14, 0.26))
	var gy := FIELD.position.y + 30.0
	while gy < FIELD.end.y - 10.0:
		var gx := FIELD.position.x + 30.0
		while gx < FIELD.end.x - 10.0:
			s.draw_circle(Vector2(gx, gy), 2.0, Color(1, 1, 1, 0.07))
			gx += 60.0
		gy += 60.0
	# Dianas visibles (y las que se desvanecen).
	for t in _schedule:
		if _time < t.t0:
			break
		var age := _time - t.t0
		if t.hit:
			continue
		if age < t.life:
			var pop := clampf(age / POP_TIME, 0.0, 1.0)
			var scale := 1.0 + 0.25 * sin(pop * PI) if pop < 1.0 else 1.0
			_draw_target(t, scale * pop, 1.0 - age / t.life, 1.0)
		elif age < t.life + 0.18:
			var k := (age - t.life) / 0.18
			_draw_target(t, 1.0 - 0.3 * k, 0.0, 1.0 - k)
	for r in _rings:
		var k := r.age / 0.35
		s.draw_arc(r.pos, r.radius * (1.0 + 0.9 * k), 0.0, TAU, 36, Color(r.color.r, r.color.g, r.color.b, 1.0 - k), 5.0, true)
	for p in _popups:
		var kp: float = p.age / 0.9
		s.text_centered(p.pos + Vector2(0, -50.0 * kp), p.text, 34, Color(p.color.r, p.color.g, p.color.b, 1.0 - kp * kp), 6)
	_draw_hud()
	if _miss_flash > 0.0:
		s.draw_rect(view_rect(), Color(1.0, 0.2, 0.25, _miss_flash * 0.12))
	if not _done and (_mouse_hidden or InputManager.is_simulated(local_player.id) if local_player != null else false):
		_draw_crosshair()
	if _done:
		s.text_centered(Vector2(640, 320), "¡TIEMPO!", 100, Palette.YELLOW, 14)
		if _done_t > 0.4:
			s.text_centered(Vector2(640, 410), "%d puntos · %d aciertos · %d fallos" % [_score, _hits, _misses], 36, Palette.WHITE, 8)

func _draw_target(t: Target, scale: float, life_frac: float, alpha: float) -> void:
	var s := surface
	var r := t.radius * scale
	if r <= 1.0:
		return
	var rings: Array[Color]
	if t.gold:
		for k in 4:
			s.draw_circle(t.pos, r * (1.7 - 0.15 * k), Color(1.0, 0.82, 0.2, (0.05 + 0.03 * k) * alpha))
		rings = [Color(1.0, 0.78, 0.1), Color(1.0, 0.96, 0.7), Color(0.9, 0.58, 0.05), Color(1.0, 0.96, 0.7), Color(1.0, 0.78, 0.1)]
	else:
		rings = [Color(0.96, 0.27, 0.32), Color(1, 1, 1), Color(0.96, 0.27, 0.32), Color(1, 1, 1), Color(0.96, 0.27, 0.32)]
	s.draw_circle(t.pos + Vector2(0, 5), r, Color(0, 0, 0, 0.3 * alpha))
	s.draw_circle(t.pos, r + 3.0, Color(0.05, 0.05, 0.12, alpha))
	for i in 5:
		var c: Color = rings[i]
		s.draw_circle(t.pos, r * (1.0 - 0.2 * i), Color(c.r, c.g, c.b, alpha))
	if t.gold:
		# Destellos que giran.
		for k in 4:
			var a := _time * 3.0 + k * PI * 0.5
			var p0 := t.pos + Vector2.from_angle(a) * (r + 6.0)
			var p1 := t.pos + Vector2.from_angle(a) * (r + 18.0)
			s.draw_line(p0, p1, Color(1, 0.95, 0.6, 0.9 * alpha), 3.0)
	# Anillo de tiempo: se cierra hasta que la diana desaparece.
	if life_frac > 0.0:
		var urgent := life_frac < 0.3
		var col := Palette.CORAL if urgent else Color(1, 1, 1, 0.85)
		s.draw_arc(t.pos, r + 10.0, -PI * 0.5, -PI * 0.5 + TAU * life_frac, 32, col, 4.0, true)

func _draw_crosshair() -> void:
	var s := surface
	var c := _cursor
	var col := local_player.color.lightened(0.4) if local_player != null else Color.WHITE
	var locked := _lockout > 0.0
	var ring_col := Palette.CORAL if locked else Color.WHITE
	s.draw_arc(c, 20.0, 0.0, TAU, 28, Color(0, 0, 0, 0.55), 6.0, true)
	s.draw_arc(c, 20.0, 0.0, TAU, 28, ring_col, 3.0, true)
	for k in 4:
		var d := Vector2.from_angle(k * PI * 0.5)
		s.draw_line(c + d * 12.0, c + d * 30.0, Color(0, 0, 0, 0.55), 6.0)
		s.draw_line(c + d * 12.0, c + d * 30.0, ring_col, 3.0)
	s.draw_circle(c, 4.0, Color(0, 0, 0, 0.55))
	s.draw_circle(c, 2.5, col)

func _draw_hud() -> void:
	var s := surface
	s.text_centered(Vector2(640, 46), str(_score), 64, Palette.WHITE, 10)
	# Barra de tiempo.
	var bar := Rect2(390, 84, 500, 16)
	s.rounded_rect(bar.grow(4), 12, Color(0, 0, 0, 0.45))
	var frac := clampf(1.0 - _time / DURATION, 0.0, 1.0)
	if frac > 0.0:
		var col := Palette.YELLOW if frac > 0.12 else Palette.CORAL
		s.rounded_rect(Rect2(bar.position, Vector2(maxf(bar.size.x * frac, 16.0), bar.size.y)), 8, col)
	var mult := _multiplier()
	s.text_centered(Vector2(150, 48), "RACHA %d" % _combo, 30, Palette.MINT if mult > 1 else Palette.WHITE, 6)
	if mult > 1:
		s.text_centered(Vector2(150, 84), "×%d" % mult, 34, Palette.YELLOW, 7)
	var total := _hits + _misses
	var acc := roundi(100.0 * float(_hits) / float(total)) if total > 0 else 100
	s.text_centered(Vector2(1130, 48), "PRECISIÓN %d%%" % acc, 30, Palette.WHITE, 6)
	s.text_centered(Vector2(1130, 84), "%d s" % maxi(0, ceili(DURATION - _time)), 30, Color(1, 1, 1, 0.85), 6)
