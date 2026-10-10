extends Minigame
## Cuesta Arriba (id uphill_rush; modelo HOST_AUTHORITATIVE, 3D): una calle empinada de noche y, arriba del todo, un
## portal del que no paran de salir coches cuesta abajo. Todos subís a la vez esquivando el tráfico; la cámara va
## detrás de TU personaje mirando cuesta arriba.
## Puntos: +1 por cada metro nuevo que subes, +10 al cruzar cada línea de neón y +30 si llegas al portal. Si te
## atropellan dejas una mancha de pintura y vuelves a la última línea que cruzaste (los puntos no se pierden).
## La partida dura 60 s (o hasta que llegan todos); gana quien tiene más puntos (empate: quien los consiguió antes).
## Controles: WASD / flechas (o palanca) para moverte y ESPACIO o CLIC para saltar (se pueden saltar los coches
## bajos en el último momento; las furgonetas no).
##
## Física propia y muy simple: la calle es un plano inclinado (y = z · SLOPE); cada jugador tiene (x, z) sobre él y
## una altura de salto h. Los coches son cajas que bajan en línea recta (algunos derrapan de lado). Todo sale de la
## semilla común: el host simula a todos a 60 Hz y envía ~30 Hz jugadores y coches; los clientes interpolan y
## adelantan los coches con su velocidad entre estados. El 3D (SubViewport con su propio mundo) es solo presentación.

const STEP := 1.0 / 60.0
const TIME_LIMIT := 60.0
const COUNTDOWN := 3.0
const DONE_DELAY := 2.4
# --- Calle ---
const SLOPE := 0.16                     # pendiente (≈ 9°)
const LENGTH := 330.0                   # metros hasta el portal (corriendo sin parar se tarda ~53 s)
const LINE_GAP := 30.0                  # una línea de neón cada tantos metros
const ROAD_HALF := 7.2                  # medio ancho de la calzada
const WALK_HALF := 9.6                  # medio ancho con las aceras (hasta los edificios)
const PLAYER_LIMIT := 9.1               # hasta dónde puede ir un jugador de lado
const CAR_LIMIT := 8.3                  # los coches derrapan hasta aquí (las aceras tampoco son seguras)
const LANES := [-6.6, -4.4, -2.2, 0.0, 2.2, 4.4, 6.6]
# --- Cuerpo ---
const RADIUS := 0.38
const RUN_SPEED := 6.2
const BACK_SPEED := 4.5
const ACCEL := 40.0
const GRAVITY := 22.0
const JUMP_V := 9.5                     # altura máxima ≈ 2 m: salta un coche, no una furgoneta
const RESPAWN_DELAY := 1.4
const INVULN := 1.6
# --- Puntos ---
const LINE_POINTS := 10
const GOAL_POINTS := 30
# --- Coches ---
enum Kind { SEDAN, TAXI, POLICE, VAN }
const CAR_W := [1.9, 1.9, 1.9, 2.3]
const CAR_L := [4.2, 4.2, 4.4, 5.2]
const CAR_H := [1.35, 1.35, 1.45, 2.3]
const SEDAN_COLORS: Array[Color] = [Color(0.55, 0.6, 0.68), Color(0.25, 0.45, 0.85), Color(0.3, 0.7, 0.45),
		Color(0.85, 0.3, 0.3), Color(0.92, 0.92, 0.95), Color(0.55, 0.35, 0.75)]
const NEON: Array[Color] = [Color(1.0, 0.3, 0.42), Color(0.25, 0.95, 1.0), Color(1.0, 0.45, 0.95)]

class RS:
	var id: int = 0
	var idx: int = 0
	var x: float = 0.0
	var z: float = 0.0
	var h: float = 0.0                  # altura del salto sobre la calle
	var vx: float = 0.0
	var vz: float = 0.0
	var vh: float = 0.0
	var face: float = 0.0               # giro del personaje (0 = cuesta arriba)
	var alive: bool = true
	var dead_t: float = 0.0
	var inv_t: float = 0.0
	var best_z: float = 0.0
	var lines: int = 0                  # líneas cruzadas (la última es el punto de vuelta)
	var score: int = 0
	var score_t: float = 0.0            # cuándo consiguió su último punto (desempate)
	var hits: int = 0
	var finished: bool = false
	var jump_pending: bool = false
	# Eventos de este paso.
	var ev_jump: bool = false
	var ev_hit: bool = false
	var ev_line: bool = false
	var ev_fin: bool = false
	var ev_respawn: bool = false
	# IA
	var skill: float = 1.0
	var bot_rng: RandomNumberGenerator = null
	var bot_jump: bool = false
	var bot_tx: float = 0.0
	var bot_think: float = 0.0
	var bot_lapse: float = 0.0
	# Presentación
	var dx: float = 0.0
	var dz: float = 0.0
	var dh: float = 0.0
	var dface: float = 0.0
	var anim: float = 0.0
	var node: Node3D = null
	var body: Node3D = null
	var arm_l: Node3D = null
	var arm_r: Node3D = null
	var leg_l: Node3D = null
	var leg_r: Node3D = null
	var shadow: MeshInstance3D = null
	var puff: CPUParticles3D = null
	var burst: bool = false

class Car:
	var id: int = 0
	var kind: int = 0
	var variant: int = 0
	var x: float = 0.0
	var z: float = 0.0
	var vx: float = 0.0
	var vz: float = 0.0
	var node: Node3D = null
	var wheels: Array[Node3D] = []
	var siren: MeshInstance3D = null

const FLOATS := 13                      # por jugador en el estado
const CAR_FLOATS := 7                   # por coche en el estado

var _rs: Dictionary = {}                # player id -> RS
var _order: Array[int] = []
var _cars: Array[Car] = []
var _car_ids: int = 0
var _spawn_t: float = 0.0
var _wave_t: float = 6.0
var _lane_last: Array[float] = []       # cuándo salió el último coche por cada carril
var _car_rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _t: float = 0.0
var _cd: float = COUNTDOWN
var _last_cd: int = 99
var _accum: float = 0.0
var _over: bool = false
var _over_t: float = 0.0
var _winner_id: int = -1
var _toast: String = ""
var _toast_t: float = 0.0
var _hint_t: float = 7.0
var _shake: float = 0.0
var _anim: float = 0.0
var _pops: Array = []                   # {"id", "text", "t"} "+10" que saltan sobre la tarjeta de cada jugador
var debug_skill: float = -1.0           # >= 0: fuerza la habilidad de todas las IAs (pruebas)

# --- Escena 3D ---
var _vp: SubViewport
var _cont: SubViewportContainer
var _root3: Node3D
var _cam: Camera3D
var _built: bool = false
var _cam_pos: Vector3 = Vector3.ZERO
var _line_mats: Array[StandardMaterial3D] = []
var _portal: Node3D = null
var _portal_swirl: MeshInstance3D = null
var _splats: Array[MeshInstance3D] = []
var _hit_puff: CPUParticles3D = null
var _car_mats: Dictionary = {}

# ----------------------------------------------------------------------------
# Utilidades de la calle
# ----------------------------------------------------------------------------

## Calle → mundo. x positiva = a la DERECHA de la pantalla (la cámara mira hacia +z, así que va a -x en el mundo).
func _w(x: float, z: float, h: float = 0.0) -> Vector3:
	return Vector3(-x, z * SLOPE + h, z)

func _line_z(i: int) -> float:
	return LINE_GAP * float(i + 1)

func _line_count() -> int:
	return int(floor((LENGTH - 1.0) / LINE_GAP))

func _checkpoint_z(r: RS) -> float:
	return 0.0 if r.lines <= 0 else _line_z(r.lines - 1)

func _player_by_id(id: int) -> PlayerData:
	for pl in players:
		if pl.id == id:
			return pl
	return null

func _mine(r: RS) -> bool:
	var pl := _player_by_id(r.id)
	return pl != null and is_audible(pl)

func _start_x(idx: int, count: int) -> float:
	if count <= 1:
		return 0.0
	return lerpf(-6.0, 6.0, float(idx) / float(count - 1))

