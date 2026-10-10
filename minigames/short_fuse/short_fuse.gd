extends Minigame
## Mecha Corta: todos en un laberinto de cajas. Tu botón planta un petardo que estalla en cruz a los 2,4 s: revienta
## cajas (algunas esconden mejoras) y elimina a quien pille, tú incluido. Gana el último en pie.
## Se adapta al nº de jugadores (tablero de 11×9 a 17×11 y más o menos tiempo). Al acabarse el tiempo, el tablero se
## va cerrando en espiral desde fuera para forzar el final.
##
## Sin lógica de red: el host simula (_simulate) y los clientes dibujan el estado que reciben (_apply_state); las
## explosiones, eliminaciones y recogidas llegan como eventos. Ver core/minigame.gd.

# Contenido de una celda.
const EMPTY := 0
const PILLAR := 1     # muro fijo
const CRATE := 2      # caja que se puede reventar
const BLOCK := 3      # bloque caído en el cierre final
const PU_BOMB := 4    # mejora: +1 petardo a la vez
const PU_FIRE := 5    # mejora: +1 de alcance
const PU_SPEED := 6   # mejora: más velocidad

const BOMB_FUSE := 2.4
const CHAIN_DELAY := 0.1      # un petardo alcanzado por otro estalla casi al instante
const FLAME_TIME := 0.5
const START_BOMBS := 1
const START_FIRE := 2
const START_SPEED := 3.6      # celdas por segundo
const MAX_BOMBS := 5
const MAX_FIRE := 6
const MAX_SPEED := 5.6
const SPEED_STEP := 0.5
const CRATE_DENSITY := 0.78
const POWERUP_CHANCE := 0.34
const BASE_TIME := 45.0       # duración antes del cierre: BASE_TIME + TIME_PER_PLAYER × jugadores
const TIME_PER_PLAYER := 5.0
const CLOSE_EVERY := 0.24     # el cierre final tapa una celda cada tanto
const CLOSE_WARN := 4         # celdas avisadas por adelantado
const END_TIME := 1.8
const PLAYER_R := 0.38        # radio del avatar, en celdas
const SMOOTHING := 20.0       # (clientes) suavizado de la posición mostrada
const FLOATS_PER_TOKEN := 8   # x, y, fx, fy, vivo, petardos, alcance, velocidad
const FLOATS_PER_BOMB := 4    # x, y, mecha, dueño
const INTS_PER_FLAME := 4     # x, y, dueño, ms restantes
const BOARD_AREA := Rect2(40, 112, 1200, 596)
const DIRS: Array[Vector2i] = [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]
const CRATE_COLOR := Color("E8A15C")
const CRATE_DARK := Color("B9743A")
const FLOOR_A := Color("E1DAFF")
const FLOOR_B := Color("D2C9FA")

class Token:
	var player: PlayerData
	var idx: int = 0
	var pos: Vector2               # en celdas (los centros de celda son enteros)
	var net_pos: Vector2           # (clientes) última posición real recibida
	var facing: Vector2 = Vector2.DOWN
	var alive: bool = true
	var max_bombs: int = START_BOMBS
	var fire: int = START_FIRE
	var speed: float = START_SPEED
	var last_horiz: bool = true
	var walk: float = 0.0
	var dead_t: float = 0.0
	var bot_path: Array[Vector2i] = []
	var bot_timer: float = 0.0
	var bot_bomb: bool = false
	var bot_react: float = 0.3     # tarda esto en "ver" un petardo ajeno recién puesto

class Bomb:
	var cell: Vector2i
	var fuse: float = BOMB_FUSE
	var fire: int = START_FIRE
	var owner: int = 0
	var age: float = 0.0
	var passers: Array[int] = []   # jugadores que aún están encima y pueden salir de ella

class Spark:
	var pos: Vector2
	var vel: Vector2
	var color: Color
	var size: float = 5.0
	var age: float = 0.0
	var life: float = 0.5

var cols: int = 13
var rows: int = 11
var _grid: PackedByteArray = PackedByteArray()
var _tokens: Array[Token] = []
var _bombs: Array[Bomb] = []
var _bomb_at: Dictionary = {}      # Vector2i -> Bomb
var _flames: Dictionary = {}       # Vector2i -> [segundos restantes, dueño]
var _death_groups: Array = []      # grupos de ids por orden de eliminación (mismo instante = empate)
var _time_left: float = 60.0
var _closing: bool = false
var _close_order: Array[Vector2i] = []
var _close_i: int = 0
var _close_t: float = 0.0
var _over: bool = false
var _over_t: float = 0.0
var _winner: int = -1              # índice del ganador (-1 = empate)
var _clock: float = 0.0
var _got_state: bool = false
var _sparks: Array[Spark] = []
var _block_anim: Dictionary = {}   # Vector2i -> edad de la caída (animación)
var _shake: float = 0.0
var _last_sec: int = 999
var _danger_cache: Dictionary = {}
var _danger_stamp: float = -1.0
var _cs: float = 50.0              # tamaño de celda en píxeles
var _origin: Vector2 = Vector2.ZERO
var _boxes: Dictionary = {}

# ----------------------------------------------------------------------------
# Preparación
# ----------------------------------------------------------------------------

## Tamaño del tablero (columnas, filas; siempre impares) según el nº de jugadores.
static func board_size(n: int) -> Vector2i:
	if n <= 2:
		return Vector2i(11, 9)
	if n <= 4:
		return Vector2i(13, 11)
	if n <= 6:
		return Vector2i(15, 11)
	return Vector2i(17, 11)

