extends Minigame
## Fuga en Pareja (id pair_escape; modelo HOST_AUTHORITATIVE, 3D): se juega POR PAREJAS. Cada pareja tiene su propio
## laberinto de piedra suspendido sobre un abismo, partido en dos por una gran columna tumbada: cada miembro corre por SU
## mitad, que es el reflejo exacto de la del compañero. Hay que llegar a la salida del fondo antes de que acabe el tiempo.
##   - Si te sales del camino, TROPIEZAS: caes al suelo un momento y vuelves a la última baldosa segura.
##   - Las rejas cortan el paso a los dos a la vez: solo se abren si los DOS pisáis a la vez vuestra baldosa roja.
##   - La pareja escapa cuando han salido los dos. Gana la que antes escape; si no, la que más haya avanzado.
## Solo se juega con un número PAR de jugadores (meta.tres: even_players_only); las parejas se sortean con la semilla.
##
## El host simula todo (60 Hz) en coordenadas del laberinto: u = distancia lateral desde la columna, v = avance. El estado
## se envía a ~30 Hz y los clientes interpolan. El 3D (SubViewport con su propio mundo) es solo presentación; si hay varias
## personas de este PC en parejas distintas, la pantalla se parte (un visor por pareja, mismo mundo 3D).

const STEP := 1.0 / 60.0
const TIME_LIMIT := 60.0
const COUNTDOWN := 3.0
const DONE_DELAY := 2.8
# --- Laberinto ---
const COLS := 5                          # baldosas por mitad (0 = junto a la columna)
const T := 2.0                           # lado de una baldosa
const LANES := 20                        # pasillos laterales (filas pares); las impares son pasos de una baldosa
const ROWS := LANES * 2 + 1              # la última fila es la salida
const GATE_LANES: Array[int] = [5, 10, 15]
const PILLAR_HALF := 0.9                 # media anchura del hueco de la columna
const PAIR_DX := 30.0                    # separación entre laberintos de parejas
const VOID := 0
const PATH := 1
const PLATE := 2
const GATE := 3
const EXIT := 4
const START := 5
# --- Jugadores ---
const RADIUS := 0.32
const RUN_SPEED := 6.0
const ACCEL := 40.0
const EDGE_GRACE := 0.28                 # margen fuera de la baldosa antes de tropezar
const TRIP_TIME := 1.1
const FLOATS := 8                        # por jugador en el estado enviado

## Un jugador (lo simula el host; los clientes lo reciben y solo interpolan la presentación).
class RS:
	var id: int = 0
	var pair: int = 0
	var side: float = -1.0                   # -1 izquierda de la columna, +1 derecha
	var pos: Vector2 = Vector2.ZERO          # (u, v) en el laberinto
	var vel: Vector2 = Vector2.ZERO
	var face: float = PI
	var stun_t: float = 0.0
	var safe: Vector2i = Vector2i.ZERO       # (fila, columna) de la última baldosa segura
	var best_row: int = 0
	var escaped: bool = false
	var esc_t: float = 0.0
	# IA
	var skill: float = 1.0
	var think_t: float = 0.0
	var path: Array[Vector2i] = []
	var over_t: float = 0.0                  # despiste: sigue recto en una curva (y suele tropezar)
	var over_dir: Vector2 = Vector2.ZERO
	var last_dir: Vector2 = Vector2.ZERO
	var rolled: Vector2i = Vector2i(-1, -1)
	var bot_rng: RandomNumberGenerator = null
	# Presentación
	var dpos: Vector2 = Vector2.ZERO
	var dface: float = PI
	var anim: float = 0.0
	var node: Node3D = null
	var body: Node3D = null
	var arm_l: Node3D = null
	var arm_r: Node3D = null
	var leg_l: Node3D = null
	var leg_r: Node3D = null
	var drops: Node3D = null
	var tag: Label3D = null

## Una pareja: sus miembros (1 si el reparto es impar, p. ej. en una práctica rara), sus rejas y su hora de escape.
class Pair:
	var members: Array[int] = []
	var open: Array[bool] = []
	var escaped: bool = false
	var esc_t: float = 0.0
	# Presentación
	var gates: Array = []                    # por reja: [Node3D izq, Node3D der]
	var gate_y: Array[float] = []
	var cam_z: float = 0.0

var _grid: PackedByteArray = PackedByteArray()
var _gate_rows: Array[int] = []
var _rs: Dictionary = {}                 # player id -> RS
var _order: Array[int] = []
var _pairs: Array = []                   # Array[Pair]
var _time_left: float = TIME_LIMIT
var _elapsed: float = 0.0
var _cd: float = COUNTDOWN
var _last_cd: int = 99
var _accum: float = 0.0
var _over: bool = false
var _over_t: float = 0.0
var _win_pair: int = -1
var _toast: String = ""
var _toast_t: float = 0.0
var _hint_t: float = 7.0
var _anim: float = 0.0
var debug_skill: float = -1.0

# --- Escena 3D ---
var _root3: Node3D
var _views: Array = []                   # {cont, vp, cam, pair}
var _built: bool = false
var _view_pairs: Array[int] = []
var _floaters: Array = []
var _torches: Array[OmniLight3D] = []
var _exit_glow: Array[MeshInstance3D] = []

# ----------------------------------------------------------------------------
# Laberinto (igual para todas las parejas; sale de la semilla común)
# ----------------------------------------------------------------------------

func _kind(row: int, col: int) -> int:
	if row < 0 or row >= ROWS or col < 0 or col >= COLS:
		return VOID
	return _grid[row * COLS + col]

func _set_kind(row: int, col: int, k: int) -> void:
	_grid[row * COLS + col] = k

func _gen_maze() -> void:
	var mr := RandomNumberGenerator.new()
	mr.seed = hash([seed_value, "pair_escape"])
	_grid = PackedByteArray()
	_grid.resize(ROWS * COLS)
	_grid.fill(VOID)
	_gate_rows.clear()
	for c in COLS:
		_set_kind(0, c, START)
	var cur := 2
	var conn: Array[int] = []            # columna del paso de cada pasillo
	for lane in LANES:
		var r := lane * 2
		var gate := GATE_LANES.has(lane)
		var k := 0
		if not gate:
			k = mr.randi_range(0, COLS - 1)
			var guard := 0
			while (k == cur or (lane > 0 and absi(k - cur) < 2 and mr.randf() < 0.5)) and guard < 10:
				k = mr.randi_range(0, COLS - 1)
				guard += 1
		for c in range(mini(cur, k), maxi(cur, k) + 1):
			if _kind(r, c) == VOID:
				_set_kind(r, c, PATH)
		# Ramal sin salida a un lado del pasillo.
		if lane > 0 and not gate and mr.randf() < 0.5:
			var lo := mini(cur, k)
			var hi := maxi(cur, k)
			var ext := mr.randi_range(1, 2)
			if hi < COLS - 1 and (lo == 0 or mr.randf() < 0.5):
				for c in range(hi + 1, mini(hi + ext, COLS - 1) + 1):
					_set_kind(r, c, PATH)
			elif lo > 0:
				for c in range(maxi(lo - ext, 0), lo):
					_set_kind(r, c, PATH)
		if gate:
			_set_kind(r, 0, PLATE)
			_set_kind(r + 1, 0, GATE)
			_gate_rows.append(r + 1)
		else:
			_set_kind(r + 1, k, PATH)
		conn.append(k)
		cur = k
	for c in COLS:
		_set_kind(ROWS - 1, c, EXIT)
	# Entrantes sin salida hacia delante (nunca en las filas de reja ni antes de la salida).
	for lane in range(1, LANES - 1):
		var q := lane * 2 + 1
		if _gate_rows.has(q):
			continue
		for c in COLS:
			if c == conn[lane] or _kind(q - 1, c) == VOID or _kind(q + 1, c) != VOID:
				continue
			if mr.randf() < 0.22:
				_set_kind(q, c, PATH)

