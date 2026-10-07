extends Minigame
## Salto Neón (modelo LOCAL_PARALLEL): un cubo corre solo por un nivel larguísimo y tú solo
## decides cuándo saltar. Pinchos, bloques y huecos. Un único intento: gana quien llegue más lejos.
##
## Cada jugador corre en su PC sin ver a los demás. El nivel es procedural y determinista: sale del
## generador `_level_rng`, sembrado con la semilla común del host, así que todos corren el MISMO
## nivel. Al chocar (o al agotarse el tiempo) se llama a report_result(distancia) y el host ordena:
## más lejos = mejor. No hay nada de red aquí.
##
## Estética: inspirada en el estilo de los "runners" de ritmo con neón (fondo degradado que cambia
## de color, suelo con línea brillante, bloques oscuros con borde luminoso, cubo con cara). Todo se
## dibuja por código con formas propias: no se usa ningún asset de terceros.

# --- Mundo (unidades: bloques; y hacia arriba, 0 = suelo) ---
const BLOCK := 48.0               # píxeles por bloque
const GROUND_Y := 570.0           # y (píxeles) de la superficie del suelo
const CUBE_SCREEN_X := 330.0      # x (píxeles) fija del cubo en pantalla
const SPEED_MIN := 9.0            # bloques por segundo al empezar
const SPEED_MAX := 14.5           # bloques por segundo al final de la rampa
const RAMP_LENGTH := 500.0        # bloques hasta alcanzar la velocidad y la dificultad máximas
const GRAVITY := 65.0             # bloques/s²
const JUMP_V := 17.0              # bloques/s → altura máx. ≈ 2,2 bloques, alcance ≈ 4,7 bloques
const STEP := 1.0 / 120.0         # paso fijo de física
const T_AIR := 2.0 * JUMP_V / GRAVITY   # s que dura un salto sobre suelo llano (≈ 0,52)
const ROT_SPEED := 6.0            # rad/s de giro en el aire (≈ 180° por salto)
const SKIN := 0.12                # holgura de las colisiones (el cubo "perdona" un poco)
const SPIKE_HALF_W := 0.17
const SPIKE_HEIGHT := 0.5
const FALL_DEATH_Y := -3.0
# --- Partida ---
const TIME_LIMIT := 100.0         # s; tope para que la partida no sea eterna
const LEVEL_LENGTH := 12000.0     # bloques: el nivel "completo" (inalcanzable en el tiempo límite)
const START_SAFE := 22.0          # bloques sin obstáculos al empezar
const DEATH_ANIM := 1.3           # s de animación antes de enviar el resultado
const JUMP_BUFFER := 0.1          # s: un toque corto antes de aterrizar cuenta

enum Kind { SPIKE, PLATFORM, GAP }

class Obj:
	var kind: int
	var x: float
	var y: float
	var w: float
	var h: float
	var tag: String = ""

## Estado físico del cubo (se copia para simular hacia delante).
class PState:
	var cx: float = 0.0       # centro del cubo, en bloques desde el inicio
	var py: float = 0.0       # base del cubo
	var vy: float = 0.0
	var on_ground: bool = true
	var rot: float = 0.0
	var alive: bool = true
	func dup() -> PState:
		var c := PState.new()
		c.cx = cx
		c.py = py
		c.vy = vy
		c.on_ground = on_ground
		c.rot = rot
		c.alive = alive
		return c

var _objs: Array[Obj] = []
## Posición (cx) donde aterriza el cubo tras el último salto planificado por el generador.
var _land_x: float = START_SAFE
## Solución de referencia: posiciones (cx) en las que un jugador perfecto salta. Las usa el bot.
var _jumps: Array[float] = []
var _bot_jump_idx: int = 0
## Solo pruebas: desplaza todos los saltos del bot (bloques) o los desactiva.
var debug_jump_offset: float = 0.0
var debug_never_jump: bool = false
var _level_rng := RandomNumberGenerator.new()
var _s := PState.new()
var _time: float = 0.0
var _accum: float = 0.0
var _jump_buffer: float = 0.0
var _dead: bool = false
var _timed_out: bool = false
var _death_t: float = 0.0
var _shards: Array = []
var _trail: Array = []
var _trail_t: float = 0.0
var _flash: float = 0.0

func _on_prepare() -> void:
	_reset_level()
	surface.draw_callback = _draw_game

