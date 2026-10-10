extends Minigame
## Vagonetas Cañoneras (id rail_cannons; modelo HOST_AUTHORITATIVE, 3D): cada jugador va en una vagoneta con un cañón delante y
## una DIANA detrás, sobre una red de raíles entre setos (patio de un castillo). Las vagonetas solo circulan por los raíles: la
## dirección elige por qué vía seguir en cada cruce (y se puede dar media vuelta en cualquier momento). La acción dispara una bala
## de cañón hacia delante, en línea recta por la vía; los setos la paran. Si la bala te da en la DIANA (por detrás) sales
## disparado y quedas eliminado; si te da por delante o de lado solo te empuja y te aturde un momento. De vez en cuando aparece
## una moneda «S» que da velocidad unos segundos. Gana el último que quede; si se acaba el tiempo (60 s), empatan los que sigan.
##
## Se adapta al nº de jugadores: el patio crece (5×4 cruces con 2-4 jugadores, 6×4 con 5-6, 6×5 con 7-8) y las salidas se
## reparten por el borde, todos mirando en el mismo sentido (cada uno ve la diana del de delante).
## El trazado de raíles sale de la semilla común (simétrico, sin callejones sin salida), así que no viaja por la red.
## El host simula a 60 Hz; el estado va a ~30 Hz y los clientes interpolan. El 3D (SubViewport con mundo propio) es presentación.

const STEP := 1.0 / 60.0
const TIME_LIMIT := 60.0
const DONE_DELAY := 2.8
# --- Patio ---
const SPACING := 4.4                     # distancia entre cruces
const LANE := 0.85                       # medio ancho del pasillo de la vía (los setos empiezan ahí)
const REMOVE_FRAC := 0.4                 # fracción de tramos interiores que se convierten en seto (como mucho)
const MAX_HEDGE_CELLS := 2              # un seto ocupa como mucho 2 celdas de la rejilla (nada de pasillos larguísimos)
# --- Vagonetas ---
const SPEED := 4.3
const BOOST_MULT := 1.55
const BOOST_TIME := 4.5
const CART_GAP := 1.5                    # distancia mínima entre vagonetas (no se atraviesan)
const FIRE_CD := 0.85
const STUN_TIME := 0.75
const KNOCK_DIST := 1.3
const HIT_RADIUS := 0.75
const FRONT_DOT := -0.5                  # la bala da "de frente" (en el cañón) si su dirección y la de la vagoneta se oponen más que esto
# --- Balas ---
const BALL_SPEED := 12.5
const BALL_LIFE := 2.6
# --- Moneda de velocidad ---
const COIN_FIRST := 6.0
const COIN_EVERY := 8.0
const COIN_LIFE := 9.0
const COIN_RADIUS := 0.75
const CART_SCALE := 1.3                 # tamaño de la vagoneta en pantalla
const FLOATS := 10                       # por jugador en el estado enviado

## Una vagoneta (la simula el host; los clientes la reciben y solo interpolan la presentación).
class RS:
	var id: int = 0
	var idx: int = 0
	var n: int = 0                       # cruce de partida del tramo actual
	var m: int = -1                      # cruce de destino (-1 = parado en el cruce n)
	var t: float = 0.0                   # distancia recorrida desde n hacia m
	var pos: Vector2 = Vector2.ZERO      # (x, z)
	var face: Vector2 = Vector2(0, -1)   # hacia donde apunta el cañón
	var moving: bool = false
	var alive: bool = true
	var out_t: float = -1.0              # momento en que lo eliminaron (segundos de partida)
	var fly_t: float = 0.0               # animación de salir volando
	var stun_t: float = 0.0
	var fire_cd: float = 0.0
	var boost_t: float = 0.0
	var kills: int = 0
	var recoil: float = 0.0
	# IA
	var bot_rng: RandomNumberGenerator = null
	var skill: float = 1.0
	var want_fire: bool = false
	var think_t: float = 0.0
	var goal: int = -1
	var dodge_t: float = 0.0
	var seen_ball: int = 0              # última bala que ya decidió si esquivar
	var wander_t: float = 0.0            # tras un cara a cara, se va por otro lado un rato
	# Presentación (interpolada)
	var dpos: Vector2 = Vector2.ZERO
	var dang: float = 0.0
	var anim: float = 0.0
	var node: Node3D = null
	var body: Node3D = null
	var barrel: Node3D = null
	var stars: Node3D = null
	var flame: MeshInstance3D = null
	var ring: MeshInstance3D = null
	var tag: Label3D = null

var _cols: int = 5
var _rows: int = 4
var _nodes: Array[Vector2] = []
var _adj: Array = []                     # por cruce: Array[int] de vecinos
var _edges: Dictionary = {}              # clave a*1000+b (a<b) -> true   (tramos con vía)
var _removed: Dictionary = {}            # tramos interiores convertidos en seto
var _half: Vector2 = Vector2.ZERO        # medio tamaño del patio (x, z)

var _rs: Dictionary = {}                 # player id -> RS
var _order: Array[int] = []
var _balls: Array = []                   # {p: Vector2, d: Vector2, o: owner id, age: float}
var _ball_seq: int = 0
var _stats: Dictionary = {"fire": 0, "out": 0, "bump": 0, "puff": 0}
var _coin_on: bool = false
var _coin_pos: Vector2 = Vector2.ZERO
var _coin_t: float = 0.0                 # tiempo de vida que le queda (o espera hasta la siguiente)
var _crng: RandomNumberGenerator
var _elapsed: float = 0.0
var _time_left: float = TIME_LIMIT
var _accum: float = 0.0
var _over: bool = false
var _over_t: float = 0.0
var _winners: Array = []
var _hint_t: float = 7.0
var _toast: String = ""
var _toast_t: float = 0.0
var _shake: float = 0.0
var _anim: float = 0.0

# --- Escena 3D ---
var _vp: SubViewport
var _cont: SubViewportContainer
var _root3: Node3D
var _cam: Camera3D
var _cam_base: Vector3 = Vector3.ZERO
var _built: bool = false
var _ball_nodes: Array[MeshInstance3D] = []
var _coin_node: Node3D = null
var _fx: Array = []                      # {n: Node3D, age: float, life: float, kind: String, v: Vector3}

# ----------------------------------------------------------------------------
# Trazado de raíles
# ----------------------------------------------------------------------------

func _nid(c: int, r: int) -> int:
	return r * _cols + c

func _ekey(a: int, b: int) -> int:
	return mini(a, b) * 1000 + maxi(a, b)

func _has_edge(a: int, b: int) -> bool:
	return _edges.has(_ekey(a, b))

func _is_border(c: int, r: int) -> bool:
	return c == 0 or r == 0 or c == _cols - 1 or r == _rows - 1

## Genera el patio: rejilla de cruces, todos los tramos del borde y una parte de los interiores (simétrico izquierda-derecha,
## cada cruce con al menos dos vías y todo conectado). Determinista a partir de la semilla común.
func _build_track() -> void:
	var n := players.size()
	if n <= 4:
		_cols = 5
		_rows = 4
	elif n <= 6:
		_cols = 6
		_rows = 4
	else:
		_cols = 6
		_rows = 5
	_half = Vector2((_cols - 1) * SPACING * 0.5, (_rows - 1) * SPACING * 0.5)
	_nodes.clear()
	for r in _rows:
		for c in _cols:
			_nodes.append(Vector2(-_half.x + c * SPACING, -_half.y + r * SPACING))
	_edges.clear()
	_removed.clear()
	var interior: Array = []
	for r in _rows:
		for c in _cols:
			var a := _nid(c, r)
			if c + 1 < _cols:
				_edges[_ekey(a, _nid(c + 1, r))] = true
				if r != 0 and r != _rows - 1:
					interior.append([c, r, c + 1, r])
			if r + 1 < _rows:
				_edges[_ekey(a, _nid(c, r + 1))] = true
				if c != 0 and c != _cols - 1:
					interior.append([c, r, c, r + 1])
	var mr := RandomNumberGenerator.new()
	mr.seed = hash([seed_value, "rails"])
	for i in range(interior.size() - 1, 0, -1):
		var j := mr.randi_range(0, i)
		var tmp: Variant = interior[i]
		interior[i] = interior[j]
		interior[j] = tmp
	var target := int(round(interior.size() * REMOVE_FRAC))
	for e in interior:
		if _removed.size() >= target:
			break
		var k1 := _ekey(_nid(e[0], e[1]), _nid(e[2], e[3]))
		var k2 := _ekey(_nid(_cols - 1 - e[0], e[1]), _nid(_cols - 1 - e[2], e[3]))
		if not _edges.has(k1) or not _edges.has(k2):
			continue
		_edges.erase(k1)
		_edges.erase(k2)
		if _track_ok():
			_removed[k1] = true
			_removed[k2] = true
		else:
			_edges[k1] = true
			_edges[k2] = true
	_adj.clear()
	for i in _nodes.size():
		var nb: Array[int] = []
		for j in _nodes.size():
			if j != i and _has_edge(i, j):
				nb.append(j)
		_adj.append(nb)