func _gate_index(row: int) -> int:
	return _gate_rows.find(row)

func _walkable(pair: Pair, row: int, col: int) -> bool:
	var k := _kind(row, col)
	if k == GATE:
		return pair.open[_gate_index(row)]
	return k != VOID

func _tile_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.y / T + 0.5), floori(p.x / T))

func _tile_center(t: Vector2i) -> Vector2:
	return Vector2((t.y + 0.5) * T, t.x * T)

func _ground_at(pair: Pair, p: Vector2) -> bool:
	var t := _tile_of(p)
	return _walkable(pair, t.x, t.y)

func _on_ground(pair: Pair, p: Vector2) -> bool:
	if _ground_at(pair, p):
		return true
	for o in [Vector2(EDGE_GRACE, 0), Vector2(-EDGE_GRACE, 0), Vector2(0, EDGE_GRACE), Vector2(0, -EDGE_GRACE)]:
		if _ground_at(pair, p + o):
			return true
	return false

func _closed_gate_at(pair: Pair, p: Vector2) -> bool:
	var t := _tile_of(p)
	return _kind(t.x, t.y) == GATE and not pair.open[_gate_index(t.x)]

# ----------------------------------------------------------------------------
# Simulación (solo el host)
# ----------------------------------------------------------------------------

func _setup_players() -> void:
	for old in _rs.values():
		if (old as RS).node != null and is_instance_valid((old as RS).node):
			(old as RS).node.queue_free()
	_rs.clear()
	_order.clear()
	_pairs.clear()
	_gen_maze()
	# Parejas al azar (misma semilla en todos los PC → mismo reparto).
	var ids: Array[int] = []
	for pl in players:
		ids.append(pl.id)
	var pr := RandomNumberGenerator.new()
	pr.seed = hash([seed_value, "pairs"])
	for i in range(ids.size() - 1, 0, -1):
		var j := pr.randi_range(0, i)
		var tmp := ids[i]
		ids[i] = ids[j]
		ids[j] = tmp
	var i := 0
	while i < ids.size():
		var pa := Pair.new()
		pa.members.append(ids[i])
		if i + 1 < ids.size():
			pa.members.append(ids[i + 1])
		for g in _gate_rows.size():
			pa.open.append(false)
			pa.gate_y.append(0.0)
		_pairs.append(pa)
		i += 2
	for pi in _pairs.size():
		var pa: Pair = _pairs[pi]
		for m in pa.members.size():
			var r := RS.new()
			r.id = pa.members[m]
			r.pair = pi
			r.side = -1.0 if m == 0 else 1.0
			r.pos = _tile_center(Vector2i(0, 1))
			r.safe = Vector2i(0, 1)
			r.dpos = r.pos
			r.bot_rng = RandomNumberGenerator.new()
			r.bot_rng.seed = hash([seed_value, r.id])
			r.skill = 0.72 + 0.28 * r.bot_rng.randf()
			_rs[r.id] = r
	for pl in players:
		_order.append(pl.id)

func _player_by_id(id: int) -> PlayerData:
	for pl in players:
		if pl.id == id:
			return pl
	return null

func _mine(r: RS) -> bool:
	var pl := _player_by_id(r.id)
	return pl != null and is_audible(pl)

func _simulate(delta: float) -> void:
	if _over:
		_over_t += delta
		if _over_t >= DONE_DELAY:
			finish(_ranking())
		return
	if _cd > 0.0:
		var c := ceili(_cd)
		if c != _last_cd:
			_last_cd = c
			send_event("beep", null)
		_cd -= delta
		if _cd <= 0.0:
			send_event("go", null)
		return
	var dirs: Dictionary = {}
	for pl in players:
		var r: RS = _rs[pl.id]
		var mv := move_input(pl)
		# Entrada de pantalla → laberinto: derecha/izquierda según el lado; arriba = avanzar.
		dirs[pl.id] = Vector2(mv.x * r.side, -mv.y)
	_accum += delta
	var steps := 0
	while _accum >= STEP and steps < 12:
		_accum -= STEP
		steps += 1
		_elapsed += STEP
		for pl in players:
			_step_player(_rs[pl.id] as RS, STEP, dirs[pl.id] as Vector2)
		_check_plates()
	_time_left = maxf(0.0, TIME_LIMIT - _elapsed)
	var all_out := true
	for pa in _pairs:
		if not (pa as Pair).escaped:
			all_out = false
	if _time_left <= 0.0 or all_out:
		_over = true
		_over_t = 0.0
		var best := _pair_order()
		_win_pair = best[0] if not best.is_empty() and ((_pairs[best[0]] as Pair).escaped or _pairs.size() > 1) else -1
		send_event("over", {"w": _win_pair})
		DevCli.log_event("pair_escape over winner_pair=%d" % _win_pair)

func _step_player(r: RS, dt: float, dir: Vector2) -> void:
	r.stun_t = maxf(0.0, r.stun_t - dt)
	if r.escaped:
		r.vel = Vector2.ZERO
		return
	var pa: Pair = _pairs[r.pair]
	if r.stun_t > 0.0:
		r.vel = Vector2.ZERO
		return
	if dir.length() > 1.0:
		dir = dir.normalized()
	r.vel = r.vel.move_toward(dir * RUN_SPEED, ACCEL * dt)
	if dir.length() > 0.2:
		r.face = lerp_angle(r.face, atan2(dir.x * r.side, -dir.y), 1.0 - exp(-18.0 * dt))
	var np := r.pos + r.vel * dt
	# La columna y las rejas cerradas son paredes (se choca, no se tropieza).
	np.x = maxf(np.x, RADIUS)
	np.y = maxf(np.y, -T * 0.5 + RADIUS)
	var ahead := Vector2(0, signf(r.vel.y) * RADIUS)
	if _closed_gate_at(pa, Vector2(r.pos.x, np.y) + ahead):
		np.y = r.pos.y
		r.vel.y = 0.0
	if _closed_gate_at(pa, Vector2(np.x, np.y) + Vector2(signf(r.vel.x) * RADIUS, 0)):
		np.x = r.pos.x
		r.vel.x = 0.0
	r.pos = np
	if not _on_ground(pa, r.pos):
		_trip(r)
		return
	var t := _tile_of(r.pos)
	if _walkable(pa, t.x, t.y):
		r.safe = t
		if t.x > r.best_row:
			r.best_row = t.x
	if _kind(t.x, t.y) == EXIT:
		r.escaped = true
		r.esc_t = _elapsed
		r.vel = Vector2.ZERO
		send_event("esc", {"p": r.id})
		var both := true
		for m in pa.members:
			if not (_rs[m] as RS).escaped:
				both = false
		if both and not pa.escaped:
			pa.escaped = true
			pa.esc_t = _elapsed
			send_event("pair", {"k": r.pair, "t": _elapsed})

