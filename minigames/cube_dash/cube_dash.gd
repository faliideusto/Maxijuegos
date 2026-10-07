extends Minigame
## Salto Neón (modelo LOCAL_PARALLEL): un cubo corre solo por un nivel larguísimo y tú solo
## decides cuándo saltar. Pinchos, bloques, huecos, plataformas, escaleras y pinchos de techo.
## Un único intento: gana quien llegue más lejos.
##
## EL NIVEL ES UNO SOLO, diseñado a mano (ver _level_script) e idéntico en todas las partidas y en
## todos los PC: no depende de ninguna semilla. Cada jugador lo corre en su PC sin ver a los demás; al
## chocar (o al agotarse el tiempo) llama a report_result(distancia) y el host ordena: más lejos =
## mejor. No hay nada de red aquí.
##
## El nivel se escribe como una lista de piezas ("S2", "G3", "R:up.hop1.end"...) y el código las
## coloca con la física real (un salto dura T_AIR s y recorre velocidad × T_AIR bloques; cada
## obstáculo se centra en el vértice del salto; el "descanso" entre saltos se fija por sección).
## Cada pieza declara los saltos de la solución de referencia. SIEMPRE PASABLE: tests/cube_level_test.gd
## corre un bot por todo el nivel, también con ±0,07 s de error en cada salto (más margen en las piezas
## estrechas y a más velocidad), y señala la pieza concreta que falle.
##
## Estética: inspirada en los "runners" de ritmo con neón (fondo degradado que cambia de color, suelo
## con línea brillante, bloques oscuros con borde luminoso, cubo con cara). Todo se dibuja por código
## con formas propias: no se usa ningún asset de terceros.

# --- Mundo (unidades: bloques; y hacia arriba, 0 = suelo) ---
const BLOCK := 48.0               # píxeles por bloque
const GROUND_Y := 570.0           # y (píxeles) de la superficie del suelo
const CUBE_SCREEN_X := 280.0      # x (píxeles) fija del cubo en pantalla
## Velocidad (bloques/s) según la distancia: puntos (x, velocidad) con interpolación lineal.
const SPEED_POINTS: Array[Vector2] = [Vector2(0, 9.5), Vector2(90, 11.0), Vector2(200, 12.5),
		Vector2(330, 14.0), Vector2(480, 15.5), Vector2(650, 16.5), Vector2(900, 17.5)]
const SPEED_MAX := 17.5
const TOL_FAR := 600.0            # distancia a la que el margen humano llega a su mínimo
const GRAVITY := 65.0             # bloques/s²
const JUMP_V := 17.0              # bloques/s → altura máx. ≈ 2,2 bloques
const T_AIR := 2.0 * JUMP_V / GRAVITY   # s que dura un salto sobre suelo llano (≈ 0,52)
const STEP := 1.0 / 120.0         # paso fijo de física
const ROT_SPEED := 6.0            # rad/s de giro en el aire (≈ 180° por salto)
const SKIN := 0.12                # holgura de las colisiones (el cubo "perdona" un poco)
const SPIKE_HALF_W := 0.17
const SPIKE_HEIGHT := 0.5
const FALL_DEATH_Y := -3.0
# --- Partida ---
const TIME_LIMIT := 100.0         # s; tope para que la partida no sea eterna
const LEVEL_TARGET := 2300.0      # bloques mínimos del nivel (inalcanzables en el tiempo límite)
const START_SAFE := 22.0          # bloques sin obstáculos al empezar
const DEATH_ANIM := 1.3           # s de animación antes de enviar el resultado
const JUMP_BUFFER := 0.1          # s: un toque corto antes de aterrizar cuenta

enum Kind { SPIKE, PLATFORM, GAP, CEILING }

class Obj:
	var kind: int
	var x: float
	var y: float
	var w: float
	var h: float
	var tag: String = ""

## Estado físico del cubo.
class PState:
	var cx: float = 0.0       # centro del cubo, en bloques desde el inicio
	var py: float = 0.0       # base del cubo
	var vy: float = 0.0
	var on_ground: bool = true
	var rot: float = 0.0
	var alive: bool = true

## Una pieza colocada: objetos + saltos de referencia + hasta dónde llega.
class Elem:
	var objs: Array[Obj] = []
	var jumps: Array[float] = []
	var end_x: float = 0.0
	var start_x: float = 0.0   # posición del primer despegue

