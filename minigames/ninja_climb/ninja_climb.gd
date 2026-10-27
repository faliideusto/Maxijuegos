extends Minigame
## Ninja Trepador (modelo LOCAL_PARALLEL), inspirado en Ninja Climb: dos paredes verticales enfrentadas y un ninja que
## sube saltando de una a otra. Cada jugador juega en su pantalla (sin verse) sobre las MISMAS paredes (salen de la
## semilla común) durante 45 s y gana la mayor ALTURA máxima; después, el segundo más alto, etc.
##
## MECÁNICA CENTRAL: desde el ninja sale una trayectoria de PUNTOS que oscila sola y sin parar entre un ángulo
## mínimo y uno máximo. El jugador NO la dirige: con su único botón (espacio, acción, clic izquierdo) salta AL INSTANTE
## siguiendo los puntos de ese momento. No se carga potencia. Los puntos son EXACTAMENTE la trayectoria que seguirá el
## ninja (misma función `_pos_at`): llegan hasta donde aterrizará o hasta el obstáculo con el que chocaría.
## Sin pulsar nada, el ninja se desliza despacio por la pared.
##
## Física: salto parabólico con velocidad inicial fija (JUMP_SPEED) y gravedad; la velocidad horizontal es constante, así
## que SIEMPRE llega a la otra pared y el ángulo solo decide cuánto sube: más vertical = más altura (la ganancia crece con
## el ángulo en todo el rango; JUMP_C la ajusta).
##
## Obstáculos: bloques con pinchos en las paredes. Cada zona de aterrizaje es un hueco entre dos bloques que se va
## estrechando con la altura, así que hay que elegir el ángulo justo; el ninja también muere si se desliza contra un
## bloque o si se cae por debajo de la cámara. La oscilación se acelera con la altura.
##
## Un solo intento. Sin red: report_result(altura en metros).

const TIME_LIMIT := 45.0
const WALL_L := 400.0                 # x de la cara interior de la pared izquierda
const WALL_R := 880.0                 # ... y de la derecha
const NINJA_R := 14.0
const GRAVITY := 1800.0               # px/s²
const JUMP_SPEED := 1238.0            # px/s (velocidad inicial fija del salto)
const ANGLE_MIN := 20.0               # grados sobre la horizontal
const ANGLE_MAX := 60.0
const SLIDE_SPEED := 36.0             # deslizamiento lento por la pared
const BLOCK_DEPTH := 40.0             # cuánto asoma un bloque hacia dentro
const PX_PER_M := 40.0
const COURSE_H := 30000.0
const CAM_REF_Y := 480.0              # y de pantalla del punto más alto alcanzado
const FALL_MARGIN := 250.0            # caer más de esto por debajo del punto más alto de la cámara = muerte
const PERIOD_START := 1.6             # s por oscilación completa al empezar...
const PERIOD_END := 1.1              # ... y a 12 000 px de altura
const PERIOD_HEIGHT := 12000.0
const DONE_DELAY := 1.6
const BOT_MIN_PROGRESS := 45.0           # el bot solo salta si el salto sube al menos esto
const BOT_MIN_SLACK := 26.0              # ... y si al aterrizar quedan al menos estos px libres bajo él (≈ 0,5 s de deslizamiento)
const MAX_FLIGHT := 1.3               # s (tope de seguridad)

enum Mode { AIM, AIR, DEAD, DONE }

class Block:
	var side: int                     # -1 pared izquierda, +1 pared derecha
	var y1: float
	var y2: float

var _blocks: Array[Block] = []
var _zones: Array = []                # {side, y, sh}: centro y semialtura de cada zona segura de aterrizaje
var _by_side: Dictionary = {-1: [], 1: []}   # bloques de cada pared, ordenados por altura
var _y1s: Dictionary = {-1: PackedFloat64Array(), 1: PackedFloat64Array()}   # sus y1 (para buscar rápido)
var _course_ready: bool = false

