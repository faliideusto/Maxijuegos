extends Minigame
## Salto Lunar (modelo LOCAL_PARALLEL): un astronauta rueda y vuela por las colinas de la Luna y gana quien
## llega más lejos en 45 s. Cada uno juega en su pantalla (sin verse) sobre el MISMO terreno, que sale de la semilla
## común. Un solo botón: MANTENER = bajar (en el aire cae en picado y pegado al suelo coge más fuerza al
## bajar la montaña); SOLTAR = planear (en el suelo, despegar por la cima y flotar con la gravedad de la Luna).
##
## LO QUE HAY QUE DOMINAR (como los juegos de "colinas"): al aterrizar solo se conserva la velocidad a lo largo
## del terreno, así que si caes sobre la LADERA DE BAJADA de una montaña con la caída casi paralela a la pendiente,
## apenas pierdes nada y sales disparado (¡PERFECTO!); si caes contra una subida o en plano, te frenas en seco. Hay
## que mantener el botón al bajar para ganar velocidad y soltarlo al empezar a subir para no perderla. Si te
## quedas casi parado más de 1,2 s, se acabó. Gana la mayor distancia; no hay desempate.
##
## Física (fija a 120 Hz): en el suelo la velocidad cambia con la pendiente (±G·sen θ; G sube al mantener el botón: más
## ganancia bajando y más pérdida subiendo) y se despega cuando la trayectoria balística queda por encima del terreno.
## En el aire hay gravedad lunar, o de picado si se mantiene. No hay nada de red: report_result(distancia en m).

const STEP := 1.0 / 120.0
const TIME_LIMIT := 45.0
const LEVEL_LEN := 140000.0           # px de terreno generado
const PX_PER_M := 50.0                # px por "metro" mostrado
const G_GROUND := 1400.0              # aceleración a lo largo de la pendiente (px/s² por sen θ)
const G_GROUND_HOLD := 3000.0         # ... manteniendo el botón
const G_AIR := 1000.0                 # gravedad lunar en el aire
const G_AIR_HOLD := 3600.0            # ... en picado
const DRAG_GROUND := 0.12
const DRAG_AIR := 0.02
const V_MAX := 2100.0
const START_SPEED := 260.0
const STUCK_SPEED := 30.0
const STUCK_TIME := 1.2
const DONE_DELAY := 1.5
const PLAYER_X := 300.0               # x fija del astronauta en pantalla
const SCREEN_REF := 580.0             # y de pantalla del suelo de referencia
const PERFECT_COS := 0.93             # coseno del ángulo entre la caída y la ladera: por encima, aterrizaje perfecto
const BAD_COS := 0.70                 # por debajo, porrazo
const LAND_KEEP := 0.2                # fracción de la caída contra el suelo que aún se aprovecha al aterrizar (perdón)

class PState:
	var x: float = 0.0
	var y: float = 0.0
	var vx: float = 0.0
	var vy: float = 0.0
	var speed: float = 0.0            # velocidad a lo largo del terreno (en el suelo)
	var grounded: bool = true
	var event: int = 0                # 1 = acaba de despegar, 2 = acaba de aterrizar
	var land_cos: float = 1.0
	var land_before: float = 0.0
	var land_after: float = 0.0
	var land_slope: float = 0.0

# --- Terreno: puntos de control (cima/valle alternados) unidos con coseno suave ---
var _tx: PackedFloat64Array = PackedFloat64Array()
var _ty: PackedFloat64Array = PackedFloat64Array()
var _terrain_ready: bool = false

var _s := PState.new()
var _time: float = 0.0
var _accum: float = 0.0
var _stuck_t: float = 0.0
var _done: bool = false
var _done_t: float = 0.0
var _stuck_end: bool = false
var _cam_y: float = 0.0
var _next_milestone: float = 100.0
var _last_hold: bool = false
var _dive_cd: float = 0.0
var _last_sec: int = 99
var _popups: Array = []               # {pos, text, color, age}
var _dust: Array = []                 # {pos, vel, life}
var _best_speed: float = 0.0
var _shake: float = 0.0
var _flash: float = 0.0
var _hint_t: float = 4.0
# IA (autopiloto)
var debug_skill: float = 1.0          # 1 = reacciona justo; <1 = más tarde y con menos puntería
var bot_hold_thr: float = 0.0        # la IA mantiene mientras la pendiente por delante sea menor que esto
var bot_look_t: float = 0.16          # ... mirando tantos segundos de camino por delante
var bot_air_dive: bool = true         # ... y también en el aire
var _ai_hold: bool = false