func _make_rs(p: PlayerData, idx: int, count: int) -> RS:
	var r := RS.new()
	r.id = p.id
	r.idx = idx
	r.x = _start_x(idx, count)
	r.z = 0.0
	r.dx = r.x
	r.bot_tx = r.x
	r.bot_rng = RandomNumberGenerator.new()
	r.bot_rng.seed = hash([seed_value, p.id, "uphill"])
	r.skill = 0.72 + 0.26 * r.bot_rng.randf()
	return r

func _setup_runners() -> void:
	# Los modelos de la tanda anterior (la preparación) se borran: si no, se quedarían quietos en la salida.
	for old in _rs.values():
		for n in [(old as RS).node, (old as RS).shadow, (old as RS).puff]:
			if n != null and is_instance_valid(n):
				(n as Node).queue_free()
	_rs.clear()
	_order.clear()
	var n := players.size()
	for i in n:
		var p := players[i]
		_rs[p.id] = _make_rs(p, i, n)
		_order.append(p.id)

func _reset_traffic() -> void:
	for c in _cars:
		if c.node != null and is_instance_valid(c.node):
			c.node.queue_free()
	_cars.clear()
	_car_ids = 0
	_car_rng.seed = hash([seed_value, "traffic"])
	_spawn_t = 0.4
	_wave_t = 7.0
	_lane_last.clear()
	for i in LANES.size():
		_lane_last.append(-99.0)
	# Unos cuantos coches ya bajando al empezar (que la calle no esté vacía).
	for i in 6:
		_spawn_car(-1, LENGTH * (0.35 + 0.1 * i))

# ----------------------------------------------------------------------------
# Tráfico (solo quien simula; sale de la semilla común)
# ----------------------------------------------------------------------------

func _difficulty() -> float:
	return clampf(_t / TIME_LIMIT, 0.0, 1.0)

func _spawn_car(lane: int = -1, at_z: float = LENGTH + 8.0, kind: int = -1) -> Car:
	var rr := _car_rng
	if lane < 0:
		# Un carril que no haya usado nadie hace poco.
		var free: Array[int] = []
		for i in LANES.size():
			if _t - _lane_last[i] > 0.9:
				free.append(i)
		lane = free[rr.randi() % free.size()] if not free.is_empty() else rr.randi() % LANES.size()
	_lane_last[lane] = _t
	var c := Car.new()
	_car_ids += 1
	c.id = _car_ids
	if kind < 0:
		var k := rr.randf()
		kind = Kind.VAN if k < 0.16 else (Kind.TAXI if k < 0.42 else (Kind.POLICE if k < 0.56 else Kind.SEDAN))
	c.kind = kind
	c.variant = rr.randi() % SEDAN_COLORS.size()
	c.x = float(LANES[lane]) + rr.randf_range(-0.4, 0.4)
	c.z = at_z
	var d := _difficulty()
	c.vz = -rr.randf_range(11.0, 16.0) - 7.0 * d
	if kind == Kind.VAN:
		c.vz *= 0.85
	# Algunos bajan derrapando de lado (rebotan contra las aceras).
	if rr.randf() < 0.22 + 0.2 * d:
		c.vx = rr.randf_range(1.5, 3.5) * (1.0 if rr.randf() < 0.5 else -1.0)
	_cars.append(c)
	return c

func _update_traffic(dt: float) -> void:
	var d := _difficulty()
	_spawn_t -= dt
	if _spawn_t <= 0.0:
		_spawn_car()
		_spawn_t = lerpf(0.62, 0.3, d) * _car_rng.randf_range(0.75, 1.25)
	# Cada pocos segundos, una "ola": una fila de coches con un hueco de dos carriles.
	_wave_t -= dt
	if _wave_t <= 0.0:
		_wave_t = lerpf(9.0, 6.0, d) * _car_rng.randf_range(0.85, 1.15)
		var gap := _car_rng.randi() % (LANES.size() - 1)
		var wave_v := -_car_rng.randf_range(12.0, 15.0) - 5.0 * d
		for i in LANES.size():
			if i == gap or i == gap + 1:
				continue
			var c := _spawn_car(i, LENGTH + 8.0 + _car_rng.randf_range(0.0, 2.5), Kind.SEDAN if _car_rng.randf() < 0.6 else Kind.TAXI)
			c.vz = wave_v
			c.vx = 0.0
	var keep: Array[Car] = []
	for c in _cars:
		c.z += c.vz * dt
		c.x += c.vx * dt
		var lim := CAR_LIMIT - float(CAR_W[c.kind]) * 0.5
		if absf(c.x) > lim:
			c.x = signf(c.x) * lim
			c.vx = -c.vx
		if c.z > -25.0:
			keep.append(c)
		elif c.node != null and is_instance_valid(c.node):
			c.node.queue_free()
	_cars = keep

func _car_hits(c: Car, x: float, z: float, h: float, margin: float = 0.0) -> bool:
	return absf(x - c.x) < float(CAR_W[c.kind]) * 0.5 + RADIUS + margin \
			and absf(z - c.z) < float(CAR_L[c.kind]) * 0.5 + RADIUS + margin \
			and h < float(CAR_H[c.kind]) - 0.12

# ----------------------------------------------------------------------------
# Un paso de un jugador
# ----------------------------------------------------------------------------

func _sim_step(r: RS, dt: float, inp: Vector2, jump: bool) -> void:
	if r.inv_t > 0.0:
		r.inv_t = maxf(0.0, r.inv_t - dt)
	if not r.alive:
		r.dead_t += dt
		if r.dead_t >= RESPAWN_DELAY:
			r.alive = true
			r.dead_t = 0.0
			r.z = _checkpoint_z(r)
			r.x = clampf(r.x, -PLAYER_LIMIT, PLAYER_LIMIT)
			r.h = 0.0
			r.vx = 0.0
			r.vz = 0.0
			r.vh = 0.0
			r.inv_t = INVULN
			r.ev_respawn = true
		return
	if r.finished or _over:
		inp = Vector2.ZERO
		jump = false
	# Movimiento: adelante = cuesta arriba. Hacia atrás se va un poco más despacio.
	var want := Vector2(inp.x, -inp.y)
	if want.length() > 1.0:
		want = want.normalized()
	var tvx := want.x * RUN_SPEED
	var tvz := want.y * (RUN_SPEED if want.y >= 0.0 else BACK_SPEED)
	var a := ACCEL * (1.0 if r.h <= 0.0 else 0.45)
	r.vx = move_toward(r.vx, tvx, a * dt)
	r.vz = move_toward(r.vz, tvz, a * dt)
	if jump and r.h <= 0.0:
		r.vh = JUMP_V
		r.ev_jump = true
	if r.h > 0.0 or r.vh > 0.0:
		r.vh -= GRAVITY * dt
		r.h += r.vh * dt
		if r.h <= 0.0:
			r.h = 0.0
			r.vh = 0.0
	r.x = clampf(r.x + r.vx * dt, -PLAYER_LIMIT, PLAYER_LIMIT)
	r.z = clampf(r.z + r.vz * dt, -4.0, LENGTH)
	if absf(r.vx) + absf(r.vz) > 0.5:
		r.face = lerp_angle(r.face, atan2(r.vx, r.vz), 1.0 - exp(-12.0 * dt))
	# Puntos: un punto por metro nuevo, líneas de neón y meta.
	if r.z > r.best_z + 1.0:
		var gained := int(floor(r.z - r.best_z))
		r.best_z += float(gained)
		r.score += gained
		r.score_t = _t
	while r.lines < _line_count() and r.z >= _line_z(r.lines):
		r.lines += 1
		r.score += LINE_POINTS
		r.score_t = _t
		r.ev_line = true
	if not r.finished and r.z >= LENGTH:
		r.finished = true
		r.score += GOAL_POINTS
		r.score_t = _t
		r.ev_fin = true
	# ¿Atropellado?
	if r.inv_t <= 0.0 and not r.finished:
		for c in _cars:
			if _car_hits(c, r.x, r.z, r.h):
				r.alive = false
				r.dead_t = 0.0
				r.hits += 1
				r.ev_hit = true
				break

# ----------------------------------------------------------------------------
# Ciclo del minijuego (el host simula a todos)
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	_setup_runners()
	_t = 0.0
	_reset_traffic()
	_build_world()
	surface.draw_callback = _draw_hud

