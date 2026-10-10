extends Minigame
## Pelea de Palabras (id word_fight; modelo HOST_AUTHORITATIVE, 3D): una arena de metal con 26 casillas con letras (A-Z).
## Sobre la cabeza de cada jugador flota la palabra del momento (la misma para todos). Se deletrea PISANDO la casilla de la
## letra que toca y pulsando ESPACIO o CLIC IZQUIERDO; cada letra acertada da 1 punto y quien completa la palabra se lleva
## 3 más y estrena palabra nueva para todos. Con CLIC DERECHO (o E) se GOLPEA al que tengas delante: queda aturdido un rato
## y pierde una letra de lo que llevaba. Gana quien más puntos tenga al acabar los 90 s.
##
## El host simula todo (60 Hz): movimiento, casillas, golpes, palabras y puntos; el estado se envía a ~30 Hz y los clientes
## interpolan. Lleva un segundo botón (golpear) por la red: ver InputManager.action2_presses / "c2" en MinigameSession.
## El 3D (SubViewport con su propio mundo) es solo presentación.

const STEP := 1.0 / 60.0
const TIME_LIMIT := 90.0
const COUNTDOWN := 3.0
const DONE_DELAY := 2.6
# --- Arena ---
const COLS := 6
const PAD_DX := 3.5
const PAD_DZ := 3.3
const PAD_Z0 := 5.3                     # z de la fila de abajo (A-F)
const PAD_HALF := 1.1
const ARENA_X := 11.0
const ARENA_Z_MIN := -9.3
const ARENA_Z_MAX := 8.7
# --- Jugadores ---
const RADIUS := 0.5
const RUN_SPEED := 6.4
const ACCEL := 46.0
const PUNCH_CD := 0.7
const PUNCH_RANGE := 1.5
const PUNCH_KNOCK := 10.0
const STUN_TIME := 1.7
const GRACE_TIME := 0.6                 # inmunidad tras recuperarse (no se puede encadenar aturdimientos)
const ERR_TIME := 0.35
const WORD_BONUS := 3
const FLOATS := 11                      # por jugador en el estado enviado
const LETTERS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

## Palabras por nivel de dificultad (solo A-Z, sin acentos). Empieza con las cortas.
const WORDS_EASY: Array[String] = ["LUNA", "SOL", "MARTE", "COHETE", "ASTRO", "NAVE", "POLVO", "ORBITA", "ROBOT", "LASER", "ATOMO", "VIENTO",
		"FUEGO", "ROCA", "NUBE", "PLUTON", "RAYO", "ESPACIO", "ALIEN", "CIELO"]
const WORDS_MID: Array[String] = ["PLANETA", "COMETA", "GALAXIA", "ESTRELLA", "SATURNO", "JUPITER", "NEPTUNO", "MERCURIO", "VENUS", "ECLIPSE",
		"METEORO", "SATELITE", "GRAVEDAD", "TELESCOPIO", "ANTENA", "RADAR", "PORTAL", "MOTOR"]
const WORDS_HARD: Array[String] = ["ASTRONAUTA", "CONSTELACION", "HIPERESPACIO", "UNIVERSO", "AGUJERONEGRO", "NEBULOSA", "CRUCERO", "PROPULSOR",
		"CAPSULA", "ESTACION", "SUPERNOVA", "ACELERADOR", "TRANSBORDADOR", "MAQUINA", "FUSION"]

## Un jugador (lo simula el host; los clientes lo reciben y solo interpolan la presentación).
class RS:
	var id: int = 0
	var idx: int = 0
	var pos: Vector2 = Vector2.ZERO          # (x, z)
	var vel: Vector2 = Vector2.ZERO
	var face: float = 0.0                    # ángulo (atan2(x, z)) hacia donde mira
	var stun_t: float = 0.0
	var inv_t: float = 0.0
	var punch_cd: float = 0.0
	var punch_t: float = 0.0
	var err_t: float = 0.0
	var progress: int = 0
	var score: int = 0
	# IA
	var skill: float = 1.0
	var aggr: float = 0.4
	var react: float = 0.0
	var hunt_t: float = 0.0
	var hunt_id: int = -1
	var want_press: bool = false
	var want_punch: bool = false
	var bot_rng: RandomNumberGenerator = null
	# Presentación (interpolada)
	var dpos: Vector2 = Vector2.ZERO
	var dface: float = 0.0
	var anim: float = 0.0
	var shown_score: int = 0
	var node: Node3D = null
	var body: Node3D = null
	var arm_l: Node3D = null
	var arm_r: Node3D = null
	var leg_l: Node3D = null
	var leg_r: Node3D = null
	var stars: Node3D = null
	var ring: MeshInstance3D = null
	var letters: Array = []                  # Label3D de la palabra sobre la cabeza
	var tag: Label3D = null
	var shown_word: String = ""
	var shown_progress: int = -1

var _rs: Dictionary = {}                 # player id -> RS
var _order: Array[int] = []
var _word: String = ""
var _words_done: int = 0
var _last_word: String = ""
var _wrng: RandomNumberGenerator
var _time_left: float = TIME_LIMIT
var _cd: float = COUNTDOWN
var _last_cd: int = 99
var _accum: float = 0.0
var _over: bool = false
var _over_t: float = 0.0
var _winner_id: int = -1
var _toast: String = ""
var _toast_t: float = 0.0
var _hint_t: float = 8.0
var _shake: float = 0.0
var _anim: float = 0.0
var _popups: Array = []                  # {id, text, age}  (los "+1" sobre el marcador)
var _flash: Dictionary = {}              # pad -> {t, ok}
var debug_skill: float = -1.0

# --- Escena 3D ---
var _vp: SubViewport
var _cont: SubViewportContainer
var _root3: Node3D
var _cam: Camera3D
var _built: bool = false
var _pads: Array[Node3D] = []
var _pad_labels: Array[Label3D] = []
var _vortex: Array[MeshInstance3D] = []
var _worms: Array = []
var _floaters: Array = []                # textos 3D que suben ("+1")

# ----------------------------------------------------------------------------
# Arena y palabras
# ----------------------------------------------------------------------------