func _on_start() -> void:
	_s = PState.new()
	_time = 0.0
	_accum = 0.0
	_dead = false
	_timed_out = false

func _reset_level() -> void:
	_objs.clear()
	_jumps.clear()
	_bot_jump_idx = 0
	_land_x = START_SAFE
	_level_rng.seed = seed_value ^ 0x5bd1e995   # derivado de la semilla común
	_s = PState.new()
	_ensure_level(60.0)

# ----------------------------------------------------------------------------
# Generación procedural del nivel (determinista: mismo flujo para todos)
# ----------------------------------------------------------------------------

func _ensure_level(until_x: float) -> void:
	while _land_x < until_x:
		_gen_next()

func _add(kind: int, x: float, y: float, w: float, h: float, tag: String) -> void:
	var o := Obj.new()
	o.kind = kind
	o.x = x
	o.y = y
	o.w = w
	o.h = h
	o.tag = tag
	_objs.append(o)   # siempre en orden de x creciente

## Velocidad del cubo en la posición x: sube de SPEED_MIN a SPEED_MAX a lo largo de RAMP_LENGTH.
func speed_at(x: float) -> float:
	return lerpf(SPEED_MIN, SPEED_MAX, smoothstep(0.0, RAMP_LENGTH, x))

## Añade el siguiente obstáculo ("cluster": pinchos, bloques o hueco). El nivel es una CADENA de
## obstáculos que se salvan con un salto cada uno. La colocación sale de la física:
##   - un salto dura T_AIR s y recorre `air = velocidad × T_AIR` bloques;
##   - el cubo aterriza en _land_x; el siguiente salto empieza al menos `rest` segundos después;
##   - el obstáculo se centra donde estaría el vértice del salto: centro = inicio + air/2.
## `rest` (el margen que le queda al jugador entre saltos) baja de ~0,6 s a 0,12 s con la
## distancia, y la velocidad sube a la vez: cuanto más lejos, menos tiempo de reacción. Como la
## ventana de cada salto es de ~0,4 s (más ancha cuanto más rápido, porque el cubo cruza antes el
## obstáculo), es SIEMPRE superable con tiempos humanos, pero cada vez exige más precisión.
func _gen_next() -> void:
	var d := clampf(_land_x / RAMP_LENGTH, 0.0, 1.0)
	var v := speed_at(_land_x + 5.0)
	var air := v * T_AIR
	var rest := lerpf(0.55, 0.12, pow(d, 0.85)) + (1.0 - d) * _level_rng.randf_range(0.0, 0.7)
	var c := _land_x + v * rest + air * 0.5   # centro del obstáculo
	var pool: Array[String] = ["spike1", "block1"]
	if d >= 0.03: pool.append_array(["spike2", "block2"])
	if d >= 0.10: pool.append("gap2")
	if d >= 0.25: pool.append("spike3")
	if d >= 0.35: pool.append("gap3")
	if d >= 0.5: pool.append_array(["spike2", "spike3", "gap3"])   # más peso a lo difícil
	var pick: String = pool[_level_rng.randi() % pool.size()]
	match pick:
		"spike1":
			_add(Kind.SPIKE, c - 0.5, 0, 1, 1, pick)
		"spike2":
			_add(Kind.SPIKE, c - 1.0, 0, 1, 1, pick)
			_add(Kind.SPIKE, c, 0, 1, 1, pick)
		"spike3":
			for i in 3:
				_add(Kind.SPIKE, c - 1.5 + i, 0, 1, 1, pick)
		"block1":
			_add(Kind.PLATFORM, c - 0.5, 0, 1, 1, pick)
		"block2":
			_add(Kind.PLATFORM, c - 1.0, 0, 2, 1, pick)
		"gap2":
			_add(Kind.GAP, c - 1.0, 0, 2, 0, pick)
		"gap3":
			_add(Kind.GAP, c - 1.5, 0, 3, 0, pick)
	# Solución de referencia: saltar al inicio del vuelo centrado en el obstáculo (la usa el bot).
	_jumps.append(c - air * 0.5)
	_land_x = c + air * 0.5

## Primer índice de objeto con x >= x_min (los objetos están ordenados por x).
func _lower_bound(x_min: float) -> int:
	var lo := 0
	var hi := _objs.size()
	while lo < hi:
		var mid := (lo + hi) >> 1
		if _objs[mid].x < x_min:
			lo = mid + 1
		else:
			hi = mid
	return lo