func _on_start() -> void:
	_setup_runners()
	_t = 0.0
	_reset_traffic()
	_rebuild_runner_nodes()
	_accum = 0.0
	_cd = COUNTDOWN
	_last_cd = 99
	_over = false
	_over_t = 0.0
	_winner_id = -1
	_hint_t = 7.0
	_toast = ""
	_toast_t = 0.0
	_pops.clear()
	for sp in _splats:
		sp.queue_free()
	_splats.clear()
	var cs := _cam_runner()
	if cs != null:
		_cam_pos = _cam_target(cs)

func _simulate(delta: float) -> void:
	if _over:
		_over_t += delta
		_update_traffic(delta)
		if _over_t >= DONE_DELAY:
			finish(_ranking_ids())
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
	var inputs: Dictionary = {}
	for pl in players:
		var r: RS = _rs[pl.id]
		inputs[pl.id] = move_input(pl)
		if action_presses(pl) > 0:
			r.jump_pending = true
	_accum += delta
	var steps := 0
	while _accum >= STEP and steps < 12:
		_accum -= STEP
		steps += 1
		_t += STEP
		_update_traffic(STEP)
		for pl in players:
			var r2: RS = _rs[pl.id]
			_sim_step(r2, STEP, inputs[pl.id] as Vector2, r2.jump_pending)
			r2.jump_pending = false
			_collect_events(r2)
	var all_done := true
	for id in _order:
		if not (_rs[id] as RS).finished:
			all_done = false
	if all_done or _t >= TIME_LIMIT:
		_over = true
		_over_t = 0.0
		var rk := _ranking_ids()
		_winner_id = rk[0] if not rk.is_empty() else -1
		send_event("over", {"w": _winner_id})
		DevCli.log_event("uphill over winner=%d" % _winner_id)

func _collect_events(r: RS) -> void:
	if r.ev_jump:
		send_event("jump", {"p": r.id})
	if r.ev_hit:
		send_event("hit", {"p": r.id, "x": r.x, "z": r.z})
	if r.ev_line:
		send_event("line", {"p": r.id, "i": r.lines})
	if r.ev_fin:
		send_event("fin", {"p": r.id})
	if r.ev_respawn:
		send_event("respawn", {"p": r.id})
	r.ev_jump = false
	r.ev_hit = false
	r.ev_line = false
	r.ev_fin = false
	r.ev_respawn = false

## Más puntos primero; a igualdad, quien los consiguió antes.
func _ranking_ids() -> Array[int]:
	var scores := {}
	var ties := {}
	for id in _order:
		var r: RS = _rs[id]
		scores[id] = float(r.score)
		ties[id] = r.score_t
	return rank_by_score(scores, ties)

func _place_of(id: int) -> int:
	return _ranking_ids().find(id) + 1

# ----------------------------------------------------------------------------
# Red
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var arr := PackedFloat32Array()
	for id in _order:
		var r: RS = _rs[id]
		arr.append_array(PackedFloat32Array([r.x, r.z, r.h, r.vx, r.vz, r.face, 1.0 if r.alive else 0.0, r.inv_t,
				float(r.score), r.best_z, float(r.lines), 1.0 if r.finished else 0.0, float(r.hits)]))
	var cars := PackedFloat32Array()
	for c in _cars:
		cars.append_array(PackedFloat32Array([float(c.id), float(c.kind), float(c.variant), c.x, c.z, c.vx, c.vz]))
	return {"r": arr, "c": cars, "t": _t, "cd": _cd, "o": _over, "w": _winner_id}

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	var st: Dictionary = state
	_t = float(st.get("t", _t))
	_cd = float(st.get("cd", _cd))
	_over = bool(st.get("o", _over))
	_winner_id = int(st.get("w", _winner_id))
	var arr: Variant = st.get("r")
	if arr is PackedFloat32Array and arr.size() >= _order.size() * FLOATS:
		for i in _order.size():
			var r: RS = _rs[_order[i]]
			var o := i * FLOATS
			r.x = arr[o]
			r.z = arr[o + 1]
			r.h = arr[o + 2]
			r.vx = arr[o + 3]
			r.vz = arr[o + 4]
			r.face = arr[o + 5]
			r.alive = arr[o + 6] > 0.5
			r.inv_t = arr[o + 7]
			r.score = int(arr[o + 8])
			r.best_z = arr[o + 9]
			r.lines = int(arr[o + 10])
			r.finished = arr[o + 11] > 0.5
			r.hits = int(arr[o + 12])
	var ca: Variant = st.get("c")
	if ca is PackedFloat32Array:
		var by_id := {}
		for c in _cars:
			by_id[c.id] = c
		var next: Array[Car] = []
		var n: int = ca.size() / CAR_FLOATS
		for i in n:
			var o := i * CAR_FLOATS
			var id := int(ca[o])
			var c: Car = by_id.get(id)
			if c == null:
				c = Car.new()
				c.id = id
				c.kind = int(ca[o + 1])
				c.variant = int(ca[o + 2])
			else:
				by_id.erase(id)
			c.x = ca[o + 3]
			c.z = ca[o + 4]
			c.vx = ca[o + 5]
			c.vz = ca[o + 6]
			next.append(c)
		for old in by_id.values():
			if (old as Car).node != null and is_instance_valid((old as Car).node):
				(old as Car).node.queue_free()
		_cars = next

func _on_event(event_name: String, data: Variant) -> void:
	var d: Dictionary = data if data is Dictionary else {}
	var r: RS = _rs.get(int(d.get("p", -1)))
	match event_name:
		"beep":
			Audio.sfx(&"beep", -7.0)
		"go":
			Audio.sfx(&"beep_go", -5.0)
		"jump":
			if r != null:
				r.burst = true
				if _mine(r):
					Audio.sfx(&"jump", -8.0)
		"hit":
			if r != null:
				var pl := _player_by_id(r.id)
				_add_splat(float(d.get("x", r.x)), float(d.get("z", r.z)), pl.color if pl != null else Palette.CORAL)
				if _mine(r):
					Audio.sfx(&"crash", -4.0)
					_shake = 0.7
					_toast = "¡ATROPELLADO!"
					_toast_t = 1.2
				else:
					Audio.sfx(&"thud", -14.0)
		"respawn":
			if r != null:
				r.burst = true
		"line":
			if r != null:
				_pops.append({"id": r.id, "text": "+%d" % LINE_POINTS, "t": 1.2})
				if _mine(r):
					Audio.sfx(&"milestone", -6.0)
		"fin":
			if r != null:
				_pops.append({"id": r.id, "text": "+%d" % GOAL_POINTS, "t": 1.6})
				Audio.sfx(&"fanfare_small" if _mine(r) else &"swish", -5.0)
				if _mine(r):
					_toast = "¡HAS LLEGADO ARRIBA!"
					_toast_t = 2.0
		"over":
			_winner_id = int(d.get("w", -1))

func _animate(delta: float) -> void:
	_shake = maxf(0.0, _shake - delta * 2.5)
	_toast_t = maxf(0.0, _toast_t - delta)
	_anim += delta
	if _cd <= 0.0:
		_hint_t = maxf(0.0, _hint_t - delta)
	for p in _pops:
		p["t"] = float(p["t"]) - delta
	_pops = _pops.filter(func(p: Dictionary) -> bool: return float(p["t"]) > 0.0)
	# Los clientes adelantan los coches con su velocidad entre un estado y el siguiente.
	if not is_authority and _cd <= 0.0:
		for c in _cars:
			c.z += c.vz * delta
			c.x += c.vx * delta
	_update_world(delta)

# ----------------------------------------------------------------------------
# IA (bots, autopiloto, práctica): elige el hueco más seguro un poco por delante y sube
# ----------------------------------------------------------------------------

## Peligro de estar en (x, z) durante el próximo segundo largo.
func _danger(x: float, z: float, horizon: float) -> float:
	var dg := 0.0
	for c in _cars:
		var dz := c.z - z
		if dz < -3.5 or dz > 30.0:
			continue
		var w := float(CAR_W[c.kind]) * 0.5 + RADIUS + 0.55
		var l := float(CAR_L[c.kind]) * 0.5 + RADIUS + 0.4
		var t := 0.0
		while t <= horizon:
			var cx := c.x + c.vx * t
			var cz := c.z + c.vz * t
			if absf(cx - x) < w and absf(cz - z) < l:
				dg += 2.0 / (t + 0.25)
				break
			t += 0.1
	return dg

