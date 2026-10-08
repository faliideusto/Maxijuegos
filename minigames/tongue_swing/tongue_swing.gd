extends Minigame
## Columpio de Lengua (modelo LOCAL_PARALLEL): una rana se columpia con la lengua de gancho en gancho
## sobre un pantano tóxico mientras una niebla venenosa la persigue. Un solo intento: gana quien
## llega más lejos. Nadie ve a los demás; no hay nada de red aquí (report_result(distancia)).
##
## CONTROL (un solo botón):
##   MANTENER → la lengua se agarra al SIGUIENTE gancho (resaltado) si está por delante, por encima y a tu alcance.
##              Colgada, la rana se balancea como un péndulo y la lengua se va acortando (coge impulso).
##   SOLTAR   → suelta el gancho y vuela con la inercia que llevaba; vuelve a mantener para agarrar el
##              siguiente. Si pulsas sin gancho a tu alcance, la lengua queda "armada" ARM_TIME s.
##
## DIFICULTAD (todo sube con la distancia): los ganchos se separan más, varían más de altura, aparecen
## ganchos FRÁGILES que se rompen a BREAK_T s de agarrarlos, la ventana para soltar a tiempo se estrecha
## y la niebla acelera.
##
## EL RECORRIDO ES UNO SOLO (ver tongue_level.gd), idéntico en todas las partidas y PC. Lo genera
## tools/gen_tongue_level.gd con un bot-planificador que usa ESTA misma física: cada gancho solo se
## coloca si hay una ventana de tiempo suficiente para soltar (con margen decreciente) y la niebla no
## alcanza al bot. tests/tongue_level_test.gd lo comprueba y señala el gancho donde falle.
##
## Estética propia (pantano al atardecer): cielo naranja→violeta, selva en siluetas, luciérnagas, ganchos
## colgando de lianas, pantano verde brillante abajo y una niebla morada con ojos que persigue.

const LEVEL := preload("res://minigames/tongue_swing/tongue_level.gd")

# --- Mundo (unidades: bloques; y hacia arriba, 0 = borde inferior de la pantalla) ---
const BLOCK := 48.0
const STEP := 1.0 / 60.0           # paso fijo de física (también lo usa el planificador)
const GRAVITY := 24.0
const R_REACH := 8.0               # alcance de la lengua
const ROPE_MIN := 2.4              # la lengua no se acorta más que esto
const REEL := 1.8                  # bloques/s que se acorta la lengua colgada
const LAVA_Y := 1.4                # por debajo de esta y: pantano → muerte
const ARM_TIME := 0.35             # s que la lengua queda armada tras pulsar sin gancho a mano
const BREAK_T := 1.15              # s que aguanta un gancho frágil
const SPEED_CAP := 26.0
const CAM_LEAD := 8.0              # bloques de la rana al borde izquierdo de la pantalla
const TIME_LIMIT := 90.0
const DEATH_ANIM := 1.3
const LEVEL_END := 900.0
const START_ANCHOR := Vector2(0.0, 12.0)
const START_ROPE := 5.0
# Niebla: x(t) = CHASE_X0 + C0·t + ½·C1·t² hasta CHASE_MAX_SPEED, y luego lineal.
const CHASE_X0 := -13.0
const CHASE_C0 := 1.8
const CHASE_C1 := 0.08
const CHASE_MAX_SPEED := 5.4

class FState:
	var pos: Vector2 = Vector2.ZERO
	var vel: Vector2 = Vector2.ZERO
	var anchor: int = -1           # gancho al que está agarrada (-1 = en vuelo)
	var last: int = -1             # último gancho agarrado (no se puede volver atrás)
	var rope: float = 0.0
	var t_att: float = 0.0         # s desde que se agarró
	var armed: float = 0.0         # s que le quedan a la lengua armada
	var prev_hold: bool = false
	var alive: bool = true
	var broke: int = -1            # gancho que se rompió en este paso (-1 = ninguno)

	func copy() -> FState:
		var c := FState.new()
		c.pos = pos
		c.vel = vel
		c.anchor = anchor
		c.last = last
		c.rope = rope
		c.t_att = t_att
		c.armed = armed
		c.prev_hold = prev_hold
		c.alive = alive
		c.broke = broke
		return c

# --- Recorrido: x, y y tipo (0 normal, 1 frágil) de cada gancho, ordenados por x ---
var _ax: PackedFloat64Array = PackedFloat64Array()
var _ay: PackedFloat64Array = PackedFloat64Array()
var _af: PackedByteArray = PackedByteArray()
var _broken: Dictionary = {}