var _mode: Mode = Mode.AIM
var _side: int = -1                   # pared en la que está apoyado (-1 izquierda, +1 derecha)
var _pos: Vector2 = Vector2.ZERO      # centro del ninja (x en pantalla, y = altura hacia arriba)
var _max_h: float = 0.0
var _phase: float = 0.0               # fase de la oscilación
var _angle: float = 45.0              # ángulo actual de la trayectoria (grados)
var _time: float = 0.0
var _done_t: float = 0.0
var _cause: String = ""
# Vuelo
var _jump_from: Vector2 = Vector2.ZERO
var _jump_dir: float = 1.0
var _jump_angle: float = 45.0
var _t_air: float = 0.0
var _jumps: int = 0
# Cámara y visuales
var _cam_h: float = 0.0
var _squash: float = 0.0
var _dust: Array = []
var _popups: Array = []
var _shake: float = 0.0
var _next_milestone: float = 25.0
var _last_extreme: int = 0
var _last_sec: int = 99
var _click_pending: bool = false
var _hint_t: float = 5.0
var _death_pos: Vector2 = Vector2.ZERO
var _cur_shake: Vector2 = Vector2.ZERO
# Autopiloto
var debug_tol: float = 1.5            # tolerancia del ángulo del bot (grados)
var debug_delay: float = 0.0          # retraso humano máximo del bot (s)
var _bot_wait: float = -1.0

# ----------------------------------------------------------------------------
# Física del salto (compartida por el juego, los puntos y el bot)
# ----------------------------------------------------------------------------

## Distancia horizontal que recorre el centro del ninja entre una pared y la otra.
static func travel() -> float:
	return (WALL_R - NINJA_R) - (WALL_L + NINJA_R)

static func wall_x(side: int) -> float:
	return WALL_L + NINJA_R if side < 0 else WALL_R - NINJA_R

## Altura que se gana al saltar con `deg` grados hasta la pared de enfrente.
static func jump_gain(deg: float) -> float:
	var th := deg_to_rad(deg)
	var t := travel() / (JUMP_SPEED * cos(th))
	return JUMP_SPEED * sin(th) * t - 0.5 * GRAVITY * t * t

## Tiempo de vuelo hasta la pared de enfrente.
static func flight_time(deg: float) -> float:
	return travel() / (JUMP_SPEED * cos(deg_to_rad(deg)))

## Posición t segundos después de saltar desde `from` (hacia `dir` = ±1) con `deg` grados.
static func pos_at(from: Vector2, dir: float, deg: float, t: float) -> Vector2:
	var th := deg_to_rad(deg)
	return Vector2(from.x + dir * JUMP_SPEED * cos(th) * t, from.y + JUMP_SPEED * sin(th) * t - 0.5 * GRAVITY * t * t)

## Ángulo (grados) que da la ganancia `gain`, o -1 si no es alcanzable con el rango del juego.
static func angle_for_gain(gain: float) -> float:
	if gain < jump_gain(ANGLE_MIN) or gain > jump_gain(ANGLE_MAX):
		return -1.0
	var lo := ANGLE_MIN
	var hi := ANGLE_MAX
	for i in 40:
		var mid := (lo + hi) * 0.5
		if jump_gain(mid) < gain:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5

## Periodo de la oscilación a esa altura: se acelera al subir.
static func period_at(h: float) -> float:
	return lerpf(PERIOD_START, PERIOD_END, clampf(h / PERIOD_HEIGHT, 0.0, 1.0))

# ----------------------------------------------------------------------------
# El recorrido (bloques con pinchos y zonas de aterrizaje), igual para todos
# ----------------------------------------------------------------------------

func _ensure_course() -> void:
	if _course_ready:
		return
	_course_ready = true
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	var last_block := {-1: -1, 1: -1}      # índice del último bloque de cada pared
	var y_cur := 0.0
	var side := -1                         # empieza en la izquierda
	var step := 0
	while y_cur < COURSE_H:
		var d := clampf(y_cur / 12000.0, 0.0, 1.0)
		var sh := lerpf(80.0, 52.0, d)
		var y_next := y_cur + r.randf_range(90.0, 215.0)
		var target := -side
		if step >= 3:
			# Si el último bloque de esa pared invade este hueco, se recorta.
			var li: int = last_block[target]
			if li >= 0 and _blocks[li].y2 > y_next - sh - 24.0:
				_blocks[li].y2 = maxf(_blocks[li].y1 + 20.0, y_next - sh - 24.0)
			var lo_top := y_next - sh
			var lo_bottom := lo_top - r.randf_range(70.0, 150.0)
			if li >= 0:
				lo_bottom = maxf(lo_bottom, _blocks[li].y2 + 4.0)
			if lo_top - lo_bottom > 24.0:
				_add_block(target, lo_bottom, lo_top)
			var up_b := y_next + sh
			_add_block(target, up_b, up_b + r.randf_range(70.0, 150.0))
			last_block[target] = _blocks.size() - 1
			_zones.append({"side": target, "y": y_next, "sh": sh})
		y_cur = y_next
		side = target
		step += 1
	for b in _blocks:
		_by_side[b.side].append(b)
	for s in [-1, 1]:
		_by_side[s].sort_custom(func(a: Block, b2: Block) -> bool: return a.y1 < b2.y1)
		var ys := PackedFloat64Array()
		for b in _by_side[s]:
			ys.append(b.y1)
		_y1s[s] = ys