func _bot_decide(r: RS) -> Vector2:
	r.bot_jump = false
	if not r.alive or r.finished or _over or _cd > 0.0:
		return Vector2.ZERO
	var sk := r.skill if debug_skill < 0.0 else debug_skill
	if r.bot_lapse > 0.0:
		r.bot_lapse -= STEP
		return Vector2(0.0, -1.0)               # distraído: sube sin mirar
	if r.bot_rng.randf() < (1.0 - sk) * 0.012:
		r.bot_lapse = r.bot_rng.randf_range(0.3, 0.8)
	var horizon := 0.8 + 0.7 * sk
	r.bot_think -= STEP
	if r.bot_think <= 0.0:
		r.bot_think = lerpf(0.25, 0.08, sk)
		var best_x := r.x
		var best := INF
		var xs := -PLAYER_LIMIT + 0.3
		while xs <= PLAYER_LIMIT - 0.3:
			var cost := _danger(xs, r.z + 1.5, horizon) + absf(xs - r.x) * 0.06 + absf(xs) * 0.01
			if cost < best:
				best = cost
				best_x = xs
			xs += 0.6
		r.bot_tx = best_x
	var here := _danger(r.x, r.z, 0.45)
	var ahead := _danger(r.x, r.z + 1.5, horizon)
	var side := clampf((r.bot_tx - r.x) * 1.4, -1.0, 1.0)
	var fwd := 1.0
	if ahead > 3.0 and absf(r.bot_tx - r.x) > 0.6:
		fwd = 0.15                              # se aparta antes de seguir subiendo
	if here > 5.0 and _danger(r.x, r.z - 1.5, 0.45) < here * 0.5:
		fwd = -1.0                              # retrocede si le viene uno encima
	# Salto de última hora sobre un coche bajo.
	if r.h <= 0.0:
		for c in _cars:
			if c.kind != Kind.VAN and _car_hits(c, r.x, r.z - c.vz * 0.2, 0.0, 0.05) and not _car_hits(c, r.x, r.z - c.vz * 0.1, 0.0):
				if r.bot_rng.randf() < 0.55 + 0.4 * sk:
					r.bot_jump = true
				break
	return Vector2(side, -fwd)

func _bot_move(player: PlayerData) -> Vector2:
	var r: RS = _rs.get(player.id)
	if r == null:
		return Vector2.ZERO
	return _bot_decide(r)

func _bot_action(player: PlayerData) -> int:
	var r: RS = _rs.get(player.id)
	if r == null:
		return 0
	var v := 1 if r.bot_jump else 0
	r.bot_jump = false
	return v

func _bot_action_held(_player: PlayerData) -> bool:
	return false

# ----------------------------------------------------------------------------
# Escena 3D: calle de noche, edificios con ventanas, farolas, líneas de neón y el portal
# ----------------------------------------------------------------------------

func _mat(c: Color, emission: float = 0.0, rough: float = 0.85) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emission
	return m

## Material "dibujo animado": color liso con contorno oscuro.
func _toon(c: Color, emission: float = 0.0, outline: float = 0.028) -> StandardMaterial3D:
	var m := _mat(c, emission, 0.55)
	var o := StandardMaterial3D.new()
	o.albedo_color = Color(0.05, 0.04, 0.1)
	o.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	o.cull_mode = BaseMaterial3D.CULL_FRONT
	o.grow = true
	o.grow_amount = outline
	m.next_pass = o
	return m

func _unshaded(c: Color, alpha: bool = false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if alpha:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
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

func _cyl(radius: float, height: float, segs: int = 20) -> CylinderMesh:
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = segs
	cm.rings = 1
	return cm

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

func _particles(color: Color, amount: int, life: float, radius: float, vel_min: float, vel_max: float, grav: Vector3) -> CPUParticles3D:
	var pt := CPUParticles3D.new()
	pt.amount = amount
	pt.lifetime = life
	pt.one_shot = true
	pt.emitting = false
	pt.explosiveness = 0.92
	pt.direction = Vector3.UP
	pt.spread = 80.0
	pt.initial_velocity_min = vel_min
	pt.initial_velocity_max = vel_max
	pt.gravity = grav
	pt.scale_amount_min = 0.6
	pt.scale_amount_max = 1.3
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(1.0, 0.0))
	pt.scale_amount_curve = curve
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 8
	sm.rings = 4
	var mat := _unshaded(color, true)
	mat.vertex_color_use_as_albedo = true
	sm.material = mat
	pt.mesh = sm
	return pt

## Pieza tumbada sobre la calle (sigue la pendiente): centro (x, z), tamaño (ancho, grosor, largo).
func _slab(parent: Node3D, x: float, z: float, size: Vector3, lift: float, mat: Material) -> MeshInstance3D:
	var mi := _box(parent, size, _w(x, z, lift), mat)
	mi.rotation.x = -atan(SLOPE)
	return mi