# --- Estado de la partida local ---
var _s := FState.new()
var _prev_pos: Vector2 = Vector2.ZERO
var _time: float = 0.0
var _accum: float = 0.0
var _touched: bool = false         # ¿ya tomó el control el jugador? (al principio cuelga solo)
var _dead: bool = false
var _timed_out: bool = false
var _death_cause: String = ""
var _death_t: float = 0.0
var _best_x: float = 0.0
var _shards: Array = []
var _flash: float = 0.0
var _cam: float = 0.0
var _rot: float = 0.0
var _tongue_ext: float = 1.0
var _whiff: float = 0.0
var _prev_anchor: int = -1
var _next_milestone: float = 100.0
var _crack_played: bool = false
var _growl_t: float = 0.0

# --- Bot / pruebas ---
var _bot_plan_for: int = -2
var _bot_release_t: float = 0.0
## Retraso (s) con el que el bot suelta respecto a lo planificado (pruebas de margen humano).
var debug_release_delay: float = 0.0
## Amplitud (s) de un error de suelta ALEATORIO distinto en cada gancho (semilla fija).
var debug_delay_random: float = 0.0
var _dbg_rng := RandomNumberGenerator.new()
var debug_seed: int = 77
var debug_never_release: bool = false
var debug_release_now: bool = false

func _on_prepare() -> void:
	_load_level()
	surface.draw_callback = _draw_game

func _on_start() -> void:
	if local_player != null and InputManager.is_simulated(local_player.id):
		# El autopiloto no es perfecto: suelta con un error aleatorio, como un jugador de carne y hueso.
		debug_delay_random = 0.07
		_dbg_rng.seed = seed_value * 31 + local_player.id
	_reset_state()
	_time = 0.0
	_accum = 0.0
	_dead = false
	_timed_out = false

func _load_level() -> void:
	var d: Array = LEVEL.DATA
	_ax = PackedFloat64Array()
	_ay = PackedFloat64Array()
	_af = PackedByteArray()
	for i in range(0, d.size() - 2, 3):
		_ax.append(float(d[i]))
		_ay.append(float(d[i + 1]))
		_af.append(int(d[i + 2]))

func _reset_state() -> void:
	_s = _start_state()
	_prev_pos = _s.pos
	_broken = {}
	_touched = false
	_best_x = 0.0
	_bot_plan_for = -2
	_prev_anchor = _s.anchor
	_next_milestone = 100.0
	_crack_played = false
	_cam = _s.pos.x - CAM_LEAD
	_tongue_ext = 1.0
	_whiff = 0.0

## Empieza colgada del gancho 0, balanceándose desde atrás.
func _start_state() -> FState:
	var s := FState.new()
	var ang := deg_to_rad(50.0)
	s.pos = START_ANCHOR + Vector2(-sin(ang), -cos(ang)) * START_ROPE
	s.anchor = 0
	s.last = 0
	s.rope = START_ROPE
	s.prev_hold = true
	return s

func chase_at(t: float) -> float:
	var t_cap := (CHASE_MAX_SPEED - CHASE_C0) / CHASE_C1
	if t <= t_cap:
		return CHASE_X0 + CHASE_C0 * t + 0.5 * CHASE_C1 * t * t
	return CHASE_X0 + CHASE_C0 * t_cap + 0.5 * CHASE_C1 * t_cap * t_cap + CHASE_MAX_SPEED * (t - t_cap)

# ----------------------------------------------------------------------------
# Física (compartida por el juego, el bot y el generador del recorrido)
# ----------------------------------------------------------------------------

## Primer gancho con x >= la dada.
func _lower(x: float) -> int:
	var lo := 0
	var hi := _ax.size()
	while lo < hi:
		@warning_ignore("integer_division")
		var mid := (lo + hi) / 2
		if _ax[mid] < x:
			lo = mid + 1
		else:
			hi = mid
	return lo

## Gancho al que se agarraría la lengua ahora: SIEMPRE el siguiente de la cadena (el que sigue al último
## agarrado), si todavía está por delante, por encima y a tiro. -1 si no. Así el objetivo está claro
## (se resalta en pantalla) y colocar ganchos más allá nunca cambia el vuelo hasta el anterior.
func _pick(s: FState) -> int:
	var i := s.last + 1
	if i >= _ax.size() or _ax[i] < s.pos.x + 0.2 or _ay[i] <= s.pos.y + 0.6:
		return -1
	return i if s.pos.distance_to(Vector2(_ax[i], _ay[i])) <= R_REACH else -1