func _pad_center(k: int) -> Vector2:
	var row := k / COLS
	var col := k % COLS
	if row == 4:
		col += 2                         # Y y Z van centradas arriba
	return Vector2((col - (COLS - 1) * 0.5) * PAD_DX, PAD_Z0 - row * PAD_DZ)

## Casilla bajo el punto (o -1).
func _pad_under(p: Vector2) -> int:
	for k in 26:
		var c := _pad_center(k)
		if absf(p.x - c.x) <= PAD_HALF and absf(p.y - c.y) <= PAD_HALF:
			return k
	return -1

func _pick_word() -> String:
	var tier := mini(_words_done / 2, 3)
	var pool: Array[String] = []
	match tier:
		0:
			pool = WORDS_EASY.filter(func(w: String) -> bool: return w.length() <= 5)
		1:
			pool = WORDS_EASY + WORDS_MID.filter(func(w: String) -> bool: return w.length() <= 7)
		2:
			pool = WORDS_MID
		_:
			pool = WORDS_MID + WORDS_HARD
	var w := pool[_wrng.randi_range(0, pool.size() - 1)]
	var guard := 0
	while w == _last_word and guard < 8:
		w = pool[_wrng.randi_range(0, pool.size() - 1)]
		guard += 1
	return w

func _letter_of(k: int) -> String:
	return LETTERS[k]

# ----------------------------------------------------------------------------
# Simulación (solo el host)
# ----------------------------------------------------------------------------

func _setup_players() -> void:
	for old in _rs.values():
		for n in [(old as RS).node, (old as RS).ring]:
			if n != null and is_instance_valid(n):
				(n as Node).queue_free()
	_rs.clear()
	_order.clear()
	_wrng = RandomNumberGenerator.new()
	_wrng.seed = seed_value
	_words_done = 0
	_last_word = ""
	_word = _pick_word()
	for i in players.size():
		var pl := players[i]
		var r := RS.new()
		r.id = pl.id
		r.idx = i
		var n := players.size()
		var x := 0.0 if n <= 1 else lerpf(-8.0, 8.0, float(i) / float(n - 1))
		r.pos = Vector2(x, 7.6)
		r.dpos = r.pos
		r.face = PI                      # miran hacia arriba (-z)
		r.dface = PI
		r.bot_rng = RandomNumberGenerator.new()
		r.bot_rng.seed = hash([seed_value, pl.id])
		r.skill = 0.7 + 0.3 * r.bot_rng.randf()
		r.aggr = 0.25 + 0.5 * r.bot_rng.randf()
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

func _simulate(delta: float) -> void:
	if _over:
		_over_t += delta
		if _over_t >= DONE_DELAY:
			finish(_ranking())
		else:
			for id in _order:
				_step_player(_rs[id] as RS, delta, Vector2.ZERO)
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
	# Entrada (una lectura por fotograma) y reglas.
	var dirs: Dictionary = {}
	for pl in players:
		var r: RS = _rs[pl.id]
		var mv := move_input(pl)
		dirs[pl.id] = Vector2(mv.x, mv.y)
		if action_presses(pl) > 0:
			_try_press(r)
		if action2_presses(pl) > 0:
			_try_punch(r)
	_accum += delta
	var steps := 0
	while _accum >= STEP and steps < 12:
		_accum -= STEP
		steps += 1
		for pl in players:
			_step_player(_rs[pl.id] as RS, STEP, dirs[pl.id] as Vector2)
		_separate_players()
	_time_left = maxf(0.0, _time_left - delta)
	if _time_left <= 0.0:
		_over = true
		_over_t = 0.0
		var rk := _ranking()
		_winner_id = rk[0] if not rk.is_empty() else -1
		send_event("over", {"w": _winner_id})
		DevCli.log_event("word_fight over winner=%d" % _winner_id)

func _step_player(r: RS, dt: float, dir: Vector2) -> void:
	r.stun_t = maxf(0.0, r.stun_t - dt)
	r.inv_t = maxf(0.0, r.inv_t - dt)
	r.punch_cd = maxf(0.0, r.punch_cd - dt)
	r.punch_t = maxf(0.0, r.punch_t - dt)
	r.err_t = maxf(0.0, r.err_t - dt)
	if r.stun_t > 0.0 or _over:
		r.vel = r.vel.move_toward(Vector2.ZERO, 14.0 * dt)
	else:
		if dir.length() > 1.0:
			dir = dir.normalized()
		r.vel = r.vel.move_toward(dir * RUN_SPEED, ACCEL * dt)
		if dir.length() > 0.2:
			r.face = lerp_angle(r.face, atan2(dir.x, dir.y), 1.0 - exp(-18.0 * dt))
	r.pos += r.vel * dt
	r.pos.x = clampf(r.pos.x, -ARENA_X, ARENA_X)
	r.pos.y = clampf(r.pos.y, ARENA_Z_MIN, ARENA_Z_MAX)

func _separate_players() -> void:
	for i in _order.size():
		var a: RS = _rs[_order[i]]
		for j in range(i + 1, _order.size()):
			var b: RS = _rs[_order[j]]
			var d := b.pos - a.pos
			var l := d.length()
			if l < RADIUS * 2.0 and l > 0.001:
				var push := d / l * (RADIUS * 2.0 - l) * 0.5
				a.pos -= push
				b.pos += push

## ESPACIO / clic izquierdo: pulsar la casilla que tienes bajo los pies.
func _try_press(r: RS) -> void:
	if r.stun_t > 0.0 or r.err_t > 0.0 or _over or _cd > 0.0:
		return
	var k := _pad_under(r.pos)
	if k < 0:
		return
	if r.progress >= _word.length():
		return
	if _letter_of(k) == _word[r.progress]:
		r.progress += 1
		r.score += 1
		send_event("ok", {"p": r.id, "k": k, "n": r.progress})
		if r.progress >= _word.length():
			_complete_word(r)
	else:
		r.err_t = ERR_TIME
		send_event("bad", {"p": r.id, "k": k})