func _add_block(side: int, y1: float, y2: float) -> void:
	var b := Block.new()
	b.side = side
	b.y1 = y1
	b.y2 = y2
	_blocks.append(b)

## Primer bloque de esa pared cuyo y1 es >= y (búsqueda binaria).
func _first_block_from(side: int, y: float) -> int:
	var ys: PackedFloat64Array = _y1s[side]
	var lo := 0
	var hi := ys.size()
	while lo < hi:
		@warning_ignore("integer_division")
		var mid := (lo + hi) / 2
		if ys[mid] < y:
			lo = mid + 1
		else:
			hi = mid
	return lo

## ¿Toca el círculo del ninja (centro `p`) algún bloque?
func _hits_block(p: Vector2) -> bool:
	var side := -1 if p.x < (WALL_L + WALL_R) * 0.5 else 1
	var x1 := WALL_L if side < 0 else WALL_R - BLOCK_DEPTH
	var x2 := WALL_L + BLOCK_DEPTH if side < 0 else WALL_R
	var dx := maxf(maxf(x1 - p.x, 0.0), p.x - x2)
	if dx >= NINJA_R:
		return false
	var blocks: Array = _by_side[side]
	# Los bloques miden como mucho ~160 px: se empieza un poco por debajo.
	var i := maxi(_first_block_from(side, p.y - NINJA_R - 200.0) - 1, 0)
	while i < blocks.size():
		var b: Block = blocks[i]
		if b.y1 > p.y + NINJA_R:
			break
		if b.y2 >= p.y - NINJA_R:
			var dy := maxf(maxf(b.y1 - p.y, 0.0), p.y - b.y2)
			if dx * dx + dy * dy < NINJA_R * NINJA_R:
				return true
		i += 1
	return false

## Espacio libre bajo el ninja hasta el bloque de más abajo de su pared (px entre el borde del círculo y el bloque).
func _slack_below(side: int, y: float) -> float:
	var blocks: Array = _by_side[side]
	var best := 1e9
	var i := maxi(_first_block_from(side, y) - 3, 0)
	var end := mini(i + 6, blocks.size())
	while i < end:
		var b: Block = blocks[i]
		if b.y2 <= y:
			best = minf(best, (y - NINJA_R) - b.y2)
		i += 1
	return best

## Simula el salto completo: devuelve {"points": PackedVector2Array, "landed": bool, "end": Vector2, "t": float}.
## `step` = intervalo de muestreo (s). Es la MISMA trayectoria y la MISMA comprobación de choques que usa el juego.
func trajectory(from: Vector2, side: int, deg: float, step: float = 0.03) -> Dictionary:
	var dir := float(-side)
	var t_land := flight_time(deg)
	var pts := PackedVector2Array()
	var phys := 1.0 / 240.0                # mismo paso que el juego: los choques se detectan igual
	var t := 0.0
	var next_point := 0.0
	while t < t_land and t < MAX_FLIGHT:
		var p := pos_at(from, dir, deg, t)
		if t >= next_point:
			pts.append(p)
			next_point += step
		if t > 0.0 and _hits_block(p):
			pts.append(p)
			return {"points": pts, "landed": false, "end": p, "t": t}
		t += phys
	var landing := pos_at(from, dir, deg, t_land)
	pts.append(landing)
	if _hits_block(landing):
		return {"points": pts, "landed": false, "end": landing, "t": t_land}
	return {"points": pts, "landed": true, "end": landing, "t": t_land}

# ----------------------------------------------------------------------------
# Ciclo del minijuego
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	_ensure_course()
	_reset_state()   # el ninja ya en su pared durante la cuenta atrás
	surface.draw_callback = _draw_game

func _on_start() -> void:
	_ensure_course()
	_reset_state()