func _anchor_pos(i: int) -> Vector2:
	return Vector2(_ax[i], _ay[i])

## Un paso de física con el botón `hold` (true = mantenido).
func _phys(s: FState, dt: float, hold: bool) -> void:
	s.broke = -1
	if hold:
		if not s.prev_hold:
			s.armed = ARM_TIME
		if s.anchor < 0 and s.armed > 0.0:
			var i := _pick(s)
			if i >= 0:
				s.anchor = i
				s.last = i
				s.rope = maxf(s.pos.distance_to(_anchor_pos(i)), ROPE_MIN)
				s.t_att = 0.0
				s.armed = 0.0
			else:
				s.armed -= dt
	else:
		s.anchor = -1
		s.armed = 0.0
	s.prev_hold = hold
	if s.anchor >= 0:
		s.t_att += dt
		if _af[s.anchor] == 1 and s.t_att >= BREAK_T:
			s.broke = s.anchor
			s.anchor = -1
			s.armed = 0.0
	var a := Vector2.ZERO
	if s.anchor >= 0:
		a = _anchor_pos(s.anchor)
		var new_rope := maxf(ROPE_MIN, s.rope - REEL * dt)
		if new_rope < s.rope:
			# Al acortar la lengua se conserva el momento angular: la rana gira más deprisa.
			var d := s.pos - a
			var dl := d.length()
			if dl > 0.001:
				var n := d / dl
				var vr := s.vel.dot(n)
				s.vel = n * vr + (s.vel - n * vr) * (s.rope / new_rope)
			s.rope = new_rope
	s.vel.y -= GRAVITY * dt
	if s.vel.length() > SPEED_CAP:
		s.vel = s.vel.normalized() * SPEED_CAP
	s.pos += s.vel * dt
	if s.anchor >= 0:
		var d2 := s.pos - a
		var dist := d2.length()
		if dist > s.rope and dist > 0.0001:
			var n2 := d2 / dist
			s.pos = a + n2 * s.rope
			var vr2 := s.vel.dot(n2)
			if vr2 > 0.0:
				s.vel -= n2 * vr2
	if s.pos.y < LAVA_Y:
		s.alive = false

# ----------------------------------------------------------------------------
# Planificador (bot de referencia): cuándo soltar para llegar al gancho `target`
# ----------------------------------------------------------------------------

## Desde `s_in` (ya soltada) vuela hasta poder agarrar `target`. Devuelve {"steps","state"} (state =
## ya agarrada) o {} si no llega (cae al pantano, se pasa de largo o tarda demasiado).
func _flight(s_in: FState, target: int) -> Dictionary:
	var s := s_in.copy()
	for step in 100:
		_phys(s, STEP, false)
		if not s.alive:
			return {}
		if s.pos.x > _ax[target] + 0.5:
			return {}
		var p := _pick(s)
		if p >= 0:
			# En cuanto hay un gancho a tiro el bot pulsa: tiene que ser EXACTAMENTE el objetivo.
			if p != target:
				return {}
			var t := s.copy()
			_phys(t, STEP, true)
			if t.anchor == target and t.alive:
				return {"steps": step + 2, "state": t}
			return {}
	return {}

## Planifica el balanceo desde `s0` (colgada) hasta el gancho `target`. `win_t` = semiventana (s) de
## tiempo de suelta que debe quedar libre a cada lado. Devuelve {"k": paso de suelta, "run": nº de
## pasos consecutivos válidos} o {} si no es posible.
func _plan(s0: FState, target: int, win_t: float) -> Dictionary:
	var swing_limit := 2.4
	if s0.anchor >= 0 and _af[s0.anchor] == 1:
		swing_limit = BREAK_T - 0.1 - s0.t_att
	var k_max := int(swing_limit / STEP)
	var ok := PackedByteArray()
	var s := s0.copy()
	for k in range(k_max + 1):
		var good := 0
		if not s.alive or s.anchor < 0:
			ok.append(0)
			break
		if not _flight(s, target).is_empty():
			good = 1
		ok.append(good)
		_phys(s, STEP, true)
	var w := int(ceil(win_t / STEP))
	var best_len := 0
	var best_k := -1
	var i := 0
	while i < ok.size():
		if ok[i] == 1:
			var j := i
			while j < ok.size() and ok[j] == 1:
				j += 1
			var length := j - i
			if length > best_len:
				best_len = length
				best_k = i + length / 2
			i = j
		else:
			i += 1
	if best_k < 0 or best_len < 2 * w + 1:
		return {}
	return {"k": best_k, "run": best_len}

