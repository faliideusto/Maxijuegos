extends Minigame
## Onda Neón (modelo LOCAL_PARALLEL): la "onda" de los runners de ritmo. Una flecha avanza sola a
## velocidad constante; MANTENER el botón la hace subir en diagonal (45°) y SOLTARLO la hace bajar. Hay
## que cruzar un pasillo de paredes en zigzag que se va ESTRECHANDO sin parar. Un solo intento: gana
## quien llegue más lejos, luego el segundo, etc. Nadie ve a los demás: todos corren el mismo pasillo.
##
## EL PASILLO ES UNO SOLO, idéntico en todas las partidas y en todos los PC: se genera con una semilla
## FIJA (LEVEL_SEED), no con la semilla de la partida. No hay nada de red aquí.
##
## Estructura: una línea central formada por tramos de pendiente exactamente ±1 (lo que recorre la onda
## si sube o baja sin parar) y unas paredes a ±h(x) de esa línea. h (medio ancho) baja de HALF_START a
## HALF_END con la distancia, los tramos se acortan (giros más seguidos), aparecen ráfagas de giros cortos
## y la velocidad sube.
##
## SIEMPRE PASABLE: la propia línea central es una trayectoria posible de la onda y nunca toca las
## paredes. tests/wave_level_test.gd corre un bot por todo el pasillo, también girando con retraso o
## adelanto (el margen humano garantizado por el diseño, ver debug_guaranteed_tol).
##
## Estética de neón: fondo degradado que cambia de color, paredes oscuras con borde luminoso y estela
## brillante. Todo se dibuja por código con formas propias.

# --- Mundo (unidades: bloques; y hacia arriba, 0 = borde inferior de la pantalla) ---
const BLOCK := 48.0               # píxeles por bloque (la pantalla mide 15 bloques de alto)
const WAVE_SCREEN_X := 300.0      # x (píxeles) fija de la onda en pantalla
const STEP := 1.0 / 120.0         # paso fijo de física
const WAVE_R := 0.18              # radio de colisión de la onda (bloques)
const LEVEL_SEED := 20260607      # semilla FIJA del pasillo: siempre el mismo
const LEVEL_TARGET := 1400.0      # bloques del pasillo (inalcanzables en el tiempo límite)
const TIME_LIMIT := 90.0          # s; tope para que la partida no sea eterna
const DEATH_ANIM := 1.3           # s de animación antes de enviar el resultado

const SPEED_POINTS: Array[Vector2] = [Vector2(0, 8.5), Vector2(50, 9.5), Vector2(130, 10.7),
		Vector2(250, 11.7), Vector2(400, 12.5)]
const SPEED_MAX := 12.5

const Y_FLOOR := 1.0              # las paredes nunca bajan de esta y
const Y_CEIL := 13.0              # ni suben de esta y (arriba queda sitio para el HUD)
const START_Y := 8.4              # y de la línea central en x = 0
const HALF_START := 3.6           # medio ancho del pasillo al empezar
const HALF_END := 1.8             # medio ancho final (pasillo de 3,6 bloques de alto)
const NARROW_FROM := 20.0         # el pasillo empieza a estrecharse aquí
const NARROW_TO := 380.0          # ... y llega a su mínimo aquí
const SEG_RAMP := 400.0           # distancia en la que los tramos se acortan del todo
const MIN_SEG := 1.5              # tramo más corto posible (bloques)

class PState:
	var x: float = 0.0
	var y: float = START_Y
	var up: bool = false           # ¿sube ahora? (empieza bajando)
	var alive: bool = true

# --- Pasillo: vértices (x, y) de la línea central; el tramo i va del vértice i al i+1 ---
var _cx: PackedFloat64Array = PackedFloat64Array()
var _cy: PackedFloat64Array = PackedFloat64Array()
var _level_end: float = LEVEL_TARGET

# --- Estado del bot / pruebas ---
var _bot_idx: int = 0
## Error de giro del bot en segundos (pruebas): se aplica según debug_pattern.
var debug_tol: float = 0.0
## 0 = giro exacto, 1 = siempre tarde, 2 = siempre pronto, 3 = alterna tarde/pronto.
var debug_pattern: int = 0
var debug_never_hold: bool = false
## Bot en BUCLE CERRADO (como un humano que corrige): decide con lo que vio hace debug_tol segundos.
var debug_closed_loop: bool = false
var _hist: Array = []
var debug_always_hold: bool = false