func _reset_state() -> void:
	_mode = Mode.AIM
	_side = -1
	_pos = Vector2(wall_x(-1), 0.0)
	_max_h = 0.0
	_phase = 0.0
	_time = 0.0
	_done_t = 0.0
	_jumps = 0
	_cam_h = 0.0
	_next_milestone = 25.0
	_hint_t = 5.0
	_bot_wait = -1.0
	_cause = ""
	_update_angle()

func _update_angle() -> void:
	var mid := (ANGLE_MIN + ANGLE_MAX) * 0.5
	var amp := (ANGLE_MAX - ANGLE_MIN) * 0.5
	_angle = mid + amp * sin(_phase)

func _unhandled_input(event: InputEvent) -> void:
	if not is_running or _mode == Mode.DONE:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_click_pending = true

func _play(delta: float) -> void:
	if _mode == Mode.DONE or local_player == null:
		return
	_time += delta
	_hint_t = maxf(0.0, _hint_t - delta)
	if _mode == Mode.DEAD:
		return
	var simulated := InputManager.is_simulated(local_player.id)
	var pressed := false
	if simulated:
		pressed = _bot_wants_jump(delta)
	else:
		pressed = action_presses(local_player) > 0 or _click_pending
	_click_pending = false
	match _mode:
		Mode.AIM:
			_aim_step(delta, pressed)
		Mode.AIR:
			_air_step(delta)
	_max_h = maxf(_max_h, _pos.y)
	if _mode != Mode.DEAD and _pos.y < _cam_h - FALL_MARGIN:
		_die("¡CAÍSTE!")
	if _max_h / PX_PER_M >= _next_milestone:
		_next_milestone += 25.0
		Audio.sfx(&"milestone", -9.0)
	var sec := ceili(TIME_LIMIT - _time)
	if sec != _last_sec and sec <= 3 and sec > 0:
		Audio.sfx(&"beep", -7.0)
	_last_sec = sec
	if _time >= TIME_LIMIT and _mode != Mode.DEAD:
		_finish("¡TIEMPO!")

## Apoyado en la pared: oscila la trayectoria, se desliza despacio y, al pulsar, salta.
func _aim_step(delta: float, pressed: bool) -> void:
	_phase += TAU / period_at(_max_h) * delta
	_update_angle()
	# Un tic suave en cada extremo de la oscilación marca el ritmo.
	var ext := 1 if sin(_phase) > 0.97 else (-1 if sin(_phase) < -0.97 else 0)
	if ext != 0 and ext != _last_extreme:
		Audio.sfx(&"flip_up" if ext > 0 else &"flip_down", -17.0)
	if ext != 0:
		_last_extreme = ext
	_pos.y -= SLIDE_SPEED * delta
	_squash = maxf(0.0, _squash - delta * 5.0)
	if _hits_block(_pos):
		_die("¡PINCHOS!")
		return
	if pressed:
		_start_jump()

func _start_jump() -> void:
	_mode = Mode.AIR
	_jump_from = _pos
	_jump_dir = float(-_side)
	_jump_angle = _angle
	_t_air = 0.0
	_jumps += 1
	_hint_t = 0.0
	Audio.sfx(&"swish", -5.0)

func _air_step(delta: float) -> void:
	var t_land := flight_time(_jump_angle)
	var t_end := _t_air + delta
	# Subpasos cortos para no atravesar un bloque.
	while _t_air < t_end:
		_t_air = minf(_t_air + 1.0 / 240.0, t_end)
		var p := pos_at(_jump_from, _jump_dir, _jump_angle, minf(_t_air, t_land))
		_pos = p
		if _hits_block(p):
			_die("¡PINCHOS!")
			return
		if _t_air >= t_land:
			_land()
			return

func _land() -> void:
	_side = -_side
	_pos = Vector2(wall_x(_side), pos_at(_jump_from, _jump_dir, _jump_angle, flight_time(_jump_angle)).y)
	_mode = Mode.AIM
	_squash = 1.0
	_bot_wait = -1.0
	Audio.sfx(&"wall", -4.0)
	_shake = 0.25
	var gain := _pos.y - _jump_from.y
	if gain > 0.0:
		_popups.append({"pos": Vector2(_pos.x, 0.0), "world_y": _pos.y, "text": "+%.1f" % (gain / PX_PER_M), "age": 0.0})
	for i in 6:
		_dust.append({"pos": _pos, "vel": Vector2(randf_range(-60.0, 60.0) + float(-_side) * 40.0, randf_range(-30.0, 60.0)), "life": randf_range(0.2, 0.5)})

