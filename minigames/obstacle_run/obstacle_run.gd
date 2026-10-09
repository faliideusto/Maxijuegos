extends Minigame
## Carrera de Obstáculos (modelo HOST_AUTHORITATIVE, en 3D): todos los jugadores corren A LA VEZ por la misma pista y se
## ven todos los personajes en la misma pantalla. Se corre solo hacia delante: con A/D o las flechas se esquiva a los
## lados y con ESPACIO o CLIC se salta. Chocar con un obstáculo hace tropezar (se pierde casi toda la velocidad y se
## vuelve a acelerar). Gana quien llega antes a la meta; los demás se ordenan por llegada y luego por distancia.
## La partida acaba cuando llegan todos, 15 s después de que llegue el primero, o a los 60 s.
##
## Obstáculos (hay que esquivarlos o saltarlos):
##   - VALLA baja que ocupa toda la pista: saltar.   - LAVA en el suelo, a todo lo ancho: saltar.
##   - PILARES altos: esquivar entre ellos.          - BARRA deslizante que va y viene: saltar o pasar por el hueco.
##   - PUERTA estrecha con un único hueco: colarse por el hueco.
## Cada vez hay más obstáculos y más seguidos, y la velocidad sube con la distancia. Quien va muy rezagado recibe un
## pequeño empujón de velocidad para no perderse la carrera (y no salir de cámara). Los corredores no chocan entre sí.
##
## Red: el host simula a todos (60 Hz fijos) y envía el estado (~30 Hz): por corredor posición, altura, velocidad,
## tropiezo y meta. Todo el 3D (SubViewport con su propio mundo) es solo presentación y se interpola en cada PC.

const STEP := 1.0 / 60.0
const TRACK_LEN := 480.0
const TRACK_W := 10.0                  # ancho de la pista
const TIME_LIMIT := 60.0
const COUNTDOWN := 3.0
const FIRST_FINISH_GRACE := 15.0       # segundos que se espera a los demás cuando llega el primero
const V_START := 13.0
const V_MAX := 22.0
const ACCEL := 4.0
const REGAIN := 10.0                   # aceleración mientras se recupera de un tropiezo
const CATCH_UP := 0.10                 # empujón máximo de velocidad (fracción) para los rezagados
const CATCH_UP_DIST := 50.0
const GRAVITY := 30.0
const JUMP_V := 10.0
const LAT_SPEED := 9.5
const PLAYER_R := 0.35
const STUMBLE_KEEP := 0.35             # fracción de velocidad que se conserva al tropezar
const STUMBLE_MIN := 5.0
const INVULN := 1.2
const DONE_DELAY := 2.5
const JUMP_BUFFER := 0.12
const COYOTE := 0.08
const FLOATS := 10                     # por corredor en el estado enviado

enum Kind { WALL, LAVA, PILLAR, SLIDER, GATE }

## Estado de un corredor (lo simula el host; los clientes lo reciben).
class RS:
	var id: int = 0
	var idx: int = 0
	var z: float = 0.0
	var x: float = 0.0
	var xv: float = 0.0
	var y: float = 0.0
	var vy: float = 0.0
	var speed: float = 0.0
	var grounded: bool = true
	var inv: float = 0.0
	var hits: int = 0
	var jump_buf: float = 0.0
	var coyote: float = 0.0
	var done: bool = false              # ya no corre (meta o fin de la partida)
	var finished: bool = false          # ha llegado a la meta
	var ftime: float = 0.0
	# Eventos de este paso (los recoge quien simula).
	var ev_jump: bool = false
	var ev_land: bool = false
	var ev_hit: bool = false
	var ev_fin: bool = false
	# IA
	var pref: float = 0.0               # carril preferido de la IA (el de salida: así no se amontonan)
	var skill: float = 1.0
	var pace: float = 1.0               # factor de velocidad (las IAs menos hábiles son algo más lentas)
	var bot_jump: bool = false
	var bot_rng: RandomNumberGenerator = null
	# Presentación (interpolada)
	var dz: float = 0.0
	var dx: float = 0.0
	var dy: float = 0.0
	var node: Node3D = null
	var body: Node3D = null
	var leg_l: Node3D = null
	var leg_r: Node3D = null
	var shadow: MeshInstance3D = null
	var anim: float = 0.0

var _obs: Array = []                   # Dictionary: kind, z, x, hw, hd, h, amp, freq, ph, node
var _level_ready: bool = false
var _rs: Dictionary = {}               # player id -> RS
var _order: Array[int] = []            # ids en el orden del reparto (= orden del estado enviado)

# --- Estado de la carrera ---
var _run_t: float = 0.0                # segundos de carrera (desde la salida)
var _cd: float = COUNTDOWN
var _last_cd: int = 99
var _accum: float = 0.0
var _over: bool = false
var _over_t: float = 0.0
var _first_finish_t: float = -1.0
var _finish_order: Array[int] = []
var _winner_id: int = -1
var _hint_t: float = 6.0
var _popups: Array = []                # {text, color, age}
var _shake: float = 0.0

# --- Escena 3D ---
var _vp: SubViewport
var _root3: Node3D
var _cam: Camera3D
var _built: bool = false
var _cam_pos: Vector3 = Vector3.ZERO
var _fov: float = 68.0
var debug_skill: float = -1.0          # >=0: fuerza la habilidad de todas las IAs (pruebas)