var _objs: Array[Obj] = []            # ordenados por x
## Solución de referencia: posiciones (cx) en las que un jugador perfecto salta (la usa el bot).
var _jumps: Array[float] = []
var _pieces: Array[Dictionary] = []   # {"text","start","end"} de cada pieza (para depurar)
var _level_end: float = 0.0
var _max_w: float = 4.0               # ancho del objeto más ancho (ventana de búsqueda de colisiones)
var _bot_jump_idx: int = 0
## Solo pruebas: margen de error del bot (s, se aplica a cada salto) y control "sin saltar".
var debug_tol: float = 0.0
var debug_jump_offset: float = 0.0
var debug_never_jump: bool = false

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
	_build_level()
	surface.draw_callback = _draw_game

func _on_start() -> void:
	_s = PState.new()
	_time = 0.0
	_accum = 0.0
	_dead = false
	_timed_out = false

# ----------------------------------------------------------------------------
# EL NIVEL (diseñado a mano)
# ----------------------------------------------------------------------------
# Piezas:
#   S1 S2 S3        pinchos de 1, 2 o 3 casillas        B1 B2     bloques de 1 o 2 de ancho (1 de alto)
#   G2 G3 G4        huecos en el suelo                   R:ops     tramo de plataformas (ver abajo)
# Opciones tras la pieza (separadas por espacios):
#   rX              descanso (s) entre el aterrizaje anterior y el despegue de esta pieza
#   cT/N/C          N pinchos de techo que empiezan T s respecto al primer despegue de la pieza (T negativo =
#                   antes de despegar). La altura se calcula sola: la punta queda C bloques por encima del punto
#                   más alto que alcanza el cubo de referencia en esa zona (también con error de tiempo), así que
#                   siempre es pasable; cuanto menor C, más molesta. Conviene ponerlos justo tras despegar o antes de aterrizar.
# Tramos R:ops — saltas a la primera plataforma (altura 1) y encadenas operaciones separadas por "."
#   sp     pincho sobre la plataforma que hay que saltar        up     escalón adyacente (1 → 2)
#   hop1   salto sobre un vacío a una plataforma de altura 1     hop2   ídem a una de altura 2
#   down   bajada adyacente (2 → 1)       end   cae al suelo (se añade solo si falta)
# "@rest=X" cambia el descanso por defecto de las piezas siguientes (la rampa de dificultad).

## Frases que se repiten en el tramo final (maratón) con descansos mínimos.
const MARATHON: Array[Array] = [
	["S2", "R:sp.hop1.hop2.end", "G3", "S3 c0.05/2/0.35", "R:up.sp.down.hop1.end", "B2", "S3", "R:hop1.sp.hop2.down.end"],
	["G3", "S2", "R:up.hop1.sp.end", "S3", "G4", "B2", "R:hop2.hop1.hop1.end", "S3 c0.05/2/0.35"],
	["S3", "R:sp.up.down.sp.end", "G4", "S2", "R:hop1.hop2.hop1.end", "B2", "G3", "S3"],
]