func _trip(r: RS) -> void:
	r.stun_t = TRIP_TIME
	r.vel = Vector2.ZERO
	send_event("trip", {"p": r.id, "u": r.pos.x, "v": r.pos.y})
	r.pos = _tile_center(r.safe)

## Una reja se abre cuando todos los de la pareja están a la vez sobre su baldosa roja.
func _check_plates() -> void:
	for pi in _pairs.size():
		var pa: Pair = _pairs[pi]
		for g in _gate_rows.size():
			if pa.open[g]:
				continue
			var on_all := true
			for m in pa.members:
				var r: RS = _rs[m]
				var t := _tile_of(r.pos)
				if r.stun_t > 0.0 or t != Vector2i(_gate_rows[g] - 1, 0):
					on_all = false
					break
			if on_all:
				pa.open[g] = true
				send_event("gate", {"k": pi, "g": g})

## Índices de pareja de la mejor a la peor: antes las que escaparon (por tiempo), luego por avance.
func _pair_order() -> Array[int]:
	var idx: Array[int] = []
	for i in _pairs.size():
		idx.append(i)
	idx.sort_custom(func(a: int, b: int) -> bool:
		var pa: Pair = _pairs[a]
		var pb: Pair = _pairs[b]
		if pa.escaped != pb.escaped:
			return pa.escaped
		if pa.escaped and not is_equal_approx(pa.esc_t, pb.esc_t):
			return pa.esc_t < pb.esc_t
		var sa := _pair_progress(a)
		var sb := _pair_progress(b)
		if not is_equal_approx(sa, sb):
			return sa > sb
		return a < b)
	return idx

## Avance de una pareja: filas alcanzadas por sus miembros (y un poco por las rejas abiertas).
func _pair_progress(i: int) -> float:
	var pa: Pair = _pairs[i]
	var s := 0.0
	for m in pa.members:
		var r: RS = _rs[m]
		s += float(ROWS - 1) if r.escaped else float(r.best_row)
	for o in pa.open:
		if o:
			s += 0.5
	return s / maxf(pa.members.size(), 1.0)

func _ranking() -> Array[int]:
	var out: Array[int] = []
	for i in _pair_order():
		var pa: Pair = _pairs[i]
		var ms := pa.members.duplicate()
		ms.sort_custom(func(a: int, b: int) -> bool:
			var ra: RS = _rs[a]
			var rb: RS = _rs[b]
			if ra.best_row != rb.best_row:
				return ra.best_row > rb.best_row
			return a < b)
		for m in ms:
			out.append(m)
	return out

## Los dos de una pareja comparten puesto (y puntos).
func _result_groups() -> Array:
	var out: Array = []
	for pa in _pairs:
		if (pa as Pair).members.size() > 1:
			out.append((pa as Pair).members.duplicate())
	return out

## Con una sola pareja (2 jugadores) no hay rival: escapar da los puntos de ganador; no escapar, los de perdedor.
func _result_points() -> Dictionary:
	if _pairs.size() != 1:
		return {}
	var pa: Pair = _pairs[0]
	var out: Dictionary = {}
	for m in pa.members:
		out[m] = players.size() if pa.escaped else 1
	return out

# ----------------------------------------------------------------------------
# Red
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var arr := PackedFloat32Array()
	for id in _order:
		var r: RS = _rs[id]
		arr.append_array(PackedFloat32Array([r.pos.x, r.pos.y, r.vel.x, r.vel.y, r.face, r.stun_t,
				1.0 if r.escaped else 0.0, float(r.best_row)]))
	var gates := PackedInt32Array()
	var esc := PackedFloat32Array()
	for pa in _pairs:
		var mask := 0
		for g in (pa as Pair).open.size():
			if (pa as Pair).open[g]:
				mask |= 1 << g
		gates.append(mask)
		esc.append((pa as Pair).esc_t if (pa as Pair).escaped else -1.0)
	return {"r": arr, "g": gates, "e": esc, "t": _time_left, "cd": _cd, "o": _over, "w": _win_pair}

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	var st: Dictionary = state
	_time_left = float(st.get("t", _time_left))
	_cd = float(st.get("cd", _cd))
	_over = bool(st.get("o", _over))
	_win_pair = int(st.get("w", _win_pair))
	var gates: Variant = st.get("g")
	var esc: Variant = st.get("e")
	if gates is PackedInt32Array and esc is PackedFloat32Array and gates.size() == _pairs.size() and esc.size() == _pairs.size():
		for i in _pairs.size():
			var pa: Pair = _pairs[i]
			for g in pa.open.size():
				pa.open[g] = (int(gates[i]) >> g) & 1 == 1
			pa.escaped = esc[i] >= 0.0
			pa.esc_t = maxf(esc[i], 0.0)
	var arr: Variant = st.get("r")
	if not arr is PackedFloat32Array or arr.size() < _order.size() * FLOATS:
		return
	for i in _order.size():
		var r: RS = _rs[_order[i]]
		var o := i * FLOATS
		r.pos = Vector2(arr[o], arr[o + 1])
		r.vel = Vector2(arr[o + 2], arr[o + 3])
		r.face = arr[o + 4]
		r.stun_t = arr[o + 5]
		r.escaped = arr[o + 6] > 0.5
		r.best_row = int(arr[o + 7])

func _on_event(event_name: String, data: Variant) -> void:
	var d: Dictionary = data if data is Dictionary else {}
	var r: RS = _rs.get(int(d.get("p", -1)))
	match event_name:
		"beep":
			Audio.sfx(&"beep", -7.0)
		"go":
			Audio.sfx(&"beep_go", -5.0)
		"trip":
			if r != null:
				r.stun_t = TRIP_TIME
				r.dpos = Vector2(float(d.get("u", r.pos.x)), float(d.get("v", r.pos.y)))
				_spawn_floater(r, "¡Uy!", false)
				Audio.sfx(&"thud", -6.0 if _mine(r) else -16.0)
		"gate":
			var k := int(d.get("k", -1))
			if k >= 0 and k < _pairs.size():
				(_pairs[k] as Pair).open[int(d.get("g", 0))] = true
				if _view_pairs.has(k):
					_toast = "¡REJA ABIERTA!"
					_toast_t = 1.3
					Audio.sfx(&"clang", -5.0)
					Audio.sfx(&"combo", -10.0)
		"esc":
			if r != null:
				r.escaped = true
				_spawn_floater(r, "¡Fuera!", true)
				if _mine(r):
					Audio.sfx(&"reaction_ok", -6.0)
		"pair":
			var k2 := int(d.get("k", -1))
			if k2 >= 0 and k2 < _pairs.size():
				(_pairs[k2] as Pair).escaped = true
				(_pairs[k2] as Pair).esc_t = float(d.get("t", 0.0))
				_toast = "¡%s ESCAPA!" % _pair_name(k2).to_upper()
				_toast_t = 1.8
				Audio.sfx(&"fanfare_small", -6.0)
		"over":
			_win_pair = int(d.get("w", -1))
			Audio.sfx(&"fanfare_big", -6.0)

func _pair_name(k: int) -> String:
	var pa: Pair = _pairs[k]
	var names: Array[String] = []
	for m in pa.members:
		var pl := _player_by_id(m)
		names.append(pl.display_name if pl != null else "?")
	return " y ".join(names)