# ----------------------------------------------------------------------------
# Terreno (igual para todos los jugadores)
# ----------------------------------------------------------------------------

func _ensure_terrain() -> void:
	if _terrain_ready:
		return
	_terrain_ready = true
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	_tx = PackedFloat64Array([0.0])
	_ty = PackedFloat64Array([210.0])           # se empieza en una cima, bajando
	var x := 0.0
	var peak := true
	var last_peak_y := 210.0
	while x < LEVEL_LEN:
		var d := clampf(x / 70000.0, 0.0, 1.0)
		var width := r.randf_range(330.0, 560.0) * lerpf(1.0, 0.82, d)
		var y: float
		if peak:
			# valle tras una cima
			y = r.randf_range(-70.0, 10.0) - 40.0 * d * r.randf()
		else:
			y = r.randf_range(120.0, 230.0) + 110.0 * d * r.randf()
			if d > 0.15 and r.randf() < 0.14:
				y += 110.0                      # alguna montaña más alta y empinada
		# Límite de pendiente (para que siempre sea jugable): máx. ~58°.
		var amp := absf(y - _ty[_ty.size() - 1])
		var min_width := amp * PI * 0.5 / 1.6
		width = maxf(width, min_width)
		x += width
		_tx.append(x)
		_ty.append(y)
		peak = not peak
		if not peak:
			last_peak_y = y
	# Un tramo final llano para que no haya un borde.
	_tx.append(x + 2000.0)
	_ty.append(_ty[_ty.size() - 1])

func _seg(x: float) -> int:
	var lo := 0
	var hi := _tx.size() - 2
	while lo < hi:
		@warning_ignore("integer_division")
		var mid := (lo + hi + 1) / 2
		if _tx[mid] <= x:
			lo = mid
		else:
			hi = mid - 1
	return lo

## Altura del terreno en x.
func height_at(x: float) -> float:
	x = maxf(x, 0.0)
	var i := _seg(x)
	if i >= _tx.size() - 1:
		return _ty[_ty.size() - 1]
	var u := (x - _tx[i]) / (_tx[i + 1] - _tx[i])
	return _ty[i] + (_ty[i + 1] - _ty[i]) * (1.0 - cos(PI * u)) * 0.5

## Pendiente (dy/dx) del terreno en x.
func slope_at(x: float) -> float:
	x = maxf(x, 0.0)
	var i := _seg(x)
	if i >= _tx.size() - 1:
		return 0.0
	var w := _tx[i + 1] - _tx[i]
	var u := (x - _tx[i]) / w
	return (_ty[i + 1] - _ty[i]) * PI * 0.5 * sin(PI * u) / w

# ----------------------------------------------------------------------------
# Física
# ----------------------------------------------------------------------------

func _reset_state() -> void:
	_s = PState.new()
	_s.x = 0.0
	_s.y = height_at(0.0)
	_s.speed = START_SPEED

func _step(s: PState, dt: float, hold: bool) -> void:
	s.event = 0
	if s.grounded:
		var th := atan(slope_at(s.x))
		var g := G_GROUND_HOLD if hold else G_GROUND
		s.speed += -g * sin(th) * dt
		s.speed *= exp(-DRAG_GROUND * dt)
		s.speed = clampf(s.speed, 0.0, V_MAX)
		var vx := s.speed * cos(th)
		var vy := s.speed * sin(th)
		var ga := G_AIR_HOLD if hold else G_AIR
		# ¿Despega? Si la trayectoria balística queda por encima del terreno (cima convexa y bastante velocidad).
		var bx := s.x + vx * dt
		var by := s.y + vy * dt - 0.5 * ga * dt * dt
		if s.speed > 80.0 and by > height_at(bx) + 0.05:
			s.grounded = false
			s.vx = vx
			s.vy = vy - ga * dt
			s.x = bx
			s.y = by
			s.event = 1
		else:
			s.x += vx * dt
			s.y = height_at(s.x)
	else:
		var ga2 := G_AIR_HOLD if hold else G_AIR
		s.vy -= ga2 * dt
		s.vx *= exp(-DRAG_AIR * dt)
		s.x += s.vx * dt
		s.y += s.vy * dt
		var h := height_at(s.x)
		if s.y <= h:
			var sl := slope_at(s.x)
			var t := Vector2(1.0, sl).normalized()
			var v := Vector2(s.vx, s.vy)
			var vt := v.dot(t)
			s.land_before = v.length()
			s.land_cos = vt / maxf(v.length(), 1.0)
			s.land_slope = sl
			var n := Vector2(-sl, 1.0).normalized()
			s.speed = clampf(maxf(vt, 0.0) + LAND_KEEP * absf(v.dot(n)), 0.0, V_MAX)
			s.land_after = s.speed
			s.y = h
			s.grounded = true
			s.event = 2