func _build_world() -> void:
	if _built:
		return
	_built = true
	var cont := SubViewportContainer.new()
	cont.stretch = true
	cont.top_level = true
	cont.set_anchors_preset(Control.PRESET_TOP_LEFT)
	cont.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cont = cont
	add_child(cont)
	move_child(cont, surface.get_index())      # el 3D va detrás del HUD
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.handle_input_locally = false
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	cont.add_child(_vp)
	_root3 = Node3D.new()
	_vp.add_child(_root3)
	# --- Noche: cielo azul oscuro, niebla violeta, brillo para el neón ---
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.03, 0.04, 0.12)
	sky_mat.sky_horizon_color = Color(0.16, 0.12, 0.3)
	sky_mat.ground_horizon_color = Color(0.16, 0.12, 0.3)
	sky_mat.ground_bottom_color = Color(0.03, 0.03, 0.08)
	sky_mat.sun_angle_max = 0.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.5, 0.85)
	env.ambient_light_energy = 0.75
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 4.0
	env.glow_enabled = true
	env.glow_intensity = 0.9
	env.glow_bloom = 0.12
	env.glow_hdr_threshold = 0.85
	env.fog_enabled = true
	env.fog_light_color = Color(0.13, 0.1, 0.26)
	env.fog_density = 0.009
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	_root3.add_child(we)
	var moon := DirectionalLight3D.new()
	moon.rotation_degrees = Vector3(-52.0, 150.0, 0.0)
	moon.light_energy = 0.75
	moon.light_color = Color(0.7, 0.78, 1.0)
	moon.shadow_enabled = true
	moon.directional_shadow_max_distance = 60.0
	_root3.add_child(moon)
	# Estrellas.
	var star_mm := MultiMesh.new()
	star_mm.transform_format = MultiMesh.TRANSFORM_3D
	var star_mesh := SphereMesh.new()
	star_mesh.radius = 0.9
	star_mesh.height = 1.8
	star_mesh.radial_segments = 6
	star_mesh.rings = 3
	star_mm.mesh = star_mesh
	star_mm.instance_count = 260
	var srng := RandomNumberGenerator.new()
	srng.seed = 9917
	for i in star_mm.instance_count:
		var dir := Vector3(srng.randf_range(-1.0, 1.0), srng.randf_range(0.12, 1.0), srng.randf_range(-0.3, 1.0)).normalized()
		star_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * srng.randf_range(0.5, 1.4)), dir * 420.0 + Vector3(0, 0, LENGTH * 0.5)))
	var stars := MultiMeshInstance3D.new()
	stars.multimesh = star_mm
	var star_mat := _unshaded(Color(1.0, 0.95, 0.85))
	star_mat.disable_fog = true
	stars.material_override = star_mat
	stars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root3.add_child(stars)
	# --- Calle: asfalto, aceras, bordillos y marcas ---
	var z0 := -40.0
	var z1 := LENGTH + 60.0
	var zc := (z0 + z1) * 0.5
	var zl := (z1 - z0) / cos(atan(SLOPE))
	_slab(_root3, 0.0, zc, Vector3(ROAD_HALF * 2.0, 0.4, zl), -0.2, _mat(Color(0.17, 0.18, 0.24), 0.0, 0.7))
	var walk_mat := _mat(Color(0.34, 0.34, 0.42), 0.0, 0.9)
	var curb_mat := _mat(Color(0.55, 0.55, 0.62), 0.0, 0.8)
	for sx in [-1.0, 1.0]:
		var wx: float = sx * (ROAD_HALF + (WALK_HALF - ROAD_HALF) * 0.5)
		_slab(_root3, wx, zc, Vector3(WALK_HALF - ROAD_HALF, 0.5, zl), -0.13, walk_mat)
		_slab(_root3, sx * (ROAD_HALF + 0.08), zc, Vector3(0.18, 0.55, zl), -0.12, curb_mat)
		_slab(_root3, sx * (ROAD_HALF - 0.35), zc, Vector3(0.14, 0.02, zl), 0.0, _mat(Color(0.85, 0.85, 0.9), 0.3))
	var yellow := _mat(Color(1.0, 0.8, 0.2), 0.6)
	for sx in [-0.16, 0.16]:
		_slab(_root3, sx, zc, Vector3(0.12, 0.02, zl), 0.0, yellow)
	var dash := _mat(Color(0.8, 0.8, 0.86), 0.25)
	var zd := z0
	while zd < z1:
		for lx in [-3.3, 3.3]:
			_slab(_root3, lx, zd, Vector3(0.12, 0.02, 2.6), 0.0, dash)
		zd += 7.0
	# Charcos que brillan.
	var puddle := _mat(Color(0.35, 0.45, 0.7), 0.15, 0.05)
	puddle.metallic = 0.6
	var prng := RandomNumberGenerator.new()
	prng.seed = 5150
	for i in 26:
		var pm := _mesh(_root3, _cyl(1.0, 0.02, 14), Vector3.ZERO, puddle)
		var px := prng.randf_range(-ROAD_HALF + 1.0, ROAD_HALF - 1.0)
		var pz := prng.randf_range(-10.0, LENGTH)
		pm.position = _w(px, pz, 0.012)
		pm.rotation.x = -atan(SLOPE)
		pm.scale = Vector3(prng.randf_range(0.8, 2.2), 1.0, prng.randf_range(0.6, 1.6))
		pm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# --- Edificios a los dos lados, con ventanas encendidas ---
	_build_buildings()
	# --- Farolas ---
	var pole_mat := _mat(Color(0.12, 0.13, 0.18), 0.0, 0.5)
	var bulb_mat := _mat(Color(1.0, 0.85, 0.55), 3.0)
	var pool_mat := _unshaded(Color(1.0, 0.82, 0.5, 0.16), true)
	pool_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	var zf := 8.0
	var side := 1.0
	while zf < LENGTH + 30.0:
		var lx2 := side * (WALK_HALF - 0.6)
		var base := _w(lx2, zf, 0.0)
		var pole := _mesh(_root3, _cyl(0.09, 5.6, 8), base + Vector3(0, 2.8, 0), pole_mat)
		pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		var arm := _box(_root3, Vector3(1.6, 0.08, 0.08), _w(lx2 - side * 0.75, zf, 5.55), pole_mat)
		arm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var bulb := _box(_root3, Vector3(0.5, 0.12, 0.3), _w(lx2 - side * 1.4, zf, 5.45), bulb_mat)
		bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var pool := _mesh(_root3, _cyl(3.2, 0.02, 20), _w(lx2 - side * 1.6, zf, 0.03), pool_mat)
		pool.rotation.x = -atan(SLOPE)
		pool.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		zf += 13.0
		side = -side
	# --- Líneas de neón (puntos de control) ---
	for i in _line_count():
		var col: Color = NEON[i % NEON.size()]
		var lm := _mat(col, 2.6, 0.4)
		_line_mats.append(lm)
		var ln := _slab(_root3, 0.0, _line_z(i), Vector3(WALK_HALF * 2.0, 0.06, 0.55), 0.03, lm)
		ln.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Meta dorada al pie del portal.
	var goal := _slab(_root3, 0.0, LENGTH, Vector3(WALK_HALF * 2.0, 0.06, 1.2), 0.03, _mat(Color(1.0, 0.82, 0.25), 3.0, 0.3))
	goal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# --- El portal del que salen los coches ---
	_portal = Node3D.new()
	_portal.position = _w(0.0, LENGTH + 9.0, 4.5)
	_root3.add_child(_portal)
	var torus := TorusMesh.new()
	torus.inner_radius = 6.3
	torus.outer_radius = 7.3
	torus.rings = 48
	torus.ring_segments = 12
	var ring := _mesh(_portal, torus, Vector3.ZERO, _mat(Color(0.35, 0.95, 1.0), 4.0, 0.2))
	ring.rotation.x = PI * 0.5
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var swirl_mat := _unshaded(Color(0.4, 0.85, 1.0, 0.55), true)
	swirl_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	swirl_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	swirl_mat.albedo_texture = _swirl_texture()
	swirl_mat.disable_fog = true
	var disc := CylinderMesh.new()
	disc.top_radius = 6.5
	disc.bottom_radius = 6.5
	disc.height = 0.05
	disc.radial_segments = 40
	_portal_swirl = _mesh(_portal, disc, Vector3.ZERO, swirl_mat)
	_portal_swirl.rotation.x = PI * 0.5
	_portal_swirl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sparks := CPUParticles3D.new()
	sparks.amount = 60
	sparks.lifetime = 2.2
	sparks.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	sparks.emission_ring_axis = Vector3(0, 0, 1)
	sparks.emission_ring_radius = 6.8
	sparks.emission_ring_inner_radius = 5.8
	sparks.emission_ring_height = 0.2
	sparks.direction = Vector3(0, 0, -1)
	sparks.spread = 35.0
	sparks.initial_velocity_min = 2.0
	sparks.initial_velocity_max = 6.0
	sparks.gravity = Vector3(0, -1.5, 0)
	var spm := SphereMesh.new()
	spm.radius = 0.12
	spm.height = 0.24
	spm.radial_segments = 6
	spm.rings = 3
	spm.material = _mat(Color(0.5, 1.0, 0.9), 4.0)
	sparks.mesh = spm
	_portal.add_child(sparks)
	# --- Restos: manchas de pintura y partículas del atropello ---
	_hit_puff = _particles(Color(1, 1, 1, 0.9), 18, 0.6, 0.14, 3.0, 7.0, Vector3(0, -12.0, 0))
	_root3.add_child(_hit_puff)
	_cam = Camera3D.new()
	_cam.fov = 66.0
	_cam.far = 600.0
	_root3.add_child(_cam)
	_cam.current = true
	_rebuild_runner_nodes()

func _swirl_texture() -> ImageTexture:
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var p := Vector2(x - n * 0.5, y - n * 0.5) / (n * 0.5)
			var rr := p.length()
			var ang := atan2(p.y, p.x)
			var v := 0.5 + 0.5 * sin(ang * 5.0 + rr * 14.0)
			var a := clampf(1.0 - rr, 0.0, 1.0) * (0.35 + 0.65 * v)
			img.set_pixel(x, y, Color(0.6 + 0.4 * v, 0.9, 1.0, a))
	return ImageTexture.create_from_image(img)