## Reproduce un plan: balanceo k pasos, suelta, vuelo y agarre. Devuelve {"state","steps","min_lead"}
## (min_lead = distancia mínima a la niebla durante todo el trayecto, con t0 = s al empezar).
func _run_plan(s_in: FState, k: int, target: int, t0: float) -> Dictionary:
	var s := s_in.copy()
	var steps := 0
	var min_lead := INF
	for i in k:
		_phys(s, STEP, true)
		steps += 1
		min_lead = minf(min_lead, s.pos.x - chase_at(t0 + steps * STEP))
	var fl := _flight(s, target)
	if fl.is_empty():
		return {}
	# Repite el vuelo paso a paso para medir la distancia a la niebla.
	var f := s.copy()
	for st in int(fl["steps"]) - 1:
		_phys(f, STEP, false)
		steps += 1
		min_lead = minf(min_lead, f.pos.x - chase_at(t0 + steps * STEP))
	var fin: FState = fl["state"]
	steps += 1
	min_lead = minf(min_lead, fin.pos.x - chase_at(t0 + steps * STEP))
	return {"state": fin, "steps": steps, "min_lead": min_lead}

# ----------------------------------------------------------------------------
# Jugador local (LOCAL_PARALLEL)
# ----------------------------------------------------------------------------

func _play(delta: float) -> void:
	if _dead or local_player == null:
		return
	_time += delta
	var held := action_held(local_player)
	var tap := false
	if not InputManager.is_simulated(local_player.id):
		tap = action_presses(local_player) > 0
	if not _touched:
		# Al empezar cuelga sola del primer gancho hasta que el jugador pulse y suelte.
		if held or tap:
			_touched = true
		held = true
	_accum += delta
	var steps := 0
	while _accum >= STEP and steps < 8:
		_accum -= STEP
		steps += 1
		_prev_pos = _s.pos
		var h := held or (tap and steps == 1)
		_phys(_s, STEP, h)
		if _s.broke >= 0:
			_broken[_s.broke] = true
		_best_x = maxf(_best_x, _s.pos.x)
		if _s.anchor != _prev_anchor:
			if _s.anchor >= 0:
				_tongue_ext = 0.0
				_crack_played = false
				Audio.sfx(&"tongue_shoot", -9.0)
				Audio.sfx(&"tongue_attach", -4.0)
			elif _s.broke >= 0:
				Audio.sfx(&"snap", -3.0)
			else:
				Audio.sfx(&"release", -7.0)
			_prev_anchor = _s.anchor
		if _s.anchor >= 0 and _af[_s.anchor] == 1 and _s.t_att > 0.6 and not _crack_played:
			_crack_played = true
			Audio.sfx(&"plat_crack", -6.0)
		if not _s.alive:
			_die("¡AL PANTANO!")
			return
		if _s.pos.x < chase_at(_time):
			_die("¡TE ALCANZÓ LA NIEBLA!")
			return
	if tap and _s.anchor < 0 and _pick(_s) < 0:
		_whiff = 0.3
		Audio.sfx(&"tongue_shoot", -14.0, 0.8)
	if _best_x >= _next_milestone:
		_next_milestone += 100.0
		Audio.sfx(&"milestone", -9.0)
	# El autopiloto (pruebas) se "cansa" pronto para que las partidas automáticas no se eternicen.
	var limit := 28.0 if InputManager.is_simulated(local_player.id) else TIME_LIMIT
	if _time >= limit or _best_x >= LEVEL_END:
		_timed_out = true
		_dead = true
		_death_t = 0.0

func _die(cause: String) -> void:
	Audio.sfx(&"splash" if cause.contains("PANTANO") else &"fog_growl", -2.0)
	_dead = true
	_death_cause = cause
	_death_t = 0.0
	_flash = 1.0
	for i in 16:
		var a := randf() * TAU
		_shards.append({"pos": _s.pos, "vel": Vector2.from_angle(a) * randf_range(2.0, 8.0) + Vector2(0, 4.0),
				"size": randf_range(0.1, 0.25), "rot": randf() * TAU, "life": 1.0})