# --- Estado de la partida local ---
var _s := PState.new()
var _time: float = 0.0
var _accum: float = 0.0
var _dead: bool = false
var _timed_out: bool = false
var _death_t: float = 0.0
var _shards: Array = []
var _path: Array = []              # vértices (Vector2 mundo) de la estela
var _flash: float = 0.0
var _next_milestone: float = 100.0

func _on_prepare() -> void:
	_build_level()
	surface.draw_callback = _draw_game

func _on_start() -> void:
	_reset_state()
	_next_milestone = 100.0
	_time = 0.0
	_accum = 0.0
	_dead = false
	_timed_out = false

func _reset_state() -> void:
	_s = PState.new()
	_path = [Vector2(0.0, START_Y)]
	_bot_idx = 0

# ----------------------------------------------------------------------------
# Parámetros que dependen de la distancia
# ----------------------------------------------------------------------------

func speed_at(x: float) -> float:
	if x <= SPEED_POINTS[0].x:
		return SPEED_POINTS[0].y
	for i in range(1, SPEED_POINTS.size()):
		if x <= SPEED_POINTS[i].x:
			var a := SPEED_POINTS[i - 1]
			var b := SPEED_POINTS[i]
			return lerpf(a.y, b.y, (x - a.x) / (b.x - a.x))
	return SPEED_MAX

## Medio ancho del pasillo en x: baja de forma continua de HALF_START a HALF_END.
func half_at(x: float) -> float:
	return lerpf(HALF_START, HALF_END, clampf((x - NARROW_FROM) / (NARROW_TO - NARROW_FROM), 0.0, 1.0))

# ----------------------------------------------------------------------------
# EL PASILLO
# ----------------------------------------------------------------------------

func _build_level() -> void:
	var r := RandomNumberGenerator.new()
	r.seed = LEVEL_SEED
	_cx = PackedFloat64Array([0.0])
	_cy = PackedFloat64Array([START_Y])
	var x := 0.0
	var y := START_Y
	var dir := -1.0                  # el primer tramo baja: la onda aún no recibe órdenes
	var burst := 0                   # tramos cortos seguidos que quedan de la ráfaga actual
	var guard := 0
	while x < LEVEL_TARGET + 60.0 and guard < 4000:
		guard += 1
		var t := clampf(x / SEG_RAMP, 0.0, 1.0)
		var lmin := lerpf(5.5, 2.4, t)
		var lmax := lerpf(12.0, 6.0, t)
		var h := half_at(x)
		var lo := Y_FLOOR + h
		var hi := Y_CEIL - h
		var seg: float
		if burst > 0:
			burst -= 1
			seg = lmin * r.randf_range(0.65, 0.9)     # esquinas muy rápidas
		else:
			seg = r.randf_range(lmin, lmax)
			if x > 60.0 and r.randf() < 0.16:
				seg = r.randf_range(14.0, 20.0)     # tramo larguísimo en diagonal (se recorta a la sala disponible)
			elif x > 80.0 and r.randf() < lerpf(0.14, 0.38, t):
				burst = r.randi_range(2, 5)
		var room := (hi - y) if dir > 0.0 else (y - lo)
		seg = minf(seg, room)
		if seg < MIN_SEG:
			# Sin sitio para un tramo digno hacia ese lado: se sigue hacia el otro.
			dir = -dir
			continue
		x += seg
		y += dir * seg
		_cx.append(x)
		_cy.append(y)
		dir = -dir
	_level_end = LEVEL_TARGET

## Índice del último vértice con x <= la dada.
func _seg_index(x: float) -> int:
	var lo := 0
	var hi := _cx.size() - 1
	while lo < hi:
		@warning_ignore("integer_division")
		var mid := (lo + hi + 1) / 2
		if _cx[mid] <= x:
			lo = mid
		else:
			hi = mid - 1
	return lo