# ----------------------------------------------------------------------------
# Ciclo del minijuego
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	_setup_players()
	_build_world()
	surface.draw_callback = _draw_hud

func _on_start() -> void:
	_setup_players()
	_rebuild_dynamic()
	_accum = 0.0
	_cd = COUNTDOWN
	_last_cd = 99
	_time_left = TIME_LIMIT
	_elapsed = 0.0
	_over = false
	_over_t = 0.0
	_win_pair = -1
	_hint_t = 7.0
	_toast = ""
	_toast_t = 0.0

func _animate(delta: float) -> void:
	_toast_t = maxf(0.0, _toast_t - delta)
	_anim += delta
	if _cd <= 0.0:
		_hint_t = maxf(0.0, _hint_t - delta)
	_update_world(delta)

# ----------------------------------------------------------------------------
# IA (bots, autopiloto, práctica): camino más corto por baldosas (BFS); espera en la baldosa roja a su pareja.
# Los menos hábiles a veces se pasan de largo en las curvas… y tropiezan.
# ----------------------------------------------------------------------------

func _bfs(pa: Pair, from: Vector2i, goal: Callable) -> Array[Vector2i]:
	var prev: Dictionary = {from: from}
	var queue: Array[Vector2i] = [from]
	var head := 0
	var found := Vector2i(-1, -1)
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		if goal.call(c):
			found = c
			break
		for dlt in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(-1, 0)]:
			var n: Vector2i = c + dlt
			if prev.has(n) or not _walkable(pa, n.x, n.y):
				continue
			prev[n] = c
			queue.append(n)
	var out: Array[Vector2i] = []
	if found.x < 0:
		return out
	var cur := found
	while cur != from:
		out.push_front(cur)
		cur = prev[cur]
	return out

func _bot_think(r: RS) -> Vector2:
	if _over or _cd > 0.0 or r.stun_t > 0.0 or r.escaped:
		r.path.clear()
		return Vector2.ZERO
	var pa: Pair = _pairs[r.pair]
	var sk := r.skill if debug_skill < 0.0 else debug_skill
	var here := _tile_of(r.pos)
	if not _walkable(pa, here.x, here.y):
		here = r.safe
	# Siguiente reja cerrada por delante: ir a su baldosa roja y esperar allí.
	var plate := Vector2i(-1, -1)
	for g in _gate_rows.size():
		if not pa.open[g] and _gate_rows[g] > here.x - 1:
			plate = Vector2i(_gate_rows[g] - 1, 0)
			break
	r.think_t -= STEP
	if r.think_t <= 0.0 or r.path.is_empty():
		r.think_t = 0.12
		if plate.x >= 0:
			r.path = _bfs(pa, here, func(c: Vector2i) -> bool: return c == plate)
		else:
			r.path = _bfs(pa, here, func(c: Vector2i) -> bool: return _kind(c.x, c.y) == EXIT)
	var spd := lerpf(0.72, 0.95, sk)
	if r.over_t > 0.0:
		r.over_t -= STEP
		return r.over_dir * spd
	if r.path.is_empty():
		# Ya en la baldosa roja: quieto en el centro hasta que llegue la pareja.
		var to_c := _tile_center(here) - r.pos
		return to_c.limit_length(1.0) * 0.6 if to_c.length() > 0.15 else Vector2.ZERO
	var target := _tile_center(r.path[0])
	if r.path.size() > 1:
		var d0 := r.path[0] - here
		var d1 := r.path[1] - r.path[0]
		if d0 == d1 and r.pos.distance_to(target) < T * 0.5:
			target = _tile_center(r.path[1])
	var to := target - r.pos
	if to.length() < 0.2:
		r.path.pop_front()
		return Vector2.ZERO
	var want := to.normalized()
	# En las curvas (una vez por baldosa), los menos hábiles a veces se pasan de largo.
	if r.last_dir.length() > 0.5 and want.dot(r.last_dir) < 0.5 and r.rolled != here:
		r.rolled = here
		if r.bot_rng.randf() < (1.0 - sk) * 0.9:
			r.over_t = r.bot_rng.randf_range(0.25, 0.45)
			r.over_dir = r.last_dir
			return r.over_dir * spd
	r.last_dir = want
	return want * spd

func _bot_move(player: PlayerData) -> Vector2:
	var r: RS = _rs.get(player.id)
	if r == null:
		return Vector2.ZERO
	var d := _bot_think(r)
	return Vector2(d.x * r.side, -d.y)                  # laberinto → entrada de pantalla

func _bot_action(_player: PlayerData) -> int:
	return 0

# ----------------------------------------------------------------------------
# Escena 3D: templo oscuro, baldosas de piedra sobre el abismo, columna central, antorchas y rejas
# ----------------------------------------------------------------------------

func _pair_x(k: int) -> float:
	return (k - (_pairs.size() - 1) * 0.5) * PAIR_DX

func _world(r: RS, p: Vector2) -> Vector3:
	return Vector3(_pair_x(r.pair) + r.side * (PILLAR_HALF + p.x), 0.0, -p.y)

func _tile_world(k: int, side: float, row: int, col: int) -> Vector3:
	return Vector3(_pair_x(k) + side * (PILLAR_HALF + (col + 0.5) * T), 0.0, -row * T)

func _mat(c: Color, emission: float = 0.0, rough: float = 0.8) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emission
	return m

func _toon(c: Color, outline: float = 0.025) -> StandardMaterial3D:
	var m := _mat(c, 0.0, 0.55)
	var o := StandardMaterial3D.new()
	o.albedo_color = Color(0.05, 0.04, 0.03)
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

func _capsule(parent: Node3D, radius: float, height: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var cm := CapsuleMesh.new()
	cm.radius = radius
	cm.height = height
	cm.radial_segments = 16
	cm.rings = 6
	return _mesh(parent, cm, pos, mat)

func _sphere(parent: Node3D, radius: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 18
	sm.rings = 9
	return _mesh(parent, sm, pos, mat)

static var _tex_stone: ImageTexture = null
static var _tex_wall: ImageTexture = null

## Piedra arenisca con vetas y una junta en el borde (una baldosa por textura).
func _stone_texture() -> ImageTexture:
	if _tex_stone != null:
		return _tex_stone
	var n := FastNoiseLite.new()
	n.seed = 23
	n.frequency = 0.045
	n.fractal_octaves = 4
	var nn := n.get_seamless_image(128, 128)
	var img := Image.create(128, 128, false, Image.FORMAT_RGB8)
	for y in 128:
		for x in 128:
			var v := 0.82 + 0.3 * (nn.get_pixel(x, y).r - 0.5)
			var e := mini(mini(x, 127 - x), mini(y, 127 - y))
			if e < 3:
				v *= 0.55
			elif e < 6:
				v *= 1.12
			if (x + y * 3) % 97 == 0:
				v *= 0.8
			img.set_pixel(x, y, Color(0.74 * v, 0.62 * v, 0.42 * v))
	img.generate_mipmaps()
	_tex_stone = ImageTexture.create_from_image(img)
	return _tex_stone

## Sillares de las paredes del templo.
func _wall_texture() -> ImageTexture:
	if _tex_wall != null:
		return _tex_wall
	var n := FastNoiseLite.new()
	n.seed = 7
	n.frequency = 0.06
	var nn := n.get_seamless_image(128, 128)
	var img := Image.create(128, 128, false, Image.FORMAT_RGB8)
	for y in 128:
		for x in 128:
			var v := 0.5 + 0.25 * (nn.get_pixel(x, y).r - 0.5)
			var row := y / 32
			var xo := (x + (16 if row % 2 == 1 else 0)) % 64
			if y % 32 < 2 or xo < 2:
				v *= 0.45
			img.set_pixel(x, y, Color(0.42 * v, 0.33 * v, 0.22 * v))
	img.generate_mipmaps()
	_tex_wall = ImageTexture.create_from_image(img)
	return _tex_wall

func _build_world() -> void:
	if _built:
		return
	_built = true
	_root3 = Node3D.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.03, 0.02, 0.015)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.62, 0.45)
	env.ambient_light_energy = 0.75
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.7
	env.glow_hdr_threshold = 1.0
	env.fog_enabled = true
	env.fog_light_color = Color(0.06, 0.04, 0.03)
	env.fog_density = 0.012
	var we := WorldEnvironment.new()
	we.environment = env
	_root3.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60.0, 25.0, 0.0)
	sun.light_energy = 0.85
	sun.light_color = Color(1.0, 0.88, 0.7)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 55.0
	_root3.add_child(sun)
	_build_views()
	_rebuild_dynamic()