# ----------------------------------------------------------------------------
# Física (función pura sobre un PState: la usan el jugador y el bot)
# ----------------------------------------------------------------------------

func _step_state(s: PState, dt: float, jump: bool) -> void:
	if not s.alive:
		return
	if jump and s.on_ground:
		s.vy = JUMP_V
		s.on_ground = false
	var prev_py := s.py
	s.cx += speed_at(s.cx) * dt
	s.vy -= GRAVITY * dt
	s.py += s.vy * dt
	_ensure_level(s.cx + 45.0)
	s.on_ground = false
	if s.vy <= 0.0:
		var top := _support_top(s.cx, prev_py)
		if s.py <= top:
			s.py = top
			s.vy = 0.0
			s.on_ground = true
	if s.on_ground:
		s.rot = roundf(s.rot / (PI * 0.5)) * (PI * 0.5)
	else:
		s.rot += ROT_SPEED * dt
	if _collides(s) or s.py < FALL_DEATH_Y:
		s.alive = false

## Altura de la superficie que sostiene al cubo (o -1000 si no hay). El suelo no sostiene a un
## cubo que ya cayó por debajo de él (hueco) ni si está del todo dentro de un hueco.
func _support_top(cx: float, prev_py: float) -> float:
	var l := cx - 0.5 + SKIN
	var r := cx + 0.5 - SKIN
	var best := -1000.0
	var ground := prev_py >= -0.02
	var i := _lower_bound(cx - 10.0)
	while i < _objs.size():
		var o := _objs[i]
		if o.x > cx + 2.0:
			break
		if o.kind == Kind.GAP:
			if l >= o.x and r <= o.x + o.w:
				ground = false
		elif o.kind == Kind.PLATFORM:
			if r > o.x and l < o.x + o.w and o.h <= prev_py + 0.02:
				best = maxf(best, o.h)
		i += 1
	if ground:
		best = maxf(best, 0.0)
	return best

func _collides(s: PState) -> bool:
	var l := s.cx - 0.5 + SKIN
	var r := s.cx + 0.5 - SKIN
	var b := s.py + SKIN
	var t := s.py + 1.0 - SKIN
	var i := _lower_bound(s.cx - 10.0)
	while i < _objs.size():
		var o := _objs[i]
		if o.x > s.cx + 2.0:
			break
		if o.kind == Kind.PLATFORM:
			if r > o.x and l < o.x + o.w and b < o.h and t > 0.0:
				return true
		elif o.kind == Kind.SPIKE:
			var sx := o.x + 0.5
			if r > sx - SPIKE_HALF_W and l < sx + SPIKE_HALF_W and b < o.y + SPIKE_HEIGHT and t > o.y:
				return true
		i += 1
	return false

# ----------------------------------------------------------------------------
# Jugador local (LOCAL_PARALLEL)
# ----------------------------------------------------------------------------

func _play(delta: float) -> void:
	if _dead or local_player == null:
		return
	_time += delta
	var held := action_held(local_player)
	if not InputManager.is_simulated(local_player.id):
		# Un toque corto justo antes de aterrizar también cuenta.
		if action_presses(local_player) > 0:
			_jump_buffer = JUMP_BUFFER
		_jump_buffer = maxf(0.0, _jump_buffer - delta)
		held = held or _jump_buffer > 0.0
	_accum += delta
	var steps := 0
	while _accum >= STEP and steps < 12:
		_accum -= STEP
		steps += 1
		_step_state(_s, STEP, held)
		if not _s.alive:
			_die()
			return
	if _time >= TIME_LIMIT:
		_timed_out = true
		_dead = true   # deja de jugar; se envía el resultado tras una breve pausa
		_death_t = 0.0

func _die() -> void:
	_dead = true
	_death_t = 0.0
	_flash = 1.0
	var center := Vector2(_s.cx, _s.py + 0.5)
	for i in 14:
		var a := randf() * TAU
		_shards.append({"pos": center, "vel": Vector2.from_angle(a) * randf_range(2.0, 9.0) + Vector2(0, 5.0),
				"size": randf_range(0.12, 0.3), "rot": randf() * TAU, "life": 1.0})