# ----------------------------------------------------------------------------
# Circuito (igual para todos los jugadores)
# ----------------------------------------------------------------------------

func _add(kind: int, z: float, x: float, hw: float, hd: float, h: float, amp: float = 0.0, freq: float = 0.0, ph: float = 0.0) -> void:
	_obs.append({"kind": kind, "z": z, "x": x, "hw": hw, "hd": hd, "h": h, "amp": amp, "freq": freq, "ph": ph, "node": null})

func _ensure_level() -> void:
	if _level_ready:
		return
	_level_ready = true
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	var z := 38.0
	var last_kind := -1
	while z < TRACK_LEN - 26.0:
		var d := z / TRACK_LEN
		var kind := Kind.WALL
		for _try in 6:
			var roll := r.randf()
			if roll < 0.22:
				kind = Kind.WALL
			elif roll < 0.38:
				kind = Kind.LAVA
			elif roll < 0.60:
				kind = Kind.PILLAR
			elif roll < 0.78 + 0.08 * d:
				kind = Kind.SLIDER
			else:
				kind = Kind.GATE
			if kind != last_kind:
				break
		last_kind = kind
		match kind:
			Kind.WALL:
				_add(kind, z, 0.0, TRACK_W * 0.5, 0.35, 0.9)
			Kind.LAVA:
				_add(kind, z, 0.0, TRACK_W * 0.5, r.randf_range(1.6, 2.4), 0.25)
			Kind.PILLAR:
				var n := 2 if d < 0.35 else 3
				var xs: Array[float] = []
				var tries := 0
				while xs.size() < n and tries < 60:
					tries += 1
					var cx := r.randf_range(-3.9, 3.9)
					var ok := true
					for ox in xs:
						if absf(ox - cx) < 3.3:
							ok = false
					if ok:
						xs.append(cx)
				for cx in xs:
					_add(kind, z + r.randf_range(-0.6, 0.6), cx, 0.6, 0.6, 3.0)
			Kind.SLIDER:
				var amp := TRACK_W * 0.5 - 1.6 - 0.2
				_add(kind, z, 0.0, 1.6, 0.4, 1.2, amp, r.randf_range(1.2, 1.5) + 0.9 * d, r.randf_range(0.0, TAU))
			Kind.GATE:
				var gx := r.randf_range(-3.0, 3.0)
				var gap := lerpf(2.8, 2.2, d)
				var left_edge := gx - gap * 0.5
				var right_edge := gx + gap * 0.5
				var lw := (left_edge + TRACK_W * 0.5) * 0.5
				var rw := (TRACK_W * 0.5 - right_edge) * 0.5
				if lw > 0.05:
					_add(kind, z, -TRACK_W * 0.5 + lw, lw, 0.5, 2.6)
				if rw > 0.05:
					_add(kind, z, TRACK_W * 0.5 - rw, rw, 0.5, 2.6)
		z += lerpf(26.0, 15.0, d) + r.randf_range(0.0, 4.0)

func _obs_x(o: Dictionary) -> float:
	if float(o.amp) == 0.0:
		return float(o.x)
	return float(o.amp) * sin(float(o.ph) + float(o.freq) * _run_t)

# ----------------------------------------------------------------------------
# Simulación (solo el host)
# ----------------------------------------------------------------------------

func _make_rs(p: PlayerData, idx: int, count: int) -> RS:
	var s := RS.new()
	s.id = p.id
	s.idx = idx
	s.x = 0.0 if count <= 1 else lerpf(-3.8, 3.8, float(idx) / float(count - 1))
	s.dx = s.x
	s.pref = s.x
	s.speed = V_START
	s.bot_rng = RandomNumberGenerator.new()
	s.bot_rng.seed = hash([seed_value, p.id])
	s.skill = 0.72 + 0.28 * s.bot_rng.randf()
	if InputManager.is_simulated(p.id):
		s.pace = lerpf(0.94, 1.0, s.skill)
	return s

func _setup_runners() -> void:
	_rs.clear()
	_order.clear()
	for i in players.size():
		var p := players[i]
		_rs[p.id] = _make_rs(p, i, players.size())
		_order.append(p.id)

func _leader_z() -> float:
	var m := 0.0
	for id in _order:
		m = maxf(m, (_rs[id] as RS).z)
	return m

func _target_speed(s: RS, leader_z: float) -> float:
	var base := lerpf(V_START, V_MAX, clampf(s.z / TRACK_LEN, 0.0, 1.0))
	return base * s.pace * (1.0 + CATCH_UP * clampf((leader_z - s.z) / CATCH_UP_DIST, 0.0, 1.0))