## Casillas de salida: primero las 4 esquinas y luego los centros de los lados.
static func spawn_cells(c: int, r: int) -> Array[Vector2i]:
	var mx := (c / 2) - ((c / 2) % 2)   # columna par más cercana al centro (libre de muros)
	var my := (r / 2) - ((r / 2) % 2)
	return [Vector2i(0, 0), Vector2i(c - 1, r - 1), Vector2i(c - 1, 0), Vector2i(0, r - 1),
			Vector2i(mx, 0), Vector2i(mx, r - 1), Vector2i(0, my), Vector2i(c - 1, my)]

static func match_time(n: int) -> float:
	return BASE_TIME + TIME_PER_PLAYER * n

func _on_prepare() -> void:
	var n := players.size()
	var size := board_size(n)
	cols = size.x
	rows = size.y
	_cs = floorf(minf(58.0, minf(BOARD_AREA.size.x / (cols + 0.6), BOARD_AREA.size.y / (rows + 0.6))))
	_origin = BOARD_AREA.get_center() - Vector2(cols, rows) * _cs * 0.5
	_time_left = match_time(n)
	var spawns := spawn_cells(cols, rows)
	for i in n:
		var t := Token.new()
		t.player = players[i]
		t.idx = i
		t.pos = Vector2(spawns[i % spawns.size()])
		t.net_pos = t.pos
		t.facing = (Vector2(cols - 1, rows - 1) * 0.5 - t.pos).normalized()
		t.bot_react = rng.randf_range(0.2, 0.7)
		t.bot_timer = rng.randf_range(0.3, 0.9)
		_tokens.append(t)
	_build_grid(spawns.slice(0, n))
	_close_order = _spiral()
	surface.draw_callback = _draw_game

# Muros fijos en las celdas impar-impar, hueco libre alrededor de cada salida y cajas en casi todo lo demás.
# Usa `rng` (semilla común): todos los PC ven el mismo tablero ya en la cuenta atrás.
func _build_grid(spawns: Array[Vector2i]) -> void:
	_grid.resize(cols * rows)
	for y in rows:
		for x in cols:
			var c := Vector2i(x, y)
			var v := EMPTY
			if x % 2 == 1 and y % 2 == 1:
				v = PILLAR
			else:
				var near_spawn := false
				for s in spawns:
					if absi(s.x - x) + absi(s.y - y) <= 2:
						near_spawn = true
				if not near_spawn and rng.randf() < CRATE_DENSITY:
					v = CRATE
			_grid[_gi(c)] = v

# Orden del cierre final: espiral desde el borde hacia el centro (saltando los muros fijos).
func _spiral() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var x0 := 0
	var y0 := 0
	var x1 := cols - 1
	var y1 := rows - 1
	while x0 <= x1 and y0 <= y1:
		for x in range(x0, x1 + 1):
			out.append(Vector2i(x, y0))
		for y in range(y0 + 1, y1 + 1):
			out.append(Vector2i(x1, y))
		if y1 > y0:
			for x in range(x1 - 1, x0 - 1, -1):
				out.append(Vector2i(x, y1))
		if x1 > x0:
			for y in range(y1 - 1, y0, -1):
				out.append(Vector2i(x0, y))
		x0 += 1
		y0 += 1
		x1 -= 1
		y1 -= 1
	return out.filter(func(c: Vector2i) -> bool: return _grid[_gi(c)] != PILLAR)

# ----------------------------------------------------------------------------
# Utilidades de tablero
# ----------------------------------------------------------------------------

func _gi(c: Vector2i) -> int:
	return c.y * cols + c.x

func _in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < cols and c.y < rows

func cell_at(c: Vector2i) -> int:
	return _grid[_gi(c)] if _in_bounds(c) else PILLAR

func _cell_of(pos: Vector2) -> Vector2i:
	return Vector2i(roundi(pos.x), roundi(pos.y))

func _is_solid(c: Vector2i) -> bool:
	var v := cell_at(c)
	return v == PILLAR or v == CRATE or v == BLOCK

## ¿Puede entrar ese jugador en la celda? (los petardos cortan el paso, salvo el que aún tienes debajo)
func _passable(c: Vector2i, t: Token) -> bool:
	if _is_solid(c):
		return false
	var b: Bomb = _bomb_at.get(c)
	return b == null or (t != null and b.passers.has(t.idx))