func _animate(delta: float) -> void:
	_flash = maxf(0.0, _flash - delta * 2.5)
	if _dead:
		_death_t += delta
		if _death_t >= DEATH_ANIM and not _reported:
			report_result(_s.cx)   # distancia recorrida: más lejos = mejor
	elif is_running and _s.alive and _s.on_ground:
		_trail_t -= delta
		if _trail_t <= 0.0:
			_trail_t = 0.035
			_trail.append({"pos": Vector2(_s.cx - 0.45, _s.py + 0.05), "life": 1.0})
	for sh in _shards:
		sh.vel.y -= 28.0 * delta
		sh.pos += sh.vel * delta
		sh.rot += 6.0 * delta
		sh.life -= delta * 0.8
	_shards = _shards.filter(func(x: Dictionary) -> bool: return x.life > 0.0)
	for tr in _trail:
		tr.life -= delta * 3.0
	_trail = _trail.filter(func(x: Dictionary) -> bool: return x.life > 0.0)

# ----------------------------------------------------------------------------
# IA del autopiloto: sigue la solución de referencia que declara el generador
# ----------------------------------------------------------------------------

## ¿Debe saltar ahora el bot? Salta al llegar a cada marca de _jumps (si está en el suelo).
func _bot_wants_jump(s: PState) -> bool:
	# Descarta marcas que ya quedaron muy atrás (por si se perdió una).
	while _bot_jump_idx < _jumps.size() and _jumps[_bot_jump_idx] + debug_jump_offset < s.cx - 1.0:
		_bot_jump_idx += 1
	if _bot_jump_idx >= _jumps.size() or not s.on_ground or not s.alive:
		return false
	if debug_never_jump:
		return false
	if s.cx >= _jumps[_bot_jump_idx] + debug_jump_offset:
		_bot_jump_idx += 1
		return true
	return false

func _bot_action_held(_player: PlayerData) -> bool:
	return _bot_wants_jump(_s)

# --- Resultado simulado de un bot / desconectado (lo calcula el host) ---
func _bot_result(_player: PlayerData, r: RandomNumberGenerator) -> Dictionary:
	return {"score": r.randf_range(40.0, 420.0), "tiebreak": 0.0}

# --- Plausibilidad: no se puede llegar más lejos que SPEED × tiempo límite ---
func _validate_result(score: float, _tiebreak: float) -> bool:
	return score >= 0.0 and score <= SPEED_MAX * (TIME_LIMIT + 3.0) + 1.0

# ----------------------------------------------------------------------------
# Utilidades de depuración / pruebas (tests/cube_level_test.gd)
# ----------------------------------------------------------------------------

## Corre el nivel entero con el bot y devuelve la distancia alcanzada (y la etiqueta del patrón
## donde murió, si murió).
func debug_bot_run(p_seed: int) -> Dictionary:
	configure(MinigameMeta.ExecutionMode.LOCAL_PARALLEL, p_seed, null)
	_reset_level()
	var s := _s
	var t := 0.0
	while t < TIME_LIMIT and s.alive:
		var jump := _bot_wants_jump(s)
		for i in 2:
			_step_state(s, STEP, jump)
		t += 1.0 / 60.0
	var where := ""
	if not s.alive:
		var i := _lower_bound(s.cx - 3.0)
		var best := INF
		while i < _objs.size() and _objs[i].x < s.cx + 3.0:
			var dist := absf(_objs[i].x - s.cx)
			if dist < best:
				best = dist
				where = _objs[i].tag
			i += 1
	return {"distance": s.cx, "alive": s.alive, "where": where}

## Firma del nivel hasta `until` bloques (para comprobar el determinismo).
func debug_level_signature(p_seed: int, until: float) -> String:
	configure(MinigameMeta.ExecutionMode.LOCAL_PARALLEL, p_seed, null)
	_reset_level()
	_ensure_level(until)
	var parts: PackedStringArray = []
	for o in _objs:
		if o.x <= until:
			parts.append("%d:%s:%s:%s:%s" % [o.kind, o.x, o.y, o.w, o.h])
	return "|".join(parts)

# ----------------------------------------------------------------------------
# Dibujo
# ----------------------------------------------------------------------------

func _bg_color(dist: float, value: float) -> Color:
	# El color del fondo deriva despacio con la distancia (azul → violeta → turquesa...).
	var h := 0.60 + 0.15 * sin(dist / 120.0) + 0.05 * sin(dist / 47.0)
	return Color.from_hsv(fposmod(h, 1.0), 0.78, value)