func _die(cause: String) -> void:
	if _mode == Mode.DEAD or _mode == Mode.DONE:
		return
	_mode = Mode.DEAD
	_cause = cause
	_done_t = 0.0
	_death_pos = _pos
	_shake = 1.0
	Audio.sfx(&"crash", -4.0)
	for i in 14:
		_dust.append({"pos": _pos, "vel": Vector2.from_angle(randf() * TAU) * randf_range(80.0, 320.0), "life": randf_range(0.3, 0.8)})
	DevCli.log_event("ninja dead height=%.1f m jumps=%d (%s)" % [_max_h / PX_PER_M, _jumps, cause])

func _finish(cause: String) -> void:
	_mode = Mode.DONE
	_cause = cause
	_done_t = 0.0
	DevCli.log_event("ninja done height=%.1f m jumps=%d" % [_max_h / PX_PER_M, _jumps])

func _animate(delta: float) -> void:
	_shake = maxf(0.0, _shake - delta * 2.5)
	# Cámara: sube con la altura máxima y NUNCA baja.
	_cam_h = maxf(_cam_h, lerpf(_cam_h, _max_h, 1.0 - exp(-6.0 * delta)))
	for p in _popups:
		p.age += delta
	_popups = _popups.filter(func(x: Dictionary) -> bool: return x.age < 1.0)
	for d in _dust:
		d.pos += d.vel * delta
		d.vel.y -= 200.0 * delta
		d.life -= delta
	_dust = _dust.filter(func(x: Dictionary) -> bool: return x.life > 0.0)
	if _mode == Mode.DEAD or _mode == Mode.DONE:
		_done_t += delta
		if _done_t >= DONE_DELAY and not _reported:
			report_result(snappedf(_max_h / PX_PER_M, 0.1), 0.0)   # más altura = mejor

# ----------------------------------------------------------------------------
# Autopiloto: apunta a la zona de aterrizaje y pulsa cuando la oscilación pasa por el ángulo justo
# ----------------------------------------------------------------------------

## ¿Es seguro saltar con `deg` grados? El salto aterriza sin chocar, sube lo suficiente y deja margen para deslizarse.
func _jump_is_good(deg: float) -> bool:
	var tr := trajectory(_pos, _side, deg, 0.05)
	if not bool(tr["landed"]):
		return false
	var end: Vector2 = tr["end"]
	if end.y < _pos.y + BOT_MIN_PROGRESS:
		return false
	return _slack_below(-_side, end.y) >= BOT_MIN_SLACK

## El bot salta en cuanto el ángulo actual (y los de alrededor, según su tolerancia) llevan a un aterrizaje seguro con
## progreso: así no espera un ángulo "perfecto" y se desliza menos. Un humano hace lo mismo: pulsa cuando los puntos
## caen en un buen sitio.
func _bot_wants_jump(delta: float) -> bool:
	if _mode != Mode.AIM:
		return false
	if _bot_wait >= 0.0:
		_bot_wait -= delta
		return _bot_wait < 0.0
	if _jump_is_good(_angle) and _jump_is_good(_angle - debug_tol) and _jump_is_good(_angle + debug_tol):
		_bot_wait = randf_range(0.0, debug_delay)
		if _bot_wait <= 0.0:
			_bot_wait = -1.0
			return true
	return false

func _bot_action_held(_player: PlayerData) -> bool:
	return false

# --- Resultado simulado de un bot / desconectado (lo calcula el host) ---
func _bot_result(_player: PlayerData, r: RandomNumberGenerator) -> Dictionary:
	return {"score": roundf(r.randf_range(25.0, 150.0)), "tiebreak": 0.0}

# --- Plausibilidad: ni más alto que el recorrido ni más deprisa que saltos de 0,38 s con la máxima ganancia ---
func _validate_result(score: float, _tiebreak: float) -> bool:
	var cap := minf(COURSE_H, TIME_LIMIT / flight_time(ANGLE_MIN) * jump_gain(ANGLE_MAX))
	return score >= 0.0 and score <= cap / PX_PER_M + 5.0

# ----------------------------------------------------------------------------
# Utilidades de depuración / pruebas (tests/ninja_test.gd)
# ----------------------------------------------------------------------------

func debug_course() -> Dictionary:
	_ensure_course()
	return {"blocks": _blocks, "zones": _zones}