## Lo que depende del reparto de parejas (laberintos, columnas, rejas, jugadores). Se rehace en cada start().
func _rebuild_dynamic() -> void:
	if not _built:
		return
	var old := _root3.get_node_or_null("Dyn")
	if old != null:
		_root3.remove_child(old)
		old.queue_free()
	var dyn := Node3D.new()
	dyn.name = "Dyn"
	_root3.add_child(dyn)
	_torches.clear()
	_exit_glow.clear()
	var stone := _mat(Color(1, 1, 1), 0.0, 0.9)
	stone.albedo_texture = _stone_texture()
	stone.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var wall := _mat(Color(1, 1, 1), 0.0, 0.95)
	wall.albedo_texture = _wall_texture()
	wall.uv1_triplanar = true
	wall.uv1_scale = Vector3(0.18, 0.18, 0.18)
	var plate_mat := _mat(Color(0.75, 0.2, 0.12), 0.25, 0.6)
	var bar_mat := _mat(Color(0.25, 0.22, 0.2), 0.0, 0.4)
	bar_mat.metallic = 0.7
	var pillar_mat := _mat(Color(0.72, 0.6, 0.42), 0.0, 0.85)
	pillar_mat.albedo_texture = _stone_texture()
	pillar_mat.uv1_scale = Vector3(3.0, 30.0, 1.0)
	var exit_mat := _mat(Color(1.0, 0.85, 0.45), 1.8)
	# Baldosas: un MultiMesh para todas.
	var count := 0
	for row in ROWS:
		for col in COLS:
			if _kind(row, col) != VOID:
				count += 1
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var tile_mesh := BoxMesh.new()
	tile_mesh.size = Vector3(T - 0.05, 1.2, T - 0.05)
	mm.mesh = tile_mesh
	mm.instance_count = count * 2 * _pairs.size()
	var n := 0
	for k in _pairs.size():
		for side: float in [-1.0, 1.0]:
			for row in ROWS:
				for col in COLS:
					if _kind(row, col) == VOID:
						continue
					mm.set_instance_transform(n, Transform3D(Basis(), _tile_world(k, side, row, col) + Vector3(0, -0.6, 0)))
					n += 1
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = stone
	dyn.add_child(mmi)
	var length := ROWS * T
	var zc := -(ROWS - 1) * T * 0.5
	for k in _pairs.size():
		var px := _pair_x(k)
		var pa: Pair = _pairs[k]
		pa.gates.clear()
		# Columna tumbada entre las dos mitades, con anillos de piedra.
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.8
		cyl.bottom_radius = 0.8
		cyl.height = length + 6.0
		cyl.radial_segments = 20
		var pil := _mesh(dyn, cyl, Vector3(px, 0.35, zc), pillar_mat)
		pil.rotation_degrees = Vector3(90, 0, 0)
		for i in range(0, ROWS, 6):
			var ring := CylinderMesh.new()
			ring.top_radius = 0.9
			ring.bottom_radius = 0.9
			ring.height = 0.35
			var rg := _mesh(dyn, ring, Vector3(px, 0.35, -i * T), pillar_mat)
			rg.rotation_degrees = Vector3(90, 0, 0)
		# Paredes del templo a los lados, con antorchas.
		var half_w := PILLAR_HALF + COLS * T
		for side: float in [-1.0, 1.0]:
			_box(dyn, Vector3(1.5, 14.0, length + 10.0), Vector3(px + side * (half_w + 3.5), -2.0, zc), wall)
			for i in range(2, ROWS, 8):
				var tz := -i * T
				var tx := px + side * (half_w + 2.6)
				_box(dyn, Vector3(0.3, 0.6, 0.3), Vector3(tx, 2.2, tz), _mat(Color(0.25, 0.18, 0.1)))
				var fl := _sphere(dyn, 0.28, Vector3(tx, 2.7, tz), _mat(Color(1.0, 0.55, 0.15), 3.5))
				fl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				var ol := OmniLight3D.new()
				ol.position = Vector3(tx - side * 0.6, 3.0, tz)
				ol.light_color = Color(1.0, 0.6, 0.25)
				ol.light_energy = 1.6
				ol.omni_range = 9.0
				dyn.add_child(ol)
				_torches.append(ol)
			# Baldosas rojas (rombo) y rejas.
			for g in _gate_rows.size():
				var prow := _gate_rows[g] - 1
				var pp := _tile_world(k, side, prow, 0)
				var dm := _box(dyn, Vector3(1.05, 0.06, 1.05), pp + Vector3(0, 0.03, 0), plate_mat)
				dm.rotation_degrees = Vector3(0, 45, 0)
			# Salida: arco brillante al fondo.
			var ez := -(ROWS - 1) * T - T * 0.5
			var ex := px + side * (PILLAR_HALF + COLS * T * 0.5)
			_box(dyn, Vector3(COLS * T, 0.5, 0.6), Vector3(ex, 4.2, ez - 0.2), wall)
			for sx: float in [-1.0, 1.0]:
				_box(dyn, Vector3(0.7, 4.4, 0.7), Vector3(ex + sx * (COLS * T * 0.5 - 0.35), 2.0, ez - 0.2), wall)
			var qm := QuadMesh.new()
			qm.size = Vector2(COLS * T - 1.4, 3.9)
			var glow := _mesh(dyn, qm, Vector3(ex, 1.95, ez - 0.3), exit_mat)
			glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_exit_glow.append(glow)
		for g in _gate_rows.size():
			var pair_nodes: Array = []
			for side: float in [-1.0, 1.0]:
				var gn := Node3D.new()
				gn.position = _tile_world(k, side, _gate_rows[g], 0) + Vector3(0, 0, T * 0.5 - 0.15)
				dyn.add_child(gn)
				for b in 5:
					_box(gn, Vector3(0.14, 2.0, 0.14), Vector3(-T * 0.4 + b * T * 0.2, 1.0, 0), bar_mat)
				_box(gn, Vector3(T, 0.18, 0.2), Vector3(0, 2.0, 0), bar_mat)
				_box(gn, Vector3(T, 0.12, 0.16), Vector3(0, 0.9, 0), bar_mat)
				pair_nodes.append(gn)
			pa.gates.append(pair_nodes)
	# Abismo: un suelo muy oscuro lejos, abajo.
	var pit := PlaneMesh.new()
	pit.size = Vector2(PAIR_DX * maxf(_pairs.size(), 1.0) + 40.0, length + 40.0)
	_mesh(dyn, pit, Vector3(0, -14.0, zc), _mat(Color(0.02, 0.015, 0.01)))
	# Jugadores.
	for id in _order:
		_build_player(_rs[id] as RS, _player_by_id(id), dyn)
	_choose_view_pairs()
	_update_world(0.0)