func _draw_game() -> void:
	var s := surface
	var dist := _s.cx
	var cam := _s.cx - CUBE_SCREEN_X / BLOCK
	var sx := func(x: float) -> float: return (x - cam) * BLOCK
	var top_c := _bg_color(dist, 0.98)
	var bot_c := _bg_color(dist, 0.52)
	s.draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(1280, 0), Vector2(1280, 720), Vector2(0, 720)]),
			PackedColorArray([top_c, top_c, bot_c, bot_c]))
	# Fondo con paralaje: columnas translúcidas que se desplazan más lento que el nivel.
	for i in 9:
		var px := fposmod(i * 190.0 - cam * BLOCK * 0.22, 1500.0) - 110.0
		var hh := 140.0 + (i % 3) * 90.0
		s.draw_rect(Rect2(px, GROUND_Y - hh, 110.0, hh), Color(1, 1, 1, 0.045 + 0.02 * (i % 2)))
	# Suelo: relleno oscuro, rejilla que se desplaza y línea brillante con halo.
	var ground_c := bot_c.darkened(0.6)
	s.draw_rect(Rect2(0, GROUND_Y, 1280, 720.0 - GROUND_Y), ground_c)
	var gx := fposmod(-cam * BLOCK, BLOCK)
	for i in 28:
		s.draw_line(Vector2(gx + i * BLOCK, GROUND_Y), Vector2(gx + i * BLOCK, 720), Color(1, 1, 1, 0.06), 2.0)
	var line_c := top_c.lightened(0.55)
	# Huecos del suelo (se pintan encima del suelo, hasta el borde inferior).
	var i0 := _lower_bound(cam - 10.0)
	var i1 := i0
	while i1 < _objs.size() and _objs[i1].x < cam + 32.0:
		i1 += 1
	for i in range(i0, i1):
		var o := _objs[i]
		if o.kind == Kind.GAP:
			var gxp: float = sx.call(o.x)
			s.draw_rect(Rect2(gxp, GROUND_Y - 1, o.w * BLOCK, 720.0 - GROUND_Y + 1), bot_c.darkened(0.8))
			s.draw_rect(Rect2(gxp - 3, GROUND_Y - 1, 3, 720.0 - GROUND_Y + 1), line_c)
			s.draw_rect(Rect2(gxp + o.w * BLOCK, GROUND_Y - 1, 3, 720.0 - GROUND_Y + 1), line_c)
	# Línea del suelo con halo, interrumpida en los huecos.
	var segs: Array = [Vector2(0.0, 1280.0)]
	for i in range(i0, i1):
		var o := _objs[i]
		if o.kind == Kind.GAP:
			var a: float = sx.call(o.x)
			var b: float = a + o.w * BLOCK
			var next: Array = []
			for sg: Vector2 in segs:
				if b <= sg.x or a >= sg.y:
					next.append(sg)
				else:
					if a > sg.x: next.append(Vector2(sg.x, a))
					if b < sg.y: next.append(Vector2(b, sg.y))
			segs = next
	for sg: Vector2 in segs:
		s.draw_rect(Rect2(sg.x, GROUND_Y - 14, sg.y - sg.x, 16), Color(line_c.r, line_c.g, line_c.b, 0.16))
		s.draw_rect(Rect2(sg.x, GROUND_Y - 3, sg.y - sg.x, 6), line_c)
	# Obstáculos.
	var edge := Color(0.82, 0.97, 1.0)
	var fill := Color(0.03, 0.03, 0.10)
	for i in range(i0, i1):
		var o := _objs[i]
		if o.kind == Kind.PLATFORM:
			var bx: float = sx.call(o.x)
			var cells_w := int(o.w)
			var cells_h := int(o.h)
			for cx in cells_w:
				for cy in cells_h:
					var r := Rect2(bx + cx * BLOCK, GROUND_Y - (cy + 1) * BLOCK, BLOCK, BLOCK)
					s.draw_rect(r, fill)
					s.draw_rect(r.grow(-2), Color(edge.r, edge.g, edge.b, 0.30), false, 2.0)
					s.draw_rect(r, edge, false, 3.0)
		elif o.kind == Kind.SPIKE:
			var px: float = sx.call(o.x)
			var base_y := GROUND_Y - o.y * BLOCK
			var tri := PackedVector2Array([Vector2(px + 2, base_y), Vector2(px + BLOCK * 0.5, base_y - BLOCK + 2), Vector2(px + BLOCK - 2, base_y)])
			s.draw_colored_polygon(tri, fill)
			s.draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]), edge, 3.0, true)
	# Estela del cubo.
	for tr in _trail:
		var p: Vector2 = tr.pos
		var a := float(tr.life) * 0.5
		var sz := 10.0 * float(tr.life)
		s.draw_rect(Rect2(float(sx.call(p.x)) - sz * 0.5, GROUND_Y - p.y * BLOCK - sz, sz, sz), Color(1, 1, 1, a))
	# Cubo (o sus fragmentos si ha chocado).
	if local_player != null and not (_dead and not _timed_out):
		_draw_cube()
	for sh in _shards:
		var p: Vector2 = sh.pos
		var sz := float(sh.size) * BLOCK
		s.draw_set_transform(Vector2(float(sx.call(p.x)), GROUND_Y - p.y * BLOCK), float(sh.rot), Vector2.ONE)
		var cc: Color = local_player.color if local_player != null else Palette.YELLOW
		s.draw_rect(Rect2(-sz * 0.5, -sz * 0.5, sz, sz), Color(cc.r, cc.g, cc.b, clampf(float(sh.life) * 1.5, 0.0, 1.0)))
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if _flash > 0.0:
		s.draw_rect(Rect2(0, 0, 1280, 720), Color(1, 1, 1, _flash * 0.45))
	_draw_hud()