## y de la línea central en x.
func center_at(x: float) -> float:
	x = maxf(x, 0.0)
	var i := _seg_index(x)
	if i >= _cx.size() - 1:
		return _cy[_cy.size() - 1]
	return lerpf(_cy[i], _cy[i + 1], (x - _cx[i]) / (_cx[i + 1] - _cx[i]))

## ¿Toca la onda (en x, y) alguna pared? Se mira en tres x para no "colarse" por las esquinas.
func _wall_hit(x: float, y: float) -> bool:
	for dx in [-WAVE_R, 0.0, WAVE_R]:
		var xx: float = x + dx
		var c := center_at(xx)
		var h := half_at(xx)
		if y - WAVE_R < c - h or y + WAVE_R > c + h:
			return true
	return false

# ----------------------------------------------------------------------------
# Física
# ----------------------------------------------------------------------------

func _step_state(s: PState, dt: float, hold: bool) -> void:
	if not s.alive:
		return
	if hold != s.up:
		s.up = hold
		_path.append(Vector2(s.x, s.y))
		if _path.size() > 80:
			_path = _path.slice(40)
	var v := speed_at(s.x)
	s.x += v * dt
	s.y += (v if s.up else -v) * dt
	if _wall_hit(s.x, s.y):
		s.alive = false

# ----------------------------------------------------------------------------
# Jugador local (LOCAL_PARALLEL)
# ----------------------------------------------------------------------------

func _play(delta: float) -> void:
	if _dead or local_player == null:
		return
	_time += delta
	var hold := action_held(local_player)
	if not InputManager.is_simulated(local_player.id):
		# Un toque muy corto entre dos fotogramas también cuenta como pulsación.
		hold = hold or action_presses(local_player) > 0
	_accum += delta
	var steps := 0
	var was_up := _s.up
	while _accum >= STEP and steps < 12:
		_accum -= STEP
		steps += 1
		_step_state(_s, STEP, hold)
		if not _s.alive:
			_die()
			return
	if _s.up != was_up:
		Audio.sfx(&"flip_up" if _s.up else &"flip_down", -9.0)
	if _s.x >= _next_milestone:
		_next_milestone += 100.0
		Audio.sfx(&"milestone", -9.0)
	# El autopiloto (pruebas) se "cansa" pronto para que las partidas automáticas no se eternicen.
	var limit := 28.0 if InputManager.is_simulated(local_player.id) else TIME_LIMIT
	if _time >= limit or _s.x >= _level_end:
		_timed_out = true
		_dead = true   # deja de jugar; se envía el resultado tras una breve pausa
		_death_t = 0.0

func _die() -> void:
	Audio.sfx(&"zap", -3.0)
	_dead = true
	_death_t = 0.0
	_flash = 1.0
	var center := Vector2(_s.x, _s.y)
	for i in 16:
		var a := randf() * TAU
		_shards.append({"pos": center, "vel": Vector2.from_angle(a) * randf_range(2.0, 9.0),
				"size": randf_range(0.1, 0.26), "rot": randf() * TAU, "life": 1.0})

func _animate(delta: float) -> void:
	_flash = maxf(0.0, _flash - delta * 2.5)
	if _dead:
		_death_t += delta
		if _death_t >= DEATH_ANIM and not _reported:
			report_result(_s.x)   # distancia recorrida: más lejos = mejor
	for sh in _shards:
		sh.vel.y -= 20.0 * delta
		sh.pos += sh.vel * delta
		sh.rot += 6.0 * delta
		sh.life -= delta * 0.8
	_shards = _shards.filter(func(x: Dictionary) -> bool: return x.life > 0.0)

# ----------------------------------------------------------------------------
# IA del autopiloto: sigue la línea central
# ----------------------------------------------------------------------------

## Retraso (s) con el que el bot gira en el vértice k (positivo = tarde, negativo = pronto).
func _delay_for(k: int) -> float:
	match debug_pattern:
		1: return debug_tol
		2: return -debug_tol
		3: return debug_tol if k % 2 == 0 else -debug_tol
	return 0.0