## Un paso de simulación de un corredor. steer: -1..1 (izquierda/derecha), jump: se ha pulsado saltar en este paso.
func _step_rs(s: RS, dt: float, steer: float, jump: bool, leader_z: float) -> void:
	if s.done:
		# Tras la meta (o el final): se frena solo.
		s.speed = maxf(s.speed - 16.0 * dt, 0.0)
		s.z += s.speed * dt
		s.xv = lerpf(s.xv, 0.0, 1.0 - exp(-8.0 * dt))
		s.x = clampf(s.x + s.xv * dt, -TRACK_W * 0.5 + 0.5, TRACK_W * 0.5 - 0.5)
		return
	# Velocidad hacia delante.
	var tv := _target_speed(s, leader_z)
	if s.speed < tv:
		s.speed = minf(tv, s.speed + (REGAIN if s.speed < tv - 2.0 else ACCEL) * dt)
	else:
		s.speed = maxf(tv, s.speed - 3.0 * dt)
	# Lateral con algo de inercia.
	var want := clampf(steer, -1.0, 1.0) * LAT_SPEED
	s.xv = lerpf(s.xv, want, 1.0 - exp(-14.0 * dt))
	s.x = clampf(s.x + s.xv * dt, -TRACK_W * 0.5 + 0.5, TRACK_W * 0.5 - 0.5)
	# Salto.
	if jump:
		s.jump_buf = JUMP_BUFFER
	s.jump_buf = maxf(0.0, s.jump_buf - dt)
	if s.grounded:
		s.coyote = COYOTE
	else:
		s.coyote = maxf(0.0, s.coyote - dt)
	if s.jump_buf > 0.0 and (s.grounded or s.coyote > 0.0) and s.vy <= 0.01:
		s.vy = JUMP_V
		s.grounded = false
		s.coyote = 0.0
		s.jump_buf = 0.0
		s.ev_jump = true
	if not s.grounded:
		s.vy -= GRAVITY * dt
		s.y += s.vy * dt
		if s.y <= 0.0:
			s.y = 0.0
			s.vy = 0.0
			s.grounded = true
			s.ev_land = true
	s.z += s.speed * dt
	s.inv = maxf(0.0, s.inv - dt)
	# Choques.
	if s.inv <= 0.0:
		for o in _obs:
			var dz := absf(s.z - float(o.z))
			if dz > 4.0:
				continue
			if dz < float(o.hd) + PLAYER_R and absf(s.x - _obs_x(o)) < float(o.hw) + PLAYER_R and s.y < float(o.h) - 0.05:
				s.hits += 1
				s.speed = maxf(s.speed * STUMBLE_KEEP, STUMBLE_MIN)
				s.inv = INVULN
				s.ev_hit = true
				break
	# Meta.
	if s.z >= TRACK_LEN:
		s.done = true
		s.finished = true
		s.ftime = _run_t
		s.ev_fin = true

func _simulate(delta: float) -> void:
	if _over:
		_over_t += delta
		if _over_t >= DONE_DELAY:
			finish(_build_ranking())
		else:
			var lz := _leader_z()
			for id in _order:
				_step_rs(_rs[id] as RS, delta, 0.0, false, lz)
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
	# Entrada de cada jugador (una lectura por fotograma).
	var steer: Dictionary = {}
	var jumped: Dictionary = {}
	for p in players:
		steer[p.id] = move_input(p).x
		jumped[p.id] = action_presses(p) > 0
	_accum += delta
	var steps := 0
	while _accum >= STEP and steps < 12:
		_accum -= STEP
		steps += 1
		_run_t += STEP
		var lz2 := _leader_z()
		for p in players:
			var s: RS = _rs[p.id]
			_step_rs(s, STEP, float(steer[p.id]), bool(jumped[p.id]), lz2)
			jumped[p.id] = false
			_collect_events(s)
	# ¿Se acaba?
	var all_done := true
	for id in _order:
		if not (_rs[id] as RS).done:
			all_done = false
	if _first_finish_t < 0.0 and not _finish_order.is_empty():
		_first_finish_t = _run_t
	var grace_over := _first_finish_t >= 0.0 and _run_t - _first_finish_t >= FIRST_FINISH_GRACE
	if all_done or grace_over or _run_t >= TIME_LIMIT:
		_over = true
		_over_t = 0.0
		for id in _order:
			(_rs[id] as RS).done = true
		_winner_id = _finish_order[0] if not _finish_order.is_empty() else _best_by_distance()
		send_event("over", {"w": _winner_id})
		DevCli.log_event("run over winner=%d finished=%d" % [_winner_id, _finish_order.size()])

func _best_by_distance() -> int:
	var best := -1
	var bz := -1.0
	for id in _order:
		var s: RS = _rs[id]
		if s.z > bz:
			bz = s.z
			best = id
	return best

func _collect_events(s: RS) -> void:
	if s.ev_jump:
		send_event("jump", {"p": s.id})
	if s.ev_land:
		send_event("land", {"p": s.id})
	if s.ev_hit:
		send_event("hit", {"p": s.id})
	if s.ev_fin:
		_finish_order.append(s.id)
		send_event("fin", {"p": s.id, "n": _finish_order.size(), "t": s.ftime})
	s.ev_jump = false
	s.ev_land = false
	s.ev_hit = false
	s.ev_fin = false

## Orden de la carrera: primero los que han llegado (por tiempo), luego el resto por distancia.
func _ranking_ids() -> Array[int]:
	var ids: Array[int] = []
	for id in _order:
		ids.append(id)
	ids.sort_custom(func(a: int, b: int) -> bool:
		var sa: RS = _rs[a]
		var sb: RS = _rs[b]
		if sa.finished != sb.finished:
			return sa.finished
		if sa.finished and not is_equal_approx(sa.ftime, sb.ftime):
			return sa.ftime < sb.ftime
		if not sa.finished and not is_equal_approx(sa.z, sb.z):
			return sa.z > sb.z
		return a < b)
	return ids