func _level_script() -> Array[String]:
	var L: Array[String] = []
	# 1 · Calentamiento (pinchos y bloques sueltos): ~8 s
	L.append_array(["@rest=0.6", "S1", "B1", "S1", "S2", "B1", "S2"])
	# 2 · Huecos y primeras plataformas
	L.append_array(["@rest=0.45", "G2", "S1", "R:end", "B1", "R:sp.end", "G3", "S2"])
	# 3 · Escaleras
	L.append_array(["@rest=0.38", "R:up.end", "S1", "R:up.down.end", "B2", "R:sp.up.end", "G2", "S3"])
	# 4 · Saltar de plataforma en plataforma
	L.append_array(["@rest=0.32", "R:hop1.end", "S2", "R:hop2.end", "G3", "R:hop1.hop1.end", "S3", "R:up.hop1.end"])
	# 5 · Primeros pinchos de techo
	L.append_array(["@rest=0.27", "S1 c0.05/2/0.5", "B2", "S2 c0.45/2/0.5", "R:up.end c0.6/3/0.5", "S1 c0.05/3/0.4", "G3", "R:sp.hop1.end", "S3 c0.05/2/0.4"])
	# 6 · Combinaciones
	L.append_array(["@rest=0.22", "R:up.hop1.sp.end", "S3", "G3", "R:hop2.down.end", "S2 c0.05/2/0.4", "R:sp.up.down.end", "B2", "S3", "G4", "R:hop1.hop2.end"])
	# 7 · Ritmo rápido
	L.append_array(["@rest=0.18", "S2", "B2", "S2", "G3", "S1", "S3", "R:up.sp.end", "G3", "S2", "B2", "R:hop1.hop1.hop2.end", "S3"])
	# 8 · Todo junto, con techos
	L.append_array(["@rest=0.15", "R:sp.hop1.hop2.end", "S3 c0.05/2/0.35", "G3", "R:up.down.hop1.sp.end", "B2", "S2 c0.45/3/0.35", "G4", "R:hop2.hop1.sp.end", "S3"])
	# 9 · Maratón: descansos mínimos (0,13 → 0,10 s) y frases que se repiten hasta el final
	var rest := 0.13
	var round_i := 0
	var cursor_estimate := 0.0
	while cursor_estimate < LEVEL_TARGET:
		L.append("@rest=%s" % snappedf(maxf(0.10, rest), 0.01))
		for piece in MARATHON[round_i % MARATHON.size()]:
			L.append(piece)
			cursor_estimate += 13.0   # estimación basta: el nivel real se corta al llegar al objetivo
		rest -= 0.01
		round_i += 1
	return L

## Velocidad del cubo en la posición x (interpolación lineal entre SPEED_POINTS).
func speed_at(x: float) -> float:
	var n := SPEED_POINTS.size()
	if x <= SPEED_POINTS[0].x:
		return SPEED_POINTS[0].y
	for i in range(1, n):
		if x <= SPEED_POINTS[i].x:
			var a := SPEED_POINTS[i - 1]
			var b := SPEED_POINTS[i]
			return lerpf(a.y, b.y, (x - a.x) / (b.x - a.x))
	return SPEED_POINTS[n - 1].y

## Margen de error humano garantizado (± s) según la distancia: de 0,13 s a 0,07 s.
func tol_at(x: float) -> float:
	return lerpf(0.13, 0.07, clampf(x / TOL_FAR, 0.0, 1.0))

# ----------------------------------------------------------------------------
# Colocación de las piezas con la física
# ----------------------------------------------------------------------------

func _build_level() -> void:
	_objs.clear()
	_jumps.clear()
	_pieces.clear()
	_max_w = 4.0
	_bot_jump_idx = 0
	var cursor := START_SAFE          # el cubo está en el suelo en este punto
	var default_rest := 1.0
	for text in _level_script():
		if text.begins_with("@rest="):
			default_rest = float(text.substr(6))
			_pieces.append({"text": text, "start": cursor, "end": cursor})
			continue
		var start := cursor
		cursor = _lay(text, cursor, default_rest)
		_pieces.append({"text": text, "start": start, "end": cursor})
		if cursor >= LEVEL_TARGET + 40.0:
			break
	_level_end = cursor
	_s = PState.new()

func _insert(o: Obj) -> void:
	var i := _objs.size()
	while i > 0 and _objs[i - 1].x > o.x:
		i -= 1
	_objs.insert(i, o)
	_max_w = maxf(_max_w, o.w)

func _mk(kind: int, x: float, y: float, w: float, h: float, tag: String) -> Obj:
	var o := Obj.new()
	o.kind = kind
	o.x = x
	o.y = y
	o.w = w
	o.h = h
	o.tag = tag
	return o

## Tiempo (desde el despegue) en que el cubo vuelve a estar a `dh` bloques por encima del despegue,
## ya descendiendo (dh > 0: aterriza en algo más alto; dh < 0: en algo más bajo).
func _t_land(dh: float) -> float:
	return (JUMP_V + sqrt(JUMP_V * JUMP_V - 2.0 * GRAVITY * dh)) / GRAVITY