func debug_signature() -> String:
	_ensure_course()
	var parts: PackedStringArray = []
	for b in _blocks:
		parts.append("%d:%.1f:%.1f" % [b.side, b.y1, b.y2])
	return "|".join(parts)

func debug_state() -> Dictionary:
	return {"mode": int(_mode), "side": _side, "pos": _pos, "max_h": _max_h, "angle": _angle, "jumps": _jumps, "time": _time, "cause": _cause}

func debug_reset() -> void:
	_ensure_course()
	_reset_state()

## Juega `seconds` de partida con el bot (sin dibujar). Devuelve altura (m), saltos y cómo acabó.
func debug_run(seconds: float = TIME_LIMIT, tol: float = 1.5, delay: float = 0.0) -> Dictionary:
	_ensure_course()
	_reset_state()
	debug_tol = tol
	debug_delay = delay
	var dt := 1.0 / 240.0
	var t := 0.0
	while t < seconds and _mode != Mode.DEAD:
		_time += dt
		match _mode:
			Mode.AIM:
				_aim_step(dt, _bot_wants_jump(dt))
			Mode.AIR:
				_air_step(dt)
		_max_h = maxf(_max_h, _pos.y)
		if _mode != Mode.DEAD:
			_cam_h = maxf(_cam_h, lerpf(_cam_h, _max_h, 1.0 - exp(-6.0 * dt)))
			if _pos.y < _cam_h - FALL_MARGIN:
				_die("¡CAÍSTE!")
		t += dt
	return {"height_m": _max_h / PX_PER_M, "jumps": _jumps, "dead": _mode == Mode.DEAD, "cause": _cause, "time": t}

func debug_jump() -> void:
	if _mode == Mode.AIM:
		_start_jump()

func debug_advance(delta: float) -> void:
	match _mode:
		Mode.AIM:
			_aim_step(delta, false)
		Mode.AIR:
			_air_step(delta)

func debug_set_phase(p: float) -> void:
	_phase = p
	_update_angle()

# ----------------------------------------------------------------------------
# Dibujo
# ----------------------------------------------------------------------------

func _sy(h: float) -> float:
	return CAM_REF_Y - (h - _cam_h)

func _draw_game() -> void:
	var s := surface
	_cur_shake = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * _shake * 6.0
	s.draw_set_transform(_cur_shake, 0.0, Vector2.ONE)
	_draw_background()
	_draw_walls()
	_draw_blocks()
	if _mode == Mode.AIM:
		_draw_aim()
	for d in _dust:
		var a := clampf(float(d.life) / 0.5, 0.0, 1.0)
		s.draw_circle(Vector2(d.pos.x, _sy(d.pos.y)), 3.0 + 3.0 * (1.0 - a), Color(0.85, 0.85, 0.95, a * 0.7))
	if _mode != Mode.DEAD:
		_draw_ninja()
	for p in _popups:
		var k: float = p.age
		s.text_centered(Vector2(float(p.pos.x), _sy(float(p.world_y)) - 30.0 - 50.0 * k), String(p.text) + " m", 26, Color(1, 1, 1, 1.0 - k * k), 5)
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_hud()

func _draw_background() -> void:
	var s := surface
	var v := view_rect().grow(8.0)   # (con margen para el temblor)
	s.draw_polygon(PackedVector2Array([v.position, Vector2(v.end.x, v.position.y), v.end, Vector2(v.position.x, v.end.y)]),
			PackedColorArray([Color(0.05, 0.04, 0.16), Color(0.05, 0.04, 0.16), Color(0.22, 0.12, 0.34), Color(0.22, 0.12, 0.34)]))
	# Luna grande y bambú en siluetas (paralaje con la altura).
	s.draw_circle(Vector2(1010, 170), 70.0, Color(1.0, 0.95, 0.78, 0.12))
	s.draw_circle(Vector2(1010, 170), 52.0, Color(1.0, 0.96, 0.8))
	for i in range(floori((v.position.x - 40.0) / 118.0), ceili((v.end.x - 40.0) / 118.0) + 1):
		var x := 40.0 + i * 118.0 + sin(i * 2.3) * 30.0
		s.draw_line(Vector2(x, v.position.y), Vector2(x, v.end.y), Color(0.1, 0.16, 0.2, 0.55), 10.0)
		var k := v.position.y - fposmod(_cam_h * 0.35 + v.position.y, 120.0)
		while k < v.end.y + 20.0:
			s.draw_line(Vector2(x - 6, k), Vector2(x + 6, k), Color(0.18, 0.26, 0.3, 0.7), 3.0)
			k += 120.0