## Celdas que alcanza una explosión: el centro y cada brazo hasta un muro (no incluido) o una caja (incluida).
func blast_cells(center: Vector2i, fire: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = [center]
	for d in DIRS:
		for i in range(1, fire + 1):
			var c := center + d * i
			var v := cell_at(c)
			if v == PILLAR or v == BLOCK:
				break
			out.append(c)
			if v == CRATE:
				break
	return out

func alive_count() -> int:
	var n := 0
	for t in _tokens:
		if t.alive:
			n += 1
	return n

func _active_bombs(idx: int) -> int:
	var n := 0
	for b in _bombs:
		if b.owner == idx:
			n += 1
	return n

func _token_of(player: PlayerData) -> Token:
	for t in _tokens:
		if t.player == player:
			return t
	return null

# ----------------------------------------------------------------------------
# Simulación (solo host)
# ----------------------------------------------------------------------------

func _simulate(delta: float) -> void:
	_clock += delta
	if _over:
		_over_t += delta
		_update_flames(delta)
		if _over_t >= END_TIME:
			finish(_ranking())
		return
	_time_left = maxf(0.0, _time_left - delta)
	for t in _tokens:
		if not t.alive:
			continue
		if InputManager.is_simulated(t.player.id):
			t.bot_timer -= delta
			if t.bot_timer <= 0.0:
				t.bot_timer = randf_range(0.14, 0.26)
				_bot_think(t)
		_move_token(t, move_input(t.player), delta)
		if action_just_pressed(t.player):
			_place_bomb(t)
		_pick_up(t)
	_update_bombs(delta)
	_update_flames(delta)
	_update_closing(delta)
	_check_deaths()
	if alive_count() <= 1:
		_over = true
		_winner = -1
		for t in _tokens:
			if t.alive:
				_winner = t.idx
		send_event("over", _winner)
		DevCli.log_event("short_fuse over winner=%d" % _winner)

func _move_token(t: Token, dir: Vector2, delta: float) -> void:
	if dir.length() < 0.3:
		return
	var dist := t.speed * delta
	var ax := Vector2i(signi(roundi(dir.x * 10.0)), 0)
	var ay := Vector2i(0, signi(roundi(dir.y * 10.0)))
	var want_x := absf(dir.x) > 0.3
	var want_y := absf(dir.y) > 0.3
	var moved := false
	if want_x and want_y:
		# En diagonal: primero se intenta girar (el eje contrario al que llevaba), sin ayuda de esquina.
		var turn := ay if t.last_horiz else ax
		var keep := ax if t.last_horiz else ay
		moved = _try_axis(t, turn, dist, false) or _try_axis(t, keep, dist, true) or _try_axis(t, turn, dist, true)
	elif want_x:
		moved = _try_axis(t, ax, dist, true)
	elif want_y:
		moved = _try_axis(t, ay, dist, true)
	if absf(dir.x) >= absf(dir.y):
		t.facing = Vector2(ax)
	else:
		t.facing = Vector2(ay)
	if moved:
		t.walk += dist

# Avanza `dist` por un eje. Si el jugador está a medias entre dos celdas en el otro eje, primero se centra en la que
# tenga salida (ayuda de esquina). Devuelve false si no pudo moverse.
func _try_axis(t: Token, axis: Vector2i, dist: float, assist: bool) -> bool:
	var horiz := axis.x != 0
	var s := axis.x if horiz else axis.y
	var along := t.pos.x if horiz else t.pos.y
	var cross := t.pos.y if horiz else t.pos.x
	var cc := roundi(cross)
	var ca := roundi(along)
	var off := cross - cc
	if absf(off) > 0.001:
		var goal := cc
		if not _passable(_ac(horiz, ca + s, cc), t):
			var far := cc + (1 if off > 0.0 else -1)
			if not assist or not _passable(_ac(horiz, ca + s, far), t):
				return false
			goal = far
		elif not assist and absf(off) > dist * 1.5:
			return false
		cross = move_toward(cross, float(goal), dist)
		along = float(ca)
	else:
		cross = float(cc)
		var na := along + s * dist
		if not _passable(_ac(horiz, ca + s, cc), t):
			if (along - ca) * s >= 0.0:
				return false
			if (na - ca) * s > 0.0:
				na = float(ca)
		along = na
	t.pos = Vector2(along, cross) if horiz else Vector2(cross, along)
	t.last_horiz = horiz
	return true

func _ac(horiz: bool, a: int, c: int) -> Vector2i:
	return Vector2i(a, c) if horiz else Vector2i(c, a)

## Planta un petardo en la celda del jugador (si le quedan y la celda está libre).
func _place_bomb(t: Token) -> bool:
	var c := _cell_of(t.pos)
	if not t.alive or _over or _active_bombs(t.idx) >= t.max_bombs or _bomb_at.has(c) or cell_at(c) != EMPTY:
		return false
	var b := Bomb.new()
	b.cell = c
	b.fire = t.fire
	b.owner = t.idx
	for o in _tokens:
		if o.alive and _overlaps(o, c):
			b.passers.append(o.idx)
	_bombs.append(b)
	_bomb_at[c] = b
	send_event("place", t.idx)
	return true

func _overlaps(t: Token, c: Vector2i) -> bool:
	return absf(t.pos.x - c.x) < 0.98 and absf(t.pos.y - c.y) < 0.98

func _pick_up(t: Token) -> void:
	var c := _cell_of(t.pos)
	var v := cell_at(c)
	if v < PU_BOMB:
		return
	match v:
		PU_BOMB: t.max_bombs = mini(MAX_BOMBS, t.max_bombs + 1)
		PU_FIRE: t.fire = mini(MAX_FIRE, t.fire + 1)
		PU_SPEED: t.speed = minf(MAX_SPEED, t.speed + SPEED_STEP)
	_grid[_gi(c)] = EMPTY
	send_event("pick", [t.idx, v])

func _update_bombs(delta: float) -> void:
	for b in _bombs:
		b.fuse -= delta
		b.age += delta
		for i in range(b.passers.size() - 1, -1, -1):
			var o := _tokens[b.passers[i]]
			if not o.alive or not _overlaps(o, b.cell):
				b.passers.remove_at(i)
	for b in _bombs.duplicate():
		if b.fuse <= 0.0 and _bombs.has(b):
			_explode(b)

func _explode(b: Bomb) -> void:
	_bombs.erase(b)
	_bomb_at.erase(b.cell)
	var cells := blast_cells(b.cell, b.fire)
	var broken := PackedInt32Array()
	for c in cells:
		var v := cell_at(c)
		if v == CRATE:
			var drop := EMPTY
			if randf() < POWERUP_CHANCE:
				var roll := randf()
				drop = PU_BOMB if roll < 0.4 else (PU_FIRE if roll < 0.8 else PU_SPEED)
			_grid[_gi(c)] = drop
			broken.append(c.x)
			broken.append(c.y)
		elif v >= PU_BOMB:
			_grid[_gi(c)] = EMPTY   # una mejora al descubierto se quema
		_flames[c] = [FLAME_TIME, b.owner]
		var other: Bomb = _bomb_at.get(c)
		if other != null:
			other.fuse = minf(other.fuse, CHAIN_DELAY)
	send_event("boom", [b.cell.x, b.cell.y, b.owner, broken])

func _update_flames(delta: float) -> void:
	for c in _flames.keys():
		_flames[c][0] -= delta
		if _flames[c][0] <= 0.0:
			_flames.erase(c)

func _update_closing(delta: float) -> void:
	if not _closing:
		if _time_left > 0.0:
			return
		_closing = true
		_close_t = CLOSE_EVERY * CLOSE_WARN
		send_event("closing")
	_close_t -= delta
	while _close_t <= 0.0 and _close_i < _close_order.size():
		_close_t += CLOSE_EVERY
		var c := _close_order[_close_i]
		_close_i += 1
		_grid[_gi(c)] = BLOCK
		_flames.erase(c)
		var b: Bomb = _bomb_at.get(c)
		if b != null:
			_bombs.erase(b)
			_bomb_at.erase(c)
		send_event("close", [c.x, c.y])

func _check_deaths() -> void:
	var group: Array = []
	for t in _tokens:
		if not t.alive:
			continue
		var c := _cell_of(t.pos)
		if _flames.has(c) or cell_at(c) == BLOCK:
			t.alive = false
			group.append(t.player.id)
			send_event("die", t.idx)
	if not group.is_empty():
		_death_groups.append(group)

## Clasificación: el superviviente y, detrás, los eliminados del último al primero.
func _ranking() -> Array[int]:
	var out: Array[int] = []
	for t in _tokens:
		if t.alive:
			out.append(t.player.id)
	for i in range(_death_groups.size() - 1, -1, -1):
		for id in _death_groups[i]:
			out.append(id)
	return out

## Los que caen en el mismo instante comparten puesto.
func _result_groups() -> Array:
	return _death_groups.filter(func(g: Array) -> bool: return g.size() > 1)

# ----------------------------------------------------------------------------
# Bots
# ----------------------------------------------------------------------------

func _bot_move(player: PlayerData) -> Vector2:
	var t := _token_of(player)
	if t == null or not t.alive:
		return Vector2.ZERO
	while not t.bot_path.is_empty() and (Vector2(t.bot_path[0]) - t.pos).length() < 0.06:
		t.bot_path.pop_front()
	var target := Vector2(t.bot_path[0]) if not t.bot_path.is_empty() else Vector2(_cell_of(t.pos))
	var d := target - t.pos
	if d.length() < 0.04:
		return Vector2.ZERO
	return Vector2(signf(d.x), 0) if absf(d.x) >= absf(d.y) else Vector2(0, signf(d.y))

func _bot_action(player: PlayerData) -> int:
	var t := _token_of(player)
	if t == null or not t.bot_bomb:
		return 0
	t.bot_bomb = false
	return 1

# Mapa de peligro: celda -> segundos hasta que arda (0 = ya arde). Cuenta las reacciones en cadena y las celdas que
# el cierre final va a tapar enseguida. `viewer`: sus despistes (no ve los petardos ajenos recién puestos).
func _danger_map(viewer: Token) -> Dictionary:
	var fuse := {}
	for b in _bombs:
		if viewer != null and b.owner != viewer.idx and b.age < viewer.bot_react:
			continue
		fuse[b] = b.fuse
	var changed := true
	while changed:
		changed = false
		for b in fuse:
			for c in blast_cells(b.cell, b.fire):
				var o: Bomb = _bomb_at.get(c)
				if o != null and o != b and fuse.has(o) and fuse[o] > fuse[b] + CHAIN_DELAY:
					fuse[o] = fuse[b] + CHAIN_DELAY
					changed = true
	var danger := {}
	for b in fuse:
		for c in blast_cells(b.cell, b.fire):
			danger[c] = minf(danger.get(c, 99.0), maxf(0.01, fuse[b]))
	for c in _flames:
		danger[c] = 0.0
	if _closing:
		for i in range(_close_i, mini(_close_i + 7, _close_order.size())):
			var c := _close_order[i]
			danger[c] = minf(danger.get(c, 99.0), maxf(0.01, _close_t + (i - _close_i) * CLOSE_EVERY))
	return danger

# Recorrido en anchura desde `start`. Devuelve {celda: celda anterior} en orden de distancia. Con `through` se puede
# cruzar una celda en peligro si da tiempo a salir de ella antes de que arda; sin él, solo celdas seguras.
func _reach(t: Token, start: Vector2i, danger: Dictionary, through: bool) -> Dictionary:
	var prev := {start: start}
	var dist := {start: 0}
	var queue: Array[Vector2i] = [start]
	var qi := 0
	while qi < queue.size():
		var c := queue[qi]
		qi += 1
		for d in DIRS:
			var nc := c + d
			if prev.has(nc) or not _passable(nc, t):
				continue
			if danger.has(nc):
				if not through or danger[nc] < (dist[c] + 2.0) / t.speed + 0.15:
					continue
			prev[nc] = c
			dist[nc] = dist[c] + 1
			queue.append(nc)
	return prev

func _path_to(prev: Dictionary, goal: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var c := goal
	while prev[c] != c:
		path.push_front(c)
		c = prev[c]
	return path

func _bot_think(t: Token) -> void:
	var here := _cell_of(t.pos)
	var danger := _danger_map(t)
	t.bot_bomb = false
	if danger.has(here):
		# En peligro: a la celda segura más cercana.
		t.bot_path = []
		var esc := _reach(t, here, danger, true)
		for c in esc:
			if not danger.has(c):
				t.bot_path = _path_to(esc, c)
				break
		return
	var reach := _reach(t, here, danger, false)
	var can_bomb := _active_bombs(t.idx) < t.max_bombs
	var goal := here
	var goal_kind := 0   # 0 = nada, 1 = mejora, 2 = sitio para plantar
	var steps := 0
	for c in reach:
		steps += 1
		if cell_at(c) >= PU_BOMB:
			goal = c
			goal_kind = 1
			break
		if goal_kind == 0 and can_bomb and cell_at(c) == EMPTY and not _bomb_at.has(c) and _bomb_value(t, c) > 0 \
				and _has_escape(t, c, danger):
			goal = c
			goal_kind = 2
			if steps > 12:
				break
	if goal_kind == 2 and goal == here:
		t.bot_bomb = true
		# Y a correr: la huida se calcula con el petardo ya puesto.
		var d2 := danger.duplicate()
		for c in blast_cells(here, t.fire):
			d2[c] = minf(d2.get(c, 99.0), BOMB_FUSE)
		var esc := _reach(t, here, d2, true)
		t.bot_path = []
		for c in esc:
			if not d2.has(c):
				t.bot_path = _path_to(esc, c)
				break
		t.bot_timer = 0.3
		return
	if goal_kind == 0:
		# Nada que hacer cerca: acercarse al rival más próximo sin salir de lo seguro.
		var best := 9999
		for c in reach:
			for o in _tokens:
				if o.alive and o != t:
					var oc := _cell_of(o.pos)
					var m := absi(oc.x - c.x) + absi(oc.y - c.y)
					if m < best and m >= 2:
						best = m
						goal = c
	t.bot_path = _path_to(reach, goal)

# Lo que rinde plantar en `c`: cajas que revienta y rivales a tiro.
func _bomb_value(t: Token, c: Vector2i) -> int:
	var value := 0
	var cells := blast_cells(c, t.fire)
	for bc in cells:
		if cell_at(bc) == CRATE:
			value += 1
	for o in _tokens:
		if o.alive and o != t and cells.has(_cell_of(o.pos)):
			value += 3
	return value

# ¿Podría ponerse a salvo tras plantar en `c`?
func _has_escape(t: Token, c: Vector2i, danger: Dictionary) -> bool:
	var d2 := danger.duplicate()
	for bc in blast_cells(c, t.fire):
		d2[bc] = minf(d2.get(bc, 99.0), BOMB_FUSE)
	var esc := _reach(t, c, d2, true)
	for e in esc:
		if not d2.has(e):
			return true
	return false

# ----------------------------------------------------------------------------
# Estado hacia los clientes
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var toks := PackedFloat32Array()
	for t in _tokens:
		toks.append_array(PackedFloat32Array([t.pos.x, t.pos.y, t.facing.x, t.facing.y,
				1.0 if t.alive else 0.0, float(t.max_bombs), float(t.fire), t.speed]))
	var bombs := PackedFloat32Array()
	for b in _bombs:
		bombs.append_array(PackedFloat32Array([float(b.cell.x), float(b.cell.y), b.fuse, float(b.owner)]))
	var flames := PackedInt32Array()
	for c in _flames:
		flames.append_array(PackedInt32Array([c.x, c.y, int(_flames[c][1]), int(_flames[c][0] * 1000.0)]))
	return {"t": _time_left, "g": _grid, "k": toks, "b": bombs, "f": flames,
			"ci": _close_i if _closing else -1, "ct": _close_t, "o": _over, "w": _winner}

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	_time_left = float(state.get("t", _time_left))
	var g: Variant = state.get("g")
	if g is PackedByteArray and g.size() == cols * rows:
		_grid = g
	var toks: Variant = state.get("k")
	if toks is PackedFloat32Array and toks.size() >= _tokens.size() * FLOATS_PER_TOKEN:
		for i in _tokens.size():
			var t := _tokens[i]
			var o := i * FLOATS_PER_TOKEN
			t.net_pos = Vector2(toks[o], toks[o + 1])
			t.facing = Vector2(toks[o + 2], toks[o + 3])
			t.alive = toks[o + 4] > 0.5
			t.max_bombs = int(toks[o + 5])
			t.fire = int(toks[o + 6])
			t.speed = toks[o + 7]
			if not _got_state:
				t.pos = t.net_pos
		_got_state = true
	var bombs: Variant = state.get("b")
	if bombs is PackedFloat32Array:
		_bombs.clear()
		_bomb_at.clear()
		for i in bombs.size() / FLOATS_PER_BOMB:
			var o: int = i * FLOATS_PER_BOMB
			var b := Bomb.new()
			b.cell = Vector2i(int(bombs[o]), int(bombs[o + 1]))
			b.fuse = bombs[o + 2]
			b.age = BOMB_FUSE - b.fuse
			b.owner = clampi(int(bombs[o + 3]), 0, maxi(0, _tokens.size() - 1))
			_bombs.append(b)
			_bomb_at[b.cell] = b
	var flames: Variant = state.get("f")
	if flames is PackedInt32Array:
		_flames.clear()
		for i in flames.size() / INTS_PER_FLAME:
			var o: int = i * INTS_PER_FLAME
			_flames[Vector2i(flames[o], flames[o + 1])] = [flames[o + 3] / 1000.0, flames[o + 2]]
	var ci := int(state.get("ci", -1))
	_closing = ci >= 0
	_close_i = maxi(0, ci)
	_close_t = float(state.get("ct", 0.0))
	_over = bool(state.get("o", false))
	_winner = int(state.get("w", -1))

func _on_event(event_name: String, data: Variant) -> void:
	match event_name:
		"place":
			var t := _tok(int(data))
			if t != null:
				Audio.sfx(&"pop", -6.0 if is_audible(t.player) else -16.0, 0.8)
		"boom":
			if data is Array and data.size() >= 4:
				var c := Vector2i(int(data[0]), int(data[1]))
				var t := _tok(int(data[2]))
				Audio.sfx(SynthSfx.boom(), -9.0, randf_range(1.1, 1.3))
				_shake = minf(_shake + 5.0, 10.0)
				_burst(_cell_px(Vector2(c)), t.player.color if t != null else Palette.YELLOW, 10, 260.0)
				var broken: PackedInt32Array = data[3]
				for i in broken.size() / 2:
					_burst(_cell_px(Vector2(broken[i * 2], broken[i * 2 + 1])), CRATE_COLOR, 7, 170.0)
		"die":
			var t := _tok(int(data))
			if t != null:
				t.alive = false
				t.dead_t = 0.0
				Audio.sfx(&"crash", -3.0 if is_audible(t.player) else -9.0)
				_burst(_cell_px(t.pos), t.player.color, 16, 300.0)
		"pick":
			if data is Array and data.size() >= 2:
				var t := _tok(int(data[0]))
				if t != null:
					Audio.sfx(&"coin_gold", -4.0 if is_audible(t.player) else -15.0)
					_burst(_cell_px(t.pos), Palette.WHITE, 8, 150.0)
		"closing":
			Audio.sfx(&"stinger", -4.0)
		"close":
			if data is Array and data.size() >= 2:
				_block_anim[Vector2i(int(data[0]), int(data[1]))] = 0.0
				Audio.sfx(&"thud", -14.0)
		"over":
			_over = true
			_winner = int(data)

func _tok(idx: int) -> Token:
	return _tokens[idx] if idx >= 0 and idx < _tokens.size() else null

# ----------------------------------------------------------------------------
# Animación (todos los PC)
# ----------------------------------------------------------------------------

func _animate(delta: float) -> void:
	if not is_authority:
		_clock += delta
		var k := 1.0 - exp(-SMOOTHING * delta)
		for t in _tokens:
			var before := t.pos
			t.pos = t.pos.lerp(t.net_pos, k)
			t.walk += before.distance_to(t.pos)
		for b in _bombs:
			b.fuse -= delta
			b.age += delta
		for c in _flames.keys():
			_flames[c][0] -= delta
			if _flames[c][0] <= 0.0:
				_flames.erase(c)
	for t in _tokens:
		if not t.alive:
			t.dead_t += delta
	for c in _block_anim.keys():
		_block_anim[c] += delta
		if _block_anim[c] > 0.3:
			_block_anim.erase(c)
	for sp in _sparks:
		sp.age += delta
		sp.pos += sp.vel * delta
		sp.vel = sp.vel * (1.0 - 3.0 * delta) + Vector2(0, 500.0) * delta
	_sparks = _sparks.filter(func(sp: Spark) -> bool: return sp.age < sp.life)
	_shake = maxf(0.0, _shake - 30.0 * delta)
	var sec := ceili(_time_left)
	if is_running and not _closing and sec != _last_sec and sec <= 5 and sec > 0:
		Audio.sfx(&"beep", -8.0)
	_last_sec = sec

func _burst(at: Vector2, color: Color, count: int, power: float) -> void:
	for i in count:
		var sp := Spark.new()
		sp.pos = at
		sp.vel = Vector2.from_angle(randf() * TAU) * randf_range(0.3, 1.0) * power
		sp.color = color
		sp.size = randf_range(3.0, 7.0)
		sp.life = randf_range(0.3, 0.6)
		_sparks.append(sp)

# ----------------------------------------------------------------------------
# Dibujo
# ----------------------------------------------------------------------------

## Centro en pantalla de una posición en celdas.
func _cell_px(pos: Vector2) -> Vector2:
	return _origin + (pos + Vector2(0.5, 0.5)) * _cs

func _box(rect: Rect2, radius: float, color: Color) -> void:
	var key := [color, int(radius)]
	var sb: StyleBoxFlat = _boxes.get(key)
	if sb == null:
		sb = StyleBoxFlat.new()
		sb.bg_color = color
		sb.set_corner_radius_all(int(radius))
		sb.anti_aliasing = true
		_boxes[key] = sb
	surface.draw_style_box(sb, rect)

func _draw_game() -> void:
	var s := surface
	var cs := _cs
	var shake := Vector2(randf_range(-1, 1), randf_range(-1, 1)) * _shake
	s.draw_set_transform(shake, 0.0, Vector2.ONE)
	var board := Rect2(_origin, Vector2(cols, rows) * cs)
	_box(Rect2(board.position + Vector2(0, 8), board.size).grow(12), 26, Color(0, 0, 0, 0.25))
	_box(board.grow(12), 26, Palette.PURPLE_DARK)
	s.draw_rect(board, FLOOR_A)
	for y in rows:
		for x in cols:
			if (x + y) % 2 == 1:
				s.draw_rect(Rect2(_origin + Vector2(x, y) * cs, Vector2(cs, cs)), FLOOR_B)
	# Aviso del cierre final: las próximas celdas que van a taparse.
	if _closing and not _over:
		for i in range(_close_i, mini(_close_i + CLOSE_WARN, _close_order.size())):
			var c := _close_order[i]
			var a := 0.35 + 0.3 * sin(_clock * 18.0)
			s.draw_rect(Rect2(_origin + Vector2(c) * cs, Vector2(cs, cs)), Color(Palette.CORAL, a))
	for y in rows:
		for x in cols:
			var c := Vector2i(x, y)
			var v := _grid[_gi(c)]
			if v == EMPTY:
				continue
			var r := Rect2(_origin + Vector2(x, y) * cs, Vector2(cs, cs)).grow(-2.0)
			match v:
				PILLAR:
					_box(r, 10, Palette.PURPLE_DARK)
					_box(Rect2(r.position, r.size - Vector2(0, 6)), 10, Palette.CARD)
					_box(Rect2(r.position + Vector2(6, 5), Vector2(r.size.x - 12, 5)), 3, Color(1, 1, 1, 0.16))
				CRATE:
					_draw_crate(r)
				BLOCK:
					var age: float = _block_anim.get(c, 1.0)
					var k := clampf(age / 0.18, 0.0, 1.0)
					var rr := r.grow((1.0 - k) * cs * 0.35)
					_box(rr, 10, Color(Palette.CORAL_DARK, k))
					_box(Rect2(rr.position, rr.size - Vector2(0, 6)), 10, Color(Palette.CORAL, k))
				_:
					_draw_powerup(_cell_px(Vector2(c)), v)
	for b in _bombs:
		_draw_bomb(b)
	for c in _flames:
		_draw_flame(c, _flames[c][0], int(_flames[c][1]))
	# Jugadores, de arriba abajo para que se tapen bien.
	var order := _tokens.duplicate()
	order.sort_custom(func(a: Token, b: Token) -> bool: return a.pos.y < b.pos.y)
	for t in order:
		_draw_token(t)
	for sp in _sparks:
		var k := 1.0 - sp.age / sp.life
		s.draw_circle(sp.pos, sp.size * k, Color(sp.color, k))
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_hud()

func _draw_crate(r: Rect2) -> void:
	var s := surface
	_box(r, 8, CRATE_DARK)
	var top := Rect2(r.position, r.size - Vector2(0, 5))
	_box(top, 8, CRATE_COLOR)
	var inner := top.grow(-6.0)
	s.draw_rect(inner, CRATE_DARK, false, 3.0)
	s.draw_line(inner.position, inner.end, CRATE_DARK, 3.0, true)
	s.draw_line(Vector2(inner.end.x, inner.position.y), Vector2(inner.position.x, inner.end.y), CRATE_DARK, 3.0, true)

func _draw_powerup(center: Vector2, kind: int) -> void:
	var s := surface
	var r := _cs * 0.32
	var c := center + Vector2(0, sin(_clock * 4.0 + center.x * 0.05) * 2.5)
	var bg := Palette.MINT if kind == PU_BOMB else (Palette.YELLOW if kind == PU_FIRE else Palette.TEAL)
	s.draw_circle(c + Vector2(0, 4), r, Color(0, 0, 0, 0.22))
	s.draw_circle(c, r, Palette.WHITE)
	s.draw_circle(c, r * 0.84, bg)
	match kind:
		PU_BOMB:
			s.draw_circle(c + Vector2(-r * 0.12, r * 0.12), r * 0.38, Palette.PURPLE_DARK)
			s.draw_line(c + Vector2(r * 0.2, -r * 0.5), c + Vector2(r * 0.6, -r * 0.5), Palette.WHITE, 3.0)
			s.draw_line(c + Vector2(r * 0.4, -r * 0.7), c + Vector2(r * 0.4, -r * 0.3), Palette.WHITE, 3.0)
		PU_FIRE:
			s.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -r * 0.62), c + Vector2(r * 0.42, r * 0.1),
					c + Vector2(0, r * 0.58), c + Vector2(-r * 0.42, r * 0.1)]), Palette.CORAL)
			s.draw_circle(c + Vector2(0, r * 0.14), r * 0.17, Palette.WHITE)
		PU_SPEED:
			s.draw_colored_polygon(PackedVector2Array([c + Vector2(r * 0.15, -r * 0.62), c + Vector2(-r * 0.4, r * 0.1),
					c + Vector2(-r * 0.02, r * 0.1), c + Vector2(-r * 0.15, r * 0.62), c + Vector2(r * 0.4, -r * 0.1),
					c + Vector2(r * 0.02, -r * 0.1)]), Palette.WHITE)