## Qué parejas se ven en este PC: las de sus personas (online: la tuya). Varias en un PC → pantalla partida.
func _choose_view_pairs() -> void:
	var wanted: Array[int] = []
	if local_player != null and _rs.has(local_player.id):
		wanted.append((_rs[local_player.id] as RS).pair)
	if not NetworkManager.is_online:
		for pl in players:
			if pl.is_local_human and _rs.has(pl.id):
				var k: int = (_rs[pl.id] as RS).pair
				if not wanted.has(k):
					wanted.append(k)
	if wanted.is_empty():
		wanted.append(0)
	_view_pairs = wanted.slice(0, 4)
	_build_views()

func _build_views() -> void:
	var want := maxi(_view_pairs.size(), 1)
	while _views.size() > want:
		var v: Dictionary = _views.pop_back()
		(v["cont"] as Node).queue_free()
	while _views.size() < want:
		var cont := SubViewportContainer.new()
		cont.stretch = true
		cont.top_level = true
		cont.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(cont)
		move_child(cont, surface.get_index())
		var vp := SubViewport.new()
		vp.handle_input_locally = false
		vp.msaa_3d = Viewport.MSAA_4X
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		cont.add_child(vp)
		if _views.is_empty():
			vp.own_world_3d = true
			vp.add_child(_root3)
		else:
			vp.world_3d = (_views[0]["vp"] as SubViewport).find_world_3d()
		var cam := Camera3D.new()
		cam.keep_aspect = Camera3D.KEEP_WIDTH
		cam.fov = 68.0
		cam.far = 160.0
		vp.add_child(cam)
		cam.current = true
		_views.append({"cont": cont, "vp": vp, "cam": cam})
	for i in _views.size():
		_views[i]["pair"] = _view_pairs[i] if i < _view_pairs.size() else 0

## Rectángulos de cada visor en el espacio lógico de 1280x720 (el HUD) — 1, 2 (izq/der) o 4 (2x2).
func _view_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	var n := _views.size()
	if n <= 1:
		out.append(Rect2(0, 0, 1280, 720))
	elif n == 2:
		out.append(Rect2(0, 0, 640, 720))
		out.append(Rect2(640, 0, 640, 720))
	else:
		for i in n:
			out.append(Rect2((i % 2) * 640, (i / 2) * 360, 640, 360))
	return out

## Un personajillo (cuerpo de color, ojos grandes, orejitas), como en el resto de minijuegos 3D.
func _build_player(r: RS, pl: PlayerData, parent: Node3D) -> void:
	var col: Color = pl.color if pl != null else Palette.YELLOW
	r.node = Node3D.new()
	parent.add_child(r.node)
	r.body = Node3D.new()
	r.node.add_child(r.body)
	r.node.scale = Vector3.ONE * 0.8
	var b := r.body
	_capsule(b, 0.42, 1.15, Vector3(0, 0.78, 0), _toon(col))
	_sphere(b, 0.48, Vector3(0, 1.5, 0), _toon(col.lightened(0.12)))
	for sx: float in [-1.0, 1.0]:
		_sphere(b, 0.17, Vector3(sx * 0.2, 1.58, 0.36), _mat(Color.WHITE, 0.25, 0.3))
		_sphere(b, 0.085, Vector3(sx * 0.2, 1.57, 0.5), _mat(Color(0.05, 0.05, 0.1), 0.0, 0.2))
		_sphere(b, 0.16, Vector3(sx * 0.4, 1.92, -0.02), _toon(col.darkened(0.2), 0.02))
	r.arm_l = Node3D.new()
	r.arm_l.position = Vector3(-0.5, 1.12, 0)
	b.add_child(r.arm_l)
	r.arm_r = Node3D.new()
	r.arm_r.position = Vector3(0.5, 1.12, 0)
	b.add_child(r.arm_r)
	for arm in [r.arm_l, r.arm_r]:
		_capsule(arm, 0.12, 0.62, Vector3(0, -0.27, 0), _toon(col))
		_sphere(arm, 0.16, Vector3(0, -0.58, 0), _toon(col.lightened(0.2), 0.02))
	r.leg_l = Node3D.new()
	r.leg_l.position = Vector3(-0.2, 0.42, 0)
	b.add_child(r.leg_l)
	r.leg_r = Node3D.new()
	r.leg_r.position = Vector3(0.2, 0.42, 0)
	b.add_child(r.leg_r)
	for leg in [r.leg_l, r.leg_r]:
		_capsule(leg, 0.13, 0.46, Vector3(0, -0.18, 0), _toon(col.darkened(0.25)))
		_box(leg, Vector3(0.26, 0.12, 0.4), Vector3(0, -0.4, 0.07), _toon(Color(0.15, 0.12, 0.1), 0.02))
	# Gotitas de sudor al tropezar.
	r.drops = Node3D.new()
	r.drops.position = Vector3(0, 1.4, 0)
	r.node.add_child(r.drops)
	for i in 3:
		var dp := _sphere(r.drops, 0.09, Vector3(-0.3 + 0.3 * i, 0.2 * (i % 2), 0.3), _mat(Color(0.5, 0.8, 1.0), 1.2))
		dp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	r.drops.visible = false
	var is_me := pl != null and (pl == local_player or (local_player == null and pl.is_local_human))
	r.tag = Label3D.new()
	r.tag.text = "▼"
	r.tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	r.tag.no_depth_test = true
	r.tag.font_size = 90
	r.tag.pixel_size = 0.012
	r.tag.modulate = Palette.YELLOW if is_me else col.lightened(0.3)
	r.tag.outline_size = 18
	r.tag.outline_modulate = Color(0.03, 0.03, 0.06)
	r.tag.position = Vector3(0, 2.8, 0)
	r.tag.visible = true
	r.tag.scale = Vector3.ONE * (1.0 if is_me else 0.6)
	r.node.add_child(r.tag)
	r.dpos = r.pos
	r.dface = r.face

func _spawn_floater(r: RS, text: String, good: bool) -> void:
	if not _built or r.node == null or not is_instance_valid(r.node):
		return
	var l := Label3D.new()
	l.text = text
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.font_size = 100
	l.pixel_size = 0.011
	l.outline_size = 22
	l.outline_modulate = Color(0.03, 0.03, 0.06)
	l.modulate = Color(0.75, 1.0, 0.3) if good else Color(0.6, 0.85, 1.0)
	l.position = _world(r, r.dpos) + Vector3(0, 2.6, 0)
	r.node.get_parent().add_child(l)
	_floaters.append({"n": l, "age": 0.0})