func _build_ranking() -> Array[int]:
	return _ranking_ids()

func _place_of(id: int) -> int:
	return _ranking_ids().find(id) + 1

# ----------------------------------------------------------------------------
# Red
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var arr := PackedFloat32Array()
	for id in _order:
		var s: RS = _rs[id]
		arr.append_array(PackedFloat32Array([s.z, s.x, s.y, s.speed, s.inv, 1.0 if s.grounded else 0.0,
				1.0 if s.done else 0.0, s.ftime if s.finished else -1.0, float(s.hits), s.vy]))
	return {"r": arr, "t": _run_t, "cd": _cd, "o": _over, "w": _winner_id}

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	var st: Dictionary = state
	_run_t = float(st.get("t", _run_t))
	_cd = float(st.get("cd", _cd))
	_over = bool(st.get("o", _over))
	_winner_id = int(st.get("w", _winner_id))
	var arr: Variant = st.get("r")
	if not arr is PackedFloat32Array or arr.size() < _order.size() * FLOATS:
		return
	for i in _order.size():
		var s: RS = _rs[_order[i]]
		var o := i * FLOATS
		s.z = arr[o]
		s.x = arr[o + 1]
		s.y = arr[o + 2]
		s.speed = arr[o + 3]
		s.inv = arr[o + 4]
		s.grounded = arr[o + 5] > 0.5
		s.done = arr[o + 6] > 0.5
		var ft: float = arr[o + 7]
		s.finished = ft >= 0.0
		if s.finished:
			s.ftime = ft
		s.hits = int(arr[o + 8])
		s.vy = arr[o + 9]

func _on_event(event_name: String, data: Variant) -> void:
	var d: Dictionary = data if data is Dictionary else {}
	var p := _player_by_id(int(d.get("p", -1)))
	match event_name:
		"beep":
			Audio.sfx(&"beep", -7.0)
		"go":
			Audio.sfx(&"beep_go", -5.0)
		"jump":
			if p != null and is_audible(p):
				Audio.sfx(&"jump", -7.0)
		"land":
			if p != null and is_audible(p):
				Audio.sfx(&"land", -12.0)
		"hit":
			if p != null:
				_shake = maxf(_shake, 0.35)
				if is_audible(p):
					Audio.sfx(&"crash", -6.0)
					_popups.append({"text": "¡AUCH!", "color": Palette.CORAL, "age": 0.0})
				else:
					Audio.sfx(&"thud", -14.0)
		"fin":
			if p != null:
				Audio.sfx(&"milestone" if is_audible(p) else &"swish", -6.0)
		"over":
			_winner_id = int(d.get("w", -1))
			Audio.sfx(&"fanfare_small", -6.0)

func _player_by_id(id: int) -> PlayerData:
	for p in players:
		if p.id == id:
			return p
	return null

# ----------------------------------------------------------------------------
# Ciclo del minijuego
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	_ensure_level()
	_setup_runners()
	_build_world()
	surface.draw_callback = _draw_hud

func _on_start() -> void:
	_ensure_level()
	_setup_runners()
	_rebuild_runner_nodes()
	_run_t = 0.0
	_accum = 0.0
	_cd = COUNTDOWN
	_last_cd = 99
	_over = false
	_over_t = 0.0
	_first_finish_t = -1.0
	_finish_order.clear()
	_winner_id = -1
	_hint_t = 6.0
	_popups.clear()
	_cam_pos = Vector3(0.0, 5.0, 9.0)

func _animate(delta: float) -> void:
	_shake = maxf(0.0, _shake - delta * 2.5)
	if _cd <= 0.0:
		_hint_t = maxf(0.0, _hint_t - delta)
	for p in _popups:
		p.age += delta
	_popups = _popups.filter(func(x: Dictionary) -> bool: return x.age < 1.1)
	_update_world(delta)

# ----------------------------------------------------------------------------
# IA (bots y autopilotos): buscan el hueco más cercano y saltan lo que se puede saltar
# ----------------------------------------------------------------------------

func _bot_decide(s: RS, sk: float) -> float:
	s.bot_jump = false
	var look := 12.0 + s.speed * 0.9
	var jump_lead := s.speed * 0.33
	var best_x := s.x
	var best_c := INF
	var cand := -4.3
	while cand <= 4.3:
		var c := absf(cand - s.x) * 0.06 + absf(cand - s.pref) * 0.03
		for o in _obs:
			var dz := float(o.z) - s.z
			if dz < -1.0 or dz > look:
				continue
			var kd := int(o.kind)
			if kd != Kind.PILLAR and kd != Kind.GATE:
				continue
			var margin := float(o.hw) + PLAYER_R + 0.45
			if absf(cand - float(o.x)) < margin:
				c += 100.0 / maxf(dz + 3.0, 1.0) + 5.0
			var lo := minf(cand, s.x)
			var hi := maxf(cand, s.x)
			if dz < 6.0 and dz > -1.0 and float(o.x) + margin > lo and float(o.x) - margin < hi:
				c += 3.0
		if c < best_c:
			best_c = c
			best_x = cand
		cand += 0.3
	# Salto: siguiente obstáculo saltable por delante.
	for o in _obs:
		var kd2 := int(o.kind)
		if kd2 == Kind.PILLAR or kd2 == Kind.GATE:
			continue
		var edge := float(o.z) - float(o.hd) - PLAYER_R - s.z
		if edge < -0.2:
			continue
		if edge <= jump_lead * lerpf(1.35, 1.0, sk) and s.grounded:
			s.bot_jump = true
		break
	if sk < 1.0 and s.bot_rng.randf() < (1.0 - sk) * 0.08:
		s.bot_jump = false               # a veces no salta a tiempo
	return clampf((best_x - s.x) * 2.2, -1.0, 1.0)