func _track_ok() -> bool:
	var deg: Array[int] = []
	deg.resize(_nodes.size())
	for k in _edges:
		deg[int(k) / 1000] += 1
		deg[int(k) % 1000] += 1
	for d in deg:
		if d < 2:
			return false
	# Setos de como mucho MAX_HEDGE_CELLS celdas (unión de celdas separadas por un tramo sin vía).
	var cw := _cols - 1
	var parent: Array[int] = []
	for i in cw * (_rows - 1):
		parent.append(i)
	var find := func(x: int) -> int:
		while parent[x] != x:
			x = parent[x]
		return x
	for r in _rows:
		for c in _cols:
			var a := _nid(c, r)
			if c + 1 < _cols and r > 0 and r < _rows - 1 and not _edges.has(_ekey(a, _nid(c + 1, r))):
				parent[find.call(c + (r - 1) * cw)] = find.call(c + r * cw)
			if r + 1 < _rows and c > 0 and c < _cols - 1 and not _edges.has(_ekey(a, _nid(c, r + 1))):
				parent[find.call(c - 1 + r * cw)] = find.call(c + r * cw)
	var sizes := {}
	for i in parent.size():
		var root: int = find.call(i)
		sizes[root] = int(sizes.get(root, 0)) + 1
		if int(sizes[root]) > MAX_HEDGE_CELLS:
			return false
	# Conectado (BFS desde el cruce 0).
	var seen := {0: true}
	var queue: Array[int] = [0]
	while not queue.is_empty():
		var a: int = queue.pop_front()
		for k in _edges:
			var x := int(k) / 1000
			var y := int(k) % 1000
			var o := -1
			if x == a:
				o = y
			elif y == a:
				o = x
			if o >= 0 and not seen.has(o):
				seen[o] = true
				queue.append(o)
	return seen.size() == _nodes.size()

## Cruces del borde en orden de vuelta (sentido horario visto desde arriba).
func _border_loop() -> Array[int]:
	var out: Array[int] = []
	for c in _cols:
		out.append(_nid(c, 0))
	for r in range(1, _rows):
		out.append(_nid(_cols - 1, r))
	for c in range(_cols - 2, -1, -1):
		out.append(_nid(c, _rows - 1))
	for r in range(_rows - 2, 0, -1):
		out.append(_nid(0, r))
	return out

## Distancia de un punto al pasillo de vía más cercano.
func _lane_dist(p: Vector2) -> float:
	var best := INF
	for k in _edges:
		var a: Vector2 = _nodes[int(k) / 1000]
		var b: Vector2 = _nodes[int(k) % 1000]
		var ab := b - a
		var tt := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * tt))
	return best

## Cruce más cercano a un punto.
func _nearest_node(p: Vector2) -> int:
	var best := 0
	var bd := INF
	for i in _nodes.size():
		var d := p.distance_squared_to(_nodes[i])
		if d < bd:
			bd = d
			best = i
	return best

# ----------------------------------------------------------------------------
# Simulación (solo el host)
# ----------------------------------------------------------------------------

func _setup_players() -> void:
	for old in _rs.values():
		for nd in [(old as RS).node, (old as RS).ring]:
			if nd != null and is_instance_valid(nd):
				(nd as Node).queue_free()
	_rs.clear()
	_order.clear()
	_balls.clear()
	var loop := _border_loop()
	var count := players.size()
	for i in count:
		var pl := players[i]
		var r := RS.new()
		r.id = pl.id
		r.idx = i
		var li := int(floor(float(i) * loop.size() / maxf(count, 1)))
		r.n = loop[li]
		r.m = -1
		r.t = 0.0
		r.pos = _nodes[r.n]
		# Uno en cada sentido: los vecinos empiezan cara a cara (de frente la bala solo empuja).
		var nxt: int = loop[(li + (1 if i % 2 == 0 else loop.size() - 1)) % loop.size()]
		r.face = (_nodes[nxt] - _nodes[r.n]).normalized()
		r.bot_rng = RandomNumberGenerator.new()
		r.bot_rng.seed = hash([seed_value, pl.id])
		r.skill = 0.65 + 0.35 * r.bot_rng.randf()
		r.dpos = r.pos
		r.dang = atan2(r.face.x, r.face.y)
		_rs[pl.id] = r
		_order.append(pl.id)

func _player_by_id(id: int) -> PlayerData:
	for pl in players:
		if pl.id == id:
			return pl
	return null

func _mine(r: RS) -> bool:
	var pl := _player_by_id(r.id)
	return pl != null and is_audible(pl)

func _alive_ids() -> Array[int]:
	var out: Array[int] = []
	for id in _order:
		if (_rs[id] as RS).alive:
			out.append(id)
	return out

func _simulate(delta: float) -> void:
	if _over:
		_over_t += delta
		_accum += delta
		while _accum >= STEP:
			_accum -= STEP
			_step_balls(STEP)
		if _over_t >= DONE_DELAY:
			finish(_ranking())
		return
	var dirs: Dictionary = {}
	for pl in players:
		var r: RS = _rs[pl.id]
		if not r.alive:
			continue
		dirs[pl.id] = move_input(pl)
		if action_presses(pl) > 0:
			_try_fire(r)
	_accum += delta
	var steps := 0
	while _accum >= STEP and steps < 12:
		_accum -= STEP
		steps += 1
		_elapsed += STEP
		for id in _order:
			var r: RS = _rs[id]
			r.stun_t = maxf(0.0, r.stun_t - STEP)
			r.fire_cd = maxf(0.0, r.fire_cd - STEP)
			r.boost_t = maxf(0.0, r.boost_t - STEP)
			if r.alive and r.stun_t <= 0.0:
				var spd := SPEED * (BOOST_MULT if r.boost_t > 0.0 else 1.0)
				_drive(r, dirs.get(id, Vector2.ZERO), spd * STEP)
			elif r.alive:
				r.moving = false
		_step_balls(STEP)
		_step_coin(STEP)
		if _over:
			return
	_time_left = maxf(0.0, TIME_LIMIT - _elapsed)
	if _time_left <= 0.0:
		_end_game()

## Mueve una vagoneta por los raíles según la dirección pedida.
## En un tramo: hacia delante o atrás según la dirección (si es perpendicular, sigue hasta el siguiente cruce para girar allí).
## En un cruce: toma la vía que más se parezca a la dirección; si ninguna, sigue recto si puede.
func _drive(r: RS, want: Vector2, dist: float) -> void:
	if want.length() < 0.3:
		r.moving = false
		return
	want = want.normalized()
	var start := r.pos
	var guard := 0
	while dist > 0.0001 and guard < 6:
		guard += 1
		if r.m < 0:
			var e := _pick_edge(r.n, want, r.face, r.moving or guard > 1)
			if e < 0:
				break
			r.m = e
			r.t = 0.0
		var a: Vector2 = _nodes[r.n]
		var b: Vector2 = _nodes[r.m]
		var dir := (b - a).normalized()
		# En el carril no se puede dar la vuelta: hacia atrás frena; perpendicular, sigue hasta el cruce para girar allí.
		if want.dot(dir) < -0.35:
			break
		r.face = dir
		var room := _nodes[r.n].distance_to(_nodes[r.m]) - r.t
		if dist < room:
			r.t += dist
			dist = 0.0
		else:
			dist -= room
			r.n = r.m
			r.m = -1
			r.t = 0.0
	_update_pos(r)
	# Choque: no se atraviesan; vuelve a donde estaba y los dos se dan la vuelta (así nadie se queda atascado).
	for id in _order:
		var o: RS = _rs[id]
		if o == r or not o.alive:
			continue
		var to := o.pos - r.pos
		if to.length() < CART_GAP and to.dot(r.face) > 0.0 and to.length() < o.pos.distance_to(start) - 0.0001:
			_snap_back(r, start)
			_turn_around(r)
			_turn_around(o)
			r.moving = false
			send_event("crash", {"a": r.id, "b": o.id, "x": (r.pos.x + o.pos.x) * 0.5, "z": (r.pos.y + o.pos.y) * 0.5})
			return
	r.moving = r.pos.distance_to(start) > 0.0001

## Media vuelta (solo tras un choque): el cañón mira al otro lado y sigue por el mismo tramo en sentido contrario.
func _turn_around(r: RS) -> void:
	if r.m >= 0:
		var L := _nodes[r.n].distance_to(_nodes[r.m])
		var tmp := r.n
		r.n = r.m
		r.m = tmp
		r.t = L - r.t
	r.face = -r.face
	_update_pos(r)

## Vías que puede tomar en un cruce: todas menos la de vuelta (la contraria a donde mira).
func _can_take(node: int, o: int, face: Vector2) -> bool:
	return (_nodes[o] - _nodes[node]).normalized().dot(face) > -0.9

func _pick_edge(node: int, want: Vector2, face: Vector2, cruise: bool) -> int:
	var best := -1
	var bd := 0.5
	for o in _adj[node]:
		if not _can_take(node, o, face):
			continue
		var dd := want.dot((_nodes[o] - _nodes[node]).normalized())
		if dd > bd:
			bd = dd
			best = o
	if best >= 0:
		return best
	# En marcha y con la dirección perpendicular sin vía: seguir recto si se puede.
	if not cruise:
		return -1
	for o in _adj[node]:
		if face.dot((_nodes[o] - _nodes[node]).normalized()) > 0.9 and absf(want.dot(face)) < 0.5:
			return o
	return -1

func _update_pos(r: RS) -> void:
	if r.m < 0:
		r.pos = _nodes[r.n]
	else:
		var a: Vector2 = _nodes[r.n]
		var b: Vector2 = _nodes[r.m]
		r.pos = a + (b - a).normalized() * r.t