func _fit_views() -> void:
	if _views.is_empty():
		return
	var off := Vector2.ZERO
	var par := get_parent()
	if par is CanvasLayer:
		off = -(par as CanvasLayer).offset
	var real := get_viewport().get_visible_rect().size
	var sc := real / Vector2(1280, 720)
	var rects := _view_rects()
	for i in _views.size():
		var cont: SubViewportContainer = _views[i]["cont"]
		cont.position = off + rects[i].position * sc
		cont.size = rects[i].size * sc

func _update_world(delta: float) -> void:
	_fit_views()
	if not _built:
		return
	var k := 1.0 if delta <= 0.0 else 1.0 - exp(-22.0 * delta)
	for id in _order:
		var r: RS = _rs[id]
		if r.node == null or not is_instance_valid(r.node):
			continue
		if r.dpos.distance_to(r.pos) > 3.0 and r.stun_t <= 0.0:
			r.dpos = r.pos
		elif r.stun_t <= 0.0:
			r.dpos = r.dpos.lerp(r.pos, k)
		r.dface = lerp_angle(r.dface, r.face, 1.0 if delta <= 0.0 else 1.0 - exp(-20.0 * delta))
		r.anim += delta
		r.node.position = _world(r, r.dpos)
		r.body.rotation.y = r.dface
		var speed := r.vel.length()
		var ph := r.anim * (7.0 + speed * 0.9)
		var swing := clampf(speed / RUN_SPEED, 0.0, 1.0)
		if r.stun_t > 0.0:
			# De bruces en el suelo, con gotitas; al final se levanta y reaparece en la baldosa segura.
			r.body.rotation.x = lerpf(r.body.rotation.x, 1.4, 0.3)
			r.body.position.y = lerpf(r.body.position.y, 0.25, 0.3)
			r.arm_l.rotation.x = -2.6
			r.arm_r.rotation.x = -2.6
			r.leg_l.rotation.x = 0.5
			r.leg_r.rotation.x = -0.3
			r.drops.visible = true
			r.drops.position.y = 1.0 + 0.2 * sin(r.anim * 9.0)
			if r.stun_t < 0.25:
				r.dpos = r.pos
		elif r.escaped:
			r.drops.visible = false
			r.body.rotation.x = 0.0
			r.body.position.y = absf(sin(r.anim * 6.0)) * 0.35        # saltitos de alegría
			r.arm_l.rotation.x = PI * 0.9
			r.arm_r.rotation.x = PI * 0.9
			r.leg_l.rotation.x = 0.0
			r.leg_r.rotation.x = 0.0
		else:
			r.drops.visible = false
			r.body.rotation.x = lerpf(r.body.rotation.x, 0.12 * swing, 0.3)
			r.body.position.y = lerpf(r.body.position.y, absf(sin(ph)) * 0.1 * swing, 0.5)
			if speed > 0.8:
				r.leg_l.rotation.x = sin(ph) * 1.0 * swing
				r.leg_r.rotation.x = -sin(ph) * 1.0 * swing
				r.arm_l.rotation.x = -sin(ph) * 0.8 * swing
				r.arm_r.rotation.x = sin(ph) * 0.8 * swing
			else:
				r.leg_l.rotation.x = lerpf(r.leg_l.rotation.x, 0.0, 0.3)
				r.leg_r.rotation.x = lerpf(r.leg_r.rotation.x, 0.0, 0.3)
				r.arm_l.rotation.x = lerpf(r.arm_l.rotation.x, 0.0, 0.3)
				r.arm_r.rotation.x = lerpf(r.arm_r.rotation.x, 0.0, 0.3)
	# Rejas: bajan hasta el suelo al abrirse.
	for pk in _pairs.size():
		var pa: Pair = _pairs[pk]
		for g in pa.gates.size():
			var target := -2.3 if pa.open[g] else 0.0
			pa.gate_y[g] = lerpf(pa.gate_y[g], target, 1.0 if delta <= 0.0 else 1.0 - exp(-5.0 * delta))
			for gn in pa.gates[g]:
				(gn as Node3D).position.y = pa.gate_y[g]
	# Antorchas que titilan, salida que late, textos que suben.
	for i in _torches.size():
		_torches[i].light_energy = 1.5 + 0.35 * sin(_anim * 11.0 + i * 1.7) + 0.2 * sin(_anim * 23.0 + i)
	for gl in _exit_glow:
		(gl.material_override as StandardMaterial3D).emission_energy_multiplier = 1.5 + 0.5 * sin(_anim * 3.0)
	for fl in _floaters:
		fl["age"] = float(fl["age"]) + delta
		var nd: Label3D = fl["n"]
		nd.position.y += delta * 1.6
		nd.modulate.a = clampf(1.0 - float(fl["age"]) / 1.0, 0.0, 1.0)
	var keep: Array = []
	for fl in _floaters:
		if float(fl["age"]) < 1.0:
			keep.append(fl)
		else:
			(fl["n"] as Node).queue_free()
	_floaters = keep
	# Cámaras: detrás y por encima de su pareja, mirando hacia la salida (como en una persecución).
	for v in _views:
		var pk2: int = v["pair"]
		if pk2 >= _pairs.size():
			continue
		var pa2: Pair = _pairs[pk2]
		var z := 0.0
		for m in pa2.members:
			z += (_rs[m] as RS).dpos.y
		z /= maxf(pa2.members.size(), 1.0)
		z = clampf(z, 1.0, (ROWS - 1) * T - 7.0)
		pa2.cam_z = z if delta <= 0.0 else lerpf(pa2.cam_z, z, 1.0 - exp(-3.0 * delta))
		var cam: Camera3D = v["cam"]
		var px := _pair_x(pk2)
		cam.position = Vector3(px, 15.0, -pa2.cam_z + 9.5)
		cam.look_at(Vector3(px, 0.0, -pa2.cam_z - 5.5), Vector3.UP)

# ----------------------------------------------------------------------------
# HUD (dibujo 2D encima del 3D): reloj arriba, avance de las parejas a la izquierda, «¡Escapa!» abajo
# ----------------------------------------------------------------------------