func _draw_cube() -> void:
	var s := surface
	var c := Vector2(CUBE_SCREEN_X, GROUND_Y - (_s.py + 0.5) * BLOCK)
	var size := BLOCK * 0.96
	var col := local_player.color
	s.draw_set_transform(c, _s.rot, Vector2.ONE)
	s.draw_rect(Rect2(-size * 0.5, -size * 0.5, size, size), Color(0.02, 0.02, 0.08))
	s.draw_rect(Rect2(-size * 0.5 + 3, -size * 0.5 + 3, size - 6, size - 6), col)
	s.draw_rect(Rect2(-size * 0.5 + 9, -size * 0.5 + 9, size - 18, size - 18), col.lightened(0.28))
	s.draw_rect(Rect2(-size * 0.5 + 3, -size * 0.5 + 3, size - 6, size - 6), Color(1, 1, 1, 0.55), false, 2.0)
	# Cara: dos ojos y boca.
	s.draw_rect(Rect2(-size * 0.28, -size * 0.2, size * 0.17, size * 0.2), Color(0.02, 0.02, 0.08))
	s.draw_rect(Rect2(size * 0.11, -size * 0.2, size * 0.17, size * 0.2), Color(0.02, 0.02, 0.08))
	s.draw_rect(Rect2(-size * 0.26, size * 0.12, size * 0.52, size * 0.1), Color(0.02, 0.02, 0.08))
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_hud() -> void:
	var s := surface
	var meters := int(_s.cx)
	# Barra de progreso del nivel (muy largo: se ve cuánto queda).
	var bar := Rect2(340, 30, 600, 18)
	s.rounded_rect(bar.grow(4), 12, Color(0, 0, 0, 0.45))
	var frac := clampf(_s.cx / LEVEL_LENGTH, 0.0, 1.0)
	if frac > 0.0:
		s.rounded_rect(Rect2(bar.position, Vector2(maxf(bar.size.x * frac, 16.0), bar.size.y)), 9, Color(1, 1, 1, 0.92))
	s.text_centered(Vector2(640, 76), "%d m" % meters, 52, Color.WHITE, 8)
	s.text_centered(Vector2(640, 122), "velocidad ×%.1f" % (speed_at(_s.cx) / SPEED_MIN), 24, Color(1, 1, 1, 0.8), 5)
	s.text_centered(Vector2(1130, 40), "%d s" % maxi(0, ceili(TIME_LIMIT - _time)), 34, Color(1, 1, 1, 0.85), 6)
	if _dead:
		var msg := "¡TIEMPO! %d m" % meters if _timed_out else "¡CHOCASTE! %d m" % meters
		s.text_centered(Vector2(640, 300), msg, 72, Palette.YELLOW, 12)
		if _death_t > 0.4:
			s.text_centered(Vector2(640, 380), "Más lejos = mejor posición", 30, Color(1, 1, 1, 0.85), 6)