# Petardo: bola oscura con una banda del color de su dueño y la mecha chisporroteando. Late más rápido al final.
func _draw_bomb(b: Bomb) -> void:
	var s := surface
	var hurry := clampf(1.0 - b.fuse / BOMB_FUSE, 0.0, 1.0)
	var pulse := 1.0 + 0.09 * sin(b.age * (8.0 + 22.0 * hurry))
	var c := _cell_px(Vector2(b.cell))
	var r := _cs * 0.33 * pulse
	var t := _tok(b.owner)
	var color := t.player.color if t != null else Palette.YELLOW
	s.draw_circle(c + Vector2(0, _cs * 0.12), r, Color(0, 0, 0, 0.22))
	s.draw_circle(c, r, Palette.WHITE)
	s.draw_circle(c, r * 0.88, Palette.PURPLE_DARK.lerp(Palette.CORAL, maxf(0.0, hurry - 0.6) * 2.0))
	s.draw_arc(c, r * 0.6, 0.0, TAU, 24, color, r * 0.22, true)
	s.draw_circle(c + Vector2(-0.35, -0.4) * r, r * 0.16, Color(1, 1, 1, 0.5))
	var tip := c + Vector2(r * 0.55, -r * 1.05)
	s.draw_line(c + Vector2(r * 0.3, -r * 0.75), tip, Palette.WHITE, 3.0, true)
	var flick := 0.6 + 0.4 * sin(b.age * 40.0)
	s.draw_circle(tip, r * 0.26 * flick, Palette.YELLOW)
	s.draw_circle(tip, r * 0.12 * flick, Palette.WHITE)