## Coloca una pieza partiendo de `cursor` (cubo en el suelo) y devuelve dónde acaba.
func _lay(text: String, cursor: float, default_rest: float) -> float:
	var toks := text.split(" ", false)
	var kind := toks[0]
	var rest := default_rest
	var ceilings: Array = []
	for i in range(1, toks.size()):
		var t := toks[i]
		if t.begins_with("r"):
			rest = float(t.substr(1))
		elif t.begins_with("c"):
			var p := t.substr(1).split("/")
			ceilings.append([float(p[0]), float(p[1]), float(p[2])])
	var v := speed_at(cursor + 6.0)
	var el := Elem.new()
	if kind.begins_with("R:"):
		_el_run(kind.substr(2).split(".", false), cursor, v, rest, tol_at(cursor), el)
	else:
		_el_cluster(kind, cursor, v, rest, el)
	for o in el.objs:
		_insert(o)
	_jumps.append_array(el.jumps)
	if not ceilings.is_empty():
		_add_ceilings(ceilings, cursor, v, el)
	return el.end_x

## Coloca los pinchos de techo de la pieza. La altura de la punta se calcula con la trayectoria del
## cubo de referencia (sin error y con ±margen de tiempo): C bloques por encima del punto más alto que
## alcanza en la zona del techo. Así siempre es pasable y, con C pequeña, castiga saltar demasiado
## pronto o demasiado tarde.
func _add_ceilings(ceilings: Array, cursor: float, v: float, el: Elem) -> void:
	var margin := v * (tol_at(cursor) + 0.02)
	var traces: Array = []
	for shift in [0.0, margin, -margin]:
		traces.append(_trace_top(cursor, el.jumps, shift, el.end_x))
	for c in ceilings:
		var x0 := el.start_x + v * float(c[0])
		var n := int(c[1])
		var max_top := 0.0
		for tr: Array in traces:
			for p: Vector2 in tr:
				if p.x > x0 - 0.05 and p.x < x0 + n + 0.05:
					max_top = maxf(max_top, p.y)
		var tip := snappedf(max_top + float(c[2]), 0.1)
		if tip > 5.5:
			continue   # demasiado alto para molestar: no se pone
		for k in n:
			_insert(_mk(Kind.CEILING, x0 + k, tip, 1, 1, "ceiling"))

## Recorre la pieza con el cubo de referencia (saltos desplazados `shift` bloques) y devuelve la altura
## de la parte superior del cubo (la que toca el techo) en cada posición.
func _trace_top(start_x: float, jumps: Array[float], shift: float, end_x: float) -> Array:
	var s := PState.new()
	s.cx = start_x
	var out: Array = []
	var idx := 0
	for i in 8000:
		var jump := false
		if idx < jumps.size() and s.cx >= jumps[idx] + shift and s.on_ground:
			jump = true
			idx += 1
		_step_state(s, STEP, jump)
		out.append(Vector2(s.cx, s.py + 1.0 - SKIN))
		if not s.alive or (idx >= jumps.size() and s.cx > end_x and s.on_ground and s.py < 0.001):
			break
	return out

## Obstáculo suelto (pinchos, bloques o hueco) que se salva con un salto centrado en él.
func _el_cluster(kind: String, cursor: float, v: float, rest: float, el: Elem) -> void:
	var air := v * T_AIR
	var s0 := cursor + v * rest
	var c := s0 + air * 0.5   # centro del obstáculo = vértice del salto
	el.start_x = s0
	match kind:
		"S1": el.objs.append(_mk(Kind.SPIKE, c - 0.5, 0, 1, 1, kind))
		"S2":
			el.objs.append(_mk(Kind.SPIKE, c - 1.0, 0, 1, 1, kind))
			el.objs.append(_mk(Kind.SPIKE, c, 0, 1, 1, kind))
		"S3":
			for i in 3:
				el.objs.append(_mk(Kind.SPIKE, c - 1.5 + i, 0, 1, 1, kind))
		"B1": el.objs.append(_mk(Kind.PLATFORM, c - 0.5, 0, 1, 1, kind))
		"B2": el.objs.append(_mk(Kind.PLATFORM, c - 1.0, 0, 2, 1, kind))
		"G2": el.objs.append(_mk(Kind.GAP, c - 1.0, 0, 2, 0, kind))
		"G3": el.objs.append(_mk(Kind.GAP, c - 1.5, 0, 3, 0, kind))
		"G4": el.objs.append(_mk(Kind.GAP, c - 2.0, 0, 4, 0, kind))
		_: push_error("Pieza desconocida: %s" % kind)
	el.jumps.append(s0)
	el.end_x = s0 + air + 0.5