func _bot_wants_up(s: PState) -> bool:
	if debug_never_hold:
		return false
	if debug_always_hold:
		return true
	if debug_closed_loop:
		# Mide cómo iba hace debug_tol segundos y sube si estaba por debajo de la línea central.
		_hist.append(Vector2(s.x, s.y))
		var lag := int(round(debug_tol / STEP))
		if _hist.size() > lag + 1:
			_hist = _hist.slice(_hist.size() - lag - 1)
		var past: Vector2 = _hist[0]
		return past.y < center_at(past.x)
	while _bot_idx + 1 < _cx.size() - 1 and _cx[_bot_idx + 1] + speed_at(_cx[_bot_idx + 1]) * _delay_for(_bot_idx + 1) <= s.x:
		_bot_idx += 1
	return _cy[_bot_idx + 1] > _cy[_bot_idx]

func _bot_action_held(_player: PlayerData) -> bool:
	return _bot_wants_up(_s)

# --- Resultado simulado de un bot / desconectado (lo calcula el host) ---
func _bot_result(_player: PlayerData, r: RandomNumberGenerator) -> Dictionary:
	return {"score": r.randf_range(60.0, 420.0), "tiebreak": 0.0}

# --- Plausibilidad: no se puede llegar más lejos que velocidad máxima × tiempo límite ---
func _validate_result(score: float, _tiebreak: float) -> bool:
	return score >= 0.0 and score <= SPEED_MAX * (TIME_LIMIT + 3.0) + 1.0

# ----------------------------------------------------------------------------
# Utilidades de depuración / pruebas (tests/wave_level_test.gd)
# ----------------------------------------------------------------------------

## Corre el pasillo entero con el bot (sin límite de tiempo). Devuelve hasta dónde llegó.
func debug_bot_run() -> Dictionary:
	_build_level()
	_reset_state()
	var s := _s
	var steps := 0
	while s.alive and s.x < _level_end and steps < 400000:
		_step_state(s, STEP, _bot_wants_up(s))
		steps += 1
	var info := "x=%.2f y=%.2f centro=%.2f medio_ancho=%.2f" % [s.x, s.y, center_at(s.x), half_at(s.x)]
	return {"distance": s.x, "alive": s.alive, "end": _level_end, "info": info}

func debug_level_end() -> float:
	_build_level()
	return _level_end

func debug_signature() -> String:
	_build_level()
	var parts: PackedStringArray = []
	for i in _cx.size():
		parts.append("%.4f:%.4f" % [_cx[i], _cy[i]])
	return "|".join(parts)

func debug_corner_count() -> int:
	_build_level()
	return _cx.size()

## Longitud media de los tramos entre x0 y x1 (comprueba que los giros se hacen más seguidos).
func debug_avg_segment(x0: float, x1: float) -> float:
	_build_level()
	var total := 0.0
	var n := 0
	for i in range(_cx.size() - 1):
		if _cx[i] >= x0 and _cx[i + 1] <= x1:
			total += _cx[i + 1] - _cx[i]
			n += 1
	return total / maxf(float(n), 1.0)

## Mayor tramo y menor tramo entre x0 y x1.
func debug_segment_range(x0: float, x1: float) -> Vector2:
	_build_level()
	var lo := INF
	var hi := 0.0
	for i in range(_cx.size() - 1):
		if _cx[i] >= x0 and _cx[i + 1] <= x1:
			lo = minf(lo, _cx[i + 1] - _cx[i])
			hi = maxf(hi, _cx[i + 1] - _cx[i])
	return Vector2(lo, hi)

## ¿Toda la línea central queda dentro de las paredes con holgura? Devuelve la holgura mínima.
func debug_min_clearance() -> float:
	_build_level()
	var best := INF
	for i in range(_cx.size() - 1):
		var x := _cx[i]
		while x <= _cx[i + 1]:
			best = minf(best, half_at(x) - WAVE_R - 0.0)
			x += 0.25
	return best

## Margen de giro (s) que el diseño garantiza al jugador: con errores de signo alterno en cada giro la
## desviación llega a 4·v·dt, que debe caber en (medio ancho − holgura de colisión). Se toma el peor caso.
func debug_guaranteed_tol() -> float:
	_build_level()
	var best := INF
	var x := 0.0
	while x <= _level_end:
		best = minf(best, (half_at(x) - 2.0 * WAVE_R) / (2.0 * speed_at(x)) - 0.01)
		x += 5.0
	return best