func _build_buildings() -> void:
	var brng := RandomNumberGenerator.new()
	brng.seed = 4401
	var wall_cols: Array[Color] = [Color(0.36, 0.22, 0.24), Color(0.3, 0.26, 0.34), Color(0.26, 0.28, 0.36), Color(0.4, 0.3, 0.26)]
	var lit_mm := MultiMesh.new()
	lit_mm.transform_format = MultiMesh.TRANSFORM_3D
	var dark_mm := MultiMesh.new()
	dark_mm.transform_format = MultiMesh.TRANSFORM_3D
	var win := BoxMesh.new()
	win.size = Vector3(0.12, 1.5, 1.1)
	lit_mm.mesh = win
	dark_mm.mesh = win
	var lit: Array[Transform3D] = []
	var dark: Array[Transform3D] = []
	for sx in [-1.0, 1.0]:
		var z := -40.0
		while z < LENGTH + 70.0:
			var blen := brng.randf_range(10.0, 20.0)
			var depth := 9.0
			var hgt := brng.randf_range(12.0, 30.0)
			var zc := z + blen * 0.5
			var ground := (z) * SLOPE                          # el pie más bajo del bloque
			var top := (z + blen) * SLOPE + hgt
			var inner: float = WALK_HALF
			var cx: float = sx * (inner + depth * 0.5)
			var m := _mat(wall_cols[brng.randi() % wall_cols.size()], 0.0, 0.95)
			var bh := top - ground + 3.0
			var b := _box(_root3, Vector3(depth, bh, blen - 0.3), Vector3(-cx, ground - 3.0 + bh * 0.5, zc), m)
			b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			# Cornisa.
			_box(_root3, Vector3(depth + 0.6, 0.5, blen), Vector3(-cx, top + 0.25, zc), _mat(wall_cols[0].darkened(0.4)))
			# Ventanas en la fachada que da a la calle (filas que siguen la cuesta).
			var face_x: float = -sx * (inner + 0.02)
			var wz := z + 2.0
			while wz < z + blen - 1.5:
				var floor0 := wz * SLOPE + 3.2
				var wy := floor0
				while wy < top - 1.5:
					var t := Transform3D(Basis(), Vector3(face_x, wy, wz))
					if brng.randf() < 0.55:
						lit.append(t)
					else:
						dark.append(t)
					wy += 3.4
				wz += 2.8
			z += blen
	lit_mm.instance_count = lit.size()
	for i in lit.size():
		lit_mm.set_instance_transform(i, lit[i])
	dark_mm.instance_count = dark.size()
	for i in dark.size():
		dark_mm.set_instance_transform(i, dark[i])
	var lit_i := MultiMeshInstance3D.new()
	lit_i.multimesh = lit_mm
	lit_i.material_override = _mat(Color(1.0, 0.8, 0.45), 2.2)
	lit_i.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root3.add_child(lit_i)
	var dark_i := MultiMeshInstance3D.new()
	dark_i.multimesh = dark_mm
	dark_i.material_override = _mat(Color(0.1, 0.12, 0.2), 0.0, 0.2)
	dark_i.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root3.add_child(dark_i)

func _rebuild_runner_nodes() -> void:
	if not _built:
		return
	for id in _order:
		var r: RS = _rs[id]
		for n in [r.node, r.shadow, r.puff]:
			if n != null and is_instance_valid(n):
				(n as Node).queue_free()
		_build_runner(r, _player_by_id(id))

## El personaje: cuerpo del color del jugador, casco con visera, brazos y piernas que se mueven.
func _build_runner(r: RS, pl: PlayerData) -> void:
	r.node = Node3D.new()
	_root3.add_child(r.node)
	var col: Color = pl.color if pl != null else Palette.YELLOW
	var dark := col.darkened(0.4)
	var skin := Color(1.0, 0.86, 0.7)
	r.body = Node3D.new()
	r.node.add_child(r.body)
	var body := r.body
	_capsule(body, 0.32, 0.92, Vector3(0, 0.8, 0), _toon(col))
	_sphere(body, 0.32, Vector3(0, 1.45, 0), _toon(skin))
	var helmet := _sphere(body, 0.36, Vector3(0, 1.55, -0.02), _toon(col.lightened(0.15), 0.1))
	helmet.scale = Vector3(1.0, 0.8, 1.0)
	var visor := _box(body, Vector3(0.46, 0.12, 0.12), Vector3(0, 1.47, 0.27), _mat(Color(0.15, 0.85, 1.0), 1.5, 0.2))
	visor.rotation.x = 0.1
	_box(body, Vector3(0.36, 0.14, 0.04), Vector3(0, 0.95, 0.31), _mat(Color(1.0, 1.0, 1.0), 0.8))   # franja reflectante
	r.arm_l = Node3D.new()
	r.arm_l.position = Vector3(-0.4, 1.12, 0)
	body.add_child(r.arm_l)
	r.arm_r = Node3D.new()
	r.arm_r.position = Vector3(0.4, 1.12, 0)
	body.add_child(r.arm_r)
	for arm in [r.arm_l, r.arm_r]:
		_capsule(arm, 0.09, 0.54, Vector3(0, -0.23, 0), _toon(col))
		_sphere(arm, 0.095, Vector3(0, -0.48, 0), _toon(skin, 0.0, 0.02))
	r.leg_l = Node3D.new()
	r.leg_l.position = Vector3(-0.15, 0.48, 0)
	body.add_child(r.leg_l)
	r.leg_r = Node3D.new()
	r.leg_r.position = Vector3(0.15, 0.48, 0)
	body.add_child(r.leg_r)
	for leg in [r.leg_l, r.leg_r]:
		_capsule(leg, 0.115, 0.48, Vector3(0, -0.2, 0), _toon(dark))
		_box(leg, Vector3(0.22, 0.12, 0.34), Vector3(0, -0.42, 0.06), _toon(Color(0.95, 0.95, 0.98), 0.0, 0.02))
	var is_me := pl != null and (pl == local_player or (local_player == null and pl.is_local_human))
	var tag := Label3D.new()
	tag.text = ("▼ " if is_me else "") + (pl.display_name if pl != null else "")
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.no_depth_test = true
	tag.pixel_size = 0.0105 if is_me else 0.0085
	tag.font_size = 64
	tag.outline_size = 22
	tag.modulate = Palette.YELLOW if is_me else Color.WHITE
	tag.outline_modulate = Palette.PURPLE_DARK
	tag.position = Vector3(0, 2.4, 0)
	r.node.add_child(tag)
	r.shadow = _mesh(_root3, _cyl(0.5, 0.02, 16), Vector3.ZERO, _unshaded(Color(0, 0, 0.05, 0.45), true))
	r.shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	r.puff = _particles(Color(0.85, 0.9, 1.0, 0.7), 12, 0.45, 0.1, 1.0, 2.6, Vector3(0, -2.0, 0))
	_root3.add_child(r.puff)
	r.dx = r.x
	r.dz = r.z
	r.dh = r.h
	r.dface = r.face

func _car_mat(key: String, c: Color, emission: float = 0.0, rough: float = 0.4) -> StandardMaterial3D:
	if not _car_mats.has(key):
		_car_mats[key] = _toon(c, emission, 0.035) if emission <= 0.0 else _mat(c, emission, rough)
	return _car_mats[key]