func _complete_word(r: RS) -> void:
	r.score += WORD_BONUS
	_words_done += 1
	_last_word = _word
	_word = _pick_word()
	for id in _order:
		(_rs[id] as RS).progress = 0
	send_event("word", {"p": r.id, "w": _word, "b": WORD_BONUS})

## CLIC DERECHO / E: golpe al que tengas delante.
func _try_punch(r: RS) -> void:
	if r.stun_t > 0.0 or r.punch_cd > 0.0 or _over or _cd > 0.0:
		return
	r.punch_cd = PUNCH_CD
	r.punch_t = 0.28
	var fwd := Vector2(sin(r.face), cos(r.face))
	var center := r.pos + fwd * 0.8
	var hit_any := false
	for id in _order:
		if id == r.id:
			continue
		var v: RS = _rs[id]
		if v.stun_t > 0.0 or v.inv_t > 0.0:
			continue
		if v.pos.distance_to(center) <= PUNCH_RANGE * 0.8:
			var away := (v.pos - r.pos)
			away = away.normalized() if away.length() > 0.01 else fwd
			v.vel = away * PUNCH_KNOCK
			v.stun_t = STUN_TIME
			v.inv_t = STUN_TIME + GRACE_TIME
			v.progress = maxi(0, v.progress - 1)
			hit_any = true
			send_event("hit", {"a": r.id, "v": v.id})
	send_event("swing", {"p": r.id, "h": hit_any})

func _ranking() -> Array[int]:
	var scores: Dictionary = {}
	var ties: Dictionary = {}
	for id in _order:
		scores[id] = (_rs[id] as RS).score
		ties[id] = 0.0
	return rank_by_score(scores, ties)

# ----------------------------------------------------------------------------
# Red
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var arr := PackedFloat32Array()
	for id in _order:
		var r: RS = _rs[id]
		arr.append_array(PackedFloat32Array([r.pos.x, r.pos.y, r.vel.x, r.vel.y, r.face, r.stun_t, r.punch_t,
				float(r.progress), float(r.score), r.err_t, r.inv_t]))
	return {"r": arr, "w": _word, "t": _time_left, "cd": _cd, "o": _over, "win": _winner_id}

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	var st: Dictionary = state
	_word = String(st.get("w", _word))
	_time_left = float(st.get("t", _time_left))
	_cd = float(st.get("cd", _cd))
	_over = bool(st.get("o", _over))
	_winner_id = int(st.get("win", _winner_id))
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
		r.punch_t = arr[o + 6]
		r.progress = int(arr[o + 7])
		r.score = int(arr[o + 8])
		r.err_t = arr[o + 9]
		r.inv_t = arr[o + 10]

func _on_event(event_name: String, data: Variant) -> void:
	var d: Dictionary = data if data is Dictionary else {}
	var r: RS = _rs.get(int(d.get("p", int(d.get("a", -1)))))
	match event_name:
		"beep":
			Audio.sfx(&"beep", -7.0)
		"go":
			Audio.sfx(&"beep_go", -5.0)
		"ok":
			var k := int(d.get("k", 0))
			_flash[k] = {"t": 0.35, "ok": true}
			if r != null:
				_spawn_floater(r, "+1", true)
				_popups.append({"id": r.id, "text": "+1", "age": 0.0})
				Audio.sfx(&"reaction_ok" if _mine(r) else &"swish", -7.0 if _mine(r) else -17.0)
		"bad":
			_flash[int(d.get("k", 0))] = {"t": 0.35, "ok": false}
			if r != null and _mine(r):
				Audio.sfx(&"error", -8.0)
		"word":
			_toast = "¡NUEVA PALABRA!"
			_toast_t = 1.5
			if r != null:
				_spawn_floater(r, "+%d" % int(d.get("b", WORD_BONUS)), true)
				_popups.append({"id": r.id, "text": "+%d" % int(d.get("b", WORD_BONUS)), "age": 0.0})
			Audio.sfx(&"fanfare_small", -6.0)
			Audio.sfx(&"combo", -9.0)
		"swing":
			if r != null:
				r.punch_t = 0.28
				Audio.sfx(&"swish", -9.0 if _mine(r) else -18.0)
		"hit":
			var v: RS = _rs.get(int(d.get("v", -1)))
			if v != null:
				_shake = maxf(_shake, 0.3)
				_spawn_floater(v, "¡POW!", false)
				Audio.sfx(&"thud", -4.0)
				Audio.sfx(&"zap", -12.0)
		"over":
			_winner_id = int(d.get("w", -1))
			Audio.sfx(&"fanfare_big", -6.0)

# ----------------------------------------------------------------------------
# Ciclo del minijuego
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	_setup_players()
	_build_world()
	surface.draw_callback = _draw_hud

func _on_start() -> void:
	_setup_players()
	_rebuild_player_nodes()
	_accum = 0.0
	_cd = COUNTDOWN
	_last_cd = 99
	_time_left = TIME_LIMIT
	_over = false
	_over_t = 0.0
	_winner_id = -1
	_hint_t = 8.0
	_toast = ""
	_toast_t = 0.0
	_popups.clear()

func _animate(delta: float) -> void:
	_shake = maxf(0.0, _shake - delta * 2.5)
	_toast_t = maxf(0.0, _toast_t - delta)
	_anim += delta
	if _cd <= 0.0:
		_hint_t = maxf(0.0, _hint_t - delta)
	for p in _popups:
		p.age += delta
	_popups = _popups.filter(func(x: Dictionary) -> bool: return x.age < 1.2)
	_update_world(delta)

# ----------------------------------------------------------------------------
# IA (bots, autopiloto, práctica): va a la casilla de su siguiente letra y la pulsa; a veces va a por el líder a golpes
# ----------------------------------------------------------------------------