## Vuelve a la posición `p` (que estaba en el tramo n-m o en uno de sus cruces).
func _snap_back(r: RS, p: Vector2) -> void:
	if r.m >= 0:
		var a: Vector2 = _nodes[r.n]
		var b: Vector2 = _nodes[r.m]
		var ab := b - a
		var on := absf((p - a).cross(ab.normalized())) < 0.01 and (p - a).dot(ab) >= -0.01 and (p - b).dot(-ab) >= -0.01
		if on:
			r.t = clampf((p - a).length(), 0.0, ab.length())
			_update_pos(r)
			return
	# p era un cruce (o el tramo anterior): buscar el cruce o el tramo que lo contiene.
	var nn := _nearest_node(p)
	if _nodes[nn].distance_to(p) < 0.01:
		r.n = nn
		r.m = -1
		r.t = 0.0
	else:
		for o in _adj[nn]:
			var a2: Vector2 = _nodes[nn]
			var b2: Vector2 = _nodes[o]
			var ab2 := b2 - a2
			if absf((p - a2).cross(ab2.normalized())) < 0.01 and (p - a2).dot(ab2) >= 0.0 and (p - a2).length() <= ab2.length():
				r.n = nn
				r.m = o
				r.t = (p - a2).length()
				break
	_update_pos(r)

## Empujón a lo largo de la vía (sin girar el cañón).
func _knock(r: RS, dir: Vector2, dist: float) -> void:
	var face := r.face
	var was_m := r.m
	if r.m < 0:
		var e := -1
		for o2 in _adj[r.n]:
			if dir.dot((_nodes[o2] - _nodes[r.n]).normalized()) > 0.9:
				e = o2
		if e < 0:
			return
		r.m = e
		r.t = 0.0
	var a: Vector2 = _nodes[r.n]
	var b: Vector2 = _nodes[r.m]
	var ed := (b - a).normalized()
	var s := 1.0 if dir.dot(ed) >= 0.0 else -1.0
	if absf(dir.dot(ed)) < 0.3:
		if was_m < 0:
			r.m = -1
		return
	var L := a.distance_to(b)
	r.t = clampf(r.t + s * dist, 0.0, L)
	if r.t >= L - 0.0001:
		r.n = r.m
		r.m = -1
		r.t = 0.0
	elif r.t <= 0.0001:
		r.m = -1
		r.t = 0.0
	r.face = face
	# El tramo va siempre en el sentido del cañón (de n hacia m).
	if r.m >= 0 and (_nodes[r.m] - _nodes[r.n]).dot(face) < 0.0:
		var L2 := _nodes[r.n].distance_to(_nodes[r.m])
		var tmp := r.n
		r.n = r.m
		r.m = tmp
		r.t = L2 - r.t
	_update_pos(r)

func _try_fire(r: RS) -> void:
	if not r.alive or r.stun_t > 0.0 or r.fire_cd > 0.0 or _over:
		return
	r.fire_cd = FIRE_CD
	var p := r.pos + r.face * 1.0
	_ball_seq += 1
	_balls.append({"p": p, "d": r.face, "o": r.id, "age": 0.0, "id": _ball_seq})
	send_event("fire", {"p": r.id})

func _step_balls(dt: float) -> void:
	var keep: Array = []
	for b in _balls:
		var p: Vector2 = b["p"]
		var d: Vector2 = b["d"]
		var dead := false
		# Subpasos para no saltarse una vagoneta.
		for s in 3:
			p += d * BALL_SPEED * dt / 3.0
			if _lane_dist(p) > LANE * 0.55 or absf(p.x) > _half.x + 1.2 or absf(p.y) > _half.y + 1.2:
				send_event("puff", {"x": p.x, "z": p.y, "h": 0})
				dead = true
				break
			for id in _order:
				var v: RS = _rs[id]
				if not v.alive or v.id == int(b["o"]):
					continue
				if v.pos.distance_to(p) <= HIT_RADIUS:
					_ball_hits(v, d, int(b["o"]), p)
					dead = true
					break
			if dead:
				break
		b["p"] = p
		b["age"] = float(b["age"]) + dt
		if not dead and float(b["age"]) < BALL_LIFE:
			keep.append(b)
	_balls = keep

func _ball_hits(v: RS, d: Vector2, owner: int, p: Vector2) -> void:
	if _over:
		send_event("puff", {"x": p.x, "z": p.y, "h": 1})
		return
	if d.dot(v.face) > FRONT_DOT:
		# Por detrás o de lado: ¡en la diana! Eliminado.
		v.alive = false
		v.out_t = _elapsed
		v.moving = false
		var o: RS = _rs.get(owner)
		if o != null:
			o.kills += 1
		send_event("out", {"v": v.id, "a": owner})
		DevCli.log_event("rail_cannons out=%d by=%d" % [v.id, owner])
		if _alive_ids().size() <= 1:
			_end_game()
	else:
		v.stun_t = STUN_TIME
		_knock(v, d, KNOCK_DIST)
		send_event("bump", {"v": v.id, "x": p.x, "z": p.y})

func _step_coin(dt: float) -> void:
	_coin_t -= dt
	if _coin_on:
		for id in _order:
			var r: RS = _rs[id]
			if r.alive and r.pos.distance_to(_coin_pos) <= COIN_RADIUS + 0.35:
				r.boost_t = BOOST_TIME
				_coin_on = false
				_coin_t = COIN_EVERY
				send_event("pick", {"p": r.id})
				return
		if _coin_t <= 0.0:
			_coin_on = false
			_coin_t = COIN_EVERY * 0.5
	elif _coin_t <= 0.0:
		# En el punto medio de un tramo, lejos de las vagonetas.
		var keys := _edges.keys()
		var best := Vector2.ZERO
		var bscore := -INF
		for i in 6:
			var k: int = keys[_crng.randi_range(0, keys.size() - 1)]
			var c := (_nodes[k / 1000] + _nodes[k % 1000]) * 0.5
			var dmin := INF
			for id in _order:
				var r2: RS = _rs[id]
				if r2.alive:
					dmin = minf(dmin, c.distance_to(r2.pos))
			if dmin > bscore:
				bscore = dmin
				best = c
		_coin_pos = best
		_coin_on = true
		_coin_t = COIN_LIFE
		send_event("coin", {"x": best.x, "z": best.y})

func _end_game() -> void:
	if _over:
		return
	_over = true
	_over_t = 0.0
	_winners = _alive_ids()
	for b in _balls:
		b["o"] = -1
	send_event("over", {"w": _winners})
	DevCli.log_event("rail_cannons over winners=%s" % str(_winners))

## Clasificación: los que siguen en pie (más eliminaciones primero), luego los eliminados del último al primero en caer.
func _ranking() -> Array[int]:
	var ids: Array[int] = _order.duplicate()
	ids.sort_custom(func(a: int, b: int) -> bool:
		var ra: RS = _rs[a]
		var rb: RS = _rs[b]
		if ra.alive != rb.alive:
			return ra.alive
		if not ra.alive and not is_equal_approx(ra.out_t, rb.out_t):
			return ra.out_t > rb.out_t
		if ra.kills != rb.kills:
			return ra.kills > rb.kills
		return a < b)
	return ids

## Si se acaba el tiempo con varios en pie, todos ellos empatan en cabeza. Los que caen a la vez, también empatan.
func _result_groups() -> Array:
	var groups: Array = []
	var alive := _alive_ids()
	if alive.size() > 1:
		groups.append(alive)
	var by_t: Dictionary = {}
	for id in _order:
		var r: RS = _rs[id]
		if not r.alive:
			var key := int(round(r.out_t * 60.0))
			if not by_t.has(key):
				by_t[key] = []
			(by_t[key] as Array).append(id)
	for k in by_t:
		if (by_t[k] as Array).size() > 1:
			groups.append(by_t[k])
	return groups

# ----------------------------------------------------------------------------
# Red
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var arr := PackedFloat32Array()
	for id in _order:
		var r: RS = _rs[id]
		arr.append_array(PackedFloat32Array([r.pos.x, r.pos.y, r.face.x, r.face.y, 1.0 if r.alive else 0.0, r.stun_t,
				r.boost_t, float(r.kills), 1.0 if r.moving else 0.0, r.fire_cd]))
	var balls := PackedFloat32Array()
	for b in _balls:
		var p: Vector2 = b["p"]
		var d: Vector2 = b["d"]
		balls.append_array(PackedFloat32Array([p.x, p.y, d.x, d.y, float(int(b["o"]))]))
	return {"r": arr, "b": balls, "t": _time_left, "o": _over, "c": _coin_on, "cx": _coin_pos.x, "cz": _coin_pos.y}

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	var st: Dictionary = state
	_time_left = float(st.get("t", _time_left))
	_over = bool(st.get("o", _over))
	_coin_on = bool(st.get("c", _coin_on))
	_coin_pos = Vector2(float(st.get("cx", _coin_pos.x)), float(st.get("cz", _coin_pos.y)))
	var arr: Variant = st.get("r")
	if arr is PackedFloat32Array and arr.size() >= _order.size() * FLOATS:
		for i in _order.size():
			var r: RS = _rs[_order[i]]
			var o := i * FLOATS
			r.pos = Vector2(arr[o], arr[o + 1])
			r.face = Vector2(arr[o + 2], arr[o + 3])
			r.alive = arr[o + 4] > 0.5
			r.stun_t = arr[o + 5]
			r.boost_t = arr[o + 6]
			r.kills = int(arr[o + 7])
			r.moving = arr[o + 8] > 0.5
			r.fire_cd = arr[o + 9]
	var bl: Variant = st.get("b")
	if bl is PackedFloat32Array:
		_balls.clear()
		for i in range(0, bl.size() - 4, 5):
			_balls.append({"p": Vector2(bl[i], bl[i + 1]), "d": Vector2(bl[i + 2], bl[i + 3]), "o": int(bl[i + 4]), "age": 0.0})