## Tramo de plataformas: saltas a la primera (altura 1) y encadenas operaciones; acaba cayendo al suelo.
func _el_run(ops: PackedStringArray, cursor: float, v: float, rest: float, tol: float, el: Elem) -> void:
	var air := v * T_AIR
	var m := v * (tol + 0.02)              # margen en bloques: error humano + cuantización por frame (1/60 s)
	var s := cursor + v * rest             # despegue desde el suelo
	el.jumps.append(s)
	el.start_x = s
	var h := 1
	var landing := s + v * _t_land(1.0)    # aterrizaje en la primera plataforma
	var a := landing - 1.0 - m             # inicio de la plataforma actual
	for op in ops:
		if op == "end":
			continue
		var takeoff := landing + v * rest
		match op:
			"sp":
				# Pincho sobre la plataforma: se salta sin salir de ella.
				el.objs.append(_mk(Kind.SPIKE, takeoff + air * 0.5 - 0.5, h, 1, 1, "plat_spike"))
				el.jumps.append(takeoff)
				landing = takeoff + air
			"up":
				if h != 1:
					push_error("'up' solo desde altura 1")
				var a_next := takeoff + m + 0.38 + 0.056 * v + 0.2
				el.objs.append(_mk(Kind.PLATFORM, a, 0, a_next - a, h, "stairs"))
				el.jumps.append(takeoff)
				landing = takeoff + v * _t_land(1.0)
				a = a_next
				h = 2
			"down":
				if h != 2:
					push_error("'down' solo desde altura 2")
				var b := landing + 1.0 + m + v * rest
				el.objs.append(_mk(Kind.PLATFORM, a, 0, b - a, h, "stairs"))
				a = b
				h = 1
				landing = b + 0.38 + v * 0.175 + 0.1
			"hop1", "hop2":
				var next_h := 1 if op == "hop1" else 2
				var landing_next := takeoff + v * _t_land(float(next_h - h))
				var b := takeoff + 0.38 + m + 0.2
				var a_next := landing_next - 1.0 - m
				if a_next - b < 1.0:
					push_error("Hueco demasiado corto en la pieza %s" % ".".join(ops))
				el.objs.append(_mk(Kind.PLATFORM, a, 0, b - a, h, "hop"))
				el.objs.append(_mk(Kind.GAP, b, 0, a_next - b, 0, "hop"))
				el.jumps.append(takeoff)
				landing = landing_next
				a = a_next
				h = next_h
			_:
				push_error("Operación desconocida: %s" % op)
	var b_end := landing + 1.0 + m + v * rest
	el.objs.append(_mk(Kind.PLATFORM, a, 0, b_end - a, h, "run"))
	el.end_x = b_end + 0.38 + v * 0.3 + 0.3   # tiempo de caer al suelo antes de la siguiente pieza

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
	var i := _lower_bound(cx - _max_w - 1.0)
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
	var i := _lower_bound(s.cx - _max_w - 1.0)
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
		elif o.kind == Kind.CEILING:
			# Punta hacia abajo: mata cualquier parte del cubo que llegue a su altura.
			var sx := o.x + 0.5
			if r > sx - SPIKE_HALF_W and l < sx + SPIKE_HALF_W and t > o.y:
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
	if _time >= TIME_LIMIT or _s.cx >= _level_end:
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
# IA del autopiloto: sigue la solución de referencia del nivel
# ----------------------------------------------------------------------------

## Posición de despegue de la marca i, con el error de prueba aplicado.
func _jump_at(i: int) -> float:
	return _jumps[i] + debug_jump_offset + debug_tol * speed_at(_jumps[i])

## ¿Debe saltar ahora el bot? Salta al llegar a cada marca de _jumps (si está en el suelo).
func _bot_wants_jump(s: PState) -> bool:
	while _bot_jump_idx < _jumps.size() and _jump_at(_bot_jump_idx) < s.cx - 1.0:
		_bot_jump_idx += 1
	if _bot_jump_idx >= _jumps.size() or not s.on_ground or not s.alive or debug_never_jump:
		return false
	if s.cx >= _jump_at(_bot_jump_idx):
		_bot_jump_idx += 1
		return true
	return false