func _bot_think(r: RS) -> Vector2:
	r.want_press = false
	r.want_punch = false
	if _over or _cd > 0.0 or r.stun_t > 0.0:
		return Vector2.ZERO
	var sk := r.skill if debug_skill < 0.0 else debug_skill
	# ¿Caza a alguien? (el que va mejor que él), con algo de azar cada cierto tiempo.
	r.hunt_t = maxf(0.0, r.hunt_t - STEP)
	if r.hunt_t <= 0.0:
		r.hunt_id = -1
		if r.bot_rng.randf() < r.aggr * 0.0025:
			var best: RS = null
			for id in _order:
				if id == r.id:
					continue
				var o: RS = _rs[id]
				if best == null or o.score > best.score:
					best = o
			if best != null and best.score >= r.score:
				r.hunt_id = best.id
				r.hunt_t = 3.5
	if r.hunt_id >= 0:
		var v: RS = _rs[r.hunt_id]
		var to := v.pos - r.pos
		if to.length() < PUNCH_RANGE * 0.75:
			r.face = lerp_angle(r.face, atan2(to.x, to.y), 0.6)
			r.want_punch = r.punch_cd <= 0.0 and v.inv_t <= 0.0 and v.stun_t <= 0.0
			if v.stun_t > 0.0 or v.inv_t > 0.0:
				r.hunt_t = 0.0
		return to.normalized()
	# Deletrear: ir a la casilla de la letra que toca.
	if r.progress >= _word.length():
		return Vector2.ZERO
	var k := LETTERS.find(_word[r.progress])
	if k < 0:
		return Vector2.ZERO
	var c := _pad_center(k)
	var to_pad := c - r.pos
	var dist := to_pad.length()
	if dist < 0.8:
		r.react += STEP
		if r.react >= lerpf(0.5, 0.12, sk) and r.err_t <= 0.0:
			r.want_press = true
			r.react = 0.0
		return Vector2.ZERO
	r.react = 0.0
	return to_pad / dist * lerpf(0.82, 1.0, sk)

func _bot_move(player: PlayerData) -> Vector2:
	var r: RS = _rs.get(player.id)
	if r == null:
		return Vector2.ZERO
	return _bot_think(r)

func _bot_action(player: PlayerData) -> int:
	var r: RS = _rs.get(player.id)
	if r == null:
		return 0
	var v := 1 if r.want_press else 0
	r.want_press = false
	return v

func _bot_action2(player: PlayerData) -> int:
	var r: RS = _rs.get(player.id)
	if r == null:
		return 0
	var v := 1 if r.want_punch else 0
	r.want_punch = false
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
	var m := _mat(c, 0.0, 0.55)
	var o := StandardMaterial3D.new()
	o.albedo_color = Color(0.05, 0.05, 0.1)
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
	cm.radial_segments = 20
	cm.rings = 6
	return _mesh(parent, cm, pos, mat)