func _bot_move(player: PlayerData) -> Vector2:
	var s: RS = _rs.get(player.id)
	if s == null:
		return Vector2.ZERO
	var sk := s.skill if debug_skill < 0.0 else debug_skill
	return Vector2(_bot_decide(s, sk), 0.0)

func _bot_action(player: PlayerData) -> int:
	var s: RS = _rs.get(player.id)
	if s == null:
		return 0
	var v := 1 if s.bot_jump else 0
	s.bot_jump = false
	return v

# ----------------------------------------------------------------------------
# Escena 3D
# ----------------------------------------------------------------------------

func _mat(c: Color, emission: float = 0.0, rough: float = 0.75) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emission
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

## Posición 3D de (x lateral, y altura, z recorrida): se corre hacia -Z.
func _w(x: float, y: float, z: float) -> Vector3:
	return Vector3(x, y, -z)

func _checker_texture() -> ImageTexture:
	var img := Image.create(16, 4, false, Image.FORMAT_RGB8)
	for yy in 4:
		for xx in 16:
			img.set_pixel(xx, yy, Color.WHITE if (xx / 2 + yy) % 2 == 0 else Color(0.1, 0.1, 0.15))
	return ImageTexture.create_from_image(img)

func _build_world() -> void:
	if _built:
		return
	_built = true
	var cont := SubViewportContainer.new()
	cont.stretch = true
	cont.set_anchors_preset(Control.PRESET_FULL_RECT)
	cont.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(cont)
	move_child(cont, surface.get_index())          # el 3D va detrás del dibujo 2D (marcadores)
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.handle_input_locally = false
	_vp.msaa_3d = Viewport.MSAA_2X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	cont.add_child(_vp)
	_root3 = Node3D.new()
	_vp.add_child(_root3)
	# Cielo, niebla y luz.
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.20, 0.12, 0.55)
	sky_mat.sky_horizon_color = Color(1.0, 0.55, 0.7)
	sky_mat.ground_horizon_color = Color(1.0, 0.55, 0.7)
	sky_mat.ground_bottom_color = Color(0.20, 0.12, 0.55)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.7, 0.95)
	env.ambient_light_energy = 0.7
	env.fog_enabled = true
	env.fog_light_color = Color(0.85, 0.45, 0.75)
	env.fog_density = 0.006
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	_root3.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
	sun.light_energy = 1.1
	_root3.add_child(sun)
	# Suelo en tramos alternados (para notar la velocidad), bordes, salida y meta.
	var seg_a := _mat(Color(0.42, 0.34, 0.80))
	var seg_b := _mat(Color(0.50, 0.42, 0.88))
	var n_seg := int((TRACK_LEN + 110.0) / 8.0)
	for i in n_seg:
		_box(_root3, Vector3(TRACK_W, 0.4, 8.0), _w(0.0, -0.2, -20.0 + 8.0 * i + 4.0), seg_a if i % 2 == 0 else seg_b)
	var rail := _mat(meta.accent_color if meta != null else Palette.YELLOW, 0.5)
	for sx in [-1.0, 1.0]:
		_box(_root3, Vector3(0.45, 0.7, TRACK_LEN + 130.0), _w(sx * (TRACK_W * 0.5 + 0.25), 0.35, (TRACK_LEN + 130.0) * 0.5 - 20.0), rail)
	var chk := StandardMaterial3D.new()
	chk.albedo_texture = _checker_texture()
	chk.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_box(_root3, Vector3(TRACK_W, 0.02, 1.2), _w(0.0, 0.01, 0.0), chk)
	_box(_root3, Vector3(TRACK_W, 0.02, 1.6), _w(0.0, 0.01, TRACK_LEN), chk)
	var post := _mat(Color(0.95, 0.95, 1.0))
	for sx in [-1.0, 1.0]:
		_box(_root3, Vector3(0.6, 7.0, 0.6), _w(sx * (TRACK_W * 0.5 + 0.6), 3.5, TRACK_LEN), post)
	_box(_root3, Vector3(TRACK_W + 2.4, 1.6, 0.6), _w(0.0, 7.0, TRACK_LEN), chk)
	# Decorado flotante a los lados (formas grandes de colores).
	var dr := RandomNumberGenerator.new()
	dr.seed = seed_value + 17
	var deco_cols: Array[Color] = [Color(1.0, 0.45, 0.65), Color(1.0, 0.8, 0.25), Color(0.3, 0.85, 0.75), Color(0.55, 0.5, 1.0), Color(1.0, 0.6, 0.3)]
	for i in 90:
		var side := -1.0 if dr.randf() < 0.5 else 1.0
		var s := dr.randf_range(1.2, 5.0)
		var px := side * (TRACK_W * 0.5 + 3.0 + s + dr.randf_range(0.0, 26.0))
		var pz := dr.randf_range(-30.0, TRACK_LEN + 120.0)
		var m: Mesh
		var pick := dr.randi() % 3
		if pick == 0:
			var bm := BoxMesh.new()
			bm.size = Vector3(s, s * dr.randf_range(0.8, 3.0), s)
			m = bm
		elif pick == 1:
			var sm := SphereMesh.new()
			sm.radius = s * 0.6
			sm.height = s * 1.2
			m = sm
		else:
			var cm := CylinderMesh.new()
			cm.top_radius = s * 0.3
			cm.bottom_radius = s * 0.6
			cm.height = s * 2.0
			m = cm
		var mi := _mesh(_root3, m, _w(px, dr.randf_range(-2.0, 7.0), pz), _mat(deco_cols[dr.randi() % deco_cols.size()], 0.15))
		mi.rotation_degrees = Vector3(0.0, dr.randf_range(0.0, 90.0), 0.0)
	# Obstáculos.
	for o in _obs:
		o["node"] = _build_obstacle(_root3, o)
	# Cámara.
	_cam = Camera3D.new()
	_cam.fov = _fov
	_cam.far = 400.0
	_root3.add_child(_cam)
	_cam.current = true
	_rebuild_runner_nodes()
	_update_world(0.0)