## Coche low-poly: carrocería, cabina con cristales, ruedas, faros (miran cuesta abajo, hacia ti) y pilotos.
func _build_car(c: Car) -> void:
	var n := Node3D.new()
	_root3.add_child(n)
	c.node = n
	var w: float = CAR_W[c.kind]
	var l: float = CAR_L[c.kind]
	var h: float = CAR_H[c.kind]
	var body_col: Color
	match c.kind:
		Kind.TAXI: body_col = Color(1.0, 0.78, 0.15)
		Kind.POLICE: body_col = Color(0.95, 0.95, 0.97)
		Kind.VAN: body_col = SEDAN_COLORS[c.variant].lightened(0.15)
		_: body_col = SEDAN_COLORS[c.variant]
	var body_m := _car_mat("b%d_%d" % [c.kind, c.variant], body_col)
	var glass := _car_mat("glass", Color(0.18, 0.25, 0.4), 0.0)
	var tire := _car_mat("tire", Color(0.07, 0.07, 0.09))
	if c.kind == Kind.VAN:
		_box(n, Vector3(w, h - 0.45, l), Vector3(0, 0.45 + (h - 0.45) * 0.5, 0), body_m)
		_box(n, Vector3(w + 0.02, 0.55, 0.9), Vector3(0, h - 0.6, -l * 0.5 + 0.5), glass)
	else:
		_box(n, Vector3(w, 0.55, l), Vector3(0, 0.62, 0), body_m)
		var cab := _box(n, Vector3(w * 0.86, 0.5, l * 0.5), Vector3(0, 1.1, 0.15), glass)
		cab.scale = Vector3(1.0, 1.0, 1.0)
		_box(n, Vector3(w * 0.88, 0.08, l * 0.46), Vector3(0, 1.37, 0.15), body_m)
		if c.kind == Kind.POLICE:
			_box(n, Vector3(w + 0.01, 0.3, l * 0.55), Vector3(0, 0.66, 0), _car_mat("black", Color(0.08, 0.08, 0.1)))
			c.siren = _box(n, Vector3(0.9, 0.16, 0.28), Vector3(0, 1.5, 0.15), _mat(Color(1.0, 0.2, 0.25), 3.0))
		elif c.kind == Kind.TAXI:
			_box(n, Vector3(0.6, 0.18, 0.26), Vector3(0, 1.5, 0.2), _car_mat("taxi_sign", Color(1.0, 0.95, 0.7), 2.0))
			for i in 4:
				_box(n, Vector3(w + 0.01, 0.1, 0.25), Vector3(0, 0.66, -1.0 + 0.5 * i + (0.25 if i % 2 == 0 else 0.0)), _car_mat("black", Color(0.08, 0.08, 0.1)))
	# Ruedas.
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var wh := Node3D.new()
			wh.position = Vector3(sx * (w * 0.5 - 0.05), 0.36, sz * (l * 0.32))
			n.add_child(wh)
			var tm := _mesh(wh, _cyl(0.36, 0.26, 12), Vector3.ZERO, tire)
			tm.rotation.z = PI * 0.5
			c.wheels.append(wh)
	# Faros delante (el coche baja hacia -z) y pilotos rojos detrás.
	var head := _car_mat("head", Color(1.0, 0.95, 0.75), 4.0)
	var tail := _car_mat("tail", Color(1.0, 0.1, 0.12), 3.0)
	for sx in [-1.0, 1.0]:
		_box(n, Vector3(0.34, 0.16, 0.06), Vector3(sx * (w * 0.5 - 0.3), 0.72, -l * 0.5 - 0.02), head)
		_box(n, Vector3(0.3, 0.14, 0.06), Vector3(sx * (w * 0.5 - 0.28), 0.74, l * 0.5 + 0.02), tail)
	# Haz de luz de los faros sobre el asfalto (avisa de que viene).
	if not _car_mats.has("beam"):
		var bm := _unshaded(Color(1.0, 0.95, 0.75, 0.13), true)
		bm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_car_mats["beam"] = bm
	var beam_m: StandardMaterial3D = _car_mats["beam"]
	var beam := _box(n, Vector3(w * 1.1, 0.02, 7.0), Vector3(0, 0.05, -l * 0.5 - 3.5), beam_m)
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _add_splat(x: float, z: float, col: Color) -> void:
	if not _built:
		return
	var m := _mat(col.darkened(0.1), 0.25, 0.3)
	var sp := _mesh(_root3, _cyl(1.0, 0.02, 14), _w(x, z, 0.02 + 0.002 * (_splats.size() % 8)), m)
	sp.rotation.x = -atan(SLOPE)
	sp.rotation.y = randf() * TAU
	sp.scale = Vector3(randf_range(0.9, 1.4), 1.0, randf_range(1.2, 2.0))
	sp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for i in 4:
		var drop := _mesh(sp, _cyl(0.25, 0.02, 8), Vector3(randf_range(-1.2, 1.2), 0.0, randf_range(-1.6, 1.6)), m)
		drop.scale = Vector3.ONE * randf_range(0.5, 1.2)
	_splats.append(sp)
	if _splats.size() > 40:
		_splats.pop_front().queue_free()
	_hit_puff.position = _w(x, z, 0.6)
	var pm := (_hit_puff.mesh as SphereMesh).material as StandardMaterial3D
	if pm != null:
		pm.albedo_color = col
	_hit_puff.restart()
	_hit_puff.emitting = true

## El jugador que sigue la cámara: el de este PC; si no hay (varios en un mismo PC), el humano que va más arriba.
func _cam_runner() -> RS:
	if local_player != null and _rs.has(local_player.id):
		return _rs[local_player.id]
	var best: RS = null
	for id in _order:
		var pl := _player_by_id(id)
		if pl == null or not pl.is_local_human:
			continue
		var r: RS = _rs[id]
		if best == null or r.z > best.z:
			best = r
	if best != null:
		return best
	for id in _order:
		var r2: RS = _rs[id]
		if best == null or r2.z > best.z:
			best = r2
	return best

func _cam_target(cs: RS) -> Vector3:
	return _w(cs.dx * 0.55, cs.dz - 7.5, 4.6)

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
	var k := 1.0 if delta <= 0.0 else 1.0 - exp(-20.0 * delta)
	for id in _order:
		var r: RS = _rs[id]
		if r.node == null:
			continue
		if absf(r.dz - r.z) > 5.0 or absf(r.dx - r.x) > 5.0:
			r.dx = r.x
			r.dz = r.z
		else:
			r.dx = lerpf(r.dx, r.x, k)
			r.dz = lerpf(r.dz, r.z, k)
		r.dh = lerpf(r.dh, r.h, k)
		r.dface = lerp_angle(r.dface, r.face, 1.0 if delta <= 0.0 else 1.0 - exp(-14.0 * delta))
		r.anim += delta
		r.node.position = _w(r.dx, r.dz, r.dh)
		r.node.rotation.y = -r.dface
		var blink := r.inv_t > 0.0 and fmod(_anim, 0.2) < 0.1
		r.node.visible = r.alive and not blink
		var speed := Vector2(r.vx, r.vz).length()
		var running := r.dh <= 0.01 and speed > 0.8
		var ph := r.anim * (7.0 + speed * 1.0)
		var swing := clampf(speed / RUN_SPEED, 0.0, 1.0)
		if running:
			r.leg_l.rotation.x = sin(ph) * 1.0 * swing
			r.leg_r.rotation.x = -sin(ph) * 1.0 * swing
			r.arm_l.rotation.x = -sin(ph) * 0.9 * swing
			r.arm_r.rotation.x = sin(ph) * 0.9 * swing
			r.body.position.y = absf(sin(ph)) * 0.08 * swing
		elif r.dh > 0.01:
			r.leg_l.rotation.x = -0.7
			r.leg_r.rotation.x = 0.4
			r.arm_l.rotation.x = -2.6
			r.arm_r.rotation.x = -2.6
			r.body.position.y = 0.0
		else:
			var idle := sin(r.anim * 2.2)
			r.leg_l.rotation.x = lerpf(r.leg_l.rotation.x, 0.0, 0.3)
			r.leg_r.rotation.x = lerpf(r.leg_r.rotation.x, 0.0, 0.3)
			r.arm_l.rotation.x = lerpf(r.arm_l.rotation.x, 0.06 * idle, 0.3)
			r.arm_r.rotation.x = lerpf(r.arm_r.rotation.x, -0.06 * idle, 0.3)
			r.body.position.y = 0.012 * idle
		r.body.rotation.x = 0.2 * swing + SLOPE * 0.8          # inclinado hacia la cuesta
		r.shadow.visible = r.alive
		r.shadow.position = _w(r.dx, r.dz, 0.03)
		r.shadow.rotation.x = -atan(SLOPE)
		var sc := clampf(1.0 - r.dh * 0.25, 0.45, 1.0)
		r.shadow.scale = Vector3(sc, 1.0, sc)
		if r.burst:
			r.burst = false
			r.puff.position = _w(r.dx, r.dz, 0.05)
			r.puff.restart()
			r.puff.emitting = true
	# Coches: se crean al aparecer y giran las ruedas; los que derrapan van un poco de lado.
	for c in _cars:
		if c.node == null or not is_instance_valid(c.node):
			_build_car(c)
		c.node.position = _w(c.x, c.z, 0.0)
		c.node.rotation = Vector3(-atan(SLOPE), -atan2(c.vx, -c.vz) * 0.6 if c.vx != 0.0 else 0.0, 0.0)
		for wh in c.wheels:
			wh.rotation.x += c.vz * delta / 0.36
		if c.siren != null:
			var on := fmod(_anim * 4.0 + float(c.id) * 0.37, 1.0) < 0.5
			(c.siren.material_override as StandardMaterial3D).albedo_color = Color(1.0, 0.2, 0.25) if on else Color(0.2, 0.4, 1.0)
			(c.siren.material_override as StandardMaterial3D).emission = (c.siren.material_override as StandardMaterial3D).albedo_color
	# Portal y líneas.
	if _portal_swirl != null:
		_portal_swirl.rotation.y = _anim * 1.6
		_portal.scale = Vector3.ONE * (1.0 + 0.03 * sin(_anim * 3.0))
	var cs := _cam_runner()
	var my_lines := cs.lines if cs != null else 0
	for i in _line_mats.size():
		var pulse := 0.5 + 0.5 * sin(_anim * 4.0 - float(i))
		_line_mats[i].emission_energy_multiplier = (0.8 if i < my_lines else 2.2 + 1.0 * pulse)
	if cs == null:
		return
	# Cámara detrás y por encima de TU personaje, mirando cuesta arriba.
	var tgt := _cam_target(cs)
	if delta <= 0.0:
		_cam_pos = tgt
	else:
		_cam_pos = _cam_pos.lerp(tgt, 1.0 - exp(-6.0 * delta))
	var shake := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * _shake * 0.2
	_cam.position = _cam_pos + shake
	_cam.look_at(_w(cs.dx * 0.75, cs.dz + 9.0, 0.6), Vector3.UP)