func _draw_walls() -> void:
	var s := surface
	var brick := Color(0.13, 0.12, 0.2)
	var v := view_rect().grow(8.0)
	s.draw_rect(Rect2(v.position.x, v.position.y, WALL_L - v.position.x, v.size.y), brick)
	s.draw_rect(Rect2(WALL_R, v.position.y, v.end.x - WALL_R, v.size.y), brick)
	# Ladrillos que suben con la cámara.
	var off := fposmod(_cam_h, 60.0)
	var y := off - 60.0
	var row := 0
	while y > v.position.y:
		y -= 120.0   # (mismo patrón de filas alternas)
	while y < v.end.y + 20.0:
		var shift := 0.0 if row % 2 == 0 else 40.0
		for wall in 2:
			var x0 := v.position.x if wall == 0 else WALL_R
			var x1 := WALL_L if wall == 0 else v.end.x
			s.draw_line(Vector2(x0, y), Vector2(x1, y), Color(0.05, 0.04, 0.1, 0.8), 3.0)
			# (las juntas siguen la rejilla de 80 px que empieza en x = 0 / WALL_R)
			var bx := (0.0 if wall == 0 else WALL_R) - shift
			bx -= ceilf((bx - x0) / 80.0) * 80.0
			while bx < x1:
				if bx > x0:
					s.draw_line(Vector2(bx, y), Vector2(bx, y + 60.0), Color(0.05, 0.04, 0.1, 0.8), 3.0)
				bx += 80.0
		y += 60.0
		row += 1
	# Cara interior iluminada.
	s.draw_line(Vector2(WALL_L, v.position.y), Vector2(WALL_L, v.end.y), Color(0.7, 0.75, 1.0, 0.85), 5.0)
	s.draw_line(Vector2(WALL_R, v.position.y), Vector2(WALL_R, v.end.y), Color(0.7, 0.75, 1.0, 0.85), 5.0)

func _draw_blocks() -> void:
	var s := surface
	var lo := _cam_h - 300.0
	var hi := _cam_h + 700.0
	for b in _blocks:
		if b.y2 < lo or b.y1 > hi:
			continue
		var y_top := _sy(b.y2)
		var h := b.y2 - b.y1
		var x := WALL_L if b.side < 0 else WALL_R - BLOCK_DEPTH
		s.draw_rect(Rect2(x, y_top, BLOCK_DEPTH, h), Color(0.3, 0.3, 0.42))
		s.draw_rect(Rect2(x, y_top, BLOCK_DEPTH, h), Color(0.75, 0.78, 0.95), false, 3.0)
		# Pinchos hacia el pasillo.
		var n := maxi(1, int(h / 22.0))
		var step := h / float(n)
		for i in n:
			var yy := y_top + i * step
			var tip_x := x + BLOCK_DEPTH + 16.0 if b.side < 0 else x - 16.0
			var base_x := x + BLOCK_DEPTH if b.side < 0 else x
			var tri := PackedVector2Array([Vector2(base_x, yy + 2.0), Vector2(tip_x, yy + step * 0.5), Vector2(base_x, yy + step - 2.0)])
			s.draw_colored_polygon(tri, Color(0.92, 0.25, 0.3))
			s.draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2]]), Color(1, 0.7, 0.72), 2.0, true)

## La trayectoria de puntos: exactamente el salto que hará el ninja ahora mismo.
func _draw_aim() -> void:
	var s := surface
	var tr := trajectory(_pos, _side, _angle, 0.035)
	var pts: PackedVector2Array = tr["points"]
	var n := pts.size()
	for i in n:
		var p := pts[i]
		var a := 0.95 - 0.45 * float(i) / float(maxi(n - 1, 1))
		var r := 4.2 - 1.2 * float(i) / float(maxi(n - 1, 1))
		s.draw_circle(Vector2(p.x, _sy(p.y)), r + 1.6, Color(0, 0, 0, a * 0.5))
		s.draw_circle(Vector2(p.x, _sy(p.y)), r, Color(1, 1, 1, a))
	var e: Vector2 = tr["end"]
	var ep := Vector2(e.x, _sy(e.y))
	if bool(tr["landed"]):
		s.draw_arc(ep, 16.0, 0.0, TAU, 20, Color(0.4, 1.0, 0.7, 0.9), 3.5, true)
	else:
		s.draw_line(ep + Vector2(-10, -10), ep + Vector2(10, 10), Color(1.0, 0.3, 0.35), 5.0)
		s.draw_line(ep + Vector2(-10, 10), ep + Vector2(10, -10), Color(1.0, 0.3, 0.35), 5.0)