func _build_obstacle(parent: Node3D, o: Dictionary) -> Node3D:
	var root := Node3D.new()
	parent.add_child(root)
	var kd := int(o.kind)
	var hw := float(o.hw)
	var hd := float(o.hd)
	var h := float(o.h)
	root.position = _w(float(o.x), 0.0, float(o.z))
	match kd:
		Kind.WALL:
			_box(root, Vector3(hw * 2.0, h, hd * 2.0), Vector3(0, h * 0.5, 0), _mat(Color(1.0, 0.55, 0.2)))
			_box(root, Vector3(hw * 2.0 + 0.02, 0.22, hd * 2.0 + 0.02), Vector3(0, h - 0.11, 0), _mat(Color(1.0, 0.9, 0.35), 0.3))
		Kind.LAVA:
			_box(root, Vector3(hw * 2.0, 0.08, hd * 2.0), Vector3(0, 0.05, 0), _mat(Color(1.0, 0.25, 0.1), 1.2, 0.4))
			_box(root, Vector3(hw * 2.0, 0.09, 0.25), Vector3(0, 0.055, hd + 0.12), _mat(Color(1.0, 0.85, 0.2), 0.8))
			_box(root, Vector3(hw * 2.0, 0.09, 0.25), Vector3(0, 0.055, -hd - 0.12), _mat(Color(1.0, 0.85, 0.2), 0.8))
		Kind.PILLAR:
			var cm := CylinderMesh.new()
			cm.top_radius = hw
			cm.bottom_radius = hw
			cm.height = h
			_mesh(root, cm, Vector3(0, h * 0.5, 0), _mat(Color(1.0, 0.4, 0.62)))
			var cap := CylinderMesh.new()
			cap.top_radius = hw + 0.08
			cap.bottom_radius = hw + 0.08
			cap.height = 0.35
			_mesh(root, cap, Vector3(0, h - 0.17, 0), _mat(Color(1.0, 0.9, 0.35), 0.3))
		Kind.SLIDER:
			_box(root, Vector3(hw * 2.0, h, hd * 2.0), Vector3(0, h * 0.5, 0), _mat(Color(0.25, 0.85, 0.95), 0.6))
			_box(root, Vector3(hw * 2.0 + 0.04, 0.2, hd * 2.0 + 0.04), Vector3(0, h - 0.1, 0), _mat(Color(1, 1, 1), 0.4))
		Kind.GATE:
			_box(root, Vector3(hw * 2.0, h, hd * 2.0), Vector3(0, h * 0.5, 0), _mat(Color(0.15, 0.8, 0.7)))
			_box(root, Vector3(hw * 2.0 + 0.02, 0.3, hd * 2.0 + 0.02), Vector3(0, h - 0.15, 0), _mat(Color(1.0, 0.9, 0.35), 0.4))
	return root

## Crea (o recrea) el modelo 3D de cada corredor, con su color y su nombre flotando encima.
func _rebuild_runner_nodes() -> void:
	if not _built:
		return
	for id in _order:
		var s: RS = _rs[id]
		if s.node != null and is_instance_valid(s.node):
			s.node.queue_free()
		if s.shadow != null and is_instance_valid(s.shadow):
			s.shadow.queue_free()
		_build_runner(s, _player_by_id(id))