func _on_event(event_name: String, data: Variant) -> void:
	var d: Dictionary = data if data is Dictionary else {}
	match event_name:
		"fire":
			_stats["fire"] = int(_stats["fire"]) + 1
			var r: RS = _rs.get(int(d.get("p", -1)))
			if r != null:
				r.recoil = 1.0
				_spawn_puff(Vector3(r.dpos.x + r.face.x * 0.95, 0.75, r.dpos.y + r.face.y * 0.95), 0.25, Color(1, 1, 1, 0.8))
				Audio.sfx(&"shot", -8.0 if _mine(r) else -17.0)
		"puff":
			_stats["puff"] = int(_stats["puff"]) + 1
			_spawn_puff(Vector3(float(d.get("x", 0.0)), 0.6, float(d.get("z", 0.0))), 0.45, Color(1, 1, 1, 0.85))
			Audio.sfx(&"pop", -16.0)
		"bump":
			_stats["bump"] = int(_stats["bump"]) + 1
			var v: RS = _rs.get(int(d.get("v", -1)))
			_spawn_puff(Vector3(float(d.get("x", 0.0)), 0.7, float(d.get("z", 0.0))), 0.6, Color(1, 1, 1, 0.9))
			_shake = maxf(_shake, 0.15)
			Audio.sfx(&"thud", -6.0 if v != null and _mine(v) else -12.0)
		"crash":
			_spawn_puff(Vector3(float(d.get("x", 0.0)), 0.6, float(d.get("z", 0.0))), 0.4, Color(1, 1, 1, 0.85))
			var ca: RS = _rs.get(int(d.get("a", -1)))
			var cb: RS = _rs.get(int(d.get("b", -1)))
			Audio.sfx(&"clang", -8.0 if (ca != null and _mine(ca)) or (cb != null and _mine(cb)) else -16.0)
		"out":
			_stats["out"] = int(_stats["out"]) + 1
			var v2: RS = _rs.get(int(d.get("v", -1)))
			if v2 != null:
				v2.alive = false
				v2.fly_t = 0.0
				_spawn_pillar(v2)
				var a: RS = _rs.get(int(d.get("a", -1)))
				var pa := _player_by_id(a.id) if a != null else null
				var pv := _player_by_id(v2.id)
				if pv != null:
					_toast = "¡%s, fuera!" % pv.display_name if pa == null else "¡%s tumba a %s!" % [pa.display_name, pv.display_name]
					_toast_t = 1.8
			_shake = maxf(_shake, 0.45)
			Audio.sfx(&"hit_gold", -5.0)
			Audio.sfx(&"launch", -7.0)
		"coin":
			_coin_on = true
			_coin_pos = Vector2(float(d.get("x", 0.0)), float(d.get("z", 0.0)))
			Audio.sfx(&"gold_spawn", -12.0)
		"pick":
			_coin_on = false
			var r2: RS = _rs.get(int(d.get("p", -1)))
			if r2 != null:
				r2.boost_t = BOOST_TIME
				_spawn_puff(Vector3(r2.dpos.x, 1.0, r2.dpos.y), 0.5, Color(1.0, 0.85, 0.2, 0.9))
				Audio.sfx(&"coin_gold", -6.0 if _mine(r2) else -14.0)
		"over":
			_over = true
			_winners = d.get("w", [])
			Audio.sfx(&"fanfare_big", -6.0)

# ----------------------------------------------------------------------------
# Ciclo del minijuego
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	_build_track()
	_setup_players()
	_build_world()
	surface.draw_callback = _draw_hud

func _on_start() -> void:
	_build_track()
	_setup_players()
	_rebuild_player_nodes()
	_crng = RandomNumberGenerator.new()
	_crng.seed = hash([seed_value, "coin"])
	_accum = 0.0
	_elapsed = 0.0
	_time_left = TIME_LIMIT
	_over = false
	_over_t = 0.0
	_winners = []
	_hint_t = 7.0
	_toast = ""
	_toast_t = 0.0
	_coin_on = false
	_coin_t = COIN_FIRST

func _animate(delta: float) -> void:
	_shake = maxf(0.0, _shake - delta * 2.5)
	_toast_t = maxf(0.0, _toast_t - delta)
	_anim += delta
	_hint_t = maxf(0.0, _hint_t - delta)
	_update_world(delta)

# ----------------------------------------------------------------------------
# IA (bots, autopiloto, práctica): persigue al rival más cercano por los raíles para ponerse detrás y disparar a su diana;
# se da la vuelta si le viene una bala por detrás; a veces va a por la moneda.
# ----------------------------------------------------------------------------

## Camino más corto (BFS) por los raíles: primer cruce a visitar desde `from` hacia `to`, y la distancia en tramos.
func _bfs_next(from: int, to: int) -> Array:
	if from == to:
		return [from, 0]
	var prev := {from: -1}
	var queue: Array[int] = [from]
	while not queue.is_empty():
		var a: int = queue.pop_front()
		if a == to:
			break
		for o in _adj[a]:
			if not prev.has(o):
				prev[o] = a
				queue.append(o)
	if not prev.has(to):
		return [from, 99]
	var cur := to
	var steps := 0
	while prev[cur] != from and prev[cur] != -1:
		cur = prev[cur]
		steps += 1
	return [cur, steps + 1]

## Nodo hacia el que se dirige la vagoneta (o en el que está).
func _ahead_node(r: RS) -> int:
	return r.n if r.m < 0 else r.m

## ¿Línea de tiro limpia (sobre la vía) de a hacia b?
func _clear_shot(a: Vector2, b: Vector2) -> bool:
	var d := b.distance_to(a)
	var steps := int(d / 0.4) + 1
	for i in range(1, steps):
		var p := a.lerp(b, float(i) / float(steps))
		if _lane_dist(p) > LANE * 0.5:
			return false
	return true

func _bot_think(r: RS) -> Vector2:
	r.want_fire = false
	r.dodge_t = maxf(0.0, r.dodge_t - STEP)
	r.wander_t = maxf(0.0, r.wander_t - STEP)
	if _over or not r.alive or r.stun_t > 0.0:
		return Vector2.ZERO
	# 2) Disparar si hay alguien delante, en línea y a tiro (sobre todo si no nos mira de frente). Mientras, seguir hacia él.
	var aiming := false
	if true:
		for id in _order:
			var v: RS = _rs[id]
			if v == r or not v.alive:
				continue
			var to := v.pos - r.pos
			var dist := to.length()
			if dist < 0.5 or dist > 13.0:
				continue
			if to.normalized().dot(r.face) > 0.985 and _clear_shot(r.pos + r.face * 0.6, v.pos):
				var exposed := v.face.dot(-r.face) < 0.5
				if exposed:
					aiming = true
				elif dist < 4.5 and r.wander_t <= 0.0 and r.bot_rng.randf() < 0.03:
					# Cara a cara: así no se gana; buscar otro camino para rodearle.
					r.wander_t = r.bot_rng.randf_range(1.2, 2.4)
					r.goal = r.bot_rng.randi_range(0, _nodes.size() - 1)
					r.think_t = r.wander_t
				if r.fire_cd <= 0.0 and (exposed or r.bot_rng.randf() < 0.04):
					if r.bot_rng.randf() < 0.1 + 0.15 * r.skill:
						r.want_fire = true
				break
	if aiming and r.bot_rng.randf() < 0.9:
		return r.face * 0.6
	# 3) Moverse: hacia el rival elegido (o la moneda si está cerca).
	r.think_t -= STEP
	if r.think_t <= 0.0 or r.goal < 0:
		r.think_t = r.bot_rng.randf_range(0.5, 1.2)
		var here := _ahead_node(r)
		var best := -1
		var bscore := INF
		for id in _order:
			var v2: RS = _rs[id]
			if v2 == r or not v2.alive:
				continue
			# Ir al cruce que queda detrás de él.
			# Ir al cruce que queda detrás de él (o, a veces, atajar hacia donde está para cortarle el paso).
			var behind := _nearest_node(v2.pos - v2.face * SPACING * 0.9)
			if r.bot_rng.randf() < 0.45:
				behind = _ahead_node(v2)
			var res := _bfs_next(here, behind)
			var sc := float(res[1]) + r.bot_rng.randf() * 1.5
			if sc < bscore:
				bscore = sc
				best = behind
		if _coin_on:
			var cn := _nearest_node(_coin_pos)
			var cres := _bfs_next(here, cn)
			if float(cres[1]) < bscore - 0.5 and r.bot_rng.randf() < 0.7:
				best = cn
		if best < 0:
			best = r.bot_rng.randi_range(0, _nodes.size() - 1)
		r.goal = best
	var here2 := _ahead_node(r)
	if here2 == r.goal:
		# Llegó: girar hacia el rival más cercano si está en una vía vecina.
		r.goal = -1
		return r.face
	var nxt: int = _bfs_next(here2, r.goal)[0]
	# No se puede volver por donde vino: si el camino más corto pide dar la vuelta en el cruce, tomar otra vía
	# (la que deje más cerca del objetivo).
	var from_face := r.face if r.m < 0 else (_nodes[r.m] - _nodes[r.n]).normalized()
	if not _can_take(here2, nxt, from_face):
		var best_o := -1
		var best_d := 1e9
		for o in _adj[here2]:
			if _can_take(here2, o, from_face):
				var dd := float(_bfs_next(o, r.goal)[1]) + r.bot_rng.randf() * 0.5
				if dd < best_d:
					best_d = dd
					best_o = o
		if best_o >= 0:
			nxt = best_o
	if r.m >= 0 and nxt != r.m:
		# Aún en el tramo: seguir hasta el cruce y allí girar.
		var dir_to: Vector2 = (_nodes[r.m] - r.pos)
		if dir_to.length() < 0.05:
			return (_nodes[nxt] - _nodes[r.m]).normalized()
		return dir_to.normalized()
	var target: Vector2 = _nodes[nxt]
	var v3 := target - r.pos
	if v3.length() < 0.05:
		return r.face
	return v3.normalized() * lerpf(0.85, 1.0, r.skill)