func _bot_action_held(_player: PlayerData) -> bool:
	return _bot_wants_jump(_s)

# --- Resultado simulado de un bot / desconectado (lo calcula el host) ---
func _bot_result(_player: PlayerData, r: RandomNumberGenerator) -> Dictionary:
	return {"score": r.randf_range(60.0, 520.0), "tiebreak": 0.0}

# --- Plausibilidad: no se puede llegar más lejos que velocidad máxima × tiempo límite ---
func _validate_result(score: float, _tiebreak: float) -> bool:
	return score >= 0.0 and score <= SPEED_MAX * (TIME_LIMIT + 3.0) + 1.0

# ----------------------------------------------------------------------------
# Utilidades de depuración / pruebas (tests/cube_level_test.gd)
# ----------------------------------------------------------------------------

## Corre el nivel entero con el bot (sin límite de tiempo) y devuelve hasta dónde llegó. Si muere,
## indica la pieza del guion en la que murió.
func debug_bot_run() -> Dictionary:
	_build_level()
	_bot_jump_idx = 0
	var s := _s
	var steps := 0
	while s.alive and s.cx < _level_end and steps < 200000:
		var jump := _bot_wants_jump(s)
		for i in 2:
			_step_state(s, STEP, jump)
		steps += 2
	var piece := ""
	if not s.alive:
		for p in _pieces:
			if s.cx >= float(p["start"]) - 1.0 and s.cx <= float(p["end"]):
				piece = "%s (x=%.0f..%.0f)" % [p["text"], p["start"], p["end"]]
				break
	var info := "py=%.2f vy=%.1f ground=%s cx=%.2f" % [s.py, s.vy, s.on_ground, s.cx]
	if not s.alive:
		var k := _lower_bound(s.cx - 6.0)
		while k < _objs.size() and _objs[k].x < s.cx + 3.0:
			var o := _objs[k]
			info += "
      obj %s kind=%d x=%.2f w=%.2f y=%.2f h=%.2f" % [o.tag, o.kind, o.x, o.w, o.y, o.h]
			k += 1
	return {"distance": s.cx, "alive": s.alive, "end": _level_end, "piece": piece, "info": info}

func debug_level_end() -> float:
	_build_level()
	return _level_end

func debug_piece_count() -> int:
	_build_level()
	return _pieces.size()

## Recuento de objetos por etiqueta (variedad del nivel).
func debug_tag_counts() -> Dictionary:
	_build_level()
	var counts := {}
	for o in _objs:
		counts[o.tag] = int(counts.get(o.tag, 0)) + 1
	return counts