func _draw_ninja() -> void:
	var s := surface
	var c := Vector2(_pos.x, _sy(_pos.y))
	var col: Color = local_player.color if local_player != null else Palette.YELLOW
	var face := float(-_side) if _mode == Mode.AIM else _jump_dir
	var sq := 1.0 + 0.3 * _squash
	var tilt := 0.0
	if _mode == Mode.AIR:
		tilt = clampf(-(JUMP_SPEED * sin(deg_to_rad(_jump_angle)) - GRAVITY * _t_air) / 1500.0, -0.9, 0.9) * face
		# Estela del salto.
		for k in 5:
			var tp := pos_at(_jump_from, _jump_dir, _jump_angle, maxf(_t_air - 0.02 * (k + 1), 0.0))
			s.draw_circle(Vector2(tp.x, _sy(tp.y)), 10.0 - k * 1.6, Color(col.r, col.g, col.b, 0.35 - 0.06 * k))
	s.draw_set_transform(c + _cur_shake, tilt, Vector2(1.0 / sq if _mode == Mode.AIM else 1.0, sq if _mode == Mode.AIM else 1.0))
	# Bufanda al viento.
	var wind := sin(_time * 14.0) * 3.0
	s.draw_polyline(PackedVector2Array([Vector2(-face * 8.0, -4.0), Vector2(-face * 22.0, -8.0 + wind), Vector2(-face * 34.0, -2.0 - wind)]), col, 5.0, true)
	s.draw_circle(Vector2.ZERO, NINJA_R + 2.5, Color(0.02, 0.02, 0.05))
	s.draw_circle(Vector2.ZERO, NINJA_R, Color(0.1, 0.1, 0.16))
	s.draw_rect(Rect2(-NINJA_R, -6.0, NINJA_R * 2.0, 6.0), col)                      # cinta de la cabeza
	s.draw_rect(Rect2(-NINJA_R * 0.7, -1.0, NINJA_R * 1.4, 5.0), Color(0.93, 0.85, 0.75))   # rendija de la cara
	s.draw_circle(Vector2(face * 3.5 - 3.0, 1.5), 2.0, Color(0.05, 0.05, 0.1))
	s.draw_circle(Vector2(face * 3.5 + 3.0, 1.5), 2.0, Color(0.05, 0.05, 0.1))
	s.draw_set_transform(_cur_shake, 0.0, Vector2.ONE)

func _draw_hud() -> void:
	var s := surface
	var h := _max_h / PX_PER_M
	s.text_centered(Vector2(640, 52), "%.0f m" % h, 66, Palette.WHITE, 10)
	var bar := Rect2(440, 92, 400, 14)
	s.rounded_rect(bar.grow(4), 12, Color(0, 0, 0, 0.45))
	var frac := clampf(1.0 - _time / TIME_LIMIT, 0.0, 1.0)
	if frac > 0.0:
		s.rounded_rect(Rect2(bar.position, Vector2(maxf(bar.size.x * frac, 14.0), bar.size.y)), 8, Palette.YELLOW if frac > 0.12 else Palette.CORAL)
	s.text_centered(Vector2(1130, 52), "%d s" % maxi(0, ceili(TIME_LIMIT - _time)), 38, Palette.WHITE, 8)
	s.text_centered(Vector2(150, 52), "SALTOS %d" % _jumps, 28, Color(1, 1, 1, 0.85), 6)
	if _hint_t > 0.0 and _mode == Mode.AIM:
		s.text_centered(Vector2(640, 150), "¡Pulsa cuando los puntos apunten donde quieres saltar!", 28, Color(1, 1, 1, clampf(_hint_t, 0.0, 1.0)), 7)
	if _mode == Mode.DEAD or _mode == Mode.DONE:
		s.text_centered(Vector2(640, 300), _cause, 84, Palette.YELLOW, 14)
		if _done_t > 0.4:
			s.text_centered(Vector2(640, 380), "%.0f m" % h, 60, Palette.WHITE, 10)
			s.text_centered(Vector2(640, 440), "Más alto = mejor posición", 28, Color(1, 1, 1, 0.8), 6)