func _build_runner(s: RS, p: PlayerData) -> void:
	var col: Color = p.color if p != null else Palette.YELLOW
	s.node = Node3D.new()
	_root3.add_child(s.node)
	s.body = Node3D.new()
	s.node.add_child(s.body)
	var cap := CapsuleMesh.new()
	cap.radius = 0.38
	cap.height = 1.25
	_mesh(s.body, cap, Vector3(0, 0.95, 0), _mat(col, 0.1, 0.5))
	var hat := SphereMesh.new()
	hat.radius = 0.2
	hat.height = 0.4
	_mesh(s.body, hat, Vector3(0, 1.62, 0), _mat(Color.WHITE, 0.2))
	var pack := BoxMesh.new()
	pack.size = Vector3(0.5, 0.55, 0.22)
	_mesh(s.body, pack, Vector3(0, 1.0, 0.33), _mat(col.darkened(0.35)))
	var eye := SphereMesh.new()
	eye.radius = 0.1
	eye.height = 0.2
	for sx in [-1.0, 1.0]:
		_mesh(s.body, eye, Vector3(sx * 0.15, 1.15, -0.3), _mat(Color.WHITE))
	s.leg_l = Node3D.new()
	s.leg_l.position = Vector3(-0.17, 0.5, 0)
	s.body.add_child(s.leg_l)
	s.leg_r = Node3D.new()
	s.leg_r.position = Vector3(0.17, 0.5, 0)
	s.body.add_child(s.leg_r)
	var leg := BoxMesh.new()
	leg.size = Vector3(0.2, 0.5, 0.24)
	var leg_mat := _mat(col.darkened(0.2))
	_mesh(s.leg_l, leg, Vector3(0, -0.2, 0), leg_mat)
	_mesh(s.leg_r, leg, Vector3(0, -0.2, 0), leg_mat)
	# Nombre flotando (y una flecha sobre el jugador de este PC).
	var is_me := p != null and p == local_player
	var tag := Label3D.new()
	tag.text = ("▼ " if is_me else "") + (p.display_name if p != null else "")
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.no_depth_test = true
	tag.pixel_size = 0.0095 if is_me else 0.0075
	tag.font_size = 64
	tag.outline_size = 24
	tag.modulate = Palette.YELLOW if is_me else Color.WHITE
	tag.outline_modulate = Palette.PURPLE_DARK
	tag.position = Vector3(0, 2.35, 0)
	s.node.add_child(tag)
	# Sombra bajo los pies.
	var sh := CylinderMesh.new()
	sh.top_radius = 0.5
	sh.bottom_radius = 0.5
	sh.height = 0.02
	var sm := StandardMaterial3D.new()
	sm.albedo_color = Color(0, 0, 0, 0.4)
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	s.shadow = _mesh(_root3, sh, Vector3.ZERO, sm)
	s.dz = s.z
	s.dx = s.x
	s.dy = s.y

func _camera_focus() -> float:
	var lead := _leader_z()
	if local_player != null and _rs.has(local_player.id):
		var me: RS = _rs[local_player.id]
		if not me.done:
			return minf(lead, me.z + 22.0)
	return lead

func _update_world(delta: float) -> void:
	if not _built or _cam == null:
		return
	var k := 1.0 if delta <= 0.0 else 1.0 - exp(-18.0 * delta)
	for id in _order:
		var s: RS = _rs[id]
		if s.node == null:
			continue
		s.dz = lerpf(s.dz, s.z, k)
		s.dx = lerpf(s.dx, s.x, k)
		s.dy = lerpf(s.dy, s.y, k)
		s.node.position = _w(s.dx, s.dy, s.dz)
		var running := s.grounded and not s.done and _cd <= 0.0
		s.anim += delta * s.speed * 0.75
		s.leg_l.rotation.x = sin(s.anim) * 0.9 if running else -0.5
		s.leg_r.rotation.x = -sin(s.anim) * 0.9 if running else 0.5
		s.body.position.y = absf(sin(s.anim)) * 0.08 if running else 0.0
		s.body.rotation.x = -0.12 if s.grounded else (-0.35 if s.vy > 0.0 else 0.2)
		if s.inv > 0.0:
			s.node.visible = int(s.inv * 14.0) % 2 == 0
			if s.inv > INVULN - 0.35:
				s.body.rotation.x = 0.5
		else:
			s.node.visible = true
		s.shadow.position = _w(s.dx, 0.03, s.dz)
		var sc := clampf(1.0 - s.dy * 0.18, 0.4, 1.0)
		s.shadow.scale = Vector3(sc, 1.0, sc)
	# Obstáculos que se mueven.
	for o in _obs:
		if float(o.amp) != 0.0 and o.node != null:
			(o.node as Node3D).position.x = _obs_x(o)
	# Cámara: detrás y arriba, centrada en la pista para ver a todos; sigue al líder (sin perder de vista al jugador local).
	var focus := _camera_focus()
	var tgt := _w(0.0, 7.0, focus - 11.0)
	if delta <= 0.0:
		_cam_pos = tgt
	else:
		_cam_pos = _cam_pos.lerp(tgt, 1.0 - exp(-8.0 * delta))
	var shake := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * _shake * 0.18
	_cam.position = _cam_pos + shake
	_cam.look_at(Vector3(0.0, 0.8, _cam_pos.z - 16.0), Vector3.UP)
	var lead_speed := 0.0
	for id in _order:
		lead_speed = maxf(lead_speed, (_rs[id] as RS).speed)
	var tf := 66.0 + (lead_speed - V_START) * 0.8
	_fov = lerpf(_fov, tf, 1.0 - exp(-4.0 * maxf(delta, 0.0)))
	_cam.fov = _fov

# ----------------------------------------------------------------------------
# HUD (dibujo 2D encima del 3D)
# ----------------------------------------------------------------------------