# ----------------------------------------------------------------------------
# HUD: tiempo, progreso con las líneas, tarjetas de puntos de todos, cuenta atrás
# ----------------------------------------------------------------------------

func _draw_hud() -> void:
	var s := surface
	var cs := _cam_runner()
	# Tiempo (arriba a la derecha) con un anillo que se vacía.
	var left := clampf(TIME_LIMIT - _t, 0.0, TIME_LIMIT)
	var tc := Vector2(1200, 64)
	s.draw_circle(tc, 42.0, Color(0, 0, 0, 0.45))
	s.draw_arc(tc, 38.0, -PI * 0.5, -PI * 0.5 + TAU * (left / TIME_LIMIT), 48, Palette.TEAL if left > 10.0 else Palette.CORAL, 6.0, true)
	s.text_centered(tc, str(ceili(left)), 38, Palette.WHITE if left > 10.0 else Palette.CORAL, 7)
	# Progreso cuesta arriba (a la izquierda, vertical): líneas de neón y todos los jugadores.
	var bar := Rect2(34, 120, 14, 420)
	s.rounded_rect(bar.grow(6), 12, Color(0, 0, 0, 0.45))
	for i in _line_count():
		var ly := bar.end.y - bar.size.y * (_line_z(i) / LENGTH)
		s.draw_line(Vector2(bar.position.x - 4, ly), Vector2(bar.end.x + 4, ly), NEON[i % NEON.size()], 3.0)
	s.draw_circle(Vector2(bar.get_center().x, bar.position.y), 9.0, Palette.TEAL)
	for id in _order:
		var r: RS = _rs[id]
		var pl := _player_by_id(id)
		var col: Color = pl.color if pl != null else Palette.WHITE
		var py := bar.end.y - bar.size.y * clampf(r.z / LENGTH, 0.0, 1.0)
		var mine := cs != null and r == cs
		s.draw_circle(Vector2(bar.get_center().x, py), 9.5 if mine else 7.0, Palette.WHITE)
		s.draw_circle(Vector2(bar.get_center().x, py), 7.0 if mine else 5.0, col)
	# Puesto.
	if cs != null:
		s.text_centered(Vector2(640, 40), "%d.º de %d" % [_place_of(cs.id), _order.size()], 44, Palette.YELLOW, 9)
	# Tarjetas de puntos abajo (como en un marcador de fiesta).
	var n := _order.size()
	var cw := minf(150.0, 1180.0 / maxf(n, 1.0) - 10.0)
	var total_w := n * (cw + 10.0) - 10.0
	var x0 := 640.0 - total_w * 0.5
	for i in n:
		var id2 := _order[i]
		var r2: RS = _rs[id2]
		var pl2 := _player_by_id(id2)
		var col2: Color = pl2.color if pl2 != null else Palette.WHITE
		var rect := Rect2(x0 + i * (cw + 10.0), 650, cw, 52)
		var mine2 := cs != null and r2 == cs
		s.rounded_rect(rect.grow(3), 14, col2 if mine2 else Color(col2.r, col2.g, col2.b, 0.6))
		s.rounded_rect(rect, 12, Color(0.05, 0.05, 0.14, 0.88))
		var nm := pl2.display_name if pl2 != null else "?"
		if nm.length() > 9:
			nm = nm.substr(0, 8) + "…"
		s.text_centered(Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y + 14), nm, 15, Color(1, 1, 1, 0.8), 3)
		s.text_centered(Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y + 36), str(r2.score), 28, col2.lightened(0.2), 5)
		if not r2.alive:
			s.text_centered(Vector2(rect.position.x + rect.size.x - 16, rect.position.y + 14), "✖", 16, Palette.CORAL, 3)
		for p in _pops:
			if int(p["id"]) == id2:
				var pt := float(p["t"])
				s.text_centered(Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y - 22 - (1.2 - pt) * 30.0), String(p["text"]), 30,
						Color(col2.r, col2.g, col2.b, clampf(pt * 2.0, 0.0, 1.0)).lightened(0.2), 7)
	if _toast_t > 0.0:
		s.text_centered(Vector2(640, 220), _toast, 64, Color(1, 1, 1, clampf(_toast_t * 2.0, 0.0, 1.0)), 12)
	if cs != null and not cs.alive and not _over:
		s.text_centered(Vector2(640, 320), "Vuelves a la última línea...", 30, Color(1, 1, 1, 0.85), 6)
	if _cd > 0.0:
		var nn := ceili(_cd)
		var frac_c := _cd - floorf(_cd)
		s.text_centered(Vector2(640, 300), str(nn), int(130.0 + 60.0 * frac_c), Palette.YELLOW, 16)
	elif _t < 0.8:
		s.text_centered(Vector2(640, 300), "¡ARRIBA!", 120, Palette.MINT, 16)
	if _hint_t > 0.0 and not _over and _cd <= 0.0:
		s.text_centered(Vector2(640, 600), "WASD / flechas para moverte  ·  ESPACIO o CLIC para saltar", 26, Color(1, 1, 1, clampf(_hint_t, 0.0, 1.0)), 7)
	if _over:
		var w := _player_by_id(_winner_id)
		s.text_centered(Vector2(640, 280), "¡FIN!", 100, Palette.YELLOW, 14)
		if w != null:
			s.text_centered(Vector2(640, 370), "Gana %s" % w.display_name, 56, w.color.lightened(0.25), 10)

# ----------------------------------------------------------------------------
# Utilidades de depuración / pruebas (tests/uphill_test.gd)
# ----------------------------------------------------------------------------

func debug_traffic_signature(seconds: float) -> String:
	_t = 0.0
	_reset_traffic()
	var tt := 0.0
	while tt < seconds:
		_t += STEP
		_update_traffic(STEP)
		tt += STEP
	var parts: PackedStringArray = []
	for c in _cars:
		parts.append("%d:%d:%.2f:%.2f" % [c.id, c.kind, c.x, c.z])
	return "|".join(parts)

func debug_runner(id: int) -> Dictionary:
	var r: RS = _rs.get(id)
	if r == null:
		return {}
	return {"x": r.x, "z": r.z, "h": r.h, "alive": r.alive, "score": r.score, "lines": r.lines, "hits": r.hits,
			"finished": r.finished, "best_z": r.best_z, "inv": r.inv_t}

func debug_place(id: int, x: float, z: float) -> void:
	var r: RS = _rs.get(id)
	if r != null:
		r.x = x
		r.z = z

func debug_clear_cars() -> void:
	for c in _cars:
		if c.node != null and is_instance_valid(c.node):
			c.node.queue_free()
	_cars.clear()

func debug_add_car(kind: int, x: float, z: float, vz: float) -> void:
	var c := Car.new()
	_car_ids += 1
	c.id = _car_ids
	c.kind = kind
	c.x = x
	c.z = z
	c.vz = vz
	_cars.append(c)

## Un paso de un jugador con una entrada dada (sin tráfico nuevo).
func debug_step(id: int, inp: Vector2, jump: bool) -> void:
	var r: RS = _rs.get(id)
	if r == null:
		return
	_t += STEP
	for c in _cars:
		c.z += c.vz * STEP
		c.x += c.vx * STEP
	_sim_step(r, STEP, inp, jump)
	_collect_events(r)

func debug_skip_countdown() -> void:
	_cd = 0.0

func debug_over() -> bool:
	return _over

func debug_winner() -> int:
	return _winner_id

func debug_cars() -> int:
	return _cars.size()

func debug_time() -> float:
	return _t