func _bot_move(player: PlayerData) -> Vector2:
	var r: RS = _rs.get(player.id)
	if r == null:
		return Vector2.ZERO
	return _bot_think(r)

func _bot_action(player: PlayerData) -> int:
	var r: RS = _rs.get(player.id)
	if r == null:
		return 0
	var v := 1 if r.want_fire else 0
	r.want_fire = false
	return v

# ----------------------------------------------------------------------------
# Escena 3D
# ----------------------------------------------------------------------------

func _mat(c: Color, emission: float = 0.0, rough: float = 0.7, metal: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emission
	return m

func _toon(c: Color, outline: float = 0.03) -> StandardMaterial3D:
	var m := _mat(c, 0.0, 0.5)
	var o := StandardMaterial3D.new()
	o.albedo_color = Color(0.08, 0.06, 0.1)
	o.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	o.cull_mode = BaseMaterial3D.CULL_FRONT
	o.grow = true
	o.grow_amount = outline
	m.next_pass = o
	return m

func _mesh(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi

func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	return _mesh(parent, bm, pos, mat)

func _sphere(parent: Node3D, radius: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 20
	sm.rings = 10
	return _mesh(parent, sm, pos, mat)

func _cyl(parent: Node3D, top: float, bottom: float, height: float, pos: Vector3, mat: Material, segs: int = 20) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.top_radius = top
	cm.bottom_radius = bottom
	cm.height = height
	cm.radial_segments = segs
	return _mesh(parent, cm, pos, mat)

# --- Texturas procedurales (una vez) ---
static var _tex_ground: ImageTexture = null
static var _tex_hedge: ImageTexture = null
static var _tex_brick: ImageTexture = null
static var _tex_target: ImageTexture = null

## Adoquines marrones irregulares (celdas de Voronoi con juntas oscuras).
func _ground_texture() -> ImageTexture:
	if _tex_ground != null:
		return _tex_ground
	var size := 256
	var cells := 9
	var pr := RandomNumberGenerator.new()
	pr.seed = 77
	var pts: Array[Vector2] = []
	var shade: Array[float] = []
	for j in cells:
		for i in cells:
			pts.append(Vector2((i + pr.randf_range(0.15, 0.85)) * size / cells, (j + pr.randf_range(0.15, 0.85)) * size / cells))
			shade.append(pr.randf_range(0.85, 1.12))
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			var d1 := INF
			var d2 := INF
			var k1 := 0
			var p := Vector2(x, y)
			var ci := int(x * cells / size)
			var cj := int(y * cells / size)
			for dj in range(-1, 2):
				for di in range(-1, 2):
					var ii := posmod(ci + di, cells)
					var jj := posmod(cj + dj, cells)
					var q: Vector2 = pts[jj * cells + ii] + Vector2((ci + di - ii) * size / cells, (cj + dj - jj) * size / cells)
					var dd := p.distance_to(q)
					if dd < d1:
						d2 = d1
						d1 = dd
						k1 = jj * cells + ii
					elif dd < d2:
						d2 = dd
			var base := Color(0.5, 0.33, 0.24) * shade[k1]
			if d2 - d1 < 2.2:
				base = Color(0.3, 0.2, 0.15)
			img.set_pixel(x, y, base)
	img.generate_mipmaps()
	_tex_ground = ImageTexture.create_from_image(img)
	return _tex_ground

func _hedge_texture() -> ImageTexture:
	if _tex_hedge != null:
		return _tex_hedge
	var n := FastNoiseLite.new()
	n.seed = 5
	n.frequency = 0.09
	n.fractal_octaves = 4
	var nn := n.get_seamless_image(128, 128)
	var img := Image.create(128, 128, false, Image.FORMAT_RGB8)
	for y in 128:
		for x in 128:
			var v := nn.get_pixel(x, y).r
			var c := Color(0.08, 0.3, 0.07).lerp(Color(0.36, 0.66, 0.2), clampf(v * 1.4 - 0.15, 0.0, 1.0))
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	_tex_hedge = ImageTexture.create_from_image(img)
	return _tex_hedge

func _brick_texture() -> ImageTexture:
	if _tex_brick != null:
		return _tex_brick
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 64:
			var row := y / 16
			var xx := (x + (8 if row % 2 == 1 else 0)) % 32
			var joint := y % 16 < 2 or xx < 2
			img.set_pixel(x, y, Color(0.32, 0.5, 0.85) if joint else Color(0.45, 0.66, 0.95))
	img.generate_mipmaps()
	_tex_brick = ImageTexture.create_from_image(img)
	return _tex_brick

func _target_texture() -> ImageTexture:
	if _tex_target != null:
		return _tex_target
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var rr := Vector2(x - 31.5, y - 31.5).length() / 32.0
			var c := Color(0, 0, 0, 0)
			if rr <= 1.0:
				var ring := int(rr * 5.0)
				c = Color(0.9, 0.12, 0.15) if ring % 2 == 0 else Color(1, 1, 1)
				if rr > 0.93:
					c = Color(0.55, 0.05, 0.08)
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	_tex_target = ImageTexture.create_from_image(img)
	return _tex_target

func _build_world() -> void:
	if _built:
		return
	_built = true
	var cont := SubViewportContainer.new()
	cont.stretch = true
	cont.top_level = true
	cont.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_cont = cont
	cont.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(cont)
	move_child(cont, surface.get_index())
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.handle_input_locally = false
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	cont.add_child(_vp)
	_root3 = Node3D.new()
	_vp.add_child(_root3)
	# --- Día soleado ---
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.78, 0.4)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.85, 0.95)
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.15
	env.adjustment_contrast = 1.08
	var we := WorldEnvironment.new()
	we.environment = env
	_root3.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-58.0, -30.0, 0.0)
	sun.light_energy = 0.85
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 70.0
	sun.shadow_bias = 0.04
	_root3.add_child(sun)
	var W := _half.x * 2.0
	var H := _half.y * 2.0
	# --- Césped exterior y suelo de adoquines ---
	_box(_root3, Vector3(W + 60.0, 0.2, H + 60.0), Vector3(0, -0.2, 0), _mat(Color(0.5, 0.75, 0.3)))
	var gm := _mat(Color(1, 1, 1), 0.0, 0.9)
	gm.albedo_texture = _ground_texture()
	gm.uv1_scale = Vector3((W + 3.0) / 6.0, (H + 3.0) / 6.0, 1.0)
	gm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var pm := PlaneMesh.new()
	pm.size = Vector2(W + 3.0, H + 3.0)
	_mesh(_root3, pm, Vector3(0, 0, 0), gm)
	# --- Muro del patio: ladrillo azul con remate naranja ---
	var brick := _mat(Color(1, 1, 1), 0.0, 0.8)
	brick.albedo_texture = _brick_texture()
	brick.uv1_scale = Vector3(12.0, 1.0, 1.0)
	brick.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var brick_side := brick.duplicate() as StandardMaterial3D
	brick_side.uv1_scale = Vector3(1.0, 1.0, 9.0)
	var top_mat := _mat(Color(1.0, 0.62, 0.15), 0.0, 0.5)
	var stripe := _mat(Color(1.0, 0.86, 0.35), 0.0, 0.5)
	var wall_h := 0.9
	var ox := _half.x + 2.0
	var oz := _half.y + 2.0
	for sx in [-1.0, 1.0]:
		_box(_root3, Vector3(1.0, wall_h, oz * 2.0 + 1.0), Vector3(sx * ox, wall_h * 0.5, 0), brick_side)
		_box(_root3, Vector3(1.3, 0.22, oz * 2.0 + 1.3), Vector3(sx * ox, wall_h + 0.11, 0), top_mat)
		_box(_root3, Vector3(0.5, 0.06, oz * 2.0 + 1.0), Vector3(sx * ox, wall_h + 0.25, 0), stripe)
		# Arbustos redondos junto al muro.
		for i in int(oz * 2.0 / 2.2):
			_sphere(_root3, 0.55, Vector3(sx * (ox + 1.3), 0.4, -oz + 1.0 + i * 2.2), _toon(Color(0.2, 0.55, 0.18), 0.02))
	_box(_root3, Vector3(ox * 2.0 + 1.0, wall_h, 1.0), Vector3(0, wall_h * 0.5, oz), brick)
	_box(_root3, Vector3(ox * 2.0 + 1.3, 0.22, 1.3), Vector3(0, wall_h + 0.11, oz), top_mat)
	_box(_root3, Vector3(ox * 2.0 + 1.0, 0.06, 0.5), Vector3(0, wall_h + 0.25, oz), stripe)
	# --- Castillo al fondo ---
	var cz := -oz - 1.2
	var castle := _mat(Color(0.98, 0.9, 0.78), 0.0, 0.7)
	var pink := _mat(Color(0.95, 0.55, 0.65), 0.0, 0.6)
	_box(_root3, Vector3(ox * 2.0 + 1.0, 4.2, 2.0), Vector3(0, 2.1, cz), castle)
	_box(_root3, Vector3(ox * 2.0 + 1.2, 0.35, 2.2), Vector3(0, 4.3, cz), pink)
	for i in int((ox * 2.0) / 1.4):
		_box(_root3, Vector3(0.7, 0.6, 2.0), Vector3(-ox + 0.5 + i * 1.4, 4.75, cz), castle)
	var tower_mat := _mat(Color(0.3, 0.5, 0.92), 0.0, 0.6)
	var roof := _mat(Color(0.92, 0.4, 0.4), 0.0, 0.6)
	var tx := [-ox, -2.6, 2.6, ox]
	for x in tx:
		var tall := 6.5 if absf(float(x)) < ox - 0.1 else 5.5
		_cyl(_root3, 1.1, 1.1, tall, Vector3(float(x), tall * 0.5, cz + 0.4), tower_mat)
		_cyl(_root3, 1.3, 1.3, 0.4, Vector3(float(x), tall + 0.2, cz + 0.4), _mat(Color(0.98, 0.9, 0.78)))
		_cyl(_root3, 0.0, 1.35, 2.2, Vector3(float(x), tall + 1.5, cz + 0.4), roof)
		for k in 2:
			_box(_root3, Vector3(0.28, 0.9, 0.1), Vector3(float(x), tall * (0.45 + 0.25 * k), cz + 1.52), _mat(Color(0.15, 0.2, 0.45)))
	# Puerta grande de madera.
	_box(_root3, Vector3(2.4, 2.8, 0.2), Vector3(0, 1.4, cz + 1.05), _mat(Color(0.75, 0.48, 0.18), 0.0, 0.8))
	_cyl(_root3, 1.2, 1.2, 0.2, Vector3(0, 2.8, cz + 1.05), _mat(Color(0.75, 0.48, 0.18), 0.0, 0.8)).rotation_degrees = Vector3(90, 0, 0)
	_box(_root3, Vector3(0.08, 3.6, 0.25), Vector3(0, 1.8, cz + 1.12), _mat(Color(0.45, 0.28, 0.1)))
	# Banderines de colores sobre el muro del castillo.
	for i in 14:
		var fx := -ox + (i + 0.5) * (ox * 2.0 / 14.0)
		_box(_root3, Vector3(0.3, 0.4, 0.05), Vector3(fx, 3.7, cz + 1.02), _mat(Color.from_hsv(float(i) / 14.0, 0.6, 1.0)))
	# --- Setos y parterres ---
	_build_hedges()
	# --- Raíles ---
	_build_rails()
	# --- Moneda S y balas ---
	_coin_node = Node3D.new()
	_root3.add_child(_coin_node)
	var coin_disc := _cyl(_coin_node, 0.5, 0.5, 0.12, Vector3.ZERO, _mat(Color(1.0, 0.82, 0.15), 0.6, 0.3, 0.6), 28)
	coin_disc.rotation_degrees = Vector3(90, 0, 0)
	_cyl(_coin_node, 0.42, 0.42, 0.14, Vector3.ZERO, _mat(Color(1.0, 0.92, 0.45), 0.4, 0.3, 0.6), 28).rotation_degrees = Vector3(90, 0, 0)
	for side in [-1.0, 1.0]:
		var sl := Label3D.new()
		sl.text = "S"
		sl.font_size = 96
		sl.pixel_size = 0.006
		sl.outline_size = 12
		sl.outline_modulate = Color(0.55, 0.35, 0.0)
		sl.modulate = Color(1.0, 0.75, 0.05)
		sl.position = Vector3(0, 0, 0.09 * side)
		sl.rotation_degrees = Vector3(0, 0 if side > 0.0 else 180, 0)
		sl.shaded = false
		_coin_node.add_child(sl)
	_coin_node.visible = false
	# --- Jugadores y cámara ---
	_rebuild_player_nodes()
	_cam = Camera3D.new()
	_cam.fov = 45.0
	_cam.far = 250.0
	_root3.add_child(_cam)
	var f := maxf(W / 19.0, H / 13.2)
	_cam_base = Vector3(0, 23.5 * f, 15.0 * f + 1.0)
	_cam.position = _cam_base
	_cam.current = true
	_cam.look_at(Vector3(0, 0, 1.2 * f), Vector3.UP)
	_update_world(0.0)