func _draw_hud() -> void:
	var s := surface
	# Barra de progreso con un punto por corredor.
	var bar := Rect2(380, 30, 520, 18)
	s.rounded_rect(bar.grow(5), 14, Color(0, 0, 0, 0.45))
	var lead_frac := clampf(_leader_z() / TRACK_LEN, 0.0, 1.0)
	s.rounded_rect(Rect2(bar.position, Vector2(maxf(bar.size.x * lead_frac, 18.0), bar.size.y)), 9, Palette.MINT)
	s.text_centered(Vector2(bar.position.x + bar.size.x + 56.0, 40), "META", 22, Palette.YELLOW, 5)
	for id in _order:
		var rs: RS = _rs[id]
		var p := _player_by_id(id)
		var c: Color = p.color if p != null else Palette.WHITE
		var px := bar.position.x + bar.size.x * clampf(rs.z / TRACK_LEN, 0.0, 1.0)
		var mine := p != null and p == local_player
		s.draw_circle(Vector2(px, bar.position.y + 9.0), 13.0 if mine else 10.0, Palette.WHITE)
		s.draw_circle(Vector2(px, bar.position.y + 9.0), 10.0 if mine else 7.0, c)
	var left := maxi(0, ceili(TIME_LIMIT - _run_t))
	s.text_centered(Vector2(1160, 44), "%d s" % left, 40, Palette.YELLOW if left > 10 else Palette.CORAL, 8)
	if local_player != null and _rs.has(local_player.id):
		var me: RS = _rs[local_player.id]
		s.text_centered(Vector2(120, 44), "%d.º de %d" % [_place_of(local_player.id), _order.size()], 34, Palette.YELLOW, 7)
		s.text_centered(Vector2(120, 84), "%d km/h" % int(me.speed * 3.6), 24, Color(1, 1, 1, 0.85), 5)
	for p in _popups:
		var kk: float = p.age / 1.1
		s.text_centered(Vector2(640, 250.0 - 60.0 * kk), String(p.text), 56, Color(p.color.r, p.color.g, p.color.b, 1.0 - kk * kk), 10)
	if _cd > 0.0:
		var n := ceili(_cd)
		var frac_c := _cd - floorf(_cd)
		s.text_centered(Vector2(640, 300), str(n), int(130.0 + 60.0 * frac_c), Palette.YELLOW, 16)
	elif _run_t < 0.8:
		s.text_centered(Vector2(640, 300), "¡YA!", 130, Palette.MINT, 16)
	if _hint_t > 0.0 and not _over and _cd <= 0.0:
		s.text_centered(Vector2(640, 670), "A/D o ◄ ► para esquivar  ·  ESPACIO o CLIC para saltar", 28, Color(1, 1, 1, clampf(_hint_t, 0.0, 1.0)), 7)
	# Aviso de meta del jugador local.
	if local_player != null and _rs.has(local_player.id) and (_rs[local_player.id] as RS).finished and not _over:
		var pos := _finish_order.find(local_player.id) + 1
		s.text_centered(Vector2(640, 200), "¡META!  %d.º" % maxi(pos, 1), 80, Palette.YELLOW, 14)
	if _over:
		var w := _player_by_id(_winner_id)
		s.text_centered(Vector2(640, 250), "¡FIN!", 100, Palette.YELLOW, 14)
		if w != null:
			s.text_centered(Vector2(640, 340), "Gana %s" % w.display_name, 56, w.color.lightened(0.25), 10)

# ----------------------------------------------------------------------------
# Utilidades de depuración / pruebas (tests/obstacle_test.gd)
# ----------------------------------------------------------------------------

func debug_signature() -> String:
	_ensure_level()
	var parts: PackedStringArray = []
	for o in _obs:
		parts.append("%d:%.2f:%.2f:%.2f" % [int(o.kind), float(o.z), float(o.x), float(o.hw)])
	return "|".join(parts)

func debug_obstacles() -> Array:
	_ensure_level()
	return _obs

func debug_runner(id: int) -> Dictionary:
	var s: RS = _rs.get(id)
	if s == null:
		return {}
	return {"z": s.z, "x": s.x, "y": s.y, "speed": s.speed, "hits": s.hits, "done": s.done, "finished": s.finished,
			"ftime": s.ftime, "inv": s.inv}

func debug_over() -> bool:
	return _over

func debug_winner() -> int:
	return _winner_id

## Un corredor SOLO (sin rezagados ni rivales) con una política: "idle" (corre recto) o "bot" (la IA).
func debug_run(policy: String, skill: float = 1.0, seconds: float = TIME_LIMIT + 1.0) -> Dictionary:
	_ensure_level()
	var s := RS.new()
	s.bot_rng = RandomNumberGenerator.new()
	s.bot_rng.seed = seed_value
	s.speed = V_START
	_run_t = 0.0
	var t := 0.0
	while t < seconds and not s.done:
		_run_t += STEP
		var steer := 0.0
		var jump := false
		if policy == "bot":
			steer = _bot_decide(s, skill)
			jump = s.bot_jump
			s.bot_jump = false
		_step_rs(s, STEP, steer, jump, s.z)
		t += STEP
	return {"finished": s.finished, "time": _run_t, "distance": s.z, "hits": s.hits}

func debug_set_runner(id: int, z: float, x: float) -> void:
	var s: RS = _rs.get(id)
	if s != null:
		s.z = z
		s.x = x