# Llamarada: manchas redondas del color del dueño con núcleo amarillo y blanco, que se encogen al apagarse.
func _draw_flame(cell: Vector2i, left: float, owner: int) -> void:
	var s := surface
	var t := _tok(owner)
	var color := t.player.color if t != null else Palette.CORAL
	var k := clampf(left / FLAME_TIME, 0.0, 1.0)
	var grow := minf(1.0, (1.0 - k) * 8.0 + 0.4)
	var wob := 1.0 + 0.08 * sin(_clock * 30.0 + cell.x * 1.7 + cell.y * 2.3)
	var r := _cs * 0.56 * grow * wob * (0.45 + 0.55 * k)
	var c := _cell_px(Vector2(cell))
	s.draw_circle(c, r, color)
	s.draw_circle(c, r * 0.7, Palette.YELLOW)
	s.draw_circle(c, r * 0.38, Palette.WHITE)

func _draw_token(t: Token) -> void:
	var s := surface
	var c := _cell_px(t.pos)
	var r := _cs * PLAYER_R
	if not t.alive:
		# Eliminado: se encoge y sube hasta desaparecer.
		var k := clampf(t.dead_t / 0.6, 0.0, 1.0)
		if k < 1.0:
			s.draw_circle(c + Vector2(0, -30.0 * k), r * (1.0 - k), Color(t.player.color, 1.0 - k))
		return
	var bob := absf(sin(t.walk * PI)) * _cs * 0.06
	s.draw_circle(c + Vector2(0, r * 0.75), r * 0.8, Color(0, 0, 0, 0.18))
	AvatarPainter.paint(s, c + Vector2(0, -bob), r, t.player.color, t.facing)
	if _over and _winner == t.idx:
		AvatarPainter.paint_crown(s, c + Vector2(0, -bob), r)
	if is_local_player(t.player):
		draw_local_marker(c + Vector2(0, -bob), r)