func _sphere(parent: Node3D, radius: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 24
	sm.rings = 12
	return _mesh(parent, sm, pos, mat)

func _cyl(radius: float, height: float) -> CylinderMesh:
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = 16
	return cm

# --- Texturas procedurales (una vez) ---
static var _tex_floor: ImageTexture = null
static var _tex_hazard: ImageTexture = null
static var _tex_swirl: ImageTexture = null

func _floor_texture() -> ImageTexture:
	if _tex_floor != null:
		return _tex_floor
	var n := FastNoiseLite.new()
	n.seed = 11
	n.frequency = 0.05
	n.fractal_octaves = 3
	var nn := n.get_seamless_image(256, 256)
	var img := Image.create(256, 256, false, Image.FORMAT_RGB8)
	for y in 256:
		for x in 256:
			var v := 0.30 + 0.12 * (nn.get_pixel(x, y).r - 0.5)
			var gx := x % 128
			var gy := y % 128
			if gx < 3 or gy < 3:
				v *= 0.45                                 # juntas entre paneles
			elif gx < 5 or gy < 5:
				v *= 1.25
			# remaches en las esquinas de cada panel
			var rx := minf(float(gx), float(127 - gx))
			var ry := minf(float(gy), float(127 - gy))
			if Vector2(rx - 12.0, ry - 12.0).length() < 3.2:
				v *= 1.5
			img.set_pixel(x, y, Color(v * 0.78, v * 0.92, v * 1.08))
	img.generate_mipmaps()
	_tex_floor = ImageTexture.create_from_image(img)
	return _tex_floor

func _hazard_texture() -> ImageTexture:
	if _tex_hazard != null:
		return _tex_hazard
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 64:
			var stripe := int(floorf(float(x + y) / 16.0)) % 2 == 0
			img.set_pixel(x, y, Color(0.85, 0.68, 0.12) if stripe else Color(0.09, 0.09, 0.1))
	img.generate_mipmaps()
	_tex_hazard = ImageTexture.create_from_image(img)
	return _tex_hazard

func _swirl_texture() -> ImageTexture:
	if _tex_swirl != null:
		return _tex_swirl
	var img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for y in 128:
		for x in 128:
			var p := Vector2(x - 63.5, y - 63.5) / 64.0
			var rr := p.length()
			var a := atan2(p.y, p.x)
			var spiral := 0.5 + 0.5 * sin(a * 3.0 + rr * 14.0)
			var fade := clampf(1.0 - rr, 0.0, 1.0)
			var core := clampf(1.0 - rr * 2.2, 0.0, 1.0)
			var al := clampf(fade * (0.35 + 0.65 * spiral) + core, 0.0, 1.0)
			img.set_pixel(x, y, Color(0.35 + 0.6 * core, 0.75 + 0.25 * core, 1.0, al))
	img.generate_mipmaps()
	_tex_swirl = ImageTexture.create_from_image(img)
	return _tex_swirl

func _build_world() -> void:
	if _built:
		return
	_built = true
	var cont := SubViewportContainer.new()
	cont.stretch = true
	cont.top_level = true                          # toda la ventana, aunque el minijuego esté en una capa centrada
	cont.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_cont = cont
	cont.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(cont)
	move_child(cont, surface.get_index())          # el 3D va detrás del dibujo 2D (HUD)
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.handle_input_locally = false
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	cont.add_child(_vp)
	_root3 = Node3D.new()
	_vp.add_child(_root3)
	# --- Ambiente oscuro de estación espacial, con brillo ---
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.04, 0.06)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.6, 0.75)
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.15
	env.glow_enabled = true
	env.glow_intensity = 0.9
	env.glow_bloom = 0.12
	env.glow_hdr_threshold = 0.9
	env.fog_enabled = true
	env.fog_light_color = Color(0.05, 0.12, 0.14)
	env.fog_density = 0.006
	var we := WorldEnvironment.new()
	we.environment = env
	_root3.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-62.0, -18.0, 0.0)
	sun.light_energy = 1.1
	sun.light_color = Color(0.8, 0.9, 1.0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 60.0
	sun.shadow_bias = 0.05
	_root3.add_child(sun)
	# --- Suelo de paneles metálicos ---
	var floor_mat := _mat(Color(1, 1, 1), 0.0, 0.55, 0.35)
	floor_mat.albedo_texture = _floor_texture()
	floor_mat.uv1_scale = Vector3(5.0, 4.5, 1.0)
	floor_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var fm := PlaneMesh.new()
	fm.size = Vector2(ARENA_X * 2.0 + 3.0, 22.0)
	_mesh(_root3, fm, Vector3(0, 0, -0.5), floor_mat)
	# --- Bordes con franjas de peligro y paredes laterales ---
	var haz := _mat(Color(1, 1, 1), 0.0, 0.7)
	haz.albedo_texture = _hazard_texture()
	haz.uv1_scale = Vector3(8.0, 1.0, 1.0)
	haz.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var haz_side := haz.duplicate() as StandardMaterial3D
	haz_side.uv1_scale = Vector3(1.0, 8.0, 1.0)
	var metal := _mat(Color(0.2, 0.26, 0.3), 0.0, 0.45, 0.6)
	for sx in [-1.0, 1.0]:
		_box(_root3, Vector3(1.0, 0.12, 20.5), Vector3(sx * (ARENA_X + 1.0), 0.06, -0.5), haz_side)
		_box(_root3, Vector3(1.2, 6.0, 22.0), Vector3(sx * (ARENA_X + 2.1), 3.0, -0.5), metal)
		# barandilla y tubos
		_box(_root3, Vector3(0.12, 0.12, 20.0), Vector3(sx * (ARENA_X + 1.35), 1.5, -0.5), _mat(Color(0.5, 0.58, 0.62), 0.0, 0.4, 0.8))
		for i in 7:
			_box(_root3, Vector3(0.1, 1.5, 0.1), Vector3(sx * (ARENA_X + 1.35), 0.75, -9.0 + i * 3.0), _mat(Color(0.5, 0.58, 0.62), 0.0, 0.4, 0.8))
		for i in 4:
			_box(_root3, Vector3(0.06, 0.06, 4.0), Vector3(sx * (ARENA_X + 1.45), 3.2 + 0.5 * i, -4.0 + 3.0 * (i % 2)), _mat(Color(0.2, 0.9, 0.85), 1.4))
	_box(_root3, Vector3(ARENA_X * 2.0 + 3.0, 0.12, 1.0), Vector3(0, 0.06, ARENA_Z_MIN - 0.9), haz)
	var back_mat := _mat(Color(0.1, 0.13, 0.16), 0.0, 0.5, 0.5)
	_box(_root3, Vector3(ARENA_X * 2.0 + 6.0, 9.0, 1.0), Vector3(0, 4.5, ARENA_Z_MIN - 1.8), back_mat)
	# Vórtices azules en la pared del fondo (de donde "salen" las palabras).
	var swirl_mat := StandardMaterial3D.new()
	swirl_mat.albedo_texture = _swirl_texture()
	swirl_mat.albedo_color = Color(0.7, 0.95, 1.4)
	swirl_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	swirl_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	swirl_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	swirl_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for i in 5:
		var qm := QuadMesh.new()
		qm.size = Vector2(4.4, 4.4)
		var vx := _mesh(_root3, qm, Vector3(-9.0 + 4.5 * i, 4.2 + 0.6 * (i % 2), ARENA_Z_MIN - 1.25), swirl_mat)
		vx.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_vortex.append(vx)
	# --- Consola de abajo con luces (donde van los marcadores) ---
	var cons := _mat(Color(0.12, 0.16, 0.2), 0.0, 0.5, 0.6)
	_box(_root3, Vector3(ARENA_X * 2.0 + 3.0, 1.6, 3.0), Vector3(0, 0.8, ARENA_Z_MAX + 2.4), cons)
	for i in 3:
		_box(_root3, Vector3(0.3, 1.0, 0.25), Vector3(-6.5 + 6.5 * i, 1.7, ARENA_Z_MAX + 1.1), _mat(Color(0.8, 0.95, 1.0), 2.2))
	# --- Casillas con letras ---
	for k in 26:
		var c := _pad_center(k)
		var hue := float(k) / 26.0
		var lc := Color.from_hsv(hue, 0.55, 1.0)
		var pad := Node3D.new()
		_root3.add_child(pad)
		pad.position = Vector3(c.x, 0.0, c.y)
		var frame_mat := haz.duplicate() as StandardMaterial3D
		frame_mat.uv1_scale = Vector3(2.0, 2.0, 1.0)
		_box(pad, Vector3(PAD_HALF * 2.0 + 0.3, 0.2, PAD_HALF * 2.0 + 0.3), Vector3(0, 0.1, 0), frame_mat)
		_box(pad, Vector3(PAD_HALF * 2.0 - 0.2, 0.26, PAD_HALF * 2.0 - 0.2), Vector3(0, 0.13, 0), _mat(Color(0.12, 0.14, 0.18), 0.0, 0.4, 0.7))
		var plate := _box(pad, Vector3(PAD_HALF * 2.0 - 0.7, 0.05, PAD_HALF * 2.0 - 0.7), Vector3(0, 0.275, 0), _mat(Color(0.2, 0.22, 0.28), 0.0, 0.3, 0.6))
		plate.name = "plate"
		var lab := Label3D.new()
		lab.text = LETTERS[k]
		lab.font_size = 160
		lab.pixel_size = 0.0105
		lab.outline_size = 14
		lab.outline_modulate = Color(0.04, 0.04, 0.08)
		lab.modulate = Color(lc.r * 1.5, lc.g * 1.5, lc.b * 1.5)
		lab.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		lab.position = Vector3(0, 0.32, 0)
		lab.double_sided = true
		lab.shaded = false
		lab.no_depth_test = false
		pad.add_child(lab)
		_pads.append(pad)
		_pad_labels.append(lab)
	# --- Gusanos decorativos que reptan por la arena ---
	var worm_mat := _mat(Color(0.85, 0.7, 0.4), 0.0, 0.8)
	var wr := RandomNumberGenerator.new()
	wr.seed = seed_value + 5
	for i in 6:
		var segs: Array = []
		for s in 9:
			var sp := _sphere(_root3, 0.16 - 0.008 * s, Vector3.ZERO, worm_mat)
			sp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			segs.append(sp)
		_worms.append({"segs": segs, "p": Vector2(wr.randf_range(-9.0, 9.0), wr.randf_range(-7.5, 6.5)), "a": wr.randf_range(0.0, TAU), "ph": wr.randf_range(0.0, TAU)})
	# --- Jugadores y cámara ---
	_rebuild_player_nodes()
	_cam = Camera3D.new()
	_cam.fov = 50.0
	_cam.far = 200.0
	_root3.add_child(_cam)
	_cam.position = Vector3(0, 21.5, 17.5)
	_cam.current = true
	_cam.look_at(Vector3(0, 0, -0.5), Vector3.UP)
	_update_world(0.0)

func _rebuild_player_nodes() -> void:
	if not _built:
		return
	for id in _order:
		var r: RS = _rs[id]
		for n in [r.node, r.ring]:
			if n != null and is_instance_valid(n):
				(n as Node).queue_free()
		_build_player(r, _player_by_id(id))

## Un personajillo (cuerpo de color, ojos grandes, orejitas), con anillo de color en el suelo y su palabra encima.
func _build_player(r: RS, pl: PlayerData) -> void:
	var col: Color = pl.color if pl != null else Palette.YELLOW
	r.node = Node3D.new()
	_root3.add_child(r.node)
	r.body = Node3D.new()
	r.node.add_child(r.body)
	var b := r.body
	_capsule(b, 0.42, 1.15, Vector3(0, 0.78, 0), _toon(col))
	_sphere(b, 0.14, Vector3(0, 0.62, 0.38), _toon(col.lightened(0.35), 0.015))                # barriguita
	# Cabeza grande con ojos.
	_sphere(b, 0.48, Vector3(0, 1.5, 0), _toon(col.lightened(0.12)))
	for sx in [-1.0, 1.0]:
		_sphere(b, 0.17, Vector3(sx * 0.2, 1.58, 0.36), _mat(Color.WHITE, 0.25, 0.3))
		_sphere(b, 0.085, Vector3(sx * 0.2, 1.57, 0.5), _mat(Color(0.05, 0.05, 0.1), 0.0, 0.2))
		_sphere(b, 0.16, Vector3(sx * 0.4, 1.92, -0.02), _toon(col.darkened(0.2), 0.02))      # orejas
	# Brazos y piernas con pivote.
	r.arm_l = Node3D.new()
	r.arm_l.position = Vector3(-0.5, 1.12, 0)
	b.add_child(r.arm_l)
	r.arm_r = Node3D.new()
	r.arm_r.position = Vector3(0.5, 1.12, 0)
	b.add_child(r.arm_r)
	var arm_mat := _toon(col)
	for arm in [r.arm_l, r.arm_r]:
		_capsule(arm, 0.12, 0.62, Vector3(0, -0.27, 0), arm_mat)
		_sphere(arm, 0.16, Vector3(0, -0.58, 0), _toon(col.lightened(0.2), 0.02))
	r.leg_l = Node3D.new()
	r.leg_l.position = Vector3(-0.2, 0.42, 0)
	b.add_child(r.leg_l)
	r.leg_r = Node3D.new()
	r.leg_r.position = Vector3(0.2, 0.42, 0)
	b.add_child(r.leg_r)
	var leg_mat := _toon(col.darkened(0.25))
	for leg in [r.leg_l, r.leg_r]:
		_capsule(leg, 0.13, 0.46, Vector3(0, -0.18, 0), leg_mat)
		_box(leg, Vector3(0.26, 0.12, 0.4), Vector3(0, -0.4, 0.07), _toon(Color(0.15, 0.15, 0.2), 0.02))
	# Estrellitas que giran cuando está aturdido.
	r.stars = Node3D.new()
	r.stars.position = Vector3(0, 2.25, 0)
	r.node.add_child(r.stars)
	for i in 3:
		var st := _sphere(r.stars, 0.12, Vector3(cos(i * TAU / 3.0) * 0.5, 0, sin(i * TAU / 3.0) * 0.5), _mat(Color(1.0, 0.9, 0.3), 1.6))
		st.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	r.stars.visible = false
	# Anillo de color bajo los pies (identifica a cada jugador).
	var is_me := pl != null and (pl == local_player or (local_player == null and pl.is_local_human))
	var tm := TorusMesh.new()
	tm.inner_radius = 0.62 if not is_me else 0.66
	tm.outer_radius = 0.78 if not is_me else 0.86
	var rm := _mat(col, 1.0, 0.4)
	r.ring = _mesh(_root3, tm, Vector3.ZERO, rm)
	r.ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Palabra sobre la cabeza: una etiqueta por letra (las acertadas en verde).
	r.letters.clear()
	for i in 14:
		var l := Label3D.new()
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.font_size = 72
		l.pixel_size = 0.0100
		l.outline_size = 22
		l.outline_modulate = Color(0.03, 0.03, 0.06)
		l.visible = false
		r.node.add_child(l)
		r.letters.append(l)
	r.tag = Label3D.new()
	r.tag.text = "▼"
	r.tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	r.tag.no_depth_test = true
	r.tag.font_size = 90
	r.tag.pixel_size = 0.0105
	r.tag.modulate = Palette.YELLOW
	r.tag.outline_size = 18
	r.tag.outline_modulate = Color(0.03, 0.03, 0.06)
	r.tag.visible = is_me
	r.tag.position = Vector3(0, 3.55, 0)
	r.node.add_child(r.tag)
	r.shown_progress = -1
	r.shown_word = ""
	r.dpos = r.pos
	r.dface = r.face

func _spawn_floater(r: RS, text: String, good: bool) -> void:
	if not _built or r.node == null:
		return
	var l := Label3D.new()
	l.text = text
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.font_size = 110
	l.pixel_size = 0.011
	l.outline_size = 24
	l.outline_modulate = Color(0.03, 0.03, 0.06)
	l.modulate = Color(0.75, 1.0, 0.25) if good else Color(1.0, 0.45, 0.3)
	l.position = Vector3(r.dpos.x, 3.2, r.dpos.y)
	_root3.add_child(l)
	_floaters.append({"n": l, "age": 0.0})

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
		if r.dpos.distance_to(r.pos) > 5.0:
			r.dpos = r.pos
		else:
			r.dpos = r.dpos.lerp(r.pos, k)
		r.dface = lerp_angle(r.dface, r.face, 1.0 if delta <= 0.0 else 1.0 - exp(-20.0 * delta))
		r.anim += delta
		r.node.position = Vector3(r.dpos.x, 0.0, r.dpos.y)
		r.body.rotation.y = r.dface
		var speed := r.vel.length()
		var stunned := r.stun_t > 0.0
		var ph := r.anim * (7.0 + speed * 0.8)
		var swing := clampf(speed / RUN_SPEED, 0.0, 1.0)
		if stunned:
			# Tumbado y dando vueltas de estrellas.
			r.body.rotation.x = lerpf(r.body.rotation.x, -1.45, 0.25)
			r.body.position.y = lerpf(r.body.position.y, 0.28, 0.25)
			r.arm_l.rotation.x = -2.2
			r.arm_r.rotation.x = -2.2
			r.leg_l.rotation.x = 0.4
			r.leg_r.rotation.x = -0.4
			r.stars.visible = true
			r.stars.rotation.y += delta * 6.0
		else:
			r.stars.visible = false
			r.body.rotation.x = lerpf(r.body.rotation.x, 0.12 * swing, 0.3)
			r.body.position.y = lerpf(r.body.position.y, absf(sin(ph)) * 0.1 * swing, 0.5)
			if speed > 0.8:
				r.leg_l.rotation.x = sin(ph) * 1.0 * swing
				r.leg_r.rotation.x = -sin(ph) * 1.0 * swing
				r.arm_l.rotation.x = -sin(ph) * 0.8 * swing
				r.arm_r.rotation.x = sin(ph) * 0.8 * swing
			else:
				var idle := sin(r.anim * 2.4)
				r.leg_l.rotation.x = lerpf(r.leg_l.rotation.x, 0.0, 0.3)
				r.leg_r.rotation.x = lerpf(r.leg_r.rotation.x, 0.0, 0.3)
				r.arm_l.rotation.x = lerpf(r.arm_l.rotation.x, 0.08 * idle, 0.3)
				r.arm_r.rotation.x = lerpf(r.arm_r.rotation.x, -0.08 * idle, 0.3)
			if r.punch_t > 0.0:
				var pk := 1.0 - r.punch_t / 0.28
				r.arm_r.rotation.x = -2.6 * sin(pk * PI)                # puñetazo hacia delante
		# Parpadeo mientras es inmune tras recuperarse.
		r.node.visible = not (r.inv_t > 0.0 and not stunned and int(r.inv_t * 16.0) % 2 == 0)
		r.ring.position = Vector3(r.dpos.x, 0.34, r.dpos.y)
		# Palabra sobre la cabeza.
		_update_word_label(r)
	# Casillas: se hunden y brillan al pulsarse.
	for kk in _flash.keys():
		var f: Dictionary = _flash[kk]
		f["t"] = float(f["t"]) - delta
		if float(f["t"]) <= 0.0:
			_flash.erase(kk)
	for i in 26:
		var pad: Node3D = _pads[i]
		var plate: MeshInstance3D = pad.get_node("plate")
		var lab: Label3D = _pad_labels[i]
		var base_hue := Color.from_hsv(float(i) / 26.0, 0.55, 1.0)
		if _flash.has(i):
			var f2: Dictionary = _flash[i]
			var a := clampf(float(f2["t"]) / 0.35, 0.0, 1.0)
			var fc := Color(0.4, 1.0, 0.4) if bool(f2["ok"]) else Color(1.0, 0.3, 0.25)
			lab.modulate = Color(base_hue.r, base_hue.g, base_hue.b).lerp(fc, a) * (1.5 + 1.2 * a)
			lab.scale = Vector3.ONE * (1.0 + 0.25 * a)
			pad.position.y = -0.08 * a
		else:
			lab.modulate = Color(base_hue.r * 1.5, base_hue.g * 1.5, base_hue.b * 1.5)
			lab.scale = Vector3.ONE
			pad.position.y = 0.0
	# Vórtices que giran, gusanos que reptan, textos que suben.
	for v in _vortex:
		v.rotation.z += delta * 0.9
	for w in _worms:
		var p: Vector2 = w["p"]
		var a2: float = w["a"]
		p += Vector2(sin(a2), cos(a2)) * 0.5 * delta
		if p.x < -10.0 or p.x > 10.0 or p.y < -8.5 or p.y > 7.5:
			a2 += PI * 0.6
			p = p.clamp(Vector2(-10.0, -8.5), Vector2(10.0, 7.5))
		w["p"] = p
		w["a"] = a2
		var segs: Array = w["segs"]
		var dirv := Vector2(sin(a2), cos(a2))
		var perp := Vector2(dirv.y, -dirv.x)
		for s in segs.size():
			var off := p - dirv * (s * 0.2) + perp * sin(_anim * 3.0 + s * 0.7 + float(w["ph"])) * 0.12
			(segs[s] as Node3D).position = Vector3(off.x, 0.2, off.y)
	for fl in _floaters:
		fl["age"] = float(fl["age"]) + delta
		var n: Label3D = fl["n"]
		n.position.y += delta * 1.8
		n.modulate.a = clampf(1.0 - float(fl["age"]) / 1.0, 0.0, 1.0)
	var keep: Array = []
	for fl in _floaters:
		if float(fl["age"]) < 1.0:
			keep.append(fl)
		else:
			(fl["n"] as Node).queue_free()
	_floaters = keep
	# Cámara fija; un temblor suave en los golpes.
	var shake := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * _shake * 0.25
	_cam.position = Vector3(0, 21.5, 17.5) + shake

## Letras de la palabra sobre la cabeza: las acertadas en verde y el resto en blanco.
func _update_word_label(r: RS) -> void:
	var w := _word
	if r.shown_word != w or r.shown_progress != r.progress:
		r.shown_word = w
		r.shown_progress = r.progress
		var n := w.length()
		var spacing := 0.62
		var x0 := -(n - 1) * spacing * 0.5
		for i in r.letters.size():
			var l: Label3D = r.letters[i]
			if i < n:
				l.visible = true
				l.text = w[i]
				l.position = Vector3(x0 + i * spacing, 2.75, 0)
				l.modulate = Color(0.72, 1.0, 0.2) if i < r.progress else Color(1, 1, 1)
			else:
				l.visible = false
	var shown := not _over and _cd <= 1.0
	for l2 in r.letters:
		if not shown:
			(l2 as Label3D).visible = false

# ----------------------------------------------------------------------------
# HUD (dibujo 2D encima del 3D): marcadores abajo, reloj arriba a la derecha
# ----------------------------------------------------------------------------

func _draw_hud() -> void:
	var s := surface
	# Reloj (círculo con los segundos).
	var left := ceili(_time_left)
	var cen := Vector2(1210, 56)
	s.draw_circle(cen, 36.0, Color(0.05, 0.12, 0.2, 0.9))
	s.draw_arc(cen, 33.0, -PI * 0.5, -PI * 0.5 + TAU * clampf(_time_left / TIME_LIMIT, 0.0, 1.0), 48, Color(0.35, 0.8, 1.0) if left > 15 else Palette.CORAL, 6.0)
	s.text_centered(cen, str(left), 34, Palette.WHITE, 6)
	# Marcadores abajo.
	var n := _order.size()
	var pw := minf(150.0, 1180.0 / maxf(n, 1))
	var total := pw * n + 8.0 * (n - 1)
	var x0 := (1280.0 - total) * 0.5
	for i in n:
		var r: RS = _rs[_order[i]]
		var pl := _player_by_id(r.id)
		var col: Color = pl.color if pl != null else Palette.WHITE
		var rect := Rect2(x0 + i * (pw + 8.0), 650.0, pw, 56.0)
		var mine := pl != null and (pl == local_player or (local_player == null and pl.is_local_human))
		s.rounded_rect(rect.grow(3.0 if mine else 0.0), 10, Palette.WHITE if mine else Color(0, 0, 0, 0))
		s.rounded_rect(rect, 9, Color(col.r * 0.35, col.g * 0.35, col.b * 0.35, 0.92))
		s.draw_circle(rect.position + Vector2(26, 28), 15.0, col)
		s.draw_circle(rect.position + Vector2(26, 28), 9.0, col.lightened(0.5))
		s.text_centered(rect.position + Vector2(pw - 34.0, 28), str(r.score), 34, Palette.WHITE, 6)
		if pl != null and n <= 6:
			s.text_centered(rect.position + Vector2(pw * 0.5, -10), pl.display_name, 18, Color(1, 1, 1, 0.8), 4)
		for p in _popups:
			if int(p.id) == r.id:
				var kk: float = p.age / 1.2
				s.text_centered(rect.position + Vector2(pw - 34.0, -16.0 - 40.0 * kk), String(p.text), 30, Color(0.75, 1.0, 0.25, 1.0 - kk * kk), 6)
	if _toast_t > 0.0:
		s.text_centered(Vector2(640, 120), _toast, 56, Color(1, 1, 1, clampf(_toast_t * 2.0, 0.0, 1.0)), 10)
	if _cd > 0.0:
		var c := ceili(_cd)
		var frac := _cd - floorf(_cd)
		s.text_centered(Vector2(640, 330), str(c), int(130.0 + 60.0 * frac), Palette.YELLOW, 16)
	elif _time_left > TIME_LIMIT - 0.8:
		s.text_centered(Vector2(640, 330), "¡YA!", 130, Palette.MINT, 16)
	if _hint_t > 0.0 and not _over and _cd <= 0.0:
		s.text_centered(Vector2(640, 600), "Pisa la letra y pulsa ESPACIO / CLIC  ·  Golpea con E / CLIC DERECHO", 26, Color(1, 1, 1, clampf(_hint_t, 0.0, 1.0)), 7)
	if _over:
		var w := _player_by_id(_winner_id)
		s.text_centered(Vector2(640, 280), "¡FIN!", 100, Palette.YELLOW, 14)
		if w != null:
			s.text_centered(Vector2(640, 370), "Gana %s" % w.display_name, 56, w.color.lightened(0.25), 10)

# ----------------------------------------------------------------------------
# Utilidades de depuración / pruebas (tests/word_fight_test.gd)
# ----------------------------------------------------------------------------

func debug_word() -> String:
	return _word

func debug_set_word(w: String) -> void:
	_word = w
	for id in _order:
		(_rs[id] as RS).progress = 0

func debug_player(id: int) -> Dictionary:
	var r: RS = _rs.get(id)
	if r == null:
		return {}
	return {"pos": r.pos, "vel": r.vel, "score": r.score, "progress": r.progress, "stun": r.stun_t, "inv": r.inv_t, "face": r.face}

func debug_place(id: int, p: Vector2, face: float = PI) -> void:
	var r: RS = _rs.get(id)
	if r != null:
		r.pos = p
		r.vel = Vector2.ZERO
		r.face = face

func debug_pad_center(k: int) -> Vector2:
	return _pad_center(k)

func debug_pad_under(p: Vector2) -> int:
	return _pad_under(p)

func debug_press(id: int) -> void:
	_try_press(_rs[id])

func debug_punch(id: int) -> void:
	_try_punch(_rs[id])

func debug_pick_words(count: int) -> Array:
	var out: Array = []
	for i in count:
		out.append(_pick_word())
		_words_done += 1
	return out

func debug_over() -> bool:
	return _over

func debug_winner() -> int:
	return _winner_id