## Un seto por celda de la rejilla, unidos donde el tramo entre dos celdas no tiene vía.
func _build_hedges() -> void:
	var hm := _mat(Color(1, 1, 1), 0.0, 0.95)
	hm.albedo_texture = _hedge_texture()
	hm.uv1_triplanar = true
	hm.uv1_scale = Vector3(0.45, 0.45, 0.45)
	var base := _mat(Color(0.36, 0.55, 0.85), 0.0, 0.7)
	var hh := 1.25
	var m := LANE
	var fr := RandomNumberGenerator.new()
	fr.seed = hash([seed_value, "flowers"])
	for r in _rows - 1:
		for c in _cols - 1:
			var a := _nodes[_nid(c, r)]
			var b := _nodes[_nid(c + 1, r + 1)]
			var center := (a + b) * 0.5
			var sz := (b - a) - Vector2(m * 2.0, m * 2.0)
			# ¿Celda suelta (todos sus lados con vía)? A veces es un parterre de flores en vez de seto.
			var lone := _has_edge(_nid(c, r), _nid(c + 1, r)) and _has_edge(_nid(c, r + 1), _nid(c + 1, r + 1)) \
					and _has_edge(_nid(c, r), _nid(c, r + 1)) and _has_edge(_nid(c + 1, r), _nid(c + 1, r + 1))
			if lone and fr.randf() < 0.35:
				_box(_root3, Vector3(sz.x, 0.25, sz.y), Vector3(center.x, 0.125, center.y), _mat(Color(0.95, 0.92, 0.85)))
				_box(_root3, Vector3(sz.x - 0.3, 0.27, sz.y - 0.3), Vector3(center.x, 0.14, center.y), _mat(Color(0.3, 0.6, 0.2)))
				for k in 14:
					var fp := center + Vector2(fr.randf_range(-sz.x * 0.4, sz.x * 0.4), fr.randf_range(-sz.y * 0.4, sz.y * 0.4))
					_sphere(_root3, 0.11, Vector3(fp.x, 0.33, fp.y), _mat(Color.from_hsv(fr.randf(), 0.6, 1.0)))
				continue
			_hedge_box(Vector2(center.x, center.y), sz, hh, hm, base)
	# Uniones entre celdas donde no hay vía.
	for k in _removed:
		var p := _nodes[int(k) / 1000]
		var q := _nodes[int(k) % 1000]
		var mid := (p + q) * 0.5
		var horiz := absf(p.y - q.y) < 0.01
		var sz2 := Vector2(SPACING - m * 2.0, m * 2.0) if horiz else Vector2(m * 2.0, SPACING - m * 2.0)
		_hedge_box(mid, sz2 + (Vector2(0, 0.02) if horiz else Vector2(0.02, 0)), hh, hm, base)
	# Esquinas alrededor de un cruce donde los dos tramos que la cierran son seto.
	for r2 in range(1, _rows - 1):
		for c2 in range(1, _cols - 1):
			var nd := _nid(c2, r2)
			var dirs := [[1, 0], [0, 1], [-1, 0], [0, -1]]
			for q in 4:
				var d1: Array = dirs[q]
				var d2: Array = dirs[(q + 1) % 4]
				var n1 := _nid(c2 + d1[0], r2 + d1[1])
				var n2 := _nid(c2 + d2[0], r2 + d2[1])
				if not _has_edge(nd, n1) and not _has_edge(nd, n2):
					var cen := _nodes[nd] + Vector2((d1[0] + d2[0]) * m * 0.5, (d1[1] + d2[1]) * m * 0.5)
					_hedge_box(cen, Vector2(m + 0.02, m + 0.02), hh, hm, base)

func _hedge_box(center: Vector2, sz: Vector2, hh: float, hm: Material, base: Material) -> void:
	_box(_root3, Vector3(sz.x + 0.1, 0.35, sz.y + 0.1), Vector3(center.x, 0.175, center.y), base)
	_box(_root3, Vector3(sz.x, hh, sz.y), Vector3(center.x, 0.35 + hh * 0.5, center.y), hm)

func _build_rails() -> void:
	var rail_mat := _mat(Color(0.92, 0.92, 0.95), 0.0, 0.35, 0.6)
	var sleeper := _mat(Color(0.82, 0.8, 0.78), 0.0, 0.8)
	for k in _edges:
		var a := _nodes[int(k) / 1000]
		var b := _nodes[int(k) % 1000]
		var L := a.distance_to(b)
		var dir := (b - a) / L
		var perp := Vector2(-dir.y, dir.x)
		var mid := (a + b) * 0.5
		var holder := Node3D.new()
		_root3.add_child(holder)
		holder.position = Vector3(mid.x, 0.0, mid.y)
		holder.rotation.y = atan2(dir.x, dir.y)
		for s in [-1.0, 1.0]:
			_box(holder, Vector3(0.09, 0.08, L), Vector3(s * 0.33, 0.07, 0), rail_mat)
		var cnt := int(L / 0.55)
		for i in cnt:
			_box(holder, Vector3(0.95, 0.04, 0.16), Vector3(0, 0.025, -L * 0.5 + (i + 0.5) * L / cnt), sleeper)
	# Placa en cada cruce.
	for i in _nodes.size():
		_box(_root3, Vector3(0.95, 0.05, 0.95), Vector3(_nodes[i].x, 0.03, _nodes[i].y), sleeper)