func _draw_hud() -> void:
	var s := surface
	var rects := _view_rects()
	if rects.size() > 1:
		s.draw_line(Vector2(640, 0), Vector2(640, 720), Color(0, 0, 0, 0.8), 6.0)
		if rects.size() > 2:
			s.draw_line(Vector2(0, 360), Vector2(1280, 360), Color(0, 0, 0, 0.8), 6.0)
	for i in rects.size():
		var rc := rects[i]
		var pk: int = _views[i]["pair"] if i < _views.size() else 0
		var small := rects.size() > 2
		# «¡Escapa!» abajo / aviso de esperar a la pareja.
		if pk < _pairs.size() and not _over and _cd <= 0.0:
			var msg := _view_message(pk)
			var by := rc.end.y - (34.0 if small else 56.0)
			var fs := 24 if small else 34
			var font := s.get_theme_default_font()
			var w := font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 36.0
			s.rounded_rect(Rect2(rc.get_center().x - w * 0.5, by - fs * 0.75, w, fs * 1.5), fs * 0.75, Color(0.05, 0.04, 0.04, 0.75))
			s.text_centered(Vector2(rc.get_center().x, by), msg, fs, Color(1.0, 0.35, 0.55), 5)
		if rects.size() > 1 and pk < _pairs.size():
			s.text_centered(rc.position + Vector2(rc.size.x * 0.5, 74.0 if not small else 20.0), _pair_name(pk), 20, Palette.WHITE, 5)
	# Reloj (arriba, en el centro).
	var left := ceili(_time_left)
	var cen := Vector2(640, 40)
	s.rounded_rect(Rect2(cen.x - 74, cen.y - 26, 148, 52), 26, Color(0.95, 0.95, 0.95, 0.95))
	s.rounded_rect(Rect2(cen.x - 69, cen.y - 21, 138, 42), 21, Color(0.25, 0.25, 0.27, 0.95))
	s.draw_circle(cen + Vector2(-38, 0), 15.0, Palette.WHITE)
	s.draw_arc(cen + Vector2(-38, 0), 11.0, 0, TAU, 24, Color(0.2, 0.2, 0.2), 2.5)
	var hand := -PI * 0.5 + TAU * (1.0 - clampf(_time_left / TIME_LIMIT, 0.0, 1.0))
	s.draw_line(cen + Vector2(-38, 0), cen + Vector2(-38, 0) + Vector2(cos(hand), sin(hand)) * 9.0, Color(0.2, 0.2, 0.2), 2.5)
	s.text_centered(cen + Vector2(16, 0), str(left), 34, Palette.WHITE if left > 10 else Palette.CORAL, 6)
	# Avance de cada pareja (barras verticales, con los colores de sus miembros).
	if _pairs.size() > 1 or rects.size() == 1:
		_draw_progress(Rect2(18, 120, 34.0 * _pairs.size() + 16.0, 300))
	if _toast_t > 0.0:
		s.text_centered(Vector2(640, 150), _toast, 52, Color(1, 1, 1, clampf(_toast_t * 2.0, 0.0, 1.0)), 10)
	if _cd > 0.0:
		var c := ceili(_cd)
		var frac := _cd - floorf(_cd)
		s.text_centered(Vector2(640, 330), str(c), int(130.0 + 60.0 * frac), Palette.YELLOW, 16)
	elif _elapsed < 0.8:
		s.text_centered(Vector2(640, 330), "¡YA!", 130, Palette.MINT, 16)
	if _hint_t > 0.0 and not _over and _cd <= 0.0:
		s.text_centered(Vector2(640, 610), "Corre por tu mitad sin salirte · Las rejas se abren si los DOS pisáis la baldosa roja",
				22, Color(1, 1, 1, clampf(_hint_t, 0.0, 1.0)), 6)
	if _over:
		s.text_centered(Vector2(640, 280), "¡FIN!", 100, Palette.YELLOW, 14)
		if _win_pair >= 0 and _win_pair < _pairs.size():
			var pa: Pair = _pairs[_win_pair]
			var first := _player_by_id(pa.members[0])
			var c1: Color = first.color if first != null else Palette.WHITE
			s.text_centered(Vector2(640, 370), ("¡Escapan %s!" if pa.escaped else "Gana %s") % _pair_name(_win_pair), 48, c1.lightened(0.25), 10)
		elif _pairs.size() == 1:
			s.text_centered(Vector2(640, 370), "No habéis escapado…", 48, Palette.CORAL, 10)

func _view_message(pk: int) -> String:
	var pa: Pair = _pairs[pk]
	if pa.escaped:
		return "¡A salvo!"
	var mine_out := false
	for m in pa.members:
		var pl := _player_by_id(m)
		if pl != null and (pl == local_player or (local_player == null and pl.is_local_human)) and (_rs[m] as RS).escaped:
			mine_out = true
	if mine_out:
		return "¡Espera a tu pareja!"
	# ¿Alguien de la pareja ya está en la baldosa roja esperando?
	for g in _gate_rows.size():
		if pa.open[g]:
			continue
		for m in pa.members:
			var r: RS = _rs[m]
			if _tile_of(r.pos) == Vector2i(_gate_rows[g] - 1, 0):
				return "¡Pisad los dos la baldosa roja!"
		break
	return "¡Escapa!"

func _draw_progress(box: Rect2) -> void:
	var s := surface
	s.rounded_rect(box, 14, Color(0.05, 0.04, 0.03, 0.7))
	var top := box.position.y + 18.0
	var bottom := box.end.y - 18.0
	for k in _pairs.size():
		var pa: Pair = _pairs[k]
		var x := box.position.x + 24.0 + k * 34.0
		s.draw_line(Vector2(x, top), Vector2(x, bottom), Color(1, 1, 1, 0.25), 4.0)
		for g in _gate_rows.size():
			var gy := lerpf(bottom, top, float(_gate_rows[g]) / float(ROWS - 1))
			s.draw_line(Vector2(x - 8, gy), Vector2(x + 8, gy), Color(0.3, 1.0, 0.5) if pa.open[g] else Color(0.85, 0.25, 0.15), 3.0)
		for mi in pa.members.size():
			var r: RS = _rs[pa.members[mi]]
			var pl := _player_by_id(r.id)
			var y := lerpf(bottom, top, clampf(r.dpos.y / ((ROWS - 1) * T), 0.0, 1.0))
			var col: Color = pl.color if pl != null else Palette.WHITE
			s.draw_circle(Vector2(x + (mi * 2 - 1) * 5.0, y), 7.0, Palette.PURPLE_DARK)
			s.draw_circle(Vector2(x + (mi * 2 - 1) * 5.0, y), 5.5, col)
		if pa.escaped:
			s.text_centered(Vector2(x, top - 2.0), "★", 18, Palette.YELLOW, 3)

# ----------------------------------------------------------------------------
# Utilidades de depuración / pruebas (tests/pair_escape_test.gd)
# ----------------------------------------------------------------------------

func debug_kind(row: int, col: int) -> int:
	return _kind(row, col)

func debug_gate_rows() -> Array[int]:
	return _gate_rows

func debug_pairs() -> Array:
	var out: Array = []
	for pa in _pairs:
		out.append({"members": (pa as Pair).members.duplicate(), "open": (pa as Pair).open.duplicate(), "escaped": (pa as Pair).escaped, "t": (pa as Pair).esc_t})
	return out

func debug_player(id: int) -> Dictionary:
	var r: RS = _rs.get(id)
	if r == null:
		return {}
	return {"pos": r.pos, "pair": r.pair, "side": r.side, "stun": r.stun_t, "escaped": r.escaped, "best": r.best_row, "tile": _tile_of(r.pos)}

func debug_place(id: int, tile: Vector2i) -> void:
	var r: RS = _rs.get(id)
	if r != null:
		r.pos = _tile_center(tile)
		r.safe = tile
		r.vel = Vector2.ZERO

func debug_step(id: int, dir: Vector2, seconds: float) -> void:
	var r: RS = _rs.get(id)
	var t := 0.0
	while t < seconds:
		_step_player(r, STEP, dir)
		_check_plates()
		t += STEP

func debug_shortest(open_all: bool) -> int:
	var pa := Pair.new()
	for g in _gate_rows.size():
		pa.open.append(open_all)
	return _bfs(pa, Vector2i(0, 1), func(c: Vector2i) -> bool: return _kind(c.x, c.y) == EXIT).size()

func debug_view_pairs() -> Array[int]:
	return _view_pairs

func debug_over() -> bool:
	return _over

func debug_win_pair() -> int:
	return _win_pair