## Filas [nombre, x, tiempo (s), velocidad, medio ancho] para ver la rampa de dificultad.
func debug_timeline() -> Array:
	_build_level()
	var rows: Array = []
	var t := 0.0
	var x := 0.0
	var marks := [0.0, 100.0, 200.0, 300.0, 380.0, 700.0, 1400.0]
	var mi := 0
	while x <= _level_end and mi < marks.size():
		if x >= marks[mi]:
			rows.append(["x=%d" % int(marks[mi]), x, t, speed_at(x), half_at(x)])
			mi += 1
		t += 0.1
		x += speed_at(x) * 0.1
	return rows

# ----------------------------------------------------------------------------
# Dibujo
# ----------------------------------------------------------------------------

## Tono de neón de las paredes: deriva despacio entre cian, azul, violeta y magenta con la distancia.
func _neon(x: float, shift: float) -> Color:
	var h := 0.72 + 0.2 * sin(x / 140.0) + 0.04 * sin(x / 37.0) + shift
	return Color.from_hsv(fposmod(h, 1.0), 0.72, 1.0)

func _sy(y: float) -> float:
	return 720.0 - y * BLOCK

## Fondo ESPACIAL: degradado casi negro teñido por la distancia, nebulosas, planeta con anillo y tres
## capas de estrellas con paralaje (posiciones deterministas, sin aleatoriedad por fotograma).
func _draw_space(cam: float) -> void:
	var s := surface
	var tint := _neon(_s.x, -0.1)
	var top_c := Color(0.015, 0.01, 0.07).lerp(tint, 0.10)
	var bot_c := Color(0.03, 0.01, 0.12).lerp(tint, 0.30)
	var vr := view_rect()
	s.draw_polygon(PackedVector2Array([vr.position, Vector2(vr.end.x, vr.position.y), vr.end, Vector2(vr.position.x, vr.end.y)]),
			PackedColorArray([top_c, top_c, bot_c, bot_c]))
	var cam_px := cam * BLOCK
	# Nebulosas: manchas enormes y suaves (círculos concéntricos casi transparentes).
	var neb_w := maxf(1900.0, ceilf((vr.size.x + 600.0) / 620.0) * 620.0)
	for i in int(neb_w / 620.0):
		var nx := fposmod(i * 620.0 + 200.0 - cam_px * 0.05, neb_w) + vr.position.x - 300.0
		var ny := 160.0 + (i % 3) * 190.0
		var nc := _neon(_s.x * 0.3 + i * 90.0, 0.0)
		for k in 5:
			s.draw_circle(Vector2(nx, ny), 300.0 - k * 55.0, Color(nc.r, nc.g, nc.b, 0.028))
	# Planeta lejano con anillo.
	var pxp := 1700.0 - fposmod(cam_px * 0.04, 2600.0)
	var pc := Vector2(pxp, 210.0)
	s.draw_circle(pc, 92.0, Color(0.05, 0.03, 0.16))
	s.draw_arc(pc, 92.0, PI * 1.05, PI * 1.75, 28, Color(tint.r, tint.g, tint.b, 0.75), 4.0, true)
	s.draw_set_transform(pc, -0.35, Vector2(1.0, 0.28))
	s.draw_arc(Vector2.ZERO, 150.0, 0.0, TAU, 56, Color(tint.r, tint.g, tint.b, 0.35), 8.0, true)
	s.draw_arc(Vector2.ZERO, 175.0, 0.0, TAU, 56, Color(1, 1, 1, 0.12), 5.0, true)
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# Estrellas: 3 capas (lejos = pequeñas y lentas, cerca = grandes y rápidas) que titilan.
	var now := Time.get_ticks_msec() / 1000.0
	var star_w := maxf(1400.0, vr.size.x + 120.0)
	for layer in 3:
		var par := 0.08 + 0.17 * layer
		for i in int(46.0 * star_w / 1400.0):
			var u := fposmod(i * 0.6180339887 + layer * 0.31, 1.0)
			var v := vr.position.y / 720.0 + fposmod(i * 0.7548776662 + layer * 0.17, 1.0) * vr.size.y / 720.0
			var px := fposmod(u * star_w - cam_px * par, star_w) + vr.position.x - 60.0
			var tw := 0.55 + 0.45 * sin(now * (1.5 + layer) + i * 1.7)
			var sz := 1.4 + layer * 1.1
			s.draw_circle(Vector2(px, v * 720.0), sz, Color(0.85, 0.92, 1.0, (0.35 + 0.2 * layer) * tw))
			if layer == 2 and i % 5 == 0:
				# Destello en cruz de las estrellas más cercanas.
				s.draw_line(Vector2(px - 6, v * 720.0), Vector2(px + 6, v * 720.0), Color(1, 1, 1, 0.5 * tw), 1.5)
				s.draw_line(Vector2(px, v * 720.0 - 6), Vector2(px, v * 720.0 + 6), Color(1, 1, 1, 0.5 * tw), 1.5)
	# Estrellas fugaces: una cada pocos segundos, cruzando en diagonal.
	var cyc := fposmod(now, 4.0) / 1.2
	if cyc < 1.0:
		var sp := Vector2(1100.0 - cyc * 900.0, 90.0 + cyc * 280.0 + 60.0 * float(int(now / 4.0) % 3))
		s.draw_line(sp, sp + Vector2(70, -31), Color(1, 1, 1, 0.8 * (1.0 - cyc)), 3.0)