# ----------------------------------------------------------------------------
# Ciclo del minijuego
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	_ensure_terrain()
	surface.draw_callback = _draw_game

func _on_start() -> void:
	_ensure_terrain()
	_reset_state()
	_time = 0.0
	_accum = 0.0
	_stuck_t = 0.0
	_done = false
	_stuck_end = false
	_next_milestone = 100.0
	_cam_y = _s.y - 150.0
	_hint_t = 4.0
	_ai_hold = false

func _play(delta: float) -> void:
	if _done or local_player == null:
		return
	_time += delta
	_hint_t = maxf(0.0, _hint_t - delta)
	var simulated := InputManager.is_simulated(local_player.id)
	var hold := _bot_hold() if simulated else action_held(local_player)
	if not simulated and action_presses(local_player) > 0:
		hold = true                         # un toque muy corto también cuenta
	_accum += delta
	var steps := 0
	while _accum >= STEP and steps < 12:
		_accum -= STEP
		steps += 1
		_step(_s, STEP, hold)
		_react(_s)
		_best_speed = maxf(_best_speed, _current_speed())
	# Frenado total: se acabó.
	if _s.grounded and _s.speed < STUCK_SPEED:
		_stuck_t += delta
		if _stuck_t >= STUCK_TIME:
			_stuck_end = true
			_finish_play()
	else:
		_stuck_t = 0.0
	if hold and not _last_hold and not _s.grounded and _dive_cd <= 0.0:
		_dive_cd = 0.35
		Audio.sfx(&"dive", -9.0)
	_last_hold = hold
	_dive_cd = maxf(0.0, _dive_cd - delta)
	if _distance_m() >= _next_milestone:
		_next_milestone += 100.0
		Audio.sfx(&"milestone", -9.0)
	var sec := ceili(TIME_LIMIT - _time)
	if sec != _last_sec and sec <= 3 and sec > 0:
		Audio.sfx(&"beep", -7.0)
	_last_sec = sec
	if _time >= TIME_LIMIT:
		_finish_play()

## Efectos de despegue y aterrizaje.
func _react(s: PState) -> void:
	if s.event == 1 and s.speed > 500.0:
		Audio.sfx(&"launch", -9.0)
	elif s.event == 2:
		var downhill := s.land_slope < -0.02
		if s.land_cos >= PERFECT_COS and downhill and s.land_before > 450.0:
			Audio.sfx(&"perfect", -3.0)
			_popup("¡PERFECTO!", Palette.MINT)
			_flash = 0.25
		elif s.land_cos < BAD_COS and s.land_before > 350.0:
			Audio.sfx(&"thud", -3.0)
			_popup("¡PORRAZO!", Palette.CORAL)
			_shake = 0.7
		else:
			Audio.sfx(&"land", -9.0)

func _popup(text: String, color: Color) -> void:
	_popups.append({"pos": Vector2(PLAYER_X + 60.0, 250.0), "text": text, "color": color, "age": 0.0})

func _current_speed() -> float:
	return _s.speed if _s.grounded else Vector2(_s.vx, _s.vy).length()

func _distance_m() -> float:
	return maxf(_s.x, 0.0) / PX_PER_M

func _finish_play() -> void:
	if _done:
		return
	_done = true
	_done_t = 0.0
	DevCli.log_event("moon distance=%.0f m time=%.1f s stuck=%s" % [_distance_m(), _time, _stuck_end])

func _animate(delta: float) -> void:
	_shake = maxf(0.0, _shake - delta * 2.5)
	_flash = maxf(0.0, _flash - delta * 2.0)
	# La cámara sigue la altura del astronauta con suavidad.
	_cam_y = lerpf(_cam_y, _s.y - 150.0, 1.0 - exp(-4.0 * delta))
	for p in _popups:
		p.age += delta
	_popups = _popups.filter(func(x: Dictionary) -> bool: return x.age < 1.1)
	# Polvo lunar detrás del astronauta mientras rueda deprisa.
	if is_running and not _done and _s.grounded and _s.speed > 350.0 and randf() < delta * 40.0:
		_dust.append({"pos": Vector2(_s.x - 14.0, _s.y + 4.0), "vel": Vector2(randf_range(-80.0, -20.0), randf_range(20.0, 90.0)), "life": randf_range(0.3, 0.7)})
	for d in _dust:
		d.pos += d.vel * delta
		d.vel.y -= 60.0 * delta
		d.life -= delta
	_dust = _dust.filter(func(x: Dictionary) -> bool: return x.life > 0.0)
	if _done:
		_done_t += delta
		if _done_t >= DONE_DELAY and not _reported:
			report_result(snappedf(_distance_m(), 0.1), 0.0)   # más distancia = mejor