func _animate(delta: float) -> void:
	# La niebla gruñe cuando está cerca.
	if is_running and not _dead and _s.pos.x - chase_at(_time) < 6.0:
		_growl_t -= delta
		if _growl_t <= 0.0:
			_growl_t = 3.0
			Audio.sfx(&"fog_growl", -14.0)
	_flash = maxf(0.0, _flash - delta * 2.5)
	_tongue_ext = minf(1.0, _tongue_ext + delta * 14.0)
	_whiff = maxf(0.0, _whiff - delta)
	var target_cam := _s.pos.x - CAM_LEAD
	_cam = lerpf(_cam, target_cam, 1.0 - exp(-9.0 * delta))
	var tr := clampf(-_s.vel.y * 0.05, -0.8, 0.8) if _s.vel.x > 0.5 else 0.0
	_rot = lerpf(_rot, tr, 1.0 - exp(-10.0 * delta))
	if _dead:
		_death_t += delta
		if _death_t >= DEATH_ANIM and not _reported:
			report_result(maxf(_best_x, 0.0))   # distancia: más lejos = mejor
	for sh in _shards:
		sh.vel.y -= 22.0 * delta
		sh.pos += sh.vel * delta
		sh.rot += 6.0 * delta
		sh.life -= delta * 0.8
	_shards = _shards.filter(func(x: Dictionary) -> bool: return x.life > 0.0)

# ----------------------------------------------------------------------------
# IA del autopiloto: planifica cada balanceo con la misma física
# ----------------------------------------------------------------------------

func _bot_wants_hold(s: FState) -> bool:
	if s.anchor >= 0:
		if debug_never_release:
			return true
		if debug_release_now:
			return false
		if _bot_plan_for != s.anchor:
			_bot_plan_for = s.anchor
			var p := _plan(s, s.anchor + 1, 0.0)
			if p.is_empty():
				_bot_release_t = 99.0
			else:
				var err := debug_release_delay
				if debug_delay_random > 0.0:
					err += _dbg_rng.randf_range(-debug_delay_random, debug_delay_random)
				_bot_release_t = s.t_att + float(p["k"]) * STEP + err
		return s.t_att < _bot_release_t - STEP * 0.5
	return _pick(s) >= 0 or s.armed > 0.0

func _bot_action_held(_player: PlayerData) -> bool:
	_touched = true
	return _bot_wants_hold(_s)

# --- Resultado simulado de un bot / desconectado (lo calcula el host) ---
func _bot_result(_player: PlayerData, r: RandomNumberGenerator) -> Dictionary:
	return {"score": r.randf_range(80.0, 420.0), "tiebreak": 0.0}

# --- Plausibilidad: ningún jugador llega más lejos que el final del recorrido ---
func _validate_result(score: float, _tiebreak: float) -> bool:
	return score >= 0.0 and score <= LEVEL_END + 60.0

# ----------------------------------------------------------------------------
# Utilidades de depuración / pruebas (tests/tongue_level_test.gd)
# ----------------------------------------------------------------------------

func debug_load() -> void:
	_load_level()
	_broken = {}

func debug_anchor_count() -> int:
	return _ax.size()

func debug_level_end() -> float:
	return _ax[_ax.size() - 1] if _ax.size() > 0 else 0.0

func debug_signature() -> String:
	var parts: PackedStringArray = []
	for i in _ax.size():
		parts.append("%.3f:%.3f:%d" % [_ax[i], _ay[i], _af[i]])
	return "|".join(parts)

func debug_fragile_count(x0: float, x1: float) -> int:
	var n := 0
	for i in _ax.size():
		if _ax[i] >= x0 and _ax[i] < x1 and _af[i] == 1:
			n += 1
	return n

func debug_avg_spacing(x0: float, x1: float) -> float:
	var total := 0.0
	var n := 0
	for i in range(1, _ax.size()):
		if _ax[i - 1] >= x0 and _ax[i] < x1:
			total += _ax[i] - _ax[i - 1]
			n += 1
	return total / maxf(float(n), 1.0)

## Juega el recorrido entero con el bot (sin límite de tiempo). Si la niebla o el pantano lo matan,
## devuelve en qué gancho. `until_x` corta la prueba.
func debug_bot_run(until_x: float = LEVEL_END) -> Dictionary:
	debug_load()
	_dbg_rng.seed = debug_seed
	var s := _start_state()
	_bot_plan_for = -2
	var steps := 0
	var cause := ""
	while steps < 60 * 400:
		var t := steps * STEP
		_phys(s, STEP, _bot_wants_hold(s))
		steps += 1
		if s.broke >= 0:
			_broken[s.broke] = true
		if not s.alive:
			cause = "pantano"
			break
		if s.pos.x < chase_at(steps * STEP):
			cause = "niebla"
			break
		if s.pos.x >= until_x:
			break
		if t > 400.0:
			break
	return {"alive": cause == "", "distance": s.pos.x, "time": steps * STEP, "cause": cause, "anchor": s.last,
			"info": "x=%.1f y=%.1f gancho=%d t=%.1f s niebla en x=%.1f" % [s.pos.x, s.pos.y, s.last, steps * STEP, chase_at(steps * STEP)]}