func _draw_game() -> void:
	var s := surface
	var cam := _s.x - WAVE_SCREEN_X / BLOCK
	var sx := func(x: float) -> float: return (x - cam) * BLOCK
	_draw_space(cam)
	# Paredes: muestras cada 2 bloques más cada vértice de la línea central visible.
	var vr := view_rect()
	var x_a := cam + vr.position.x / BLOCK - 2.0
	var x_b := cam + vr.end.x / BLOCK + 2.0
	var xs: Array = []
	var xx := x_a
	while xx <= x_b:
		xs.append(xx)
		xx += 2.0
	var k := _seg_index(maxf(x_a, 0.0)) + 1
	while k < _cx.size() and _cx[k] <= x_b:
		xs.append(_cx[k])
		k += 1
	xs.sort()
	var ceil_pts := PackedVector2Array()
	var floor_pts := PackedVector2Array()
	for x: float in xs:
		var c := center_at(x)
		var h := half_at(x)
		ceil_pts.append(Vector2(sx.call(x), _sy(c + h)))
		floor_pts.append(Vector2(sx.call(x), _sy(c - h)))
	var fill := Color(0.01, 0.005, 0.045, 0.96)
	var edge_c := _neon(_s.x, 0.0)          # techo
	var edge_f := _neon(_s.x, 0.16)         # suelo
	var edge := edge_c
	var top := vr.position.y - 20.0
	var bottom := vr.end.y + 20.0
	var cpoly := PackedVector2Array([Vector2(ceil_pts[0].x, top)])
	cpoly.append_array(ceil_pts)
	cpoly.append(Vector2(ceil_pts[ceil_pts.size() - 1].x, top))
	s.draw_colored_polygon(cpoly, fill)
	var fpoly := PackedVector2Array(floor_pts)
	fpoly.append(Vector2(floor_pts[floor_pts.size() - 1].x, bottom))
	fpoly.append(Vector2(floor_pts[0].x, bottom))
	s.draw_colored_polygon(fpoly, fill)
	# Rejilla dentro de las paredes (una línea por bloque entero).
	var gx := ceilf(x_a)
	while gx <= x_b:
		var c := center_at(gx)
		var h := half_at(gx)
		var px: float = sx.call(gx)
		s.draw_line(Vector2(px, top), Vector2(px, _sy(c + h)), Color(edge.r, edge.g, edge.b, 0.07), 2.0)
		s.draw_line(Vector2(px, _sy(c - h)), Vector2(px, bottom), Color(edge.r, edge.g, edge.b, 0.07), 2.0)
		gx += 1.0
	# Bordes de neón: campo de energía que se desvanece hacia el interior del pasillo + núcleo blanco.
	for wall in 2:
		var pts: PackedVector2Array = ceil_pts if wall == 0 else floor_pts
		var col: Color = edge_c if wall == 0 else edge_f
		var inward := 1.0 if wall == 0 else -1.0
		for band in 4:
			var shifted := PackedVector2Array()
			for p in pts:
				shifted.append(p + Vector2(0, inward * (8.0 + band * 11.0)))
			s.draw_polyline(shifted, Color(col.r, col.g, col.b, 0.20 - band * 0.045), 9.0, true)
		s.draw_polyline(pts, Color(col.r, col.g, col.b, 0.30), 16.0, true)
		s.draw_polyline(pts, col, 7.0, true)
		s.draw_polyline(pts, Color(1, 1, 1, 0.95), 2.5, true)
	# Estela de la onda (la línea en zigzag por la que ha pasado).
	if local_player != null:
		var tp := PackedVector2Array()
		for p: Vector2 in _path:
			tp.append(Vector2(sx.call(p.x), _sy(p.y)))
		tp.append(Vector2(WAVE_SCREEN_X, _sy(_s.y)))
		if tp.size() >= 2:
			var col := local_player.color
			s.draw_polyline(tp, Color(col.r, col.g, col.b, 0.28), 16.0, true)
			s.draw_polyline(tp, col, 7.0, true)
			s.draw_polyline(tp, Color(1, 1, 1, 0.9), 2.5, true)
	# Onda (o sus fragmentos si ha chocado).
	if local_player != null and not (_dead and not _timed_out):
		_draw_wave()
	for sh in _shards:
		var p: Vector2 = sh.pos
		var sz := float(sh.size) * BLOCK
		s.draw_set_transform(Vector2(float(sx.call(p.x)), _sy(p.y)), float(sh.rot), Vector2.ONE)
		var cc: Color = local_player.color if local_player != null else Palette.YELLOW
		s.draw_rect(Rect2(-sz * 0.5, -sz * 0.5, sz, sz), Color(cc.r, cc.g, cc.b, clampf(float(sh.life) * 1.5, 0.0, 1.0)))
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if _flash > 0.0:
		s.draw_rect(view_rect(), Color(1, 1, 1, _flash * 0.45))
	_draw_hud()