func _draw_hud() -> void:
	var s := surface
	if _over:
		var t := _tok(_winner)
		s.text_centered(Vector2(640, 60), "¡Gana %s!" % t.player.label() if t != null else "¡Empate!", 52,
				t.player.color if t != null else Palette.WHITE, 12)
	elif _closing:
		s.text_centered(Vector2(640, 60), "¡SE CIERRA!", 44, Palette.CORAL, 12)
	else:
		s.text_centered(Vector2(640, 60), "%d" % ceili(_time_left), 64, Palette.YELLOW, 12)
	# Jugadores repartidos a ambos lados del reloj, cada uno con sus petardos y su alcance.
	var n := _tokens.size()
	var left_n := ceili(n / 2.0)
	var right_n := n - left_n
	for i in n:
		var t := _tokens[i]
		var x: float
		if i < left_n:
			x = 62.0 + i * 118.0
		else:
			x = 1140.0 - (right_n - 1 - (i - left_n)) * 118.0
		var c := Vector2(x, 56.0)
		if not t.alive:
			AvatarPainter.paint(s, c, 22.0, t.player.color.lerp(Palette.CARD, 0.75))
			s.draw_line(c + Vector2(-16, -16), c + Vector2(16, 16), Palette.CORAL, 6.0, true)
			s.draw_line(c + Vector2(16, -16), c + Vector2(-16, 16), Palette.CORAL, 6.0, true)
			continue
		AvatarPainter.paint(s, c, 22.0, t.player.color)
		if is_local_player(t.player):
			draw_local_marker(c, 22.0)
		var a := c + Vector2(40, -13)
		s.draw_circle(a, 8.0, Palette.PURPLE_DARK)
		s.draw_circle(a, 4.0, Palette.MINT)
		s.text_centered(a + Vector2(20, 0), str(t.max_bombs), 22, Palette.WHITE, 6)
		var b := c + Vector2(40, 13)
		s.draw_colored_polygon(PackedVector2Array([b + Vector2(0, -10), b + Vector2(7, 1), b + Vector2(0, 9),
				b + Vector2(-7, 1)]), Palette.YELLOW)
		s.text_centered(b + Vector2(20, 0), str(t.fire), 22, Palette.WHITE, 6)