# ----------------------------------------------------------------------------
# Dibujo
# ----------------------------------------------------------------------------

func _sx(x: float) -> float:
	return (x - _cam) * BLOCK

func _sy(y: float) -> float:
	return 720.0 - y * BLOCK

func _draw_pos() -> Vector2:
	return _prev_pos.lerp(_s.pos, clampf(_accum / STEP, 0.0, 1.0))

func _draw_game() -> void:
	var s := surface
	var now := Time.get_ticks_msec() / 1000.0
	var cam_px := _cam * BLOCK
	var night := clampf(_s.pos.x / 700.0, 0.0, 1.0)
	# Cielo de atardecer que se va haciendo noche.
	var top_c := Color(0.10, 0.04, 0.26).lerp(Color(0.02, 0.01, 0.12), night)
	var hor_c := Color(0.98, 0.45, 0.40).lerp(Color(0.40, 0.12, 0.50), night * 0.75)
	s.draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(1280, 0), Vector2(1280, 720), Vector2(0, 720)]),
			PackedColorArray([top_c, top_c, hor_c, hor_c]))
	# Sol / luna.
	var sun_x := fposmod(1000.0 - cam_px * 0.03, 1800.0) - 200.0
	var sun_c := Color(1.0, 0.86, 0.5).lerp(Color(0.85, 0.9, 1.0), night)
	for k in 4:
		s.draw_circle(Vector2(sun_x, 470.0), 150.0 - k * 22.0, Color(sun_c.r, sun_c.g, sun_c.b, 0.07))
	s.draw_circle(Vector2(sun_x, 470.0), 88.0, sun_c)
	# Selva en siluetas (2 capas con paralaje).
	for layer in 2:
		var par := 0.12 + 0.2 * layer
		var col := Color(0.32, 0.12, 0.42).lerp(Color(0.12, 0.04, 0.22), layer * 0.7 + night * 0.3)
		for i in 16:
			var u := fposmod(i * 0.6180339887 + layer * 0.37, 1.0)
			var px := fposmod(i * 170.0 - cam_px * par, 16 * 170.0) - 120.0
			var h := 180.0 + u * 190.0 + layer * 40.0
			s.draw_rect(Rect2(px + 70.0, 660.0 - h, 22.0 + layer * 8.0, h), col)
			for c in 3:
				s.draw_circle(Vector2(px + 80.0 + (c - 1) * 46.0, 660.0 - h - 6.0 + abs(c - 1) * 22.0), 62.0 - abs(c - 1) * 12.0, col)
	# Luciérnagas.
	for i in 22:
		var u := fposmod(i * 0.7548776662, 1.0)
		var fx := fposmod(u * 1400.0 - cam_px * 0.5 + sin(now * 0.7 + i) * 30.0, 1400.0) - 60.0
		var fy := 120.0 + fposmod(i * 0.331, 1.0) * 420.0 + sin(now * 1.3 + i * 2.0) * 26.0
		var tw := 0.4 + 0.6 * (0.5 + 0.5 * sin(now * 3.0 + i * 1.9))
		s.draw_circle(Vector2(fx, fy), 7.0, Color(1.0, 1.0, 0.5, 0.10 * tw))
		s.draw_circle(Vector2(fx, fy), 2.6, Color(1.0, 1.0, 0.6, 0.9 * tw))
	# Ganchos (lianas con anillo). El que va a agarrar la lengua se resalta.
	var pos := _draw_pos()
	var aim := -1
	var next_i := _s.last + 1 if _s.anchor < 0 and not _dead else -1
	if _s.anchor < 0 and not _dead:
		aim = _pick(_s)
	var i0 := _lower(_cam - 2.0)
	var i1 := i0
	while i1 < _ax.size() and _ax[i1] < _cam + 28.0:
		i1 += 1
	for i in range(i0, i1):
		if _broken.has(i):
			continue
		var c := Vector2(_sx(_ax[i]), _sy(_ay[i]))
		var frag := _af[i] == 1
		var vine := Color(0.22, 0.62, 0.34) if not frag else Color(0.6, 0.35, 0.2)
		s.draw_line(Vector2(c.x, -10), c, vine, 4.0)
		var ring := Color(1.0, 0.85, 0.3) if not frag else Color(1.0, 0.45, 0.25)
		var shake := Vector2.ZERO
		if frag and _s.anchor == i:
			var f := clampf(_s.t_att / BREAK_T, 0.0, 1.0)
			shake = Vector2(sin(now * 60.0), cos(now * 53.0)) * 4.0 * f
			ring = ring.lerp(Color(1, 0.1, 0.1), f)
		c += shake
		if i == next_i and aim < 0:
			s.draw_arc(c, 24.0 + 2.0 * sin(now * 6.0), 0.0, TAU, 24, Color(1, 1, 1, 0.35), 3.0, true)
		if i == aim:
			s.draw_circle(c, 30.0 + 4.0 * sin(now * 12.0), Color(1, 1, 1, 0.25))
		s.draw_circle(c, 17.0, Color(0.1, 0.04, 0.15))
		s.draw_arc(c, 14.0, 0.0, TAU, 24, ring, 5.0, true)
		s.draw_circle(c, 5.0, ring)
		if frag:
			s.draw_line(c + Vector2(-9, -9), c + Vector2(-2, 1), Color(0.1, 0.04, 0.15), 3.0)
			s.draw_line(c + Vector2(2, 1), c + Vector2(9, 10), Color(0.1, 0.04, 0.15), 3.0)
	# Pantano tóxico.
	var sw := _sy(LAVA_Y)
	var wave := PackedVector2Array()
	for k in 33:
		var wx := k * 40.0
		wave.append(Vector2(wx, sw + sin(wx / 38.0 + now * 2.2 + cam_px * 0.01) * 5.0))
	var poly := PackedVector2Array(wave)
	poly.append(Vector2(1280, 730))
	poly.append(Vector2(0, 730))
	s.draw_colored_polygon(poly, Color(0.06, 0.36, 0.20, 0.97))
	s.draw_polyline(wave, Color(0.5, 1.0, 0.45, 0.30), 14.0, true)
	s.draw_polyline(wave, Color(0.7, 1.0, 0.55), 4.0, true)
	for k in 12:
		var bx := fposmod(k * 131.0 - cam_px * 0.9, 1400.0) - 60.0
		var by := sw + 10.0 + fposmod(now * 18.0 + k * 37.0, 50.0)
		s.draw_arc(Vector2(bx, by), 5.0 + (k % 3) * 2.0, 0.0, TAU, 12, Color(0.7, 1.0, 0.6, 0.5), 2.0, true)
	# Lengua.
	var frog := Vector2(_sx(pos.x), _sy(pos.y))
	var mouth := frog + Vector2(15.0, -4.0).rotated(_rot)
	if local_player != null and not (_dead and not _timed_out):
		if _s.anchor >= 0 and not _broken.has(_s.anchor):
			var a := Vector2(_sx(_ax[_s.anchor]), _sy(_ay[_s.anchor]))
			var tip := mouth.lerp(a, _tongue_ext)
			s.draw_line(mouth, tip, Color(0.45, 0.05, 0.25), 11.0, true)
			s.draw_line(mouth, tip, Color(1.0, 0.45, 0.62), 7.0, true)
			s.draw_circle(tip, 8.0, Color(1.0, 0.45, 0.62))
		elif _whiff > 0.0 or (_s.armed > 0.0 and _s.anchor < 0):
			var ext := (_whiff / 0.3) if _whiff > 0.0 else 1.0
			var tip2 := mouth + Vector2(1.0, -1.1).normalized() * 130.0 * ext
			s.draw_line(mouth, tip2, Color(1.0, 0.45, 0.62, 0.8), 6.0, true)
			s.draw_circle(tip2, 6.0, Color(1.0, 0.45, 0.62, 0.8))
		_draw_frog(frog)
	for sh in _shards:
		var p: Vector2 = sh.pos
		var sz := float(sh.size) * BLOCK
		s.draw_set_transform(Vector2(_sx(p.x), _sy(p.y)), float(sh.rot), Vector2.ONE)
		var cc: Color = local_player.color if local_player != null else Palette.YELLOW
		s.draw_rect(Rect2(-sz * 0.5, -sz * 0.5, sz, sz), Color(cc.r, cc.g, cc.b, clampf(float(sh.life) * 1.5, 0.0, 1.0)))
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_fog(now)
	if _flash > 0.0:
		s.draw_rect(Rect2(0, 0, 1280, 720), Color(1, 1, 1, _flash * 0.4))
	_draw_hud()