# ----------------------------------------------------------------------------
# IA del autopiloto: mantiene al bajar y suelta al subir, mirando un poco adelante
# ----------------------------------------------------------------------------

func _bot_hold() -> bool:
	var sk := clampf(debug_skill, 0.0, 1.0)
	var look := maxf(70.0, _current_speed() * bot_look_t * lerpf(2.2, 1.0, sk))
	var sl := slope_at(_s.x + look)
	var threshold := bot_hold_thr - (1.0 - sk) * 0.25
	if not _s.grounded and not bot_air_dive:
		_ai_hold = false
	else:
		_ai_hold = sl < threshold
	return _ai_hold

func _bot_action_held(_player: PlayerData) -> bool:
	return _bot_hold()

# --- Resultado simulado de un bot / desconectado (lo calcula el host) ---
func _bot_result(_player: PlayerData, r: RandomNumberGenerator) -> Dictionary:
	return {"score": roundf(r.randf_range(120.0, 520.0)), "tiebreak": 0.0}

# --- Plausibilidad: no se puede ir más deprisa que V_MAX durante TIME_LIMIT ---
func _validate_result(score: float, _tiebreak: float) -> bool:
	return score >= 0.0 and score <= V_MAX * (TIME_LIMIT + 2.0) / PX_PER_M + 1.0

# ----------------------------------------------------------------------------
# Utilidades de depuración / pruebas (tests/moon_test.gd)
# ----------------------------------------------------------------------------

func debug_terrain() -> Dictionary:
	_ensure_terrain()
	return {"x": _tx, "y": _ty}

func debug_signature() -> String:
	_ensure_terrain()
	var parts: PackedStringArray = []
	for i in _tx.size():
		parts.append("%.2f:%.2f" % [_tx[i], _ty[i]])
	return "|".join(parts)

## Simula una carrera completa con una política: "never" (nunca mantiene), "always" (siempre), "bot" (la IA).
func debug_run(policy: String, skill: float = 1.0, seconds: float = TIME_LIMIT) -> Dictionary:
	_ensure_terrain()
	_reset_state()
	debug_skill = skill
	var t := 0.0
	var stuck := 0.0
	var perfect := 0
	var bad := 0
	var max_speed := 0.0
	while t < seconds:
		var hold := false
		match policy:
			"always": hold = true
			"bot": hold = _bot_hold()
		_step(_s, STEP, hold)
		if _s.event == 2:
			if _s.land_cos >= PERFECT_COS and _s.land_slope < -0.02 and _s.land_before > 450.0:
				perfect += 1
			elif _s.land_cos < BAD_COS and _s.land_before > 350.0:
				bad += 1
		max_speed = maxf(max_speed, _current_speed())
		t += STEP
		if _s.grounded and _s.speed < STUCK_SPEED:
			stuck += STEP
			if stuck >= STUCK_TIME:
				break
		else:
			stuck = 0.0
	return {"distance_m": _distance_m(), "time": t, "perfect": perfect, "bad": bad, "max_speed": max_speed,
			"stuck": stuck >= STUCK_TIME}

func debug_state() -> PState:
	return _s

func debug_reset() -> void:
	_ensure_terrain()
	_reset_state()

func debug_step(hold: bool) -> void:
	_step(_s, STEP, hold)

# ----------------------------------------------------------------------------
# Dibujo
# ----------------------------------------------------------------------------

func _sx(x: float) -> float:
	return x - _s.x + PLAYER_X

func _sy(y: float) -> float:
	return SCREEN_REF - (y - _cam_y) + 150.0 - 150.0