func _draw_wave() -> void:
	var s := surface
	var col := local_player.color
	var wc := Vector2(WAVE_SCREEN_X, _sy(_s.y))
	s.draw_circle(wc, 30.0, Color(col.r, col.g, col.b, 0.14))
	s.draw_circle(wc, 19.0, Color(col.r, col.g, col.b, 0.22))
	s.draw_set_transform(wc, -PI / 4.0 if _s.up else PI / 4.0, Vector2.ONE)
	var tri := PackedVector2Array([Vector2(20, 0), Vector2(-14, -13), Vector2(-6, 0), Vector2(-14, 13)])
	s.draw_colored_polygon(tri, col)
	s.draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[3], tri[0]]), Color(1, 1, 1, 0.95), 3.0, true)
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_hud() -> void:
	var s := surface
	var meters := int(_s.x)
	# Barra de progreso del pasillo (muy largo: se ve cuánto queda).
	var bar := Rect2(340, 30, 600, 18)
	s.rounded_rect(bar.grow(4), 12, Color(0, 0, 0, 0.45))
	var frac := clampf(_s.x / maxf(_level_end, 1.0), 0.0, 1.0)
	if frac > 0.0:
		s.rounded_rect(Rect2(bar.position, Vector2(maxf(bar.size.x * frac, 16.0), bar.size.y)), 9, Color(1, 1, 1, 0.92))
	s.text_centered(Vector2(640, 76), "%d m" % meters, 52, Color.WHITE, 8)
	s.text_centered(Vector2(640, 122), "pasillo %d%%" % roundi(100.0 * half_at(_s.x) / HALF_START), 24, Color(1, 1, 1, 0.8), 5)
	s.text_centered(Vector2(1130, 40), "%d s" % maxi(0, ceili(TIME_LIMIT - _time)), 34, Color(1, 1, 1, 0.85), 6)
	if _dead:
		var msg := "¡TIEMPO! %d m" % meters if _timed_out else "¡CHOCASTE! %d m" % meters
		s.text_centered(Vector2(640, 330), msg, 72, Palette.YELLOW, 12)
		if _death_t > 0.4:
			s.text_centered(Vector2(640, 410), "Más lejos = mejor posición", 30, Color(1, 1, 1, 0.85), 6)