func _draw_frog(c: Vector2) -> void:
	var s := surface
	var col := local_player.color
	s.draw_set_transform(c, _rot, Vector2.ONE)
	s.draw_circle(Vector2.ZERO, 27.0, Color(0.05, 0.02, 0.10))
	s.draw_circle(Vector2.ZERO, 24.0, col)
	s.draw_circle(Vector2(2, 8), 15.0, col.lightened(0.35))
	# Ojos que miran hacia donde va.
	var look := Vector2(clampf(_s.vel.x * 0.12, -1.0, 1.0), clampf(-_s.vel.y * 0.12, -1.0, 1.0)) * 2.5
	for ex in [-9.0, 10.0]:
		s.draw_circle(Vector2(ex, -17.0), 10.0, Color(0.05, 0.02, 0.10))
		s.draw_circle(Vector2(ex, -17.0), 8.0, Color.WHITE)
		s.draw_circle(Vector2(ex, -17.0) + look, 4.0, Color(0.05, 0.02, 0.10))
	s.draw_arc(Vector2(3, 4), 11.0, 0.15 * PI, 0.85 * PI, 10, Color(0.05, 0.02, 0.10), 3.0, true)
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## Niebla venenosa que persigue: muro morado con ojos y aviso rojo cuando está cerca.
func _draw_fog(now: float) -> void:
	var s := surface
	var fx := _sx(chase_at(_time))
	if fx < -120.0:
		return
	s.draw_rect(Rect2(-40, 0, fx - 60.0, 720), Color(0.16, 0.03, 0.24, 0.96))
	for k in 10:
		var cy := k * 80.0 + sin(now * 1.8 + k) * 18.0
		s.draw_circle(Vector2(fx - 50.0 + sin(now * 2.3 + k * 1.7) * 14.0, cy), 78.0, Color(0.20, 0.04, 0.30, 0.95))
		s.draw_circle(Vector2(fx - 10.0 + sin(now * 1.9 + k) * 12.0, cy + 30.0), 52.0, Color(0.5, 0.1, 0.6, 0.35))
	for e in 3:
		var ey := 150.0 + e * 190.0 + sin(now * 1.1 + e) * 20.0
		var ex := fx - 70.0 - (e % 2) * 40.0
		for sgn in [-1.0, 1.0]:
			s.draw_circle(Vector2(ex + sgn * 22.0, ey), 13.0, Color(1.0, 0.95, 0.4))
			s.draw_circle(Vector2(ex + sgn * 22.0 + 3.0, ey), 5.0, Color(0.3, 0.0, 0.1))
	var gap := _s.pos.x - chase_at(_time)
	if gap < 7.0 and not _dead:
		var a := (0.25 + 0.2 * sin(now * 14.0)) * (1.0 - gap / 7.0)
		s.draw_rect(Rect2(0, 0, 90, 720), Color(1.0, 0.1, 0.2, a))