func debug_signature() -> String:
	_build_level()
	var parts: PackedStringArray = []
	for o in _objs:
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
	var i0 := _lower_bound(cam - _max_w - 1.0)
	var i1 := i0
	while i1 < _objs.size() and _objs[i1].x < cam + 32.0:
		i1 += 1
	# Huecos del suelo (se pintan encima del suelo, hasta el borde inferior).
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
			var r := Rect2(bx, GROUND_Y - o.h * BLOCK, o.w * BLOCK, o.h * BLOCK)
			s.draw_rect(r, fill)
			# Rejilla de bloques dentro de la plataforma.
			var cells := int(ceil(o.w))
			for k in range(1, cells):
				s.draw_line(Vector2(bx + k * BLOCK, r.position.y), Vector2(bx + k * BLOCK, r.end.y), Color(edge.r, edge.g, edge.b, 0.18), 2.0)
			for k in range(1, int(o.h)):
				s.draw_line(Vector2(bx, GROUND_Y - k * BLOCK), Vector2(bx + o.w * BLOCK, GROUND_Y - k * BLOCK), Color(edge.r, edge.g, edge.b, 0.18), 2.0)
			s.draw_rect(r.grow(-3), Color(edge.r, edge.g, edge.b, 0.30), false, 2.0)
			s.draw_rect(r, edge, false, 3.0)
		elif o.kind == Kind.SPIKE:
			var px: float = sx.call(o.x)
			var base_y := GROUND_Y - o.y * BLOCK
			var tri := PackedVector2Array([Vector2(px + 2, base_y), Vector2(px + BLOCK * 0.5, base_y - BLOCK + 2), Vector2(px + BLOCK - 2, base_y)])
			s.draw_colored_polygon(tri, fill)
			s.draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]), edge, 3.0, true)
		elif o.kind == Kind.CEILING:
			var px: float = sx.call(o.x)
			var tip_y := GROUND_Y - o.y * BLOCK
			var base_y := tip_y - BLOCK * 0.5
			# Bloque de techo (hasta el borde superior) y pincho apuntando hacia abajo.
			s.draw_rect(Rect2(px, -10, BLOCK, base_y + 10), fill)
			s.draw_rect(Rect2(px, -10, BLOCK, base_y + 10), edge, false, 3.0)
			var tri := PackedVector2Array([Vector2(px + 3, base_y), Vector2(px + BLOCK - 3, base_y), Vector2(px + BLOCK * 0.5, tip_y)])
			s.draw_colored_polygon(tri, fill)
			s.draw_polyline(PackedVector2Array([tri[0], tri[2], tri[1], tri[0]]), edge, 3.0, true)
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
	var frac := clampf(_s.cx / maxf(_level_end, 1.0), 0.0, 1.0)
	if frac > 0.0:
		s.rounded_rect(Rect2(bar.position, Vector2(maxf(bar.size.x * frac, 16.0), bar.size.y)), 9, Color(1, 1, 1, 0.92))
	s.text_centered(Vector2(640, 76), "%d m" % meters, 52, Color.WHITE, 8)
	s.text_centered(Vector2(640, 122), "velocidad ×%.1f" % (speed_at(_s.cx) / SPEED_POINTS[0].y), 24, Color(1, 1, 1, 0.8), 5)
	s.text_centered(Vector2(1130, 40), "%d s" % maxi(0, ceili(TIME_LIMIT - _time)), 34, Color(1, 1, 1, 0.85), 6)
	if _dead:
		var msg := "¡TIEMPO! %d m" % meters if _timed_out else "¡CHOCASTE! %d m" % meters
		s.text_centered(Vector2(640, 300), msg, 72, Palette.YELLOW, 12)
		if _death_t > 0.4:
			s.text_centered(Vector2(640, 380), "Más lejos = mejor posición", 30, Color(1, 1, 1, 0.85), 6)

## Vuelca objetos y saltos de referencia entre x0 y x1 (para depurar una pieza concreta).
func debug_dump(x0: float, x1: float) -> String:
	_build_level()
	var out := ""
	for o in _objs:
		if o.x + o.w >= x0 and o.x <= x1:
			out += "  obj %-10s kind=%d x=%.2f..%.2f y=%.2f h=%.2f\n" % [o.tag, o.kind, o.x, o.x + o.w, o.y, o.h]
	for j in _jumps:
		if j >= x0 and j <= x1:
			out += "  salto en %.2f\n" % j
	return out

## Traza del bot entre x0 y x1 (estado del cubo cada ~0,5 bloques).
func debug_trace(x0: float, x1: float) -> String:
	_build_level()
	_bot_jump_idx = 0
	var s := _s
	var out := ""
	var last := -100.0
	while s.alive and s.cx < x1:
		var jump := _bot_wants_jump(s)
		if jump:
			out += "  >> SALTA en cx=%.2f (py=%.2f)\n" % [s.cx, s.py]
		for i in 2:
			_step_state(s, STEP, jump)
		if s.cx >= x0 and s.cx - last >= 0.5:
			last = s.cx
			out += "  cx=%.2f py=%.2f vy=%.1f suelo=%s vivo=%s\n" % [s.cx, s.py, s.vy, s.on_ground, s.alive]
	out += "  FIN: cx=%.2f py=%.2f vivo=%s\n" % [s.cx, s.py, s.alive]
	return out

## Línea de tiempo del nivel para un jugador perfecto: (texto, x, segundos) de cada marcador de sección.
func debug_timeline() -> Array:
	_build_level()
	var out: Array = []
	var t := 0.0
	var x := 0.0
	for p in _pieces:
		var target := float(p["start"])
		while x < target:
			var step := minf(1.0, target - x)
			t += step / speed_at(x + step * 0.5)
			x += step
		if String(p["text"]).begins_with("@rest="):
			out.append([p["text"], target, t, speed_at(target)])
	return out