func _draw_game() -> void:
	var s := surface
	var shake := Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * _shake * 6.0
	s.draw_set_transform(shake, 0.0, Vector2.ONE)
	_draw_sky()
	_draw_terrain()
	for d in _dust:
		var a := clampf(float(d.life) / 0.7, 0.0, 1.0)
		s.draw_circle(Vector2(_sx(d.pos.x), _sy(d.pos.y)), 3.0 + 4.0 * (1.0 - a), Color(0.75, 0.75, 0.8, a * 0.6))
	if local_player != null and not _done or _done and not _stuck_end:
		_draw_astronaut()
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_hud()
	if _flash > 0.0:
		s.draw_rect(Rect2(0, 0, 1280, 720), Color(0.7, 1.0, 0.85, _flash * 0.25))

func _draw_sky() -> void:
	var s := surface
	s.draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(1280, 0), Vector2(1280, 720), Vector2(0, 720)]),
			PackedColorArray([Color(0.01, 0.01, 0.06), Color(0.01, 0.01, 0.06), Color(0.06, 0.05, 0.2), Color(0.06, 0.05, 0.2)]))
	var cam := _s.x
	# Estrellas con paralaje.
	for layer in 3:
		var par := 0.01 + 0.03 * layer
		for i in 40:
			var u := fposmod(i * 0.6180339887 + layer * 0.31, 1.0)
			var v := fposmod(i * 0.7548776662 + layer * 0.17, 1.0)
			var px := fposmod(u * 1400.0 - cam * par, 1400.0) - 60.0
			s.draw_circle(Vector2(px, v * 520.0), 1.2 + layer * 0.8, Color(0.9, 0.95, 1.0, 0.5 + 0.15 * layer))
	# La Tierra, grande y lejana.
	var ex := fposmod(980.0 - cam * 0.004, 1800.0) - 200.0
	var ec := Vector2(ex, 235.0)
	for k in 4:
		s.draw_circle(ec, 96.0 + k * 10.0, Color(0.3, 0.6, 1.0, 0.04))
	s.draw_circle(ec, 88.0, Color(0.12, 0.35, 0.8))
	s.draw_circle(ec + Vector2(-20, -10), 40.0, Color(0.2, 0.62, 0.35, 0.9))
	s.draw_circle(ec + Vector2(28, 26), 28.0, Color(0.22, 0.6, 0.34, 0.9))
	s.draw_arc(ec, 88.0, PI * 1.1, PI * 1.7, 20, Color(1, 1, 1, 0.5), 4.0, true)
	# Montañas lejanas (silueta).
	var base := 560.0 - (_cam_y * 0.15)
	var pts := PackedVector2Array()
	pts.append(Vector2(0, 720))
	for i in 33:
		var wx := i * 40.0
		var gx := cam * 0.25 + wx
		var h := 70.0 * sin(gx / 150.0) + 46.0 * sin(gx / 61.0 + 1.3) + 30.0 * sin(gx / 330.0)
		pts.append(Vector2(wx, minf(base - 60.0 - h, 715.0)))
	pts.append(Vector2(1280, 720))
	s.draw_colored_polygon(pts, Color(0.16, 0.15, 0.3))