func _draw_hud() -> void:
	var s := surface
	var meters := int(maxf(_best_x, 0.0))
	var bar := Rect2(340, 30, 600, 18)
	s.rounded_rect(bar.grow(4), 12, Color(0, 0, 0, 0.45))
	var frac := clampf(_best_x / LEVEL_END, 0.0, 1.0)
	if frac > 0.0:
		s.rounded_rect(Rect2(bar.position, Vector2(maxf(bar.size.x * frac, 16.0), bar.size.y)), 9, Color(1, 1, 1, 0.92))
	s.text_centered(Vector2(640, 76), "%d m" % meters, 52, Color.WHITE, 8)
	s.text_centered(Vector2(1130, 40), "%d s" % maxi(0, ceili(TIME_LIMIT - _time)), 34, Color(1, 1, 1, 0.85), 6)
	if not _touched and not _dead:
		s.text_centered(Vector2(640, 200), "¡Suelta para saltar y mantén para agarrar!", 30, Color(1, 1, 1, 0.9), 6)
	if _dead:
		var msg := "¡TIEMPO! %d m" % meters if _timed_out else "%s %d m" % [_death_cause, meters]
		s.text_centered(Vector2(640, 330), msg, 60, Palette.YELLOW, 12)
		if _death_t > 0.4:
			s.text_centered(Vector2(640, 410), "Más lejos = mejor posición", 30, Color(1, 1, 1, 0.85), 6)