func _rebuild_player_nodes() -> void:
	if not _built:
		return
	for id in _order:
		var r: RS = _rs[id]
		for nd in [r.node, r.ring]:
			if nd != null and is_instance_valid(nd):
				(nd as Node).queue_free()
		_build_player(r, _player_by_id(id))

## Vagoneta en forma de taza con el piloto dentro, cañón delante y diana detrás.
func _build_player(r: RS, pl: PlayerData) -> void:
	var col: Color = pl.color if pl != null else Palette.YELLOW
	r.node = Node3D.new()
	_root3.add_child(r.node)
	r.body = Node3D.new()
	r.node.add_child(r.body)
	var b := r.body
	_cyl(b, 0.34, 0.34, 0.16, Vector3(0, 0.12, 0), _mat(Color(0.25, 0.25, 0.3), 0.0, 0.4, 0.7))       # bogie
	_cyl(b, 0.58, 0.42, 0.62, Vector3(0, 0.52, 0), _toon(col))                                        # taza
	var rim := TorusMesh.new()
	rim.inner_radius = 0.5
	rim.outer_radius = 0.62
	_mesh(b, rim, Vector3(0, 0.83, 0), _mat(Color(1, 1, 1), 0.0, 0.4))
	_cyl(b, 0.6, 0.6, 0.06, Vector3(0, 0.36, 0), _mat(col.lightened(0.45)))                           # franja
	# Piloto: cuerpo y cabeza con pelo y ojos mirando al frente (+z).
	_cyl(b, 0.28, 0.32, 0.45, Vector3(0, 0.95, -0.05), _toon(col.lightened(0.25), 0.02))
	var skin := Color(1.0, 0.82, 0.66)
	_sphere(b, 0.3, Vector3(0, 1.42, -0.05), _toon(skin, 0.02))
	var hair := _sphere(b, 0.31, Vector3(0, 1.5, -0.1), _toon(Color(0.22, 0.14, 0.1), 0.02))
	hair.scale = Vector3(1.0, 0.75, 1.0)
	for sx in [-1.0, 1.0]:
		_sphere(b, 0.05, Vector3(sx * 0.11, 1.42, 0.22), _mat(Color(0.08, 0.06, 0.08), 0.0, 0.2))
	# Cañón delante.
	r.barrel = Node3D.new()
	r.barrel.position = Vector3(0, 0.66, 0.42)
	b.add_child(r.barrel)
	var tube := _cyl(r.barrel, 0.15, 0.18, 0.62, Vector3(0, 0, 0.22), _mat(Color(0.18, 0.18, 0.22), 0.0, 0.35, 0.8))
	tube.rotation_degrees = Vector3(90, 0, 0)
	var muzzle := TorusMesh.new()
	muzzle.inner_radius = 0.12
	muzzle.outer_radius = 0.2
	var mz := _mesh(r.barrel, muzzle, Vector3(0, 0, 0.52), _mat(Color(0.3, 0.3, 0.35), 0.0, 0.3, 0.8))
	mz.rotation_degrees = Vector3(90, 0, 0)
	# Diana detrás.
	var tm := StandardMaterial3D.new()
	tm.albedo_texture = _target_texture()
	tm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	tm.cull_mode = BaseMaterial3D.CULL_DISABLED
	var qm := QuadMesh.new()
	qm.size = Vector2(0.95, 0.95)
	var target := _mesh(b, qm, Vector3(0, 0.62, -0.6), tm)
	target.rotation_degrees = Vector3(0, 180, 0)
	# Llamita de turbo (moneda S).
	r.flame = _sphere(b, 0.2, Vector3(0, 0.3, -0.75), _mat(Color(1.0, 0.6, 0.1), 2.5))
	r.flame.visible = false
	r.flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Estrellitas de aturdido.
	r.stars = Node3D.new()
	r.stars.position = Vector3(0, 1.95, 0)
	r.node.add_child(r.stars)
	for i in 3:
		var st := _sphere(r.stars, 0.1, Vector3(cos(i * TAU / 3.0) * 0.45, 0, sin(i * TAU / 3.0) * 0.45), _mat(Color(1.0, 0.9, 0.3), 1.6))
		st.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	r.stars.visible = false
	# Anillo de color en el suelo.
	var is_me := pl != null and (pl == local_player or (local_player == null and pl.is_local_human))
	var rt := TorusMesh.new()
	rt.inner_radius = 0.72
	rt.outer_radius = 0.86 if not is_me else 0.95
	r.ring = _mesh(_root3, rt, Vector3.ZERO, _mat(col, 0.9, 0.4))
	r.ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	r.tag = Label3D.new()
	r.tag.text = "▼"
	r.tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	r.tag.no_depth_test = true
	r.tag.font_size = 90
	r.tag.pixel_size = 0.011
	r.tag.modulate = Palette.YELLOW
	r.tag.outline_size = 18
	r.tag.outline_modulate = Color(0.03, 0.03, 0.06)
	r.tag.visible = is_me
	r.tag.position = Vector3(0, 2.5, 0)
	r.node.add_child(r.tag)
	r.dpos = r.pos
	r.dang = atan2(r.face.x, r.face.y)

func _spawn_puff(p: Vector3, size: float, col: Color) -> void:
	if not _built:
		return
	for i in 4:
		var m := _mat(col, 0.0, 1.0)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var s := _sphere(_root3, size * (0.45 + 0.12 * i), p + Vector3(randf_range(-0.2, 0.2), randf_range(0.0, 0.2), randf_range(-0.2, 0.2)), m)
		s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_fx.append({"n": s, "age": 0.0, "life": 0.45, "kind": "puff", "v": Vector3(randf_range(-1, 1), 1.2, randf_range(-1, 1))})

## Columna de luz y estrellas cuando alguien sale volando.
func _spawn_pillar(r: RS) -> void:
	if not _built:
		return
	var m := _mat(Color(1.0, 1.0, 0.85), 3.0)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var c := _cyl(_root3, 0.7, 0.9, 14.0, Vector3(r.dpos.x, 7.0, r.dpos.y), m)
	c.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fx.append({"n": c, "age": 0.0, "life": 1.1, "kind": "pillar", "v": Vector3.ZERO})
	for i in 8:
		var sm := _mat(Color(1.0, 0.9, 0.2), 2.0)
		var st := _sphere(_root3, 0.14, Vector3(r.dpos.x, 1.0, r.dpos.y), sm)
		st.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var a := TAU * i / 8.0
		_fx.append({"n": st, "age": 0.0, "life": 0.9, "kind": "star", "v": Vector3(cos(a) * 3.5, 4.0, sin(a) * 3.5)})

func _fit_view() -> void:
	if _cont == null:
		return
	var off := Vector2.ZERO
	var par := get_parent()
	if par is CanvasLayer:
		off = -(par as CanvasLayer).offset
	_cont.position = off
	_cont.size = get_viewport().get_visible_rect().size