func _draw_terrain() -> void:
	var s := surface
	var x0 := _s.x - PLAYER_X - 20.0
	var top := PackedVector2Array()
	var step_px := 10.0
	var n := int((1280.0 + 60.0) / step_px)
	for i in n + 1:
		var wx := x0 + i * step_px
		# Se limita la y para que el polígono nunca quede del revés (con la cámara muy alta, el suelo se sale por abajo).
		top.append(Vector2(_sx(wx), minf(_sy(height_at(wx)), 770.0)))
	var poly := PackedVector2Array(top)
	poly.append(Vector2(top[top.size() - 1].x, 790))
	poly.append(Vector2(top[0].x, 790))
	s.draw_colored_polygon(poly, Color(0.56, 0.56, 0.64))
	# Sombreado: franja más oscura bajo la superficie y borde claro.
	var shade := PackedVector2Array()
	for p in top:
		shade.append(Vector2(p.x, minf(p.y + 38.0, 780.0)))
	var poly2 := PackedVector2Array(shade)
	poly2.append(Vector2(shade[shade.size() - 1].x, 790))
	poly2.append(Vector2(shade[0].x, 790))
	s.draw_colored_polygon(poly2, Color(0.42, 0.42, 0.52))
	s.draw_polyline(top, Color(0.88, 0.88, 0.96), 5.0, true)
	# Cráteres (deterministas por celda).
	var cell0 := int(floor(x0 / 170.0))
	for k in range(cell0, cell0 + 10):
		var hsh := fposmod(sin(float(k) * 12.9898) * 43758.5453, 1.0)
		if hsh < 0.5:
			var cx := k * 170.0 + hsh * 140.0
			var rad := 12.0 + hsh * 46.0
			var c := Vector2(_sx(cx), _sy(height_at(cx)) + 22.0 + hsh * 20.0)
			s.draw_set_transform(c, 0.0, Vector2(1.0, 0.38))
			s.draw_circle(Vector2.ZERO, rad, Color(0.34, 0.34, 0.44, 0.8))
			s.draw_arc(Vector2.ZERO, rad, PI, TAU, 16, Color(0.8, 0.8, 0.9, 0.7), 3.0, true)
			s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_astronaut() -> void:
	var s := surface
	var c := Vector2(PLAYER_X, _sy(_s.y) - 20.0)
	var roll := _s.x / 22.0 if _s.grounded else _s.x / 22.0 + _time * 3.0
	var tilt := atan2(_s.vy, maxf(_s.vx, 1.0)) * 0.4 if not _s.grounded else atan(slope_at(_s.x)) * -0.8
	# Estela de velocidad.
	var spd := _current_speed()
	if spd > 800.0:
		var a := clampf((spd - 800.0) / 900.0, 0.0, 1.0)
		for k in 6:
			s.draw_line(c + Vector2(-30 - k * 18, -14 + k * 6), c + Vector2(-70 - k * 30, -14 + k * 6), Color(1, 1, 1, 0.5 * a), 3.0)
	s.draw_set_transform(c, tilt, Vector2.ONE)
	var col: Color = local_player.color if local_player != null else Palette.YELLOW
	s.draw_circle(Vector2(0, 4), 24.0, Color(0, 0, 0, 0.3))
	s.draw_circle(Vector2.ZERO, 24.0, Palette.PURPLE_DARK)
	s.draw_circle(Vector2.ZERO, 21.5, Color(0.95, 0.96, 1.0))                 # traje
	s.draw_circle(Vector2(2, -3), 13.5, Palette.PURPLE_DARK)
	s.draw_circle(Vector2(2, -3), 12.0, col)                                  # visor con tu color
	s.draw_circle(Vector2(-3, -8), 3.5, Color(1, 1, 1, 0.55))
	# Mochila que gira (indica que rueda).
	s.draw_set_transform(c, roll, Vector2.ONE)
	s.draw_rect(Rect2(-6, 14, 12, 6), Color(0.62, 0.64, 0.74))
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_hud() -> void:
	var s := surface
	s.text_centered(Vector2(640, 48), "%d m" % int(_distance_m()), 64, Palette.WHITE, 10)
	var spd := _current_speed()
	var bar := Rect2(440, 88, 400, 16)
	s.rounded_rect(bar.grow(4), 12, Color(0, 0, 0, 0.45))
	var frac := clampf(spd / 1600.0, 0.0, 1.0)
	if frac > 0.0:
		var col := Palette.MINT.lerp(Palette.YELLOW, clampf((frac - 0.4) * 2.0, 0.0, 1.0))
		s.rounded_rect(Rect2(bar.position, Vector2(maxf(bar.size.x * frac, 16.0), bar.size.y)), 8, col)
	s.text_centered(Vector2(640, 120), "VELOCIDAD", 18, Color(1, 1, 1, 0.7), 4)
	var left := maxi(0, ceili(TIME_LIMIT - _time))
	s.text_centered(Vector2(1130, 48), "%d s" % left, 40, Palette.YELLOW if left > 5 else Palette.CORAL, 8)
	for p in _popups:
		var k: float = p.age / 1.1
		s.text_centered(Vector2(p.pos.x, p.pos.y - 60.0 * k), String(p.text), 44, Color(p.color.r, p.color.g, p.color.b, 1.0 - k * k), 9)
	if _hint_t > 0.0 and not _done:
		s.text_centered(Vector2(640, 190), "¡MANTÉN para bajar las montañas, SUELTA para planear!", 30, Color(1, 1, 1, clampf(_hint_t, 0.0, 1.0)), 7)
	if _done:
		var msg := "¡SIN IMPULSO!" if _stuck_end else "¡TIEMPO!"
		s.text_centered(Vector2(640, 300), msg, 84, Palette.YELLOW, 14)
		if _done_t > 0.4:
			s.text_centered(Vector2(640, 380), "%d m" % int(_distance_m()), 64, Palette.WHITE, 10)
			s.text_centered(Vector2(640, 440), "Más lejos = mejor posición", 28, Color(1, 1, 1, 0.8), 6)