func _update_world(delta: float) -> void:
	_fit_view()
	if not _built or _cam == null:
		return
	var k := 1.0 if delta <= 0.0 else 1.0 - exp(-22.0 * delta)
	for id in _order:
		var r: RS = _rs[id]
		if r.node == null:
			continue
		if r.dpos.distance_to(r.pos) > 4.0:
			r.dpos = r.pos
		else:
			r.dpos = r.dpos.lerp(r.pos, k)
		r.dang = lerp_angle(r.dang, atan2(r.face.x, r.face.y), 1.0 if delta <= 0.0 else 1.0 - exp(-16.0 * delta))
		r.anim += delta
		r.recoil = maxf(0.0, r.recoil - delta * 5.0)
		if not r.alive:
			# Sale volando hacia arriba girando y desaparece.
			r.fly_t += delta
			r.node.position = Vector3(r.dpos.x, r.fly_t * 7.0 + r.fly_t * r.fly_t * 5.0, r.dpos.y)
			r.body.rotation.y += delta * 14.0
			r.node.visible = r.fly_t < 0.9
			r.ring.visible = false
			r.stars.visible = false
			continue
		r.node.visible = true
		r.ring.visible = true
		var bob := sin(r.anim * 18.0) * 0.03 if r.moving else 0.0
		r.node.position = Vector3(r.dpos.x, bob, r.dpos.y)
		r.node.scale = Vector3.ONE * CART_SCALE
		r.body.rotation.y = r.dang
		r.body.rotation.z = sin(r.anim * 25.0) * 0.12 if r.stun_t > 0.0 else 0.0
		r.barrel.position.z = 0.42 - 0.18 * r.recoil
		r.stars.visible = r.stun_t > 0.0
		r.stars.rotation.y += delta * 7.0
		r.flame.visible = r.boost_t > 0.0
		if r.flame.visible:
			r.flame.scale = Vector3.ONE * (0.8 + 0.4 * absf(sin(r.anim * 30.0)))
		r.ring.position = Vector3(r.dpos.x, 0.1, r.dpos.y)
	# Balas.
	while _ball_nodes.size() < _balls.size():
		var bn := _sphere(_root3, 0.2, Vector3.ZERO, _mat(Color(0.15, 0.15, 0.2), 0.0, 0.3, 0.6))
		_ball_nodes.append(bn)
	for i in _ball_nodes.size():
		var bn2: MeshInstance3D = _ball_nodes[i]
		if i < _balls.size():
			var bp: Vector2 = _balls[i]["p"]
			var bd: Vector2 = _balls[i]["d"]
			# Los clientes adelantan la bala entre snapshots.
			if not is_authority and delta > 0.0:
				_balls[i]["p"] = bp + bd * BALL_SPEED * delta
			bn2.visible = true
			bn2.position = Vector3(bp.x, 0.68, bp.y)
			var ow: RS = _rs.get(int(_balls[i]["o"]))
			var pl := _player_by_id(ow.id) if ow != null else null
			var bm := bn2.material_override as StandardMaterial3D
			bm.albedo_color = pl.color.lightened(0.15) if pl != null else Color(0.2, 0.2, 0.25)
			bm.emission_enabled = true
			bm.emission = bm.albedo_color
			bm.emission_energy_multiplier = 0.5
		else:
			bn2.visible = false
	# Moneda S.
	_coin_node.visible = _coin_on and not _over
	if _coin_on:
		_coin_node.position = Vector3(_coin_pos.x, 0.9 + sin(_anim * 3.0) * 0.12, _coin_pos.y)
		_coin_node.rotation.y = _anim * 2.6
	# Efectos.
	var keep: Array = []
	for fx in _fx:
		fx["age"] = float(fx["age"]) + delta
		var n: Node3D = fx["n"]
		var a := float(fx["age"]) / float(fx["life"])
		var mi := n as MeshInstance3D
		var mm := mi.material_override as StandardMaterial3D
		match String(fx["kind"]):
			"puff":
				n.position += (fx["v"] as Vector3) * delta
				n.scale = Vector3.ONE * (1.0 + a * 1.2)
				mm.albedo_color.a = clampf(1.0 - a, 0.0, 1.0) * 0.85
			"pillar":
				n.scale = Vector3(1.0 - a * 0.8, 1.0, 1.0 - a * 0.8)
				mm.albedo_color.a = clampf(1.0 - a, 0.0, 1.0) * 0.7
			"star":
				var v: Vector3 = fx["v"]
				v.y -= 9.0 * delta
				fx["v"] = v
				n.position += v * delta
		if a < 1.0:
			keep.append(fx)
		else:
			n.queue_free()
	_fx = keep
	var shake := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * _shake * 0.3
	_cam.position = _cam_base + shake

# ----------------------------------------------------------------------------
# HUD (dibujo 2D encima del 3D): reloj arriba en el centro, vagonetas vivas abajo
# ----------------------------------------------------------------------------

func _draw_hud() -> void:
	var s := surface
	var left := ceili(_time_left)
	var pill := Rect2(640 - 70, 18, 140, 58)
	s.rounded_rect(pill.grow(4), 32, Color(0.25, 0.25, 0.3, 0.9))
	s.rounded_rect(pill, 29, Color(1, 1, 1, 0.95))
	var cc := Vector2(pill.position.x + 32, pill.position.y + 29)
	s.draw_circle(cc, 17.0, Color(0.25, 0.25, 0.3))
	s.draw_circle(cc, 13.0, Color(1, 1, 1))
	s.draw_line(cc, cc + Vector2(0, -9), Color(0.25, 0.25, 0.3), 3.0)
	s.draw_line(cc, cc + Vector2(7, 0), Color(0.25, 0.25, 0.3), 3.0)
	s.text_centered(Vector2(pill.position.x + 92, pill.position.y + 29), str(left), 40,
			Color(0.3, 0.3, 0.35) if left > 10 else Palette.CORAL, 0)
	# Tarjetas abajo: color, nombre y si sigue en pie.
	var n := _order.size()
	var pw := minf(150.0, 1180.0 / maxf(n, 1))
	var total := pw * n + 8.0 * (n - 1)
	var x0 := (1280.0 - total) * 0.5
	for i in n:
		var r: RS = _rs[_order[i]]
		var pl := _player_by_id(r.id)
		var col: Color = pl.color if pl != null else Palette.WHITE
		var rect := Rect2(x0 + i * (pw + 8.0), 656.0, pw, 48.0)
		var mine := pl != null and (pl == local_player or (local_player == null and pl.is_local_human))
		var dim := 1.0 if r.alive else 0.45
		s.rounded_rect(rect.grow(3.0 if mine else 0.0), 10, Palette.WHITE if mine else Color(0, 0, 0, 0))
		s.rounded_rect(rect, 9, Color(col.r * 0.35 * dim, col.g * 0.35 * dim, col.b * 0.35 * dim, 0.92))
		var dc := rect.position + Vector2(24, 24)
		s.draw_circle(dc, 14.0, col if r.alive else col.darkened(0.5))
		s.draw_circle(dc, 8.0, Color(0.95, 0.15, 0.2) if r.alive else Color(0.3, 0.3, 0.3))
		s.draw_circle(dc, 4.0, Color(1, 1, 1) if r.alive else Color(0.4, 0.4, 0.4))
		if not r.alive:
			s.draw_line(dc + Vector2(-11, -11), dc + Vector2(11, 11), Palette.CORAL, 4.0)
			s.draw_line(dc + Vector2(-11, 11), dc + Vector2(11, -11), Palette.CORAL, 4.0)
		var label := "x%d" % r.kills if r.kills > 0 else ""
		if not r.alive:
			label = "FUERA"
		s.text_centered(rect.position + Vector2(pw - 34.0, 24), label, 20 if not r.alive else 26, Palette.WHITE if r.alive else Color(1, 1, 1, 0.6), 5)
		if pl != null and n <= 6:
			s.text_centered(rect.position + Vector2(pw * 0.5, -10), pl.display_name, 18, Color(1, 1, 1, 0.85 * dim + 0.15), 4)
	if _toast_t > 0.0 and not _over:
		s.text_centered(Vector2(640, 118), _toast, 40, Color(1, 1, 1, clampf(_toast_t * 2.0, 0.0, 1.0)), 9)
	if _hint_t > 0.0 and not _over:
		s.text_centered(Vector2(640, 610), "Muévete por los raíles y dispara con la acción: ¡dale en la DIANA de su espalda!", 24, Color(1, 1, 1, clampf(_hint_t, 0.0, 1.0)), 7)
	if _over:
		s.text_centered(Vector2(640, 290), "¡FIN!", 110, Palette.YELLOW, 14)
		var names: Array[String] = []
		for id in _winners:
			var w := _player_by_id(int(id))
			if w != null:
				names.append(w.display_name)
		if names.size() == 1:
			var w1 := _player_by_id(int(_winners[0]))
			s.text_centered(Vector2(640, 385), "Gana %s" % names[0], 56, w1.color.lightened(0.25), 10)
		elif names.size() > 1:
			s.text_centered(Vector2(640, 385), "Siguen en pie: %s" % ", ".join(names), 40, Palette.WHITE, 9)

# ----------------------------------------------------------------------------
# Utilidades de depuración / pruebas (tests/rail_cannons_test.gd)
# ----------------------------------------------------------------------------

func debug_grid() -> Vector2i:
	return Vector2i(_cols, _rows)

func debug_nodes() -> Array[Vector2]:
	return _nodes

func debug_adj() -> Array:
	return _adj

func debug_removed() -> int:
	return _removed.size()

func debug_player(id: int) -> Dictionary:
	var r: RS = _rs.get(id)
	if r == null:
		return {}
	return {"pos": r.pos, "face": r.face, "alive": r.alive, "stun": r.stun_t, "kills": r.kills, "boost": r.boost_t, "n": r.n, "m": r.m}

## Coloca una vagoneta en el cruce `node` mirando hacia el cruce vecino `toward`.
func debug_place(id: int, node: int, toward: int) -> void:
	var r: RS = _rs.get(id)
	if r == null:
		return
	r.n = node
	r.m = -1
	r.t = 0.0
	r.face = (_nodes[toward] - _nodes[node]).normalized()
	r.stun_t = 0.0
	r.fire_cd = 0.0
	r.moving = false
	_update_pos(r)

func debug_drive(id: int, want: Vector2, seconds: float) -> void:
	var r: RS = _rs[id]
	var t := 0.0
	while t < seconds:
		_drive(r, want, SPEED * STEP)
		t += STEP

func debug_fire(id: int) -> void:
	_try_fire(_rs[id])

func debug_step_balls(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		_step_balls(STEP)
		t += STEP

func debug_ball_count() -> int:
	return _balls.size()

func debug_lane_dist(p: Vector2) -> float:
	return _lane_dist(p)

func debug_coin(p: Vector2) -> void:
	_coin_on = true
	_coin_pos = p
	_coin_t = COIN_LIFE

func debug_step_coin() -> void:
	_step_coin(STEP)

func debug_kill_all_but(id: int) -> void:
	for oid in _order:
		if oid != id:
			var r: RS = _rs[oid]
			r.alive = false
			r.out_t = _elapsed
	_end_game()

func debug_stats() -> Dictionary:
	return _stats

func debug_over() -> bool:
	return _over

func debug_winners() -> Array:
	return _winners

func debug_ranking() -> Array[int]:
	return _ranking()
