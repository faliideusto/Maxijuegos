extends Minigame
## Karts Arcoíris (id rainbow_kart; modelo HOST_AUTHORITATIVE, 3D): carrera de karts a 3 vueltas por la Senda
## Arcoíris, una pista de colores que flota en el espacio (hecha para este juego: un ocho con un puente por encima de
## la recta de salida, subidas, bajadas, una chicane, un salto y tramos SIN barandilla por los que te puedes caer).
## Inspirado en las carreras de karts de toda la vida: cajas de objetos, derrapes con turbo, monedas, rampas con
## acrobacia, plátanos y caparazones. Todo (pista, karts, pilotos, objetos) se genera por código.
##
## Controles: WASD / flechas (o palanca) para girar; el kart acelera solo y ABAJO frena o da marcha atrás.
## ESPACIO / CLIC (mantener) mientras giras = DERRAPE: cuanto más dura, más turbo al soltar (chispas azules, naranjas
## y moradas). En el aire después de una rampa, ESPACIO = acrobacia (turbo al aterrizar). E / CLIC DERECHO = usar el
## objeto (con ABAJO pulsado los plátanos y caparazones van hacia atrás; con ARRIBA el plátano se lanza adelante).
##
## Objetos (según tu puesto, como en los juegos de karts: los últimos reciben los mejores): plátano, caparazón verde
## (recto, rebota en las barandillas), caparazón rojo (persigue al de delante), champiñón turbo (x1 o x3), estrella
## (invencible y más rápido), rayo (encoge a los demás) y caparazón azul con pinchos (va a por el primero).
## Las monedas (máx. 10) suben un poco la velocidad punta; si te dan o te caes, pierdes algunas.
## Si caes de la pista, una nube te recoge y te devuelve al último punto seguro.
##
## Fin: cuando todas las personas han cruzado la meta (o todos), 25 s después del primero o a los TIME_LIMIT s. Orden:
## los que acabaron por tiempo y el resto por lo que les faltaba.
##
## Pantalla partida: en modo local cada persona del PC (hasta 4) tiene su cámara, como en las consolas.
## Red: el host simula todo a 60 Hz y envía karts, objetos, cajas y monedas (~30 Hz); los clientes interpolan. El
## botón de derrape mantenido llega con "h:1"/"h:0" por el canal de texto del minijuego (fiable, solo al cambiar).

const STEP := 1.0 / 60.0
const LAPS := 3
const TIME_LIMIT := 210.0
const AFTER_FIRST := 25.0               # segundos que siguen tras llegar el primero
const DONE_DELAY := 3.2
# --- Pista ---
const SCALE := 0.8
const SPACING := 1.0                    # separación de los puntos de la línea central (m)
const ROAD_W := 15.0
const BRIDGE_W := 12.5
const RAILLESS: Array = [[0.300, 0.462], [0.676, 0.760]]   # tramos sin barandilla (fracción de vuelta)
const RAMP := [0.680, 0.690]            # la rampa de salto
const RAMP_H := 1.6
const PADS: Array = [[0.162, 0.0], [0.473, 3.0], [0.669, 0.0], [0.787, -3.0], [0.935, -2.5]]   # turbos [fracción, lateral]
const BOX_ROWS: Array[float] = [0.074, 0.335, 0.614, 0.905]
const BOX_LANES: Array[float] = [-5.0, -2.5, 0.0, 2.5, 5.0]
const COIN_LINES: Array = [[0.12, 4.0], [0.25, -4.0], [0.40, 0.0], [0.55, 3.0], [0.83, -3.0], [0.96, 2.0]]
const ARCHES: Array[float] = [0.04, 0.2, 0.28, 0.5, 0.58, 0.8, 0.88]
## Puntos de control de la pista: (x, z, altura). Se escalan con SCALE y se unen con una spline Catmull-Rom cerrada.
const CTRL: Array = [
	[0, 8, 0], [0, 40, 0], [0, 90, 1], [12, 128, 3], [45, 150, 5], [85, 146, 7], [112, 118, 9], [118, 78, 11],
	[100, 48, 13], [60, 38, 14], [0, 38, 14], [-55, 38, 13], [-95, 50, 11], [-125, 30, 9], [-130, -10, 7],
	[-110, -45, 5], [-70, -60, 3], [-40, -85, 2], [-10, -110, 1], [30, -104, 0.5], [48, -70, 0], [36, -34, 0],
	[12, -14, 0]]
const START_ANCHOR := Vector2(0.0, 48.0 * SCALE)
const SEARCH := 10                      # ventana de búsqueda del punto más cercano (± puntos)
# --- Kart ---
const KART_R := 1.05
const TOP := 27.0                       # velocidad punta (m/s)
const COIN_BONUS := 0.012               # +1,2 % de punta por moneda
const MAX_COINS := 10
const BOOST_TOP := 37.0
const STAR_TOP := 32.0
const REVERSE_TOP := 7.0
const TURN := 1.85                      # rad/s a toda velocidad
const DRIFT_BASE := 1.3
const DRIFT_STEER := 0.85
const DRIFT_MIN_SPEED := 10.0
const DRIFT_LEVELS: Array[float] = [0.75, 1.55, 2.5]          # azul, naranja, morado (s de derrape)
const DRIFT_BOOST: Array[float] = [0.55, 1.0, 1.45]
const GRAVITY := 30.0
const HOP_V := 3.6
const RAMP_V := 10.5
const FALL_TIME := 1.1
const RESCUE_TIME := 1.4
const INVULN := 1.6
# --- Objetos ---
enum Item { NONE, BANANA, GREEN, RED, MUSHROOM, STAR, BOLT, BLUE }
const ITEM_NAMES := ["", "PLÁTANO", "CAPARAZÓN VERDE", "CAPARAZÓN ROJO", "CHAMPIÑÓN", "ESTRELLA", "RAYO", "CAPARAZÓN AZUL"]
const ROULETTE := 1.3
const BOX_RESPAWN := 2.5
const COIN_RESPAWN := 9.0
const SHELL_SPEED := 46.0
const RED_SPEED := 42.0
const BLUE_SPEED := 52.0
const MUSH_TIME := 1.25
const STAR_TIME := 7.0
const BOLT_TIME := 4.5
const SHRINK := 0.55
enum Obj { BANANA, GREEN, RED, BLUE }

class Kart:
	var id: int = 0
	var idx: int = 0
	var pos: Vector3 = Vector3.ZERO
	var yaw: float = 0.0
	var speed: float = 0.0
	var vy: float = 0.0
	var air: bool = false
	var seg: int = 0
	var s: float = 0.0
	var d: float = 0.0
	var lap: int = 0
	var prog: float = 0.0
	var safe_seg: int = 0
	var safe_d: float = 0.0
	var steer: float = 0.0
	var drift_dir: int = 0
	var drift_t: float = 0.0
	var drift_grace: float = 0.0
	var boost_t: float = 0.0
	var spin_t: float = 0.0
	var star_t: float = 0.0
	var shrink_t: float = 0.0
	var inv_t: float = 0.0
	var item: int = Item.NONE
	var item_n: int = 0
	var roulette_t: float = 0.0
	var coins: int = 0
	var state: int = 0                  # 0 corriendo, 1 cayendo, 2 la nube lo devuelve
	var state_t: float = 0.0
	var finished: bool = false
	var fin_time: float = 0.0
	var place: int = 1
	var trick_ok: bool = false
	var trick_t: float = 0.0
	var trick_done: bool = false
	var wrong_t: float = 0.0
	var wall_cd: float = 0.0
	var falls: int = 0
	var hits: int = 0
	var best_lap: float = 0.0
	var lap_start: float = 0.0
	# Entrada de este paso.
	var press: bool = false
	var press2: bool = false
	var held: int = -1                  # 1 mantiene el derrape, 0 lo soltó, -1 desconocido (bots: alterna)
	# IA
	var skill: float = 1.0
	var bot_rng: RandomNumberGenerator = null
	var bot_steer: float = 0.0
	var bot_brake: bool = false
	var bot_press: bool = false
	var bot_press2: bool = false
	var bot_item_wait: float = 0.0
	var bot_last_item: int = 0
	var bot_line: float = 0.0
	var bot_drift_cd: float = 0.0
	var bot_wobble: float = 0.0
	var bot_wobble_dir: float = 0.0
	var vert: float = 0.0               # arriba (-1) / abajo (+1) de la entrada: frenar y lanzar objetos
	# Presentación
	var dpos: Vector3 = Vector3.ZERO
	var dyaw: float = 0.0
	var dsteer: float = 0.0
	var drift_vis: float = 0.0
	var spin_vis: float = 0.0
	var anim: float = 0.0
	var node: Node3D = null
	var body: Node3D = null
	var wheels: Array[Node3D] = []
	var front_pivots: Array[Node3D] = []
	var sparks: Array[CPUParticles3D] = []
	var flame: Node3D = null
	var shadow: MeshInstance3D = null
	var paint: Array[StandardMaterial3D] = []
	var paint_col: Color = Color.WHITE
	var cloud: Node3D = null
	var star_ring: MeshInstance3D = null

class TrackObj:
	var id: int = 0
	var kind: int = Obj.BANANA
	var pos: Vector3 = Vector3.ZERO
	var vel: Vector3 = Vector3.ZERO
	var seg: int = 0
	var s: float = 0.0
	var life: float = 0.0
	var bounces: int = 0
	var owner: int = -1
	var target: int = -1
	var air: bool = false
	var dive: float = -1.0
	var dead: bool = false
	var node: Node3D = null

const KF := 27                          # floats por kart en el estado
const OF := 8                           # floats por objeto en el estado

var _karts: Dictionary = {}             # player id -> Kart
var _order: Array[int] = []
var _objs: Array[TrackObj] = []
var _obj_ids: int = 0
var _boxes: Array[Vector3] = []         # posición de cada caja de objetos
var _box_t: PackedFloat32Array = PackedFloat32Array()   # > 0: rota (segundos hasta reaparecer)
var _coins: Array[Vector3] = []
var _coin_t: PackedFloat32Array = PackedFloat32Array()
var _held_remote: Dictionary = {}       # player id -> bool (derrape mantenido, llega por texto)
var _held_sent: Dictionary = {}         # (cliente) último valor enviado por cada jugador de este PC
var _t: float = 0.0
var _accum: float = 0.0
var _over: bool = false
var _over_t: float = 0.0
var _first_fin: float = -1.0
var _winner_id: int = -1
var _item_rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _anim: float = 0.0
var _hint_t: float = 7.0
var _flash: float = 0.0
var _msgs: Dictionary = {}              # player id -> {"text", "t", "col"} avisos grandes por jugador
var _shake: Dictionary = {}             # player id -> intensidad
var debug_skill: float = -1.0

# --- Pista (se calcula una vez, es igual en todos los PC) ---
var _tp: PackedVector3Array = PackedVector3Array()      # centro de la pista (con altura)
var _tt: PackedVector3Array = PackedVector3Array()      # tangente horizontal
var _tn: PackedVector3Array = PackedVector3Array()      # normal horizontal (a la DERECHA del sentido de la marcha)
var _tw: PackedFloat32Array = PackedFloat32Array()      # ancho
var _trail: PackedByteArray = PackedByteArray()         # 1 = con barandilla
var _n: int = 0
var _len: float = 0.0
var _ramp_i: Vector2i = Vector2i.ZERO
var _pads: Array = []                   # [índice, lateral]
var _map_pts: PackedVector2Array = PackedVector2Array()
var _map_rect: Rect2 = Rect2()
# Resultado de _locate().
var _li: int = 0
var _lt: float = 0.0
var _ld: float = 0.0
var _lh: float = 0.0

# --- Escena 3D ---
var _world: World3D
var _root3: Node3D
var _host_cont: Control
var _views: Array = []                  # {"cont", "vp", "cam", "id", "rect", "pos", "look", "fov"}
var _built: bool = false
var _box_nodes: Array[Node3D] = []
var _coin_nodes: Array[Node3D] = []
var _pad_mats: Array[StandardMaterial3D] = []
var _spin_nodes: Array[Node3D] = []     # decoración que gira
var _ring_mats: Array[StandardMaterial3D] = []
var _hit_fx: CPUParticles3D = null
var _boom_fx: CPUParticles3D = null
var _box_fx: CPUParticles3D = null
var _mats: Dictionary = {}
var _start_lights: Array[StandardMaterial3D] = []

# ----------------------------------------------------------------------------
# Pista: spline, puntos, búsqueda del punto más cercano
# ----------------------------------------------------------------------------

func _build_track() -> void:
	if _n > 0:
		return
	var ctrl: Array[Vector3] = []
	for c in CTRL:
		ctrl.append(Vector3(float(c[0]) * SCALE, float(c[2]), float(c[1]) * SCALE))
	var dense: Array[Vector3] = []
	var m := ctrl.size()
	for i in m:
		var p0 := ctrl[(i - 1 + m) % m]
		var p1 := ctrl[i]
		var p2 := ctrl[(i + 1) % m]
		var p3 := ctrl[(i + 2) % m]
		for k in 60:
			var t := float(k) / 60.0
			var t2 := t * t
			var t3 := t2 * t
			dense.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
	# Empieza en la línea de salida.
	var best := 0
	var bd := INF
	for i in mini(dense.size(), 400):
		var dd := Vector2(dense[i].x, dense[i].z).distance_to(START_ANCHOR)
		if dd < bd:
			bd = dd
			best = i
	var rot: Array[Vector3] = []
	for i in dense.size():
		rot.append(dense[(best + i) % dense.size()])
	rot.append(rot[0])
	var cum: PackedFloat32Array = PackedFloat32Array([0.0])
	for i in range(1, rot.size()):
		cum.append(cum[i - 1] + rot[i].distance_to(rot[i - 1]))
	_len = cum[cum.size() - 1]
	_n = int(round(_len / SPACING))
	var step := _len / float(_n)
	_tp.resize(_n)
	var j := 0
	for i in _n:
		var s := float(i) * step
		while j < cum.size() - 2 and cum[j + 1] < s:
			j += 1
		var f := (s - cum[j]) / maxf(cum[j + 1] - cum[j], 0.0001)
		_tp[i] = rot[j].lerp(rot[j + 1], f)
	_tt.resize(_n)
	_tn.resize(_n)
	_tw.resize(_n)
	_trail.resize(_n)
	for i in _n:
		var a := _tp[(i - 1 + _n) % _n]
		var b := _tp[(i + 1) % _n]
		var t := Vector3(b.x - a.x, 0.0, b.z - a.z).normalized()
		_tt[i] = t
		_tn[i] = Vector3(-t.z, 0.0, t.x)
		var fr := float(i) / float(_n)
		var w := ROAD_W
		var rail := 1
		for r in RAILLESS:
			if fr >= float(r[0]) and fr <= float(r[1]):
				rail = 0
		# El puente (el tramo alto sin barandilla) es más estrecho, con transición suave.
		var rb: Array = RAILLESS[0]
		var bridge := clampf(minf(fr - float(rb[0]), float(rb[1]) - fr) * _len / 10.0, 0.0, 1.0)
		w = lerpf(ROAD_W, BRIDGE_W, bridge)
		_tw[i] = w
		_trail[i] = rail
	_ramp_i = Vector2i(int(RAMP[0] * _n), int(RAMP[1] * _n))
	_pads.clear()
	for p in PADS:
		_pads.append([int(float(p[0]) * _n), float(p[1])])
	_boxes.clear()
	for fr in BOX_ROWS:
		var i := int(fr * _n)
		for lane in BOX_LANES:
			_boxes.append(_tp[i] + _tn[i] * lane * (_tw[i] / ROAD_W) + Vector3(0, 1.0, 0))
	_coins.clear()
	for cl in COIN_LINES:
		var i0 := int(float(cl[0]) * _n)
		for k in 4:
			var i := (i0 + k * 3) % _n
			_coins.append(_tp[i] + _tn[i] * float(cl[1]) + Vector3(0, 0.75, 0))
	# Minimapa: la pista vista desde arriba, encajada en un cuadrado.
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in _tp:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.z))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.z))
	_map_rect = Rect2(lo, hi - lo)
	_map_pts.clear()
	for i in range(0, _n, 4):
		_map_pts.append(Vector2(_tp[i].x, _tp[i].z))

func _wrap(i: int) -> int:
	return ((i % _n) + _n) % _n

## Punto de la pista más cercano a `p` buscando alrededor de `hint` (así el puente y la recta de abajo no se
## confunden). Deja el resultado en _li (segmento), _lt (fracción), _ld (lateral, + a la derecha) y _lh (altura).
func _locate(p: Vector3, hint: int) -> void:
	var best := INF
	for k in range(hint - SEARCH, hint + SEARCH + 1):
		var i := _wrap(k)
		var a := _tp[i]
		var b := _tp[(i + 1) % _n]
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var ap := Vector2(p.x - a.x, p.z - a.z)
		var t := clampf(ap.dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
		var q := Vector2(a.x, a.z) + ab * t
		var dd := q.distance_squared_to(Vector2(p.x, p.z))
		if dd < best:
			best = dd
			_li = i
			_lt = t
	var i2 := (_li + 1) % _n
	var c := _tp[_li].lerp(_tp[i2], _lt)
	var nrm := _tn[_li].lerp(_tn[i2], _lt).normalized()
	_ld = (p - c).dot(nrm)
	_lh = c.y

func _width_at(i: int) -> float:
	return _tw[_wrap(i)]

## Altura del suelo en el punto localizado (incluye la rampa).
func _ground() -> float:
	var h := _lh
	if _li >= _ramp_i.x and _li < _ramp_i.y and absf(_ld) < _tw[_li] * 0.5:
		h += RAMP_H * (float(_li - _ramp_i.x) + _lt) / float(_ramp_i.y - _ramp_i.x)
	return h

func _s_of(i: int, t: float) -> float:
	return (float(i) + t) * (_len / float(_n))

func _point(i: int, lateral: float = 0.0) -> Vector3:
	var w := _wrap(i)
	return _tp[w] + _tn[w] * lateral

func _fwd(yaw: float) -> Vector3:
	return Vector3(sin(yaw), 0.0, cos(yaw))

func _yaw_of(v: Vector3) -> float:
	return atan2(v.x, v.z)

func _player_by_id(id: int) -> PlayerData:
	for pl in players:
		if pl.id == id:
			return pl
	return null

func _audible(k: Kart) -> bool:
	var pl := _player_by_id(k.id)
	return pl != null and is_audible(pl)

func _is_human(id: int) -> bool:
	var pl := _player_by_id(id)
	return pl != null and not pl.is_bot

# ----------------------------------------------------------------------------
# Preparación
# ----------------------------------------------------------------------------

func _make_kart(p: PlayerData, slot: int) -> Kart:
	var k := Kart.new()
	k.id = p.id
	k.idx = slot
	# Parrilla: de dos en dos, al tresbolillo, detrás de la línea de salida.
	var row := slot / 2
	var side := -1.0 if slot % 2 == 0 else 1.0
	var back := 6.0 + float(row) * 6.0 + (2.5 if side > 0.0 else 0.0)
	var i := _wrap(-int(round(back / (_len / float(_n)))))
	k.pos = _point(i, side * 3.4)
	k.yaw = _yaw_of(_tt[i])
	k.seg = i
	k.safe_seg = i
	k.s = _s_of(i, 0.0)
	k.prog = k.s - _len
	k.lap = 0
	k.dpos = k.pos
	k.dyaw = k.yaw
	k.bot_rng = RandomNumberGenerator.new()
	k.bot_rng.seed = hash([seed_value, p.id, "kart"])
	k.skill = 0.74 + 0.26 * k.bot_rng.randf()
	return k

func _setup_karts() -> void:
	for old in _karts.values():
		_free_kart_nodes(old as Kart)
	_karts.clear()
	_order.clear()
	# Orden de salida al azar (con la semilla común).
	var ids: Array[int] = []
	for p in players:
		ids.append(p.id)
	var r := RandomNumberGenerator.new()
	r.seed = hash([seed_value, "grid"])
	for i in range(ids.size() - 1, 0, -1):
		var j := r.randi() % (i + 1)
		var tmp := ids[i]
		ids[i] = ids[j]
		ids[j] = tmp
	for slot in ids.size():
		var p := _player_by_id(ids[slot])
		_karts[p.id] = _make_kart(p, slot)
	for p in players:
		_order.append(p.id)
	_update_places()

func _free_kart_nodes(k: Kart) -> void:
	for n in [k.node, k.shadow, k.cloud]:
		if n != null and is_instance_valid(n):
			(n as Node).queue_free()
	k.node = null
	k.shadow = null
	k.cloud = null

func _reset_race() -> void:
	for o in _objs:
		if o.node != null and is_instance_valid(o.node):
			o.node.queue_free()
	_objs.clear()
	_obj_ids = 0
	_box_t = PackedFloat32Array()
	_box_t.resize(_boxes.size())
	_coin_t = PackedFloat32Array()
	_coin_t.resize(_coins.size())
	_item_rng.seed = hash([seed_value, "items"])
	_held_remote.clear()
	_t = 0.0
	_accum = 0.0
	_over = false
	_over_t = 0.0
	_first_fin = -1.0
	_winner_id = -1
	_hint_t = 7.0
	_msgs.clear()

func _on_prepare() -> void:
	_build_track()
	_reset_race()
	_setup_karts()
	_build_world()
	surface.draw_callback = _draw_hud
	_snap_cameras()

func _on_start() -> void:
	_build_track()
	_reset_race()
	_setup_karts()
	_rebuild_kart_nodes()
	_snap_cameras()

# ----------------------------------------------------------------------------
# Simulación (solo host)
# ----------------------------------------------------------------------------

func _simulate(delta: float) -> void:
	if _over:
		_over_t += delta
		_accum += delta
		while _accum >= STEP:
			_accum -= STEP
			_step_world(STEP, true)
		if _over_t >= DONE_DELAY:
			finish(_ranking_ids())
		return
	for pl in players:
		var k: Kart = _karts[pl.id]
		var mv := move_input(pl)
		k.steer = clampf(mv.x, -1.0, 1.0)
		k.bot_brake = mv.y > 0.5
		k.vert = mv.y
		if action_presses(pl) > 0:
			k.press = true
		if action2_presses(pl) > 0:
			k.press2 = true
		if InputManager.is_simulated(pl.id):
			k.held = -1
		elif pl.is_remote:
			k.held = 1 if bool(_held_remote.get(pl.id, false)) else 0
		else:
			k.held = 1 if action_held(pl) else 0
	_accum += delta
	var steps := 0
	while _accum >= STEP and steps < 12:
		_accum -= STEP
		steps += 1
		_t += STEP
		_step_world(STEP, false)
	_check_end()

func _step_world(dt: float, ended: bool) -> void:
	for i in _box_t.size():
		if _box_t[i] > 0.0:
			_box_t[i] = maxf(0.0, _box_t[i] - dt)
	for i in _coin_t.size():
		if _coin_t[i] > 0.0:
			_coin_t[i] = maxf(0.0, _coin_t[i] - dt)
	for id in _order:
		var k: Kart = _karts[id]
		if ended or k.finished:
			# Tras la meta (o al acabar) el kart sigue solo, sin objetos.
			k.steer = _auto_steer(k)
			k.press = false
			k.press2 = false
			k.bot_brake = false
			k.vert = 0.0
			k.held = -1
		_kart_step(k, dt)
		k.press = false
		k.press2 = false
	_kart_collisions()
	_objects_step(dt)
	_update_places()

func _check_end() -> void:
	var all_done := true
	var humans := 0
	var humans_done := 0
	for id in _order:
		var k: Kart = _karts[id]
		if not k.finished:
			all_done = false
		if _is_human(id):
			humans += 1
			if k.finished:
				humans_done += 1
	var end := all_done or (humans > 0 and humans_done == humans) or _t >= TIME_LIMIT
	if _first_fin >= 0.0 and _t - _first_fin >= AFTER_FIRST:
		end = true
	if end:
		_over = true
		_over_t = 0.0
		var rk := _ranking_ids()
		_winner_id = rk[0] if not rk.is_empty() else -1
		send_event("over", {"w": _winner_id})
		DevCli.log_event("rainbow_kart over winner=%d t=%.1f" % [_winner_id, _t])

func _top_speed(k: Kart) -> float:
	var top := TOP * (1.0 + COIN_BONUS * float(k.coins))
	if k.shrink_t > 0.0:
		top *= 0.7
	if k.star_t > 0.0:
		top = maxf(top, STAR_TOP)
	if k.boost_t > 0.0:
		top = maxf(top, BOOST_TOP * (0.8 if k.shrink_t > 0.0 else 1.0))
	if k.drift_dir != 0:
		top *= 0.975
	# Un poco de ayuda a los bots rezagados (y un freno suave al que va muy escapado), como en los juegos de karts.
	var pl := _player_by_id(k.id)
	if pl != null and pl.is_bot and not k.finished:
		var lead := _leader_prog()
		if lead - k.prog > 60.0:
			top *= 1.05
	return top

func _leader_prog() -> float:
	var best := -INF
	for id in _order:
		best = maxf(best, (_karts[id] as Kart).prog)
	return best

func _kart_step(k: Kart, dt: float) -> void:
	k.inv_t = maxf(0.0, k.inv_t - dt)
	k.boost_t = maxf(0.0, k.boost_t - dt)
	k.star_t = maxf(0.0, k.star_t - dt)
	k.shrink_t = maxf(0.0, k.shrink_t - dt)
	k.wall_cd = maxf(0.0, k.wall_cd - dt)
	k.trick_t = maxf(0.0, k.trick_t - dt)
	if k.roulette_t > 0.0:
		k.roulette_t -= dt
		if k.roulette_t <= 0.0:
			k.roulette_t = 0.0
			send_event("got", {"p": k.id, "i": k.item, "n": k.item_n})
	# --- Caída y rescate ---
	if k.state == 1:
		k.state_t += dt
		k.vy -= GRAVITY * dt
		k.pos += _fwd(k.yaw) * k.speed * dt + Vector3(0, k.vy * dt, 0)
		k.speed = move_toward(k.speed, 0.0, 8.0 * dt)
		if k.state_t >= FALL_TIME:
			k.state = 2
			k.state_t = 0.0
			k.seg = k.safe_seg
			k.d = clampf(k.safe_d, -3.0, 3.0)
			k.pos = _point(k.seg, k.d) + Vector3(0, 5.0, 0)
			k.yaw = _yaw_of(_tt[k.seg])
			k.speed = 0.0
			k.vy = 0.0
		return
	if k.state == 2:
		k.state_t += dt
		var base := _point(k.seg, k.d)
		k.pos = base + Vector3(0, 5.0 * (1.0 - clampf(k.state_t / (RESCUE_TIME * 0.8), 0.0, 1.0)), 0)
		if k.state_t >= RESCUE_TIME:
			k.state = 0
			k.state_t = 0.0
			k.pos = base
			k.air = false
			k.inv_t = INVULN
		return
	# --- Velocidad ---
	var top := _top_speed(k)
	if k.spin_t > 0.0:
		k.spin_t = maxf(0.0, k.spin_t - dt)
		k.speed = move_toward(k.speed, 0.0, 34.0 * dt)
	elif k.bot_brake and not k.finished:
		if k.speed > 0.5:
			k.speed = move_toward(k.speed, 0.0, 32.0 * dt)
		else:
			k.speed = move_toward(k.speed, -REVERSE_TOP, 10.0 * dt)
	else:
		if k.boost_t > 0.0:
			k.speed = move_toward(k.speed, top, 70.0 * dt)
		elif k.speed < top:
			var acc := lerpf(17.0, 4.0, clampf(k.speed / top, 0.0, 1.0))
			k.speed = minf(top, k.speed + acc * dt)
		else:
			k.speed = move_toward(k.speed, top, 9.0 * dt)
	# --- Botón de acción: salto/derrape en el suelo, acrobacia en el aire ---
	if k.press and k.spin_t <= 0.0:
		if k.air:
			if k.trick_ok and not k.trick_done:
				k.trick_done = true
				k.trick_t = 0.5
				send_event("trick", {"p": k.id})
		elif k.drift_dir != 0 and k.held < 0:
			_end_drift(k)                 # bots: segunda pulsación = soltar
		elif k.drift_dir == 0:
			k.vy = HOP_V
			k.air = true
			if absf(k.steer) > 0.25 and k.speed > DRIFT_MIN_SPEED:
				k.drift_dir = 1 if k.steer > 0.0 else -1
				k.drift_t = 0.0
				k.drift_grace = 0.3
	# --- Derrape ---
	if k.drift_dir != 0:
		k.drift_grace = maxf(0.0, k.drift_grace - dt)
		if k.spin_t > 0.0 or k.speed < DRIFT_MIN_SPEED * 0.6:
			k.drift_dir = 0
			k.drift_t = 0.0
		elif k.held == 0 and k.drift_grace <= 0.0:
			_end_drift(k)
		elif not k.air:
			var inward := k.steer * float(k.drift_dir)
			k.drift_t += dt * (0.8 + 0.5 * maxf(inward, 0.0))
	# --- Giro ---
	var spd_f := clampf(absf(k.speed) / 9.0, 0.0, 1.0) * (1.0 - 0.22 * clampf(absf(k.speed) / BOOST_TOP, 0.0, 1.0))
	var rate := 0.0
	if k.spin_t > 0.0:
		rate = 0.0
	elif k.drift_dir != 0:
		var inward2 := k.steer * float(k.drift_dir)
		rate = float(k.drift_dir) * (DRIFT_BASE + DRIFT_STEER * inward2) * clampf(absf(k.speed) / 12.0, 0.4, 1.0)
	else:
		rate = k.steer * TURN * spd_f * (1.0 if k.speed >= 0.0 else -1.0)
		if k.air:
			rate *= 0.5
	k.yaw -= rate * dt                  # girar a la derecha (steer > 0) baja el ángulo
	# --- Movimiento ---
	var fwd := _fwd(k.yaw)
	k.pos += fwd * k.speed * dt
	_locate(k.pos, k.seg)
	k.seg = _li
	k.d = _ld
	var w := _tw[_li]
	var g := _ground()
	var on_road := absf(_ld) <= w * 0.5 + 0.2
	if k.air:
		k.vy -= GRAVITY * dt
		k.pos.y += k.vy * dt
		if on_road and k.pos.y <= g:
			k.pos.y = g
			k.air = false
			k.vy = 0.0
			if k.trick_done:
				_give_boost(k, 0.6, "trick")
			k.trick_ok = false
			k.trick_done = false
		elif not on_road and k.pos.y < g - 2.0:
			_start_fall(k)
			return
	else:
		if on_road:
			# Salto al final de la rampa.
			if _li == _ramp_i.y - 1 and _lt > 0.5 and k.speed > 12.0 and absf(_ld) < w * 0.5:
				k.air = true
				k.vy = RAMP_V * clampf(k.speed / TOP, 0.6, 1.2)
				k.trick_ok = true
				k.trick_done = false
				k.pos.y = g
				send_event("jump", {"p": k.id})
			else:
				k.pos.y = g
		else:
			k.air = true
			k.vy = 0.0
	# --- Bordes: barandilla o caída ---
	var lim := w * 0.5 - KART_R * (SHRINK if k.shrink_t > 0.0 else 1.0)
	if absf(_ld) > lim:
		if _trail[_li] == 1:
			var over := absf(_ld) - lim
			k.pos -= _tn[_li] * signf(_ld) * over
			k.d = signf(_ld) * lim
			var tang := _tt[_li]
			var along := fwd.dot(tang)
			var into := absf(fwd.dot(_tn[_li]))
			# El golpe frena según lo de frente que llegues; rozar la barandilla, poco.
			if k.wall_cd <= 0.0:
				k.speed *= 1.0 - clampf(into * 1.0, 0.05, 0.6)
			else:
				k.speed *= 1.0 - into * 0.04
			var ty := _yaw_of(tang if along >= 0.0 else -tang)
			k.yaw = lerp_angle(k.yaw, ty, 0.35)
			if k.wall_cd <= 0.0 and into > 0.25:
				k.wall_cd = 0.4
				send_event("wall", {"p": k.id})
		elif absf(_ld) > w * 0.5 + 0.6:
			if not k.air or k.pos.y < g - 0.5:
				_start_fall(k)
				return
	# --- Punto seguro, vueltas y progreso ---
	if not k.air and absf(_ld) < w * 0.5 - 2.5 and k.state == 0:
		k.safe_seg = _li
		k.safe_d = _ld
	var s := _s_of(_li, _lt)
	if k.s > _len * 0.75 and s < _len * 0.25:
		k.lap += 1
		if k.lap >= 2:
			var lt := _t - k.lap_start
			if k.best_lap <= 0.0 or lt < k.best_lap:
				k.best_lap = lt
		k.lap_start = _t
		if k.lap > LAPS and not k.finished:
			k.finished = true
			k.fin_time = _t
			if _first_fin < 0.0:
				_first_fin = _t
			_drop_item(k)
			_update_places()
			send_event("fin", {"p": k.id, "pl": k.place})
		elif k.lap >= 2 and not k.finished:
			send_event("lap", {"p": k.id, "l": k.lap})
	elif k.s < _len * 0.25 and s > _len * 0.75:
		k.lap -= 1
	k.s = s
	if not k.finished:
		k.prog = float(k.lap - 1) * _len + s
	# Sentido contrario.
	if fwd.dot(_tt[_li]) < -0.35 and k.speed > 3.0:
		k.wrong_t += dt
	else:
		k.wrong_t = 0.0
	if not k.air:
		_pickups(k)
	# --- Objeto ---
	if k.press2 and k.item != Item.NONE and k.roulette_t <= 0.0 and k.spin_t <= 0.0:
		_use_item(k)

func _end_drift(k: Kart) -> void:
	var lvl := _drift_level(k)
	k.drift_dir = 0
	k.drift_t = 0.0
	if lvl > 0:
		_give_boost(k, DRIFT_BOOST[lvl - 1], "drift%d" % lvl)

func _drift_level(k: Kart) -> int:
	if k.drift_dir == 0:
		return 0
	var lvl := 0
	for i in DRIFT_LEVELS.size():
		if k.drift_t >= DRIFT_LEVELS[i]:
			lvl = i + 1
	return lvl

func _give_boost(k: Kart, secs: float, kind: String) -> void:
	k.boost_t = maxf(k.boost_t, secs)
	send_event("boost", {"p": k.id, "k": kind})

func _start_fall(k: Kart) -> void:
	k.state = 1
	k.state_t = 0.0
	k.air = true
	k.drift_dir = 0
	k.drift_t = 0.0
	k.boost_t = 0.0
	k.falls += 1
	var lost := mini(k.coins, 2)
	k.coins -= lost
	send_event("fall", {"p": k.id})

## Dirección automática hacia la línea central (tras la meta, o con la carrera ya acabada).
func _auto_steer(k: Kart) -> float:
	var ahead := _point(k.seg + 10 + int(absf(k.speed) * 0.3), 0.0)
	var want := _yaw_of(ahead - k.pos)
	var err := wrapf(want - k.yaw, -PI, PI)
	return clampf(-err * 2.2, -1.0, 1.0)

func _pickups(k: Kart) -> void:
	var rr := 1.6 * (SHRINK if k.shrink_t > 0.0 else 1.0) + 0.6
	for i in _boxes.size():
		if _box_t[i] > 0.0:
			continue
		if k.pos.distance_squared_to(_boxes[i] - Vector3(0, 0.6, 0)) < rr * rr:
			_box_t[i] = BOX_RESPAWN
			send_event("box", {"p": k.id, "b": i})
			if k.item == Item.NONE and k.roulette_t <= 0.0 and not k.finished:
				k.item = _roll_item(k)
				k.item_n = 3 if k.item == Item.MUSHROOM and _item_rng.randf() < _triple_chance(k) else 1
				k.roulette_t = ROULETTE
	for i in _coins.size():
		if _coin_t[i] > 0.0:
			continue
		if k.pos.distance_squared_to(_coins[i] - Vector3(0, 0.5, 0)) < rr * rr:
			_coin_t[i] = COIN_RESPAWN
			if k.coins < MAX_COINS:
				k.coins += 1
			send_event("coin", {"p": k.id, "c": i})

func _place_frac(k: Kart) -> float:
	var n := _order.size()
	if n <= 1:
		return 0.0
	return float(k.place - 1) / float(n - 1)

func _triple_chance(k: Kart) -> float:
	return clampf(_place_frac(k) * 0.8, 0.0, 0.7)

## Objeto según el puesto: los primeros reciben defensas, los últimos lo bueno.
func _roll_item(k: Kart) -> int:
	var f := _place_frac(k)
	var n := _order.size()
	var w := {
		Item.BANANA: lerpf(36.0, 4.0, f),
		Item.GREEN: lerpf(34.0, 10.0, f),
		Item.RED: lerpf(10.0, 22.0, f) if n > 2 else 0.0,
		Item.MUSHROOM: lerpf(14.0, 30.0, f),
		Item.STAR: lerpf(0.0, 18.0, f * f),
		Item.BOLT: (lerpf(0.0, 9.0, maxf(f - 0.5, 0.0) * 2.0)) if n >= 3 else 0.0,
		Item.BLUE: (6.0 if f > 0.35 and f < 0.95 else 0.0) if n >= 4 else 0.0,
	}
	var total := 0.0
	for key in w:
		total += float(w[key])
	var r := _item_rng.randf() * total
	for key in w:
		r -= float(w[key])
		if r <= 0.0:
			return int(key)
	return Item.BANANA

func _drop_item(k: Kart) -> void:
	k.item = Item.NONE
	k.item_n = 0
	k.roulette_t = 0.0

func _use_item(k: Kart) -> void:
	var fwd := _fwd(k.yaw)
	var back := k.vert > 0.5
	var front := k.vert < -0.5
	var used := k.item
	match k.item:
		Item.BANANA:
			if front:
				var o := _spawn_obj(Obj.BANANA, k, k.pos + fwd * 2.4 + Vector3(0, 1.2, 0))
				o.vel = fwd * maxf(k.speed, 0.0) * 0.6 + fwd * 16.0 + Vector3(0, 7.0, 0)
				o.air = true
			else:
				_spawn_obj(Obj.BANANA, k, k.pos - fwd * 2.4 + Vector3(0, 0.3, 0))
		Item.GREEN:
			var dir := -fwd if back else fwd
			var o2 := _spawn_obj(Obj.GREEN, k, k.pos + dir * 2.6 + Vector3(0, 0.45, 0))
			o2.vel = dir * SHELL_SPEED
		Item.RED:
			if back:
				var o3 := _spawn_obj(Obj.GREEN, k, k.pos - fwd * 2.6 + Vector3(0, 0.45, 0))
				o3.vel = -fwd * SHELL_SPEED
				o3.kind = Obj.RED
				o3.target = -1
			else:
				var o4 := _spawn_obj(Obj.RED, k, k.pos + fwd * 2.6 + Vector3(0, 0.45, 0))
				o4.vel = fwd * RED_SPEED
				o4.target = _kart_ahead(k)
		Item.MUSHROOM:
			_give_boost(k, MUSH_TIME, "mush")
		Item.STAR:
			k.star_t = STAR_TIME
			k.spin_t = 0.0
		Item.BOLT:
			for id in _order:
				var o5: Kart = _karts[id]
				if o5 == k or o5.star_t > 0.0 or o5.finished:
					continue
				o5.shrink_t = BOLT_TIME + 0.5 * float(o5.place - 1) / maxf(_order.size() - 1, 1.0)
				o5.spin_t = maxf(o5.spin_t, 0.6)
				o5.drift_dir = 0
				_drop_item(o5)
		Item.BLUE:
			var o6 := _spawn_obj(Obj.BLUE, k, k.pos + Vector3(0, 4.0, 0))
			o6.s = k.prog
			o6.target = _leader_id()
	send_event("use", {"p": k.id, "i": used})
	k.item_n -= 1
	if k.item_n <= 0:
		_drop_item(k)

func _leader_id() -> int:
	for id in _order:
		if (_karts[id] as Kart).place == 1:
			return id
	return -1

## El kart que va justo delante (por puesto). -1 si eres el primero.
func _kart_ahead(k: Kart) -> int:
	for id in _order:
		if (_karts[id] as Kart).place == k.place - 1:
			return id
	return -1

func _spawn_obj(kind: int, owner: Kart, at: Vector3) -> TrackObj:
	var o := TrackObj.new()
	_obj_ids += 1
	o.id = _obj_ids
	o.kind = kind
	o.pos = at
	o.owner = owner.id
	o.seg = owner.seg
	_objs.append(o)
	return o

# ----------------------------------------------------------------------------
# Choques entre karts y con objetos
# ----------------------------------------------------------------------------

func _kart_collisions() -> void:
	for a in _order.size():
		var ka: Kart = _karts[_order[a]]
		if ka.state != 0:
			continue
		for b in range(a + 1, _order.size()):
			var kb: Kart = _karts[_order[b]]
			if kb.state != 0:
				continue
			var ra := KART_R * (SHRINK if ka.shrink_t > 0.0 else 1.0)
			var rb := KART_R * (SHRINK if kb.shrink_t > 0.0 else 1.0)
			var dv := Vector3(kb.pos.x - ka.pos.x, 0.0, kb.pos.z - ka.pos.z)
			if absf(kb.pos.y - ka.pos.y) > 1.6:
				continue
			var dist := dv.length()
			if dist >= ra + rb or dist < 0.0001:
				continue
			var nrm := dv / dist
			var push := (ra + rb - dist) * 0.5
			# El grande (o el de la estrella) empuja más.
			var wa := (0.5 if ka.shrink_t > 0.0 else 1.0) * (3.0 if ka.star_t > 0.0 else 1.0)
			var wb := (0.5 if kb.shrink_t > 0.0 else 1.0) * (3.0 if kb.star_t > 0.0 else 1.0)
			ka.pos -= nrm * push * 2.0 * wb / (wa + wb)
			kb.pos += nrm * push * 2.0 * wa / (wa + wb)
			if ka.star_t > 0.0 and kb.star_t <= 0.0:
				_hit(kb, "star", ka.id)
			elif kb.star_t > 0.0 and ka.star_t <= 0.0:
				_hit(ka, "star", kb.id)
			elif ka.shrink_t > 0.0 and kb.shrink_t <= 0.0:
				_hit(ka, "squash", kb.id)
			elif kb.shrink_t > 0.0 and ka.shrink_t <= 0.0:
				_hit(kb, "squash", ka.id)
			else:
				var avg := (ka.speed + kb.speed) * 0.5
				ka.speed = lerpf(ka.speed, avg, 0.2)
				kb.speed = lerpf(kb.speed, avg, 0.2)

## Golpe a un kart: trompo (plátano), vuelta de campana (caparazón, explosión) o aplastado.
func _hit(k: Kart, kind: String, by: int = -1) -> bool:
	if k.state != 0 or k.finished:
		return false
	if k.star_t > 0.0 or (k.inv_t > 0.0 and kind != "blue"):
		return false
	var heavy := kind in ["green", "red", "blue", "star"]
	k.spin_t = 2.0 if kind == "blue" else (1.25 if heavy else 1.0)
	k.speed *= 0.25 if heavy else 0.4
	if heavy:
		k.vy = 7.0 if kind == "blue" else 4.5
		k.air = true
	k.drift_dir = 0
	k.drift_t = 0.0
	k.boost_t = 0.0
	k.inv_t = k.spin_t + 0.8
	k.hits += 1
	var lost := mini(k.coins, 3)
	k.coins -= lost
	send_event("hit", {"p": k.id, "k": kind, "by": by, "x": k.pos.x, "y": k.pos.y, "z": k.pos.z})
	return true

func _objects_step(dt: float) -> void:
	for o in _objs:
		if o.dead:
			continue
		o.life += dt
		match o.kind:
			Obj.BANANA:
				if o.air:
					o.vel.y -= GRAVITY * dt
					o.pos += o.vel * dt
					_locate(o.pos, o.seg)
					o.seg = _li
					var g := _ground() + 0.3
					if o.pos.y <= g:
						if absf(_ld) <= _tw[_li] * 0.5:
							o.pos.y = g
							o.air = false
							o.vel = Vector3.ZERO
						elif o.pos.y < g - 6.0:
							o.dead = true
			Obj.GREEN, Obj.RED:
				_shell_step(o, dt)
			Obj.BLUE:
				_blue_step(o, dt)
	# Objetos contra karts.
	for o in _objs:
		if o.dead or o.kind == Obj.BLUE:
			continue
		for id in _order:
			var k: Kart = _karts[id]
			if k.state != 0:
				continue
			if k.id == o.owner and o.life < 0.35:
				continue
			var rr := KART_R * (SHRINK if k.shrink_t > 0.0 else 1.0) + (0.5 if o.kind == Obj.BANANA else 0.55)
			if k.pos.distance_squared_to(o.pos - Vector3(0, 0.4, 0)) < rr * rr:
				o.dead = true
				var kind := "banana" if o.kind == Obj.BANANA else ("red" if o.kind == Obj.RED else "green")
				if not _hit(k, kind, o.owner) and k.star_t > 0.0:
					send_event("pop", {"x": o.pos.x, "y": o.pos.y, "z": o.pos.z})
				break
	# Objetos entre sí (un caparazón rompe un plátano o a otro caparazón).
	for i in _objs.size():
		var a := _objs[i]
		if a.dead or a.kind == Obj.BLUE:
			continue
		for j in range(i + 1, _objs.size()):
			var b := _objs[j]
			if b.dead or b.kind == Obj.BLUE:
				continue
			if a.kind == Obj.BANANA and b.kind == Obj.BANANA:
				continue
			if a.pos.distance_squared_to(b.pos) < 1.3:
				a.dead = true
				b.dead = true
				send_event("pop", {"x": a.pos.x, "y": a.pos.y, "z": a.pos.z})
				break
	var keep: Array[TrackObj] = []
	for o in _objs:
		if o.dead or (o.kind != Obj.BANANA and o.life > (9.0 if o.kind == Obj.BLUE else 7.0)):
			if o.node != null and is_instance_valid(o.node):
				o.node.queue_free()
		else:
			keep.append(o)
	# Como mucho 24 objetos en pista: se van los plátanos más viejos.
	while keep.size() > 24:
		var old: TrackObj = keep.pop_front()
		if old.node != null and is_instance_valid(old.node):
			old.node.queue_free()
	_objs = keep

func _shell_step(o: TrackObj, dt: float) -> void:
	var spd := o.vel.length()
	if o.kind == Obj.RED and o.target >= 0 and _karts.has(o.target):
		var tk: Kart = _karts[o.target]
		var aim: Vector3
		if tk.state == 0 and tk.pos.distance_to(o.pos) < 32.0:
			aim = tk.pos
		else:
			# Sigue la pista hacia el objetivo.
			aim = _point(o.seg + 12, clampf(tk.d, -4.0, 4.0))
		var want := Vector3(aim.x - o.pos.x, 0.0, aim.z - o.pos.z).normalized()
		var cur := Vector3(o.vel.x, 0.0, o.vel.z).normalized()
		var ang := cur.signed_angle_to(want, Vector3.UP)
		cur = cur.rotated(Vector3.UP, clampf(ang, -5.0 * dt, 5.0 * dt))
		o.vel = cur * spd
	o.pos += Vector3(o.vel.x, 0.0, o.vel.z) * dt
	_locate(o.pos, o.seg)
	o.seg = _li
	var w := _tw[_li]
	o.pos.y = _ground() + 0.45
	if absf(_ld) > w * 0.5 - 0.5:
		if _trail[_li] == 1:
			var nrm := _tn[_li] * signf(_ld)
			o.pos -= nrm * (absf(_ld) - (w * 0.5 - 0.5))
			var vn := o.vel.dot(nrm)
			if vn > 0.0:
				o.vel -= nrm * vn * 2.0
				o.bounces += 1
				if o.kind == Obj.GREEN and o.bounces > 5:
					o.dead = true
		elif absf(_ld) > w * 0.5 + 0.5:
			o.dead = true

func _blue_step(o: TrackObj, dt: float) -> void:
	if not _karts.has(o.target) or (_karts[o.target] as Kart).finished:
		o.target = _leader_id()
	if o.target < 0:
		o.dead = true
		return
	var tk: Kart = _karts[o.target]
	if o.dive < 0.0:
		o.s += BLUE_SPEED * dt
		var ss := fposmod(o.s, _len)
		var i := int(ss / (_len / float(_n)))
		o.seg = i
		o.pos = _point(i, 0.0) + Vector3(0, 5.0, 0)
		if tk.prog - o.s < 8.0:
			o.dive = 0.0
	else:
		o.dive += dt
		var to := tk.pos + Vector3(0, 0.6, 0)
		o.pos = o.pos.lerp(to, clampf(o.dive * 4.0, 0.0, 1.0))
		if o.dive >= 0.45:
			o.dead = true
			send_event("boom", {"x": o.pos.x, "y": o.pos.y, "z": o.pos.z})
			for id in _order:
				var k: Kart = _karts[id]
				if k.pos.distance_to(o.pos) < 6.5:
					_hit(k, "blue", o.owner)

func _update_places() -> void:
	var rk := _ranking_ids()
	for i in rk.size():
		(_karts[rk[i]] as Kart).place = i + 1

## Los que acabaron, por tiempo; luego el resto, por progreso.
func _ranking_ids() -> Array[int]:
	var ids: Array[int] = _order.duplicate()
	ids.sort_custom(func(a: int, b: int) -> bool:
		var ka: Kart = _karts[a]
		var kb: Kart = _karts[b]
		if ka.finished != kb.finished:
			return ka.finished
		if ka.finished:
			if not is_equal_approx(ka.fin_time, kb.fin_time):
				return ka.fin_time < kb.fin_time
			return a < b
		if not is_equal_approx(ka.prog, kb.prog):
			return ka.prog > kb.prog
		return a < b)
	return ids

# ----------------------------------------------------------------------------
# IA (bots, autopiloto y práctica): sigue una trazada por dentro de las curvas, coge cajas, esquiva plátanos,
# derrapa en las curvas largas y usa los objetos con cabeza
# ----------------------------------------------------------------------------

func _bot_think(k: Kart) -> void:
	k.bot_press = false
	k.bot_press2 = false
	k.bot_brake = false
	k.vert = 0.0
	if k.state != 0 or not is_running or _over or k.finished:
		k.bot_steer = 0.0
		return
	var sk := k.skill if debug_skill < 0.0 else debug_skill
	var dt := STEP
	k.bot_drift_cd = maxf(0.0, k.bot_drift_cd - dt)
	var spd := maxf(k.speed, 6.0)
	var la := k.seg + 5 + int(spd * 0.42)
	var t_a := _tt[_wrap(k.seg + 4)]
	var t_b := _tt[_wrap(k.seg + 30)]
	var bend := t_a.signed_angle_to(t_b, Vector3.UP)
	var half := _width_at(la) * 0.5
	var margin := 3.0 if _trail[_wrap(la)] == 1 else 4.6
	# Trazada: por dentro de la curva que viene.
	var inside := signf((t_b - t_a).dot(_tn[_wrap(la)]))
	var off := inside * clampf(absf(bend) * 9.0, 0.0, half - margin) * (0.55 + 0.45 * sk)
	# Sin objeto: a por la caja más a mano de la próxima fila.
	if k.item == Item.NONE and k.roulette_t <= 0.0:
		var best := INF
		for row in BOX_ROWS.size():
			var ri := int(BOX_ROWS[row] * _n)
			var ahead := _wrap(ri - k.seg)
			if ahead < 6 or ahead > 45:
				continue
			for lane in BOX_LANES.size():
				var bi := row * BOX_LANES.size() + lane
				if _box_t[bi] > 0.0:
					continue
				var lat: float = BOX_LANES[lane] * (_tw[ri] / ROAD_W)
				var cost := absf(lat - k.d)
				if cost < best:
					best = cost
					off = lat
	# Esquivar plátanos (y caparazones parados) que tenga delante.
	for o in _objs:
		if o.kind != Obj.BANANA or o.air:
			continue
		var ahead2 := _wrap(o.seg - k.seg)
		if ahead2 < 2 or ahead2 > 26:
			continue
		var od := (o.pos - _point(o.seg)).dot(_tn[o.seg])
		if absf(od - off) < 2.4:
			off = od + (3.2 if off >= od else -3.2)
	off = clampf(off, -(half - margin * 0.7), half - margin * 0.7)
	k.bot_line = lerpf(k.bot_line, off, 0.08)
	var target := _point(la, k.bot_line)
	var err := wrapf(_yaw_of(target - k.pos) - k.yaw, -PI, PI)
	var steer := clampf(-err * 2.4, -1.0, 1.0)
	if k.drift_dir != 0:
		var f := clampf(absf(k.speed) / 12.0, 0.4, 1.0)
		var need := -err * 3.0
		var inward := clampf((need / (float(k.drift_dir) * f) - DRIFT_BASE) / DRIFT_STEER, -1.0, 1.0)
		steer = inward * float(k.drift_dir)
		# Suelta el derrape al acabar la curva, si se abre demasiado o con el turbo morado.
		if absf(bend) < 0.22 or (absf(err) > 0.55 and signf(-err) != float(k.drift_dir)) or k.drift_t > DRIFT_LEVELS[2] + 0.2:
			k.bot_press = true
	elif not k.air and k.speed > 17.0 and absf(bend) > 0.55 and k.bot_drift_cd <= 0.0:
		k.bot_drift_cd = 1.2
		if k.bot_rng.randf() < 0.35 + 0.6 * sk:
			k.bot_press = true
			steer = -signf(bend)
	# Despistes de los bots menos hábiles.
	if k.bot_wobble > 0.0:
		k.bot_wobble -= dt
		steer = clampf(steer + k.bot_wobble_dir, -1.0, 1.0)
	elif k.bot_rng.randf() < (1.0 - sk) * 0.006:
		k.bot_wobble = k.bot_rng.randf_range(0.2, 0.5)
		k.bot_wobble_dir = k.bot_rng.randf_range(-0.9, 0.9)
	if absf(err) > 1.15 and k.speed > 14.0 and k.drift_dir == 0:
		k.bot_brake = true
	# Acrobacia en el aire tras la rampa.
	if k.air and k.trick_ok and not k.trick_done and k.bot_rng.randf() < 0.1 * sk:
		k.bot_press = true
	k.bot_steer = steer
	_bot_items(k, bend, sk)

func _bot_items(k: Kart, bend: float, sk: float) -> void:
	if k.item == Item.NONE or k.roulette_t > 0.0:
		k.bot_last_item = Item.NONE
		return
	if k.bot_last_item != k.item:
		k.bot_last_item = k.item
		k.bot_item_wait = k.bot_rng.randf_range(0.4, 2.6) / (0.6 + 0.4 * sk)
	k.bot_item_wait -= STEP
	if k.bot_item_wait > 0.0:
		return
	var behind := INF
	var ahead := INF
	var ahead_ang := INF
	for id in _order:
		var o: Kart = _karts[id]
		if o == k:
			continue
		var dp := o.prog - k.prog
		if dp < 0.0:
			behind = minf(behind, -dp)
		elif dp > 0.0 and dp < ahead:
			ahead = dp
			ahead_ang = absf(wrapf(_yaw_of(o.pos - k.pos) - k.yaw, -PI, PI))
	var use := false
	match k.item:
		Item.BANANA:
			use = behind < 14.0 or k.bot_item_wait < -5.0
		Item.GREEN:
			if ahead < 32.0 and ahead_ang < 0.14:
				use = true
			elif behind < 10.0 and k.bot_item_wait < -2.0:
				use = true
				k.vert = 1.0
			elif k.bot_item_wait < -7.0:
				use = true
		Item.RED:
			if k.place > 1:
				use = true
			elif behind < 12.0:
				use = true
				k.vert = 1.0
		Item.MUSHROOM:
			use = absf(bend) < 0.35 and k.drift_dir == 0 and k.speed > 10.0
		_:
			use = true
	if use:
		k.bot_press2 = true
		k.bot_item_wait = k.bot_rng.randf_range(0.3, 1.2)

func _bot_move(player: PlayerData) -> Vector2:
	var k: Kart = _karts.get(player.id)
	if k == null:
		return Vector2.ZERO
	_bot_think(k)
	var y := k.vert
	if k.bot_brake:
		y = 1.0
	return Vector2(k.bot_steer, y)

func _bot_action(player: PlayerData) -> int:
	var k: Kart = _karts.get(player.id)
	if k == null or not k.bot_press:
		return 0
	k.bot_press = false
	return 1

func _bot_action2(player: PlayerData) -> int:
	var k: Kart = _karts.get(player.id)
	if k == null or not k.bot_press2:
		return 0
	k.bot_press2 = false
	return 1

func _bot_action_held(_player: PlayerData) -> bool:
	return false

# ----------------------------------------------------------------------------
# Red
# ----------------------------------------------------------------------------

## (cliente) El botón de derrape mantenido no viaja con la entrada normal: se avisa al host solo al cambiar.
func _send_held() -> void:
	if is_authority or not is_running or local_player == null or InputManager.is_simulated(local_player.id):
		return
	var held := InputManager.is_action_pressed(local_player.id)
	if bool(_held_sent.get(local_player.id, false)) != held:
		_held_sent[local_player.id] = held
		submit_text("h:1" if held else "h:0", true)

func _on_player_text(player: PlayerData, text: String, _final: bool) -> void:
	if player == null or not _karts.has(player.id):
		return
	if text == "h:1" or text == "h:0":
		_held_remote[player.id] = text == "h:1"

func _serialize_state() -> Variant:
	var arr := PackedFloat32Array()
	for id in _order:
		var k: Kart = _karts[id]
		arr.append_array(PackedFloat32Array([k.pos.x, k.pos.y, k.pos.z, k.yaw, k.speed, float(k.drift_dir), float(_drift_level(k)),
				k.boost_t, k.spin_t, k.star_t, k.shrink_t, k.inv_t, float(k.item), float(k.item_n), k.roulette_t, float(k.coins),
				float(k.lap), k.prog, 1.0 if k.finished else 0.0, k.fin_time, float(k.place), float(k.state), k.state_t,
				k.wrong_t, k.trick_t, 1.0 if k.air else 0.0, k.steer]))
	var objs := PackedFloat32Array()
	for o in _objs:
		objs.append_array(PackedFloat32Array([float(o.id), float(o.kind), o.pos.x, o.pos.y, o.pos.z, o.vel.x, o.vel.y, o.vel.z]))
	var boxes := PackedByteArray()
	boxes.resize(_box_t.size())
	for i in _box_t.size():
		boxes[i] = 1 if _box_t[i] > 0.0 else 0
	var coins := PackedByteArray()
	coins.resize(_coin_t.size())
	for i in _coin_t.size():
		coins[i] = 1 if _coin_t[i] > 0.0 else 0
	return {"k": arr, "o": objs, "b": boxes, "c": coins, "t": _t, "x": _over, "w": _winner_id, "f": _first_fin}

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	var st: Dictionary = state
	_t = float(st.get("t", _t))
	_over = bool(st.get("x", _over))
	_winner_id = int(st.get("w", _winner_id))
	_first_fin = float(st.get("f", _first_fin))
	var arr: Variant = st.get("k")
	if arr is PackedFloat32Array and arr.size() >= _order.size() * KF:
		for i in _order.size():
			var k: Kart = _karts[_order[i]]
			var o := i * KF
			k.pos = Vector3(arr[o], arr[o + 1], arr[o + 2])
			k.yaw = arr[o + 3]
			k.speed = arr[o + 4]
			k.drift_dir = int(arr[o + 5])
			var lvl := int(arr[o + 6])
			k.drift_t = 0.0 if lvl <= 0 else DRIFT_LEVELS[lvl - 1]
			k.boost_t = arr[o + 7]
			k.spin_t = arr[o + 8]
			k.star_t = arr[o + 9]
			k.shrink_t = arr[o + 10]
			k.inv_t = arr[o + 11]
			k.item = int(arr[o + 12])
			k.item_n = int(arr[o + 13])
			k.roulette_t = arr[o + 14]
			k.coins = int(arr[o + 15])
			k.lap = int(arr[o + 16])
			k.prog = arr[o + 17]
			k.finished = arr[o + 18] > 0.5
			k.fin_time = arr[o + 19]
			k.place = int(arr[o + 20])
			k.state = int(arr[o + 21])
			k.state_t = arr[o + 22]
			k.wrong_t = arr[o + 23]
			k.trick_t = arr[o + 24]
			k.air = arr[o + 25] > 0.5
			k.steer = arr[o + 26]
	var oa: Variant = st.get("o")
	if oa is PackedFloat32Array:
		var by_id := {}
		for ob in _objs:
			by_id[ob.id] = ob
		var next: Array[TrackObj] = []
		for i in int(oa.size()) / OF:
			var o2 := i * OF
			var id := int(oa[o2])
			var ob: TrackObj = by_id.get(id)
			if ob == null:
				ob = TrackObj.new()
				ob.id = id
				ob.kind = int(oa[o2 + 1])
			else:
				by_id.erase(id)
			ob.pos = Vector3(oa[o2 + 2], oa[o2 + 3], oa[o2 + 4])
			ob.vel = Vector3(oa[o2 + 5], oa[o2 + 6], oa[o2 + 7])
			next.append(ob)
		for old in by_id.values():
			if (old as TrackObj).node != null and is_instance_valid((old as TrackObj).node):
				(old as TrackObj).node.queue_free()
		_objs = next
	var ba: Variant = st.get("b")
	if ba is PackedByteArray and ba.size() == _box_t.size():
		for i in ba.size():
			_box_t[i] = 1.0 if ba[i] > 0 else 0.0
	var ca: Variant = st.get("c")
	if ca is PackedByteArray and ca.size() == _coin_t.size():
		for i in ca.size():
			_coin_t[i] = 1.0 if ca[i] > 0 else 0.0

func _say(id: int, text: String, secs: float, col: Color = Color.WHITE) -> void:
	_msgs[id] = {"text": text, "t": secs, "max": secs, "col": col}

func _on_event(event_name: String, data: Variant) -> void:
	var d: Dictionary = data if data is Dictionary else {}
	var k: Kart = _karts.get(int(d.get("p", -1)))
	var mine := k != null and _audible(k)
	match event_name:
		"box":
			if mine:
				Audio.sfx(&"pop", -6.0, 1.2)
			_burst(_box_fx, _boxes[int(d.get("b", 0))] if int(d.get("b", 0)) < _boxes.size() else Vector3.ZERO)
		"got":
			if mine:
				Audio.sfx(&"claim", -6.0)
		"coin":
			if mine:
				Audio.sfx(&"coin", -9.0)
		"use":
			if mine:
				var it := int(d.get("i", 0))
				match it:
					Item.STAR: Audio.sfx(&"perfect", -4.0)
					Item.BOLT: Audio.sfx(&"zap", -3.0)
					Item.MUSHROOM: pass
					_: Audio.sfx(&"throw", -6.0)
			if int(d.get("i", 0)) == Item.BOLT:
				_flash = 0.5
				Audio.sfx(&"zap", -8.0)
				for id in _order:
					if id != int(d.get("p", -1)):
						_say(id, "¡RAYO!", 1.2, Palette.YELLOW)
		"boost":
			if mine:
				var kind := String(d.get("k", ""))
				Audio.sfx(&"launch" if kind.begins_with("drift") or kind == "trick" else &"dash", -5.0)
				if kind == "drift3":
					_say(k.id, "¡TURBO MORADO!", 0.8, Color(0.85, 0.5, 1.0))
		"trick":
			if mine:
				Audio.sfx(&"swish", -6.0)
		"jump":
			if mine:
				Audio.sfx(&"jump", -8.0)
		"wall":
			if mine:
				Audio.sfx(&"wall", -10.0)
		"hit":
			_burst(_hit_fx, Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)) + 0.8, float(d.get("z", 0.0))))
			if mine:
				Audio.sfx(&"crash" if String(d.get("k", "")) != "banana" else &"dive", -4.0)
				_shake[k.id] = 0.8
			elif k != null:
				Audio.sfx(&"thud", -16.0)
			var by: Kart = _karts.get(int(d.get("by", -1)))
			if by != null and by != k and _audible(by):
				_say(by.id, "¡TOMA!", 0.9, Palette.MINT)
				Audio.sfx(&"hit", -6.0)
		"pop":
			_burst(_hit_fx, Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("z", 0.0))))
		"boom":
			_burst(_boom_fx, Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("z", 0.0))))
			Audio.sfx(&"crash", -6.0, 0.7)
		"fall":
			if mine:
				Audio.sfx(&"plat_fall", -5.0)
				_say(k.id, "¡TE HAS CAÍDO!", 1.4, Palette.CORAL)
		"lap":
			if mine:
				var l := int(d.get("l", 0))
				if l == LAPS:
					Audio.sfx(&"fanfare_small", -4.0)
					_say(k.id, "¡ÚLTIMA VUELTA!", 2.2, Palette.YELLOW)
				else:
					Audio.sfx(&"milestone", -5.0)
					_say(k.id, "VUELTA %d/%d" % [l, LAPS], 1.6)
		"fin":
			if k != null:
				var pl := int(d.get("pl", 0))
				if mine:
					Audio.sfx(&"fanfare_big" if pl == 1 else &"fanfare_small", -3.0)
					_say(k.id, "¡META!  %d.º" % pl, 3.5, Palette.YELLOW if pl == 1 else Palette.WHITE)
				else:
					Audio.sfx(&"swish", -14.0)
		"over":
			_winner_id = int(d.get("w", -1))

func _burst(fx: CPUParticles3D, at: Vector3) -> void:
	if fx == null:
		return
	fx.position = at
	fx.restart()
	fx.emitting = true

func _animate(delta: float) -> void:
	_anim += delta
	_flash = maxf(0.0, _flash - delta)
	if is_running:
		_hint_t = maxf(0.0, _hint_t - delta)
	for id in _msgs.keys():
		var m: Dictionary = _msgs[id]
		m["t"] = float(m["t"]) - delta
		if float(m["t"]) <= 0.0:
			_msgs.erase(id)
	for id in _shake.keys():
		_shake[id] = maxf(0.0, float(_shake[id]) - delta * 2.0)
	_send_held()
	# Tictac de la ruleta de objetos (solo la de quien juega en este PC).
	for v in _views:
		var rk := _view_kart(v)
		if rk != null and rk.roulette_t > 0.0 and _audible(rk) and fmod(_anim, 0.09) < delta:
			Audio.sfx(&"score_tick", -14.0, 1.0 + 0.3 * rk.roulette_t)
	# Los clientes adelantan los objetos con su velocidad entre un estado y el siguiente.
	if not is_authority and is_running:
		for o in _objs:
			if o.kind != Obj.BANANA:
				o.pos += Vector3(o.vel.x, 0.0, o.vel.z) * delta
	_update_world(delta)

# ----------------------------------------------------------------------------
# Escena 3D: la Senda Arcoíris en el espacio
# ----------------------------------------------------------------------------

const RAINBOW: Array[Color] = [Color(1.0, 0.25, 0.35), Color(1.0, 0.58, 0.18), Color(1.0, 0.9, 0.25), Color(0.35, 0.95, 0.45),
		Color(0.25, 0.85, 1.0), Color(0.35, 0.5, 1.0), Color(0.75, 0.4, 1.0)]

func _mat(c: Color, emission: float = 0.0, rough: float = 0.6) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emission
	return m

## Material "dibujo animado": color liso con contorno oscuro.
func _toon(c: Color, emission: float = 0.0, outline: float = 0.03) -> StandardMaterial3D:
	var m := _mat(c, emission, 0.5)
	var o := StandardMaterial3D.new()
	o.albedo_color = Color(0.06, 0.03, 0.12)
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

func _shared(key: String, make: Callable) -> Material:
	if not _mats.has(key):
		_mats[key] = make.call()
	return _mats[key]

func _mesh(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi

func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	return _mesh(parent, bm, pos, mat)

func _cyl(radius: float, height: float, segs: int = 16, top: float = -1.0) -> CylinderMesh:
	var cm := CylinderMesh.new()
	cm.top_radius = radius if top < 0.0 else top
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = segs
	cm.rings = 1
	return cm

func _sphere(parent: Node3D, radius: float, pos: Vector3, mat: Material, segs: int = 16) -> MeshInstance3D:
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = segs
	sm.rings = maxi(4, segs / 2)
	return _mesh(parent, sm, pos, mat)

func _capsule(parent: Node3D, radius: float, height: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var cm := CapsuleMesh.new()
	cm.radius = radius
	cm.height = height
	cm.radial_segments = 14
	cm.rings = 5
	return _mesh(parent, cm, pos, mat)

func _particles(color: Color, amount: int, life: float, radius: float, vel_min: float, vel_max: float, grav: Vector3, one_shot: bool = true) -> CPUParticles3D:
	var pt := CPUParticles3D.new()
	pt.amount = amount
	pt.lifetime = life
	pt.one_shot = one_shot
	pt.emitting = false
	pt.explosiveness = 0.92 if one_shot else 0.0
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
	sm.radial_segments = 6
	sm.rings = 3
	var mat := _unshaded(Color.WHITE, true)
	mat.vertex_color_use_as_albedo = true
	sm.material = mat
	pt.mesh = sm
	pt.color = color
	return pt

func _build_world() -> void:
	if _built:
		return
	_built = true
	# --- Espacio: cielo oscuro violeta, niebla nula, mucho brillo para el neón ---
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.02, 0.01, 0.08)
	sky_mat.sky_horizon_color = Color(0.16, 0.06, 0.3)
	sky_mat.ground_horizon_color = Color(0.16, 0.06, 0.3)
	sky_mat.ground_bottom_color = Color(0.01, 0.0, 0.05)
	sky_mat.sun_angle_max = 0.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.62, 1.0)
	env.ambient_light_energy = 0.85
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 4.0
	env.glow_enabled = true
	env.glow_intensity = 0.85
	env.glow_bloom = 0.1
	env.glow_hdr_threshold = 0.9
	_world = World3D.new()
	_world.environment = env
	_root3 = Node3D.new()
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0, 35.0, 0.0)
	light.light_energy = 0.95
	light.light_color = Color(1.0, 0.95, 1.0)
	_root3.add_child(light)
	_build_space()
	_build_road()
	_build_rails()
	_build_props()
	_build_pickups()
	_hit_fx = _particles(Color(1.0, 0.95, 0.6), 22, 0.6, 0.16, 3.0, 8.0, Vector3(0, -14.0, 0))
	_root3.add_child(_hit_fx)
	_boom_fx = _particles(Color(0.4, 0.75, 1.0), 48, 0.9, 0.35, 5.0, 14.0, Vector3(0, -6.0, 0))
	_root3.add_child(_boom_fx)
	_box_fx = _particles(Color(1.0, 1.0, 1.0, 0.9), 16, 0.5, 0.12, 2.0, 6.0, Vector3(0, -8.0, 0))
	_root3.add_child(_box_fx)
	_build_views()
	_rebuild_kart_nodes()

## Estrellas, nebulosas, un planeta con anillo y una luna.
func _build_space() -> void:
	var r := RandomNumberGenerator.new()
	r.seed = 7311
	var star_mm := MultiMesh.new()
	star_mm.transform_format = MultiMesh.TRANSFORM_3D
	star_mm.use_colors = true
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 6
	sm.rings = 3
	star_mm.mesh = sm
	star_mm.instance_count = 700
	for i in star_mm.instance_count:
		var dir := Vector3(r.randf_range(-1.0, 1.0), r.randf_range(-0.7, 1.0), r.randf_range(-1.0, 1.0)).normalized()
		star_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * r.randf_range(0.6, 2.0)), dir * 600.0))
		var tint := [Color(1, 1, 1), Color(1.0, 0.85, 0.7), Color(0.75, 0.85, 1.0), Color(1.0, 0.7, 0.95)][r.randi() % 4] as Color
		star_mm.set_instance_color(i, tint)
	var stars := MultiMeshInstance3D.new()
	stars.multimesh = star_mm
	var smat := _unshaded(Color.WHITE)
	smat.vertex_color_use_as_albedo = true
	stars.material_override = smat
	stars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root3.add_child(stars)
	# Nebulosas: manchas de color muy grandes y suaves.
	var neb_tex := _radial_texture()
	var neb_cols: Array[Color] = [Color(0.9, 0.3, 0.9, 0.35), Color(0.3, 0.5, 1.0, 0.35), Color(0.2, 0.9, 0.9, 0.25), Color(1.0, 0.45, 0.4, 0.25)]
	for i in 7:
		var q := QuadMesh.new()
		q.size = Vector2.ONE * r.randf_range(260.0, 420.0)
		var m := _unshaded(neb_cols[i % neb_cols.size()], true)
		m.albedo_texture = neb_tex
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		var dir2 := Vector3(r.randf_range(-1.0, 1.0), r.randf_range(-0.4, 0.6), r.randf_range(-1.0, 1.0)).normalized()
		_mesh(_root3, q, dir2 * 520.0, m)
	# Planeta con anillo.
	var planet := Node3D.new()
	planet.position = Vector3(260.0, 70.0, 300.0)
	_root3.add_child(planet)
	var pm := _mat(Color.WHITE, 0.0, 0.9)
	pm.albedo_texture = _band_texture()
	pm.emission_enabled = true
	pm.emission = Color(0.25, 0.12, 0.3)
	_sphere(planet, 70.0, Vector3.ZERO, pm, 40)
	var ring := TorusMesh.new()
	ring.inner_radius = 95.0
	ring.outer_radius = 130.0
	ring.rings = 64
	ring.ring_segments = 4
	var rm := _unshaded(Color(1.0, 0.8, 0.6, 0.45), true)
	rm.cull_mode = BaseMaterial3D.CULL_DISABLED
	var rmi := _mesh(planet, ring, Vector3.ZERO, rm)
	rmi.scale = Vector3(1.0, 0.05, 1.0)
	rmi.rotation = Vector3(0.35, 0.0, 0.25)
	_spin_nodes.append(planet)
	# Luna.
	var moon := _sphere(_root3, 26.0, Vector3(-240.0, 40.0, -260.0), _mat(Color(0.75, 0.75, 0.9), 0.25, 0.95), 28)
	for i in 6:
		var c := _sphere(moon, r.randf_range(3.0, 6.0), Vector3(r.randf_range(-1, 1), r.randf_range(-1, 1), r.randf_range(-1, 1)).normalized() * 24.0, _mat(Color(0.55, 0.55, 0.7)), 10)
		c.scale = Vector3(1.0, 0.4, 1.0)
		c.look_at_from_position(c.position, Vector3.ZERO)
	# Estrellas de cinco puntas flotando alrededor de la pista.
	var star_mesh := _star_mesh(1.0, 0.45, 0.35)
	var smat2 := _mat(Color(1.0, 0.86, 0.25), 1.6, 0.3)
	for i in 34:
		var idx := r.randi() % _n
		var side := -1.0 if r.randf() < 0.5 else 1.0
		var p := _point(idx, side * (_tw[idx] * 0.5 + r.randf_range(10.0, 45.0))) + Vector3(0, r.randf_range(-14.0, 18.0), 0)
		var st := _mesh(_root3, star_mesh, p, smat2)
		st.scale = Vector3.ONE * r.randf_range(1.5, 4.0)
		st.rotation = Vector3(0.0, r.randf() * TAU, 0.0)
		_spin_nodes.append(st)

func _radial_texture() -> ImageTexture:
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var p := Vector2(x - n * 0.5 + 0.5, y - n * 0.5 + 0.5) / (n * 0.5)
			var a := clampf(1.0 - p.length(), 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a * a))
	return ImageTexture.create_from_image(img)

func _band_texture() -> ImageTexture:
	var img := Image.create(8, 128, false, Image.FORMAT_RGBA8)
	var cols: Array[Color] = [Color(0.95, 0.55, 0.45), Color(0.85, 0.4, 0.6), Color(0.98, 0.75, 0.5), Color(0.7, 0.4, 0.75), Color(0.95, 0.6, 0.5)]
	for y in 128:
		var f := float(y) / 128.0 * float(cols.size() - 1)
		var c := cols[int(f)].lerp(cols[mini(int(f) + 1, cols.size() - 1)], fmod(f, 1.0))
		c = c.darkened(0.12 * (0.5 + 0.5 * sin(float(y) * 0.9)))
		for x in 8:
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)

## Estrella de cinco puntas con volumen (centro abombado).
func _star_mesh(outer: float, inner: float, depth: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pts: Array[Vector3] = []
	for i in 10:
		var a := PI * 0.5 + TAU * float(i) / 10.0
		var rr := outer if i % 2 == 0 else inner
		pts.append(Vector3(cos(a) * rr, sin(a) * rr, 0.0))
	for side: float in [1.0, -1.0]:
		var c := Vector3(0, 0, depth * side)
		for i in 10:
			var a2 := pts[i]
			var b2 := pts[(i + 1) % 10]
			var nrm := (b2 - a2).cross(c - a2).normalized() * side
			st.set_normal(nrm)
			st.add_vertex(a2)
			st.add_vertex(b2 if side > 0.0 else c)
			st.add_vertex(c if side > 0.0 else b2)
	return st.commit()

## La calzada: siete franjas de colores, con bandas más claras cada pocos metros (dan sensación de velocidad),
## bordes blancos brillantes y un faldón oscuro por debajo.
func _build_road() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bands := RAINBOW.size()
	for i in _n:
		var j := (i + 1) % _n
		var bright := 1.0 if (i / 3) % 2 == 0 else 0.78
		for b in bands:
			var f0 := -0.5 + float(b) / float(bands)
			var f1 := -0.5 + float(b + 1) / float(bands)
			var a0 := _tp[i] + _tn[i] * (f0 * _tw[i])
			var a1 := _tp[i] + _tn[i] * (f1 * _tw[i])
			var b0 := _tp[j] + _tn[j] * (f0 * _tw[j])
			var b1 := _tp[j] + _tn[j] * (f1 * _tw[j])
			var col := RAINBOW[b] * bright
			col.a = 1.0
			st.set_color(col)
			st.set_normal(Vector3.UP)
			for v in [a0, b0, a1, a1, b0, b1]:
				st.add_vertex(v)
	var road := MeshInstance3D.new()
	road.mesh = st.commit()
	var rm := StandardMaterial3D.new()
	rm.vertex_color_use_as_albedo = true
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.cull_mode = BaseMaterial3D.CULL_DISABLED
	road.material_override = rm
	road.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root3.add_child(road)
	# Bordes brillantes y faldón por debajo.
	var edge := SurfaceTool.new()
	edge.begin(Mesh.PRIMITIVE_TRIANGLES)
	var skirt := SurfaceTool.new()
	skirt.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in _n:
		var j := (i + 1) % _n
		for side: float in [-1.0, 1.0]:
			var ai := _tp[i] + _tn[i] * (side * _tw[i] * 0.5)
			var bj := _tp[j] + _tn[j] * (side * _tw[j] * 0.5)
			var ai2 := ai - _tn[i] * side * 0.35 + Vector3(0, 0.03, 0)
			var bj2 := bj - _tn[j] * side * 0.35 + Vector3(0, 0.03, 0)
			for v in [ai + Vector3(0, 0.03, 0), bj + Vector3(0, 0.03, 0), ai2, ai2, bj + Vector3(0, 0.03, 0), bj2]:
				edge.add_vertex(v)
			var down := Vector3(0, -0.9, 0)
			for v in [ai, bj, ai + down, ai + down, bj, bj + down]:
				skirt.add_vertex(v)
		var l0 := _tp[i] - _tn[i] * _tw[i] * 0.5 + Vector3(0, -0.9, 0)
		var r0 := _tp[i] + _tn[i] * _tw[i] * 0.5 + Vector3(0, -0.9, 0)
		var l1 := _tp[j] - _tn[j] * _tw[j] * 0.5 + Vector3(0, -0.9, 0)
		var r1 := _tp[j] + _tn[j] * _tw[j] * 0.5 + Vector3(0, -0.9, 0)
		for v in [l0, l1, r0, r0, l1, r1]:
			skirt.add_vertex(v)
	var em := _mat(Color(1.0, 1.0, 1.0), 2.2)
	em.cull_mode = BaseMaterial3D.CULL_DISABLED
	var emi := _mesh(_root3, edge.commit(), Vector3.ZERO, em)
	emi.name = "Edges"
	var sk := _unshaded(Color(0.22, 0.1, 0.4, 0.82), true)
	sk.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh(_root3, skirt.commit(), Vector3.ZERO, sk)
	# Rampa: cuña de rayas blancas y azules.
	var rp := SurfaceTool.new()
	rp.begin(Mesh.PRIMITIVE_TRIANGLES)
	var span := float(_ramp_i.y - _ramp_i.x)
	for i in range(_ramp_i.x, _ramp_i.y):
		var h0 := RAMP_H * float(i - _ramp_i.x) / span
		var h1 := RAMP_H * float(i + 1 - _ramp_i.x) / span
		var w0 := _tw[i] * 0.5
		var w1 := _tw[i + 1] * 0.5
		var stripes := 6
		for b in stripes:
			var f0 := -1.0 + 2.0 * float(b) / float(stripes)
			var f1 := -1.0 + 2.0 * float(b + 1) / float(stripes)
			rp.set_color(Color(1, 1, 1) if b % 2 == 0 else Color(0.3, 0.6, 1.0))
			var a0 := _tp[i] + _tn[i] * (f0 * w0) + Vector3(0, h0 + 0.05, 0)
			var a1 := _tp[i] + _tn[i] * (f1 * w0) + Vector3(0, h0 + 0.05, 0)
			var b0 := _tp[i + 1] + _tn[i + 1] * (f0 * w1) + Vector3(0, h1 + 0.05, 0)
			var b1 := _tp[i + 1] + _tn[i + 1] * (f1 * w1) + Vector3(0, h1 + 0.05, 0)
			for v in [a0, b0, a1, a1, b0, b1]:
				rp.add_vertex(v)
	# Cara frontal vertical al final de la rampa.
	var ie := _ramp_i.y
	var we := _tw[ie] * 0.5
	rp.set_color(Color(0.2, 0.3, 0.8))
	var p0 := _tp[ie] - _tn[ie] * we
	var p1 := _tp[ie] + _tn[ie] * we
	for v in [p0, p1, p0 + Vector3(0, RAMP_H + 0.05, 0), p0 + Vector3(0, RAMP_H + 0.05, 0), p1, p1 + Vector3(0, RAMP_H + 0.05, 0)]:
		rp.add_vertex(v)
	var ramp := MeshInstance3D.new()
	ramp.mesh = rp.commit()
	var ramp_m := StandardMaterial3D.new()
	ramp_m.vertex_color_use_as_albedo = true
	ramp_m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ramp_m.cull_mode = BaseMaterial3D.CULL_DISABLED
	ramp.material_override = ramp_m
	_root3.add_child(ramp)

## Barandillas: postes y un pasamanos de neón en los tramos que las tienen.
func _build_rails() -> void:
	var post_mm := MultiMesh.new()
	post_mm.transform_format = MultiMesh.TRANSFORM_3D
	post_mm.mesh = _cyl(0.09, 1.0, 6)
	var posts: Array[Transform3D] = []
	var bar := SurfaceTool.new()
	bar.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in _n:
		if _trail[i] == 0:
			continue
		var j := (i + 1) % _n
		for side: float in [-1.0, 1.0]:
			var e := _tp[i] + _tn[i] * (side * (_tw[i] * 0.5 + 0.12))
			if i % 3 == 0:
				posts.append(Transform3D(Basis(), e + Vector3(0, 0.5, 0)))
			if _trail[j] == 1:
				var e2 := _tp[j] + _tn[j] * (side * (_tw[j] * 0.5 + 0.12))
				var lo := Vector3(0, 0.78, 0)
				var hi := Vector3(0, 1.02, 0)
				for v in [e + lo, e2 + lo, e + hi, e + hi, e2 + lo, e2 + hi]:
					bar.add_vertex(v)
	post_mm.instance_count = posts.size()
	for i in posts.size():
		post_mm.set_instance_transform(i, posts[i])
	var pmi := MultiMeshInstance3D.new()
	pmi.multimesh = post_mm
	pmi.material_override = _mat(Color(1.0, 0.85, 1.0), 1.2)
	pmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root3.add_child(pmi)
	var bm := _mat(Color(0.55, 0.95, 1.0), 2.4)
	bm.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh(_root3, bar.commit(), Vector3.ZERO, bm)

## Salida/meta con su arco y semáforo, aros de neón alrededor de la pista y turbos en el suelo.
func _build_props() -> void:
	# Cuadros de la línea de meta.
	var w0 := _tw[0]
	var cells := 12
	var black := _unshaded(Color(0.08, 0.06, 0.12))
	var white := _unshaded(Color(1, 1, 1))
	for row in 2:
		for c in cells:
			var lat := -w0 * 0.5 + (float(c) + 0.5) * w0 / float(cells)
			var p := _point(row, lat) + Vector3(0, 0.04, 0)
			var q := _box(_root3, Vector3(w0 / float(cells), 0.02, 1.0), p, white if (row + c) % 2 == 0 else black)
			q.rotation.y = _yaw_of(_tt[0])
	# Arco de salida con nombre y semáforo.
	var gate := Node3D.new()
	gate.position = _tp[0]
	gate.rotation.y = _yaw_of(_tt[0])
	_root3.add_child(gate)
	var pillar_m := _mat(Color(0.95, 0.95, 1.0), 0.6)
	for side: float in [-1.0, 1.0]:
		_box(gate, Vector3(0.7, 7.0, 0.7), Vector3(-side * (w0 * 0.5 + 0.9), 3.5, 0), pillar_m)
	_box(gate, Vector3(w0 + 2.6, 1.6, 0.8), Vector3(0, 7.3, 0), _mat(Color(0.3, 0.15, 0.6), 0.4))
	var sign_l := Label3D.new()
	sign_l.text = "SENDA ARCOÍRIS"
	sign_l.font_size = 96
	sign_l.pixel_size = 0.012
	sign_l.outline_size = 18
	sign_l.modulate = Palette.YELLOW
	sign_l.outline_modulate = Palette.PURPLE_DARK
	sign_l.position = Vector3(0, 7.3, -0.45)
	sign_l.rotation.y = PI
	gate.add_child(sign_l)
	for i in 3:
		var lm := _mat(Color(0.3, 0.05, 0.05), 0.5)
		_start_lights.append(lm)
		_sphere(gate, 0.38, Vector3(-1.2 + 1.2 * float(i), 5.8, -0.2), lm, 12)
	# Aros de neón.
	for k in ARCHES.size():
		var i := int(ARCHES[k] * _n)
		var t := TorusMesh.new()
		t.inner_radius = _tw[i] * 0.5 + 1.6
		t.outer_radius = _tw[i] * 0.5 + 2.3
		t.rings = 48
		t.ring_segments = 8
		var m := _mat(RAINBOW[k % RAINBOW.size()], 2.6)
		_ring_mats.append(m)
		var ring := _mesh(_root3, t, _tp[i] + Vector3(0, 1.0, 0), m)
		ring.basis = Basis.looking_at(_tt[i], Vector3.UP) * Basis(Vector3.RIGHT, PI * 0.5)
	# Turbos: flechas que avanzan.
	var tex := _chevron_texture()
	for p in _pads:
		var i: int = p[0]
		var lat: float = p[1]
		var m2 := _unshaded(Color(1, 1, 1, 0.95), true)
		m2.albedo_texture = tex
		m2.uv1_scale = Vector3(1.0, 2.0, 1.0)
		_pad_mats.append(m2)
		var q2 := PlaneMesh.new()
		q2.size = Vector2(3.6, 4.5)
		var mi := _mesh(_root3, q2, _point(i + 2, lat) + Vector3(0, 0.06, 0), m2)
		mi.rotation.y = _yaw_of(_tt[i]) + PI

func _chevron_texture() -> ImageTexture:
	var w := 64
	var h := 64
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var u := absf(float(x) - w * 0.5) / (w * 0.5)
			var v := fmod(float(y) / float(h) + u * 0.35, 0.5) / 0.5
			var on := v < 0.45
			var col := Color(1.0, 0.85, 0.15) if on else Color(1.0, 0.45, 0.05)
			col.a = 0.95
			if u > 0.9:
				col = Color(1, 1, 1, 0.95)
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)

## Cajas de objetos (cubos arcoíris con "?") y monedas.
func _build_pickups() -> void:
	var box_mat := _mat(Color(1, 1, 1, 0.8), 1.1, 0.1)
	box_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	box_mat.albedo_texture = _box_texture()
	box_mat.emission_texture = box_mat.albedo_texture
	box_mat.emission = Color(1, 1, 1)
	box_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE * 1.35
	for p in _boxes:
		var n := Node3D.new()
		n.position = p
		_root3.add_child(n)
		_mesh(n, bm, Vector3.ZERO, box_mat)
		var q := Label3D.new()
		q.text = "?"
		q.font_size = 128
		q.pixel_size = 0.01
		q.outline_size = 22
		q.render_priority = 1
		q.modulate = Color(1, 1, 1)
		q.outline_modulate = Color(0.85, 0.3, 0.6)
		q.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		n.add_child(q)
		_box_nodes.append(n)
	var cm := _mat(Color(1.0, 0.8, 0.15), 1.4, 0.2)
	cm.metallic = 0.6
	var coin_mesh := _cyl(0.42, 0.1, 18)
	for p in _coins:
		var n2 := Node3D.new()
		n2.position = p
		_root3.add_child(n2)
		var c := _mesh(n2, coin_mesh, Vector3.ZERO, cm)
		c.rotation.x = PI * 0.5
		_box(n2, Vector3(0.12, 0.42, 0.13), Vector3.ZERO, _shared("coin_mark", func() -> Material: return _mat(Color(1.0, 0.95, 0.6), 1.8)))
		_coin_nodes.append(n2)

func _box_texture() -> ImageTexture:
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var f := (float(x) + float(y)) / float(2 * n)
			var c := Color.from_hsv(fmod(f + 0.05, 1.0), 0.65, 1.0)
			var edge := mini(mini(x, y), mini(n - 1 - x, n - 1 - y))
			c.a = 0.95 if edge < 5 else 0.6
			if edge < 4:
				c = c.lightened(0.4)
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)

# ----------------------------------------------------------------------------
# Pantalla partida: una cámara por persona de este PC (máx. 4)
# ----------------------------------------------------------------------------

## Karts que tienen cámara en este PC: online, el tuyo; en modo local, cada persona (hasta 4); si no hay ninguna
## (todo bots), una cámara que sigue al primero.
func _view_ids() -> Array[int]:
	var ids: Array[int] = []
	if local_player != null and _karts.has(local_player.id):
		ids.append(local_player.id)
		return ids
	for p in players:
		if p.is_local_human and ids.size() < 4:
			ids.append(p.id)
	if ids.is_empty():
		ids.append(-1)
	return ids

func _view_rects(count: int, size: Vector2) -> Array[Rect2]:
	var out: Array[Rect2] = []
	match count:
		1:
			out.append(Rect2(Vector2.ZERO, size))
		2:
			out.append(Rect2(0, 0, size.x, size.y * 0.5))
			out.append(Rect2(0, size.y * 0.5, size.x, size.y * 0.5))
		_:
			for i in count:
				out.append(Rect2((i % 2) * size.x * 0.5, (i / 2) * size.y * 0.5, size.x * 0.5, size.y * 0.5))
	return out

func _build_views() -> void:
	var ids := _view_ids()
	for i in ids.size():
		var cont := SubViewportContainer.new()
		cont.stretch = true
		cont.top_level = true
		cont.set_anchors_preset(Control.PRESET_TOP_LEFT)
		cont.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(cont)
		move_child(cont, surface.get_index())      # el 3D va detrás del HUD
		var vp := SubViewport.new()
		vp.world_3d = _world
		vp.handle_input_locally = false
		vp.msaa_3d = Viewport.MSAA_4X if ids.size() <= 2 else Viewport.MSAA_2X
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		cont.add_child(vp)
		if i == 0:
			vp.add_child(_root3)
		var cam := Camera3D.new()
		cam.fov = 70.0
		cam.near = 0.2
		cam.far = 1600.0
		vp.add_child(cam)
		cam.current = true
		_views.append({"cont": cont, "vp": vp, "cam": cam, "id": ids[i], "rect": Rect2(), "pos": Vector3.ZERO,
				"yaw": 0.0, "fov": 70.0})
	_fit_views()

func _fit_views() -> void:
	if _views.is_empty():
		return
	var off := Vector2.ZERO
	var par := get_parent()
	if par is CanvasLayer:
		off = -(par as CanvasLayer).offset
	var size := surface.size if surface != null and surface.size.x > 10.0 else get_viewport().get_visible_rect().size
	var rects := _view_rects(_views.size(), size)
	for i in _views.size():
		var v: Dictionary = _views[i]
		var r: Rect2 = rects[i]
		v["rect"] = r
		var cont: SubViewportContainer = v["cont"]
		cont.position = off + r.position
		cont.size = r.size

## El kart que sigue una cámara (-1 = el que va primero).
func _view_kart(v: Dictionary) -> Kart:
	var id := int(v["id"])
	if id >= 0 and _karts.has(id):
		return _karts[id]
	var lead := _leader_id()
	return _karts.get(lead) if lead >= 0 else null

func _snap_cameras() -> void:
	for v in _views:
		var k := _view_kart(v)
		if k == null:
			continue
		v["yaw"] = k.yaw
		v["pos"] = _cam_target(k, k.yaw)
		var cam: Camera3D = v["cam"]
		cam.position = v["pos"]
		cam.look_at(k.pos + _fwd(k.yaw) * 6.0 + Vector3(0, 1.2, 0), Vector3.UP)

## ¿Está este kart pegado a una cámara de otro? (se oculta: si no, taparía toda la pantalla)
func _at_camera(k: Kart) -> bool:
	for v in _views:
		if int(v["id"]) == k.id:
			continue
		if (v["pos"] as Vector3).distance_squared_to(k.dpos + Vector3(0, 0.8, 0)) < 3.4 * 3.4:
			return true
	return false

func _cam_target(k: Kart, yaw: float) -> Vector3:
	var sc := 0.8 if k.shrink_t > 0.0 else 1.0
	return k.dpos - _fwd(yaw) * 7.4 * sc + Vector3(0, 3.1 * sc, 0)

func _update_cameras(delta: float) -> void:
	for v in _views:
		var k := _view_kart(v)
		if k == null:
			continue
		var cam: Camera3D = v["cam"]
		var a := 1.0 if delta <= 0.0 else 1.0 - exp(-5.0 * delta)
		if k.state == 0 or k.state == 2:
			var cy := k.dyaw - (k.drift_vis * 0.15 if k.drift_dir != 0 else 0.0)
			if k.spin_t > 0.0:
				cy = float(v["yaw"])             # durante el trompo la cámara no gira con el kart
			v["yaw"] = lerp_angle(float(v["yaw"]), cy, a)
			var tgt := _cam_target(k, float(v["yaw"]))
			var cur: Vector3 = v["pos"]
			# Pegada al kart en horizontal; la altura se suaviza (saltos, baches).
			v["pos"] = Vector3(tgt.x, lerpf(cur.y, tgt.y, 1.0 if delta <= 0.0 else 1.0 - exp(-8.0 * delta)), tgt.z)
		var shake := float(_shake.get(k.id, 0.0))
		var jitter := Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * shake * 0.25
		cam.position = (v["pos"] as Vector3) + jitter
		var look := k.dpos + _fwd(float(v["yaw"])) * 6.0 + Vector3(0, 1.2, 0)
		if k.state == 1:
			look = k.dpos
		if cam.position.distance_squared_to(look) > 0.01:
			cam.look_at(look, Vector3.UP)
		var want_fov := 70.0 + (9.0 if k.boost_t > 0.0 else 0.0) + clampf(k.speed / TOP, 0.0, 1.0) * 4.0
		v["fov"] = lerpf(float(v["fov"]), want_fov, a)
		# El ángulo de visión es el de una pantalla 16:9; en las franjas anchas (2 jugadores) se fija el horizontal
		# para no ver la pista como con ojo de pez.
		var rr: Rect2 = v["rect"]
		var aspect := rr.size.x / maxf(rr.size.y, 1.0)
		if aspect > 16.0 / 9.0 + 0.01:
			cam.keep_aspect = Camera3D.KEEP_WIDTH
			cam.fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(float(v["fov"])) * 0.5) * 16.0 / 9.0))
		else:
			cam.keep_aspect = Camera3D.KEEP_HEIGHT
			cam.fov = float(v["fov"])

# ----------------------------------------------------------------------------
# Karts y pilotos
# ----------------------------------------------------------------------------

func _rebuild_kart_nodes() -> void:
	if not _built:
		return
	for id in _order:
		var k: Kart = _karts[id]
		_free_kart_nodes(k)
		_build_kart(k, _player_by_id(id))

## Kart: chasis del color del jugador, cuatro ruedas, motor con tubos de escape, y el piloto (una mascota redonda
## con gorra del mismo color y su inicial).
func _build_kart(k: Kart, pl: PlayerData) -> void:
	var col: Color = pl.color if pl != null else Palette.YELLOW
	k.paint_col = col
	k.paint.clear()
	k.wheels.clear()
	k.front_pivots.clear()
	k.sparks.clear()
	k.node = Node3D.new()
	_root3.add_child(k.node)
	k.body = Node3D.new()
	k.node.add_child(k.body)
	var b := k.body
	var paint := _toon(col)
	var paint2 := _toon(col.darkened(0.25))
	k.paint.append(paint)
	k.paint.append(paint2)
	var dark := _shared("k_dark", func() -> Material: return _toon(Color(0.12, 0.1, 0.16)))
	var metal := _shared("k_metal", func() -> Material: return _mat(Color(0.75, 0.78, 0.85), 0.0, 0.25))
	var tire := _shared("k_tire", func() -> Material: return _toon(Color(0.08, 0.07, 0.1)))
	var rim := _shared("k_rim", func() -> Material: return _mat(Color(0.95, 0.95, 1.0), 0.3, 0.3))
	var skin := _shared("k_skin", func() -> Material: return _toon(Color(1.0, 0.84, 0.68)))
	var white := _shared("k_white", func() -> Material: return _toon(Color(1, 1, 1)))
	var eye := _shared("k_eye", func() -> Material: return _mat(Color(0.05, 0.05, 0.1)))
	# Chasis.
	_box(b, Vector3(1.5, 0.3, 2.3), Vector3(0, 0.45, 0), paint)
	_box(b, Vector3(1.05, 0.28, 0.9), Vector3(0, 0.52, 1.35), paint)
	_box(b, Vector3(1.4, 0.16, 0.22), Vector3(0, 0.38, 1.82), dark)
	for sx: float in [-1.0, 1.0]:
		_box(b, Vector3(0.32, 0.3, 1.25), Vector3(sx * 0.86, 0.5, 0.05), paint2)
	_box(b, Vector3(0.75, 0.62, 0.22), Vector3(0, 0.9, -0.6), dark)
	_box(b, Vector3(0.95, 0.42, 0.55), Vector3(0, 0.66, -1.05), metal)
	for sx: float in [-1.0, 1.0]:
		var ex := _mesh(b, _cyl(0.1, 0.5, 10), Vector3(sx * 0.3, 0.8, -1.38), metal)
		ex.rotation.x = PI * 0.5
	# Alerón.
	_box(b, Vector3(1.5, 0.08, 0.36), Vector3(0, 1.12, -1.3), paint)
	for sx: float in [-1.0, 1.0]:
		_box(b, Vector3(0.06, 0.4, 0.2), Vector3(sx * 0.55, 0.92, -1.3), dark)
	# Ruedas (las delanteras giran con la dirección).
	for wpos in [Vector3(-0.95, 0.42, -0.78), Vector3(0.95, 0.42, -0.78), Vector3(-0.9, 0.34, 0.88), Vector3(0.9, 0.34, 0.88)]:
		var front: bool = wpos.z > 0.0
		var pivot := Node3D.new()
		pivot.position = wpos
		b.add_child(pivot)
		var wh := Node3D.new()
		pivot.add_child(wh)
		var r: float = 0.34 if front else 0.42
		var tm := _mesh(wh, _cyl(r, 0.34 if front else 0.4, 14), Vector3.ZERO, tire)
		tm.rotation.z = PI * 0.5
		var rm := _mesh(wh, _cyl(r * 0.5, 0.42 if front else 0.48, 10), Vector3.ZERO, rim)
		rm.rotation.z = PI * 0.5
		k.wheels.append(wh)
		if front:
			k.front_pivots.append(pivot)
	# Volante.
	var sw := TorusMesh.new()
	sw.inner_radius = 0.14
	sw.outer_radius = 0.2
	sw.rings = 16
	sw.ring_segments = 6
	var swi := _mesh(b, sw, Vector3(0, 1.0, 0.42), dark)
	swi.rotation.x = -1.0
	# Piloto.
	_capsule(b, 0.3, 0.8, Vector3(0, 1.05, -0.25), paint)
	_sphere(b, 0.34, Vector3(0, 1.66, -0.18), skin)
	var cap := _sphere(b, 0.37, Vector3(0, 1.8, -0.2), paint)
	cap.scale = Vector3(1.0, 0.62, 1.0)
	_box(b, Vector3(0.5, 0.05, 0.3), Vector3(0, 1.74, 0.16), paint2)
	for sx: float in [-1.0, 1.0]:
		_sphere(b, 0.09, Vector3(sx * 0.12, 1.66, 0.12), white, 10)
		_sphere(b, 0.05, Vector3(sx * 0.12, 1.66, 0.19), eye, 8)
		_sphere(b, 0.1, Vector3(sx * 0.2, 1.05, 0.38), white, 10)       # guantes en el volante
	var initial := Label3D.new()
	initial.text = (pl.display_name.substr(0, 1).to_upper() if pl != null and pl.display_name != "" else "?")
	initial.font_size = 64
	initial.pixel_size = 0.006
	initial.outline_size = 10
	initial.modulate = Color.WHITE
	initial.outline_modulate = col.darkened(0.5)
	initial.position = Vector3(0, 1.93, 0.12)
	initial.rotation.x = -0.35
	b.add_child(initial)
	# Etiqueta con el nombre (la tuya, marcada).
	var is_me := pl != null and (pl == local_player or (local_player == null and pl.is_local_human))
	var tag := Label3D.new()
	tag.text = ("▼ " if is_me else "") + (pl.display_name if pl != null else "")
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.no_depth_test = true
	tag.fixed_size = true
	tag.pixel_size = 0.0011 if is_me else 0.0009
	tag.font_size = 48
	tag.outline_size = 14
	tag.modulate = Palette.YELLOW if is_me else Color.WHITE
	tag.outline_modulate = Palette.PURPLE_DARK
	tag.position = Vector3(0, 2.75, 0)
	k.node.add_child(tag)
	# Chispas del derrape (una por rueda trasera) y llamas del turbo.
	for sx: float in [-1.0, 1.0]:
		var sp := _particles(Color(1, 1, 1), 18, 0.32, 0.07, 2.0, 5.0, Vector3(0, -9.0, 0), false)
		sp.position = Vector3(sx * 0.95, 0.12, -1.0)
		sp.direction = Vector3(sx * 0.6, 1.0, -0.8)
		sp.spread = 35.0
		k.body.add_child(sp)
		k.sparks.append(sp)
	k.flame = Node3D.new()
	k.body.add_child(k.flame)
	var fl := _shared("k_flame", func() -> Material: return _mat(Color(1.0, 0.55, 0.15), 4.0))
	var fl2 := _shared("k_flame2", func() -> Material: return _mat(Color(0.45, 0.75, 1.0), 4.0))
	for sx: float in [-1.0, 1.0]:
		var cone := _mesh(k.flame, _cyl(0.16, 0.9, 10, 0.0), Vector3(sx * 0.3, 0.8, -1.95), fl)
		cone.rotation.x = -PI * 0.5
		var core := _mesh(k.flame, _cyl(0.08, 0.6, 8, 0.0), Vector3(sx * 0.3, 0.8, -1.8), fl2)
		core.rotation.x = -PI * 0.5
	k.flame.visible = false
	k.shadow = _mesh(_root3, _cyl(1.3, 0.02, 16), Vector3.ZERO, _shared("shadow", func() -> Material: return _unshaded(Color(0, 0, 0.05, 0.45), true)))
	# Nube que te rescata al caer.
	k.cloud = Node3D.new()
	_root3.add_child(k.cloud)
	var cw := _shared("cloud", func() -> Material: return _toon(Color(1, 1, 1), 0.3))
	for cp in [Vector3(0, 0, 0), Vector3(0.7, -0.1, 0.1), Vector3(-0.7, -0.1, 0.0), Vector3(0.2, 0.35, -0.1)]:
		_sphere(k.cloud, 0.65, cp, cw, 12)
	for sx: float in [-1.0, 1.0]:
		_sphere(k.cloud, 0.1, Vector3(sx * 0.22, 0.12, 0.6), eye, 8)
	var line := _mesh(k.cloud, _cyl(0.025, 3.0, 4), Vector3(0, -1.6, 0), dark)
	line.name = "Line"
	k.cloud.visible = false
	k.dpos = k.pos
	k.dyaw = k.yaw

func _build_obj_node(o: TrackObj) -> void:
	o.node = Node3D.new()
	_root3.add_child(o.node)
	match o.kind:
		Obj.BANANA:
			var y := _shared("banana", func() -> Material: return _toon(Color(1.0, 0.88, 0.2), 0.2))
			var br := _shared("banana_tip", func() -> Material: return _toon(Color(0.4, 0.25, 0.1)))
			for i in 3:
				var c := _capsule(o.node, 0.14, 0.7, Vector3(0, 0.25, 0), y)
				c.rotation = Vector3(0.0, TAU * float(i) / 3.0, 0.9)
				c.position = Vector3(cos(TAU * float(i) / 3.0) * 0.12, 0.2, sin(TAU * float(i) / 3.0) * 0.12)
			_sphere(o.node, 0.08, Vector3(0, 0.48, 0), br, 8)
		Obj.GREEN, Obj.RED, Obj.BLUE:
			var col := Color(0.25, 0.85, 0.35) if o.kind == Obj.GREEN else (Color(0.95, 0.2, 0.25) if o.kind == Obj.RED else Color(0.25, 0.45, 1.0))
			var shell := _toon(col, 0.35)
			var dome := _sphere(o.node, 0.5, Vector3(0, 0.05, 0), shell, 14)
			dome.scale = Vector3(1.0, 0.72, 1.0)
			var rim_t := TorusMesh.new()
			rim_t.inner_radius = 0.38
			rim_t.outer_radius = 0.56
			rim_t.rings = 18
			rim_t.ring_segments = 6
			_mesh(o.node, rim_t, Vector3(0, -0.02, 0), _shared("shell_rim", func() -> Material: return _toon(Color(1, 1, 0.95))))
			if o.kind == Obj.BLUE:
				var spike := _shared("spike", func() -> Material: return _toon(Color(1, 1, 1)))
				for i in 6:
					var a := TAU * float(i) / 6.0
					var sp := _mesh(o.node, _cyl(0.12, 0.35, 6, 0.0), Vector3(cos(a) * 0.3, 0.38, sin(a) * 0.3), spike)
					sp.rotation = Vector3(sin(a) * 0.6, 0.0, -cos(a) * 0.6)
				for sx: float in [-1.0, 1.0]:
					var wing := _box(o.node, Vector3(0.9, 0.06, 0.4), Vector3(sx * 0.85, 0.15, 0), spike)
					wing.rotation.z = sx * 0.3
				o.node.scale = Vector3.ONE * 1.5

# ----------------------------------------------------------------------------
# Presentación por frame
# ----------------------------------------------------------------------------

func _update_world(delta: float) -> void:
	_fit_views()
	if not _built:
		return
	var k_lerp := 1.0 if delta <= 0.0 else 1.0 - exp(-18.0 * delta)
	for id in _order:
		var k: Kart = _karts[id]
		if k.node == null:
			continue
		if k.dpos.distance_squared_to(k.pos) > 64.0:
			k.dpos = k.pos
			k.dyaw = k.yaw
		else:
			k.dpos = k.dpos.lerp(k.pos, k_lerp)
			k.dyaw = lerp_angle(k.dyaw, k.yaw, k_lerp)
		k.anim += delta
		k.dsteer = lerpf(k.dsteer, k.steer, k_lerp)
		k.drift_vis = lerpf(k.drift_vis, float(k.drift_dir), 1.0 - exp(-10.0 * delta))
		k.node.position = k.dpos
		k.node.rotation.y = k.dyaw - k.drift_vis * 0.48       # derrapando, el morro apunta hacia dentro
		var sc := SHRINK if k.shrink_t > 0.0 else 1.0
		k.node.scale = k.node.scale.lerp(Vector3.ONE * sc, 1.0 - exp(-10.0 * delta))
		# Trompo, vuelta de campana y acrobacia.
		if k.spin_t > 0.0:
			k.spin_vis += delta * 14.0
		else:
			k.spin_vis = lerp_angle(k.spin_vis, 0.0, 1.0 - exp(-12.0 * delta))
		k.body.rotation.y = k.spin_vis
		k.body.rotation.x = -TAU * (1.0 - k.trick_t / 0.5) if k.trick_t > 0.0 else 0.0
		k.body.rotation.z = -k.drift_vis * 0.08 - k.dsteer * 0.05
		k.body.position.y = absf(sin(k.anim * 22.0)) * 0.03 * clampf(k.speed / TOP, 0.0, 1.0)
		var blink := k.inv_t > 0.0 and k.spin_t <= 0.0 and k.star_t <= 0.0 and fmod(_anim, 0.16) < 0.08
		k.node.visible = not blink and not (k.state == 1 and k.state_t > FALL_TIME * 0.9) and not _at_camera(k)
		for i in k.wheels.size():
			k.wheels[i].rotation.x += k.speed * delta / (0.34 if i >= 2 else 0.42)
		for fp in k.front_pivots:
			fp.rotation.y = -k.dsteer * 0.45
		# Estrella: el kart cambia de color sin parar.
		var tint := k.paint_col
		if k.star_t > 0.0:
			tint = Color.from_hsv(fmod(_anim * 2.5, 1.0), 0.75, 1.0)
		for i in k.paint.size():
			var m := k.paint[i]
			m.albedo_color = tint if i == 0 else tint.darkened(0.25)
			m.emission_enabled = k.star_t > 0.0
			if k.star_t > 0.0:
				m.emission = tint
				m.emission_energy_multiplier = 1.2
		# Chispas: blancas al empezar, luego azules, naranjas y moradas.
		var lvl := _drift_level(k)
		var spark_col := [Color(1, 1, 0.9), Color(0.3, 0.6, 1.0), Color(1.0, 0.55, 0.15), Color(0.8, 0.35, 1.0)][lvl] as Color
		for sp in k.sparks:
			sp.emitting = k.drift_dir != 0 and not k.air and k.state == 0
			sp.color = spark_col
			sp.amount = 18 if lvl == 0 else 30
		k.flame.visible = k.boost_t > 0.0
		if k.flame.visible:
			k.flame.scale = Vector3.ONE * (0.8 + 0.4 * absf(sin(_anim * 40.0)))
		# Sombra en el suelo (si hay suelo debajo).
		k.shadow.visible = k.state == 0
		if k.shadow.visible:
			_locate(k.dpos, k.seg)
			k.seg = _li if not is_authority else k.seg
			var on := absf(_ld) <= _tw[_li] * 0.5 + 0.5
			k.shadow.visible = on
			k.shadow.position = Vector3(k.dpos.x, _ground() + 0.04, k.dpos.z)
			k.shadow.scale = Vector3.ONE * sc * clampf(1.0 - (k.dpos.y - _ground()) * 0.12, 0.4, 1.0)
		# Nube de rescate.
		k.cloud.visible = k.state == 2
		if k.cloud.visible:
			k.cloud.position = k.dpos + Vector3(0, 3.6, 0)
			k.cloud.rotation.y = k.dyaw + PI
	# Objetos en pista.
	for o in _objs:
		if o.node == null or not is_instance_valid(o.node):
			_build_obj_node(o)
		o.node.position = o.pos - Vector3(0, 0.45 if o.kind != Obj.BANANA else 0.3, 0)
		if o.kind != Obj.BANANA:
			o.node.rotation.y += delta * 12.0
	# Cajas, monedas, turbos, aros, decoración.
	for i in _box_nodes.size():
		var bn := _box_nodes[i]
		bn.visible = _box_t[i] <= 0.0
		bn.rotation = Vector3(0.4 + _anim * 0.6, _anim * 1.4 + float(i), 0.3)
		bn.position = _boxes[i] + Vector3(0, 0.15 * sin(_anim * 2.0 + float(i)), 0)
	for i in _coin_nodes.size():
		_coin_nodes[i].visible = _coin_t[i] <= 0.0
		_coin_nodes[i].rotation.y = _anim * 3.0 + float(i) * 0.4
	for m in _pad_mats:
		m.uv1_offset = Vector3(0.0, fmod(_anim * 1.6, 1.0), 0.0)
	for i in _ring_mats.size():
		_ring_mats[i].emission_energy_multiplier = 2.0 + 1.2 * (0.5 + 0.5 * sin(_anim * 3.0 - float(i)))
	for n in _spin_nodes:
		n.rotation.y += delta * 0.6
	for i in _start_lights.size():
		var on := is_running
		_start_lights[i].albedo_color = Color(0.2, 1.0, 0.35) if on else Color(1.0, 0.15, 0.15)
		_start_lights[i].emission = _start_lights[i].albedo_color
		_start_lights[i].emission_energy_multiplier = 3.0
		_start_lights[i].emission_enabled = true
	_update_cameras(delta)

# ----------------------------------------------------------------------------
# HUD (uno por cámara): objeto arriba a la izquierda, monedas y vuelta abajo a la izquierda, puesto grande abajo a la
# derecha, tiempo arriba a la derecha; minimapa y clasificación comunes
# ----------------------------------------------------------------------------

func _text_at(pos: Vector2, s: String, size: int, col: Color, outline: int = 6, align_right: bool = false) -> void:
	var font := surface.get_theme_default_font()
	var p := pos
	if align_right:
		p.x -= font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	if outline > 0:
		surface.draw_string_outline(font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, outline, Palette.PURPLE_DARK)
	surface.draw_string(font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)

func _place_color(place: int) -> Color:
	match place:
		1: return Color(1.0, 0.84, 0.2)
		2: return Color(0.85, 0.9, 1.0)
		3: return Color(1.0, 0.62, 0.35)
	return Color(0.6, 0.85, 1.0)

func _fmt_time(t: float) -> String:
	var m := int(t) / 60
	var s := fmod(t, 60.0)
	return "%d:%05.2f" % [m, s]

func _draw_hud() -> void:
	var s := surface
	_fit_views()
	var size := s.size
	for v in _views:
		_draw_view_hud(v)
	# Separadores de la pantalla partida.
	if _views.size() == 2:
		s.draw_rect(Rect2(0, size.y * 0.5 - 3, size.x, 6), Palette.PURPLE_DARK)
	elif _views.size() >= 3:
		s.draw_rect(Rect2(0, size.y * 0.5 - 3, size.x, 6), Palette.PURPLE_DARK)
		s.draw_rect(Rect2(size.x * 0.5 - 3, 0, 6, size.y), Palette.PURPLE_DARK)
	# Minimapa y clasificación.
	match _views.size():
		1:
			_draw_minimap(Rect2(size.x - 200, size.y * 0.5 - 150, 170, 170))
			_draw_standings(Vector2(26, 170), 1.0)
		2:
			_draw_minimap(Rect2(size.x - 150, size.y * 0.5 - 65, 130, 130))
		3:
			var q := Rect2(size.x * 0.5, size.y * 0.5, size.x * 0.5, size.y * 0.5)
			s.draw_rect(q, Color(0.06, 0.03, 0.14))
			_draw_minimap(Rect2(q.position.x + q.size.x - 260, q.position.y + 40, 230, 230))
			_draw_standings(q.position + Vector2(30, 50), 0.9)
		_:
			_draw_minimap(Rect2(size.x * 0.5 - 60, size.y * 0.5 - 60, 120, 120))
	if _flash > 0.0:
		s.draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 0.85, _flash * 0.8))
	if _over:
		var w := _player_by_id(_winner_id)
		s.draw_rect(Rect2(0, size.y * 0.5 - 110, size.x, 200), Color(0.05, 0.02, 0.15, 0.55))
		s.text_centered(Vector2(size.x * 0.5, size.y * 0.5 - 40), "¡FIN DE LA CARRERA!", 76, Palette.YELLOW, 12)
		if w != null:
			s.text_centered(Vector2(size.x * 0.5, size.y * 0.5 + 40), "Gana %s" % w.display_name, 50, w.color.lightened(0.25), 10)

func _draw_view_hud(v: Dictionary) -> void:
	var s := surface
	var r: Rect2 = v["rect"]
	var k := _view_kart(v)
	if k == null:
		return
	var sc := clampf(minf(r.size.x / 1280.0, r.size.y / 720.0) * 1.25, 0.55, 1.0)
	# Hueco para el minimapa común (a la derecha con 2 cámaras, en el centro con 4).
	var pad_l := 0.0
	var pad_r := 0.0
	if _views.size() == 2:
		pad_r = 165.0
	elif _views.size() == 4:
		if r.position.x < 1.0:
			pad_r = 70.0
		else:
			pad_l = 70.0
	r = Rect2(r.position + Vector2(pad_l, 0.0), r.size - Vector2(pad_l + pad_r, 0.0))
	var o := r.position
	# --- Objeto ---
	var ib := Rect2(o + Vector2(22, 20) * sc, Vector2(112, 112) * sc)
	s.rounded_rect(ib.grow(5 * sc), 26 * sc, Color(1, 1, 1, 0.9))
	s.rounded_rect(ib, 22 * sc, Color(0.08, 0.05, 0.2, 0.85))
	var shown := k.item
	if k.roulette_t > 0.0:
		shown = 1 + int(_anim * 14.0 + float(k.id)) % 7
	if shown != Item.NONE:
		_draw_item_icon(ib.get_center(), 40.0 * sc, shown)
		if k.item_n > 1 and k.roulette_t <= 0.0:
			_text_at(ib.end + Vector2(-34, -10) * sc, "x%d" % k.item_n, int(30 * sc), Palette.WHITE, int(6 * sc))
	# --- Monedas y vuelta ---
	var bl := Vector2(o.x + 26 * sc, r.end.y - 26 * sc)
	var cc := bl + Vector2(18, -66) * sc
	s.draw_circle(cc, 17 * sc, Color(1.0, 0.78, 0.1))
	s.draw_circle(cc, 12 * sc, Color(1.0, 0.9, 0.35))
	s.draw_rect(Rect2(cc - Vector2(3, 8) * sc, Vector2(6, 16) * sc), Color(0.9, 0.62, 0.05))
	_text_at(cc + Vector2(26, 12) * sc, "× %d" % k.coins, int(34 * sc), Color(1.0, 0.92, 0.5) if k.coins < MAX_COINS else Palette.YELLOW, int(7 * sc))
	var lap_shown := clampi(k.lap, 1, LAPS)
	_text_at(bl, "VUELTA %d/%d" % [lap_shown, LAPS], int(38 * sc), Palette.WHITE, int(8 * sc))
	# --- Puesto ---
	var pc := _place_color(k.place)
	var pos_txt := "%d" % k.place
	var font := s.get_theme_default_font()
	var big := int(120 * sc)
	var pw := font.get_string_size(pos_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, big).x
	var base := Vector2(r.end.x - 70 * sc - pw, r.end.y - 28 * sc)
	_text_at(base, pos_txt, big, pc, int(14 * sc))
	_text_at(base + Vector2(pw + 4 * sc, -big * 0.45), ".º", int(46 * sc), pc, int(8 * sc))
	# --- Tiempo ---
	var tshow := k.fin_time if k.finished else _t
	_text_at(Vector2(r.end.x - 24 * sc, o.y + 52 * sc), _fmt_time(tshow), int(34 * sc), Palette.WHITE, int(7 * sc), true)
	# --- Avisos ---
	var mid := Vector2(r.get_center().x, o.y + r.size.y * 0.3)
	if _msgs.has(k.id):
		var m: Dictionary = _msgs[k.id]
		var a := clampf(float(m["t"]) * 2.5, 0.0, 1.0)
		var grow := 1.0 + 0.25 * clampf(1.0 - (float(m["max"]) - float(m["t"])) * 5.0, 0.0, 1.0)
		var mc: Color = m["col"]
		s.text_centered(mid, String(m["text"]), int(66 * sc * grow), Color(mc.r, mc.g, mc.b, a), int(12 * sc))
	elif k.wrong_t > 0.8 and not k.finished and fmod(_anim, 0.6) < 0.4:
		s.text_centered(mid, "¡SENTIDO CONTRARIO!", int(54 * sc), Palette.CORAL, int(10 * sc))
	if k.finished and not _over and not _msgs.has(k.id):
		s.text_centered(mid, "Esperando a los demás…", int(32 * sc), Color(1, 1, 1, 0.85), int(6 * sc))
	if is_running and _t < 1.0:
		s.text_centered(Vector2(r.get_center().x, r.get_center().y - 20 * sc), "¡YA!", int(150 * sc), Palette.MINT, int(18 * sc))
	if _hint_t > 0.0 and not _over and is_running and (_views.size() == 1 or sc >= 0.7):
		var hc := Color(1, 1, 1, clampf(_hint_t, 0.0, 1.0))
		s.text_centered(Vector2(r.get_center().x, r.end.y - 100 * sc), "Gira con WASD / flechas  ·  ESPACIO derrapa  ·  E o CLIC DERECHO usa el objeto", int(22 * sc), hc, int(6 * sc))

## Iconos de los objetos dibujados con formas simples.
func _draw_item_icon(c: Vector2, rad: float, item: int) -> void:
	var s := surface
	match item:
		Item.BANANA:
			var pts := PackedVector2Array()
			for i in 13:
				var a := lerpf(-2.4, -0.5, float(i) / 12.0)
				pts.append(c + Vector2(cos(a), sin(a)) * rad * 0.95 + Vector2(-rad * 0.1, rad * 0.55))
			for i in 13:
				var a := lerpf(-0.5, -2.4, float(i) / 12.0)
				pts.append(c + Vector2(cos(a), sin(a)) * rad * 0.55 + Vector2(-rad * 0.1, rad * 0.35))
			s.draw_colored_polygon(pts, Color(1.0, 0.86, 0.2))
			s.draw_polyline(pts, Color(0.55, 0.38, 0.05), 2.0)
			s.draw_circle(pts[0], rad * 0.1, Color(0.4, 0.25, 0.1))
		Item.GREEN, Item.RED, Item.BLUE:
			var col := Color(0.25, 0.85, 0.35) if item == Item.GREEN else (Color(0.95, 0.2, 0.25) if item == Item.RED else Color(0.25, 0.45, 1.0))
			if item == Item.BLUE:
				for i in 6:
					var a := TAU * float(i) / 6.0
					var tip := c + Vector2(cos(a), sin(a)) * rad * 1.15
					s.draw_colored_polygon(PackedVector2Array([tip, c + Vector2(cos(a + 0.3), sin(a + 0.3)) * rad * 0.7,
							c + Vector2(cos(a - 0.3), sin(a - 0.3)) * rad * 0.7]), Color.WHITE)
			s.draw_circle(c, rad * 0.85, Color(1, 1, 0.95))
			s.draw_circle(c, rad * 0.7, col)
			var hexp := PackedVector2Array()
			for i in 6:
				var a := TAU * float(i) / 6.0
				hexp.append(c + Vector2(cos(a), sin(a)) * rad * 0.32)
			s.draw_colored_polygon(hexp, col.lightened(0.35))
			s.draw_arc(c, rad * 0.7, 0.0, TAU, 32, col.darkened(0.4), 2.0)
		Item.MUSHROOM:
			s.draw_rect(Rect2(c + Vector2(-rad * 0.3, 0.0), Vector2(rad * 0.6, rad * 0.65)), Color(1.0, 0.92, 0.78))
			var cap := PackedVector2Array()
			for i in 17:
				var a := PI + PI * float(i) / 16.0
				cap.append(c + Vector2(cos(a) * rad * 0.9, sin(a) * rad * 0.8 + rad * 0.05))
			s.draw_colored_polygon(cap, Color(0.95, 0.25, 0.3))
			for sp in [Vector2(-0.45, -0.3), Vector2(0.4, -0.35), Vector2(0.0, -0.6)]:
				s.draw_circle(c + sp * rad, rad * 0.17, Color.WHITE)
			s.draw_circle(c + Vector2(-0.12, 0.3) * rad, rad * 0.06, Color(0.1, 0.05, 0.1))
			s.draw_circle(c + Vector2(0.12, 0.3) * rad, rad * 0.06, Color(0.1, 0.05, 0.1))
		Item.STAR:
			var sp2 := PackedVector2Array()
			for i in 10:
				var a := -PI * 0.5 + TAU * float(i) / 10.0
				sp2.append(c + Vector2(cos(a), sin(a)) * rad * (1.0 if i % 2 == 0 else 0.45))
			var hue := Color.from_hsv(fmod(_anim * 1.5, 1.0), 0.5, 1.0)
			s.draw_colored_polygon(sp2, Color(1.0, 0.85, 0.2).lerp(hue, 0.3))
			s.draw_circle(c + Vector2(-0.15, 0.0) * rad, rad * 0.07, Color(0.1, 0.05, 0.1))
			s.draw_circle(c + Vector2(0.15, 0.0) * rad, rad * 0.07, Color(0.1, 0.05, 0.1))
		Item.BOLT:
			var bolt := PackedVector2Array([c + Vector2(0.15, -1.0) * rad, c + Vector2(-0.55, 0.12) * rad, c + Vector2(-0.05, 0.12) * rad,
					c + Vector2(-0.3, 1.0) * rad, c + Vector2(0.55, -0.2) * rad, c + Vector2(0.05, -0.2) * rad])
			s.draw_colored_polygon(bolt, Color(1.0, 0.92, 0.25))
			var closed := bolt.duplicate()
			closed.append(bolt[0])
			s.draw_polyline(closed, Color(0.75, 0.5, 0.0), 2.0)

func _draw_minimap(box: Rect2) -> void:
	var s := surface
	if _map_pts.is_empty():
		return
	s.rounded_rect(box.grow(8), 18, Color(0.05, 0.02, 0.14, 0.55))
	var scale := minf(box.size.x / _map_rect.size.x, box.size.y / _map_rect.size.y)
	var center := box.get_center()
	var mid := _map_rect.get_center()
	var pts := PackedVector2Array()
	for p in _map_pts:
		# Mirando desde arriba con el norte de la pista hacia arriba (x del mundo invertida, como la cámara).
		pts.append(center + Vector2(-(p.x - mid.x), -(p.y - mid.y)) * scale)
	pts.append(pts[0])
	s.draw_polyline(pts, Color(1, 1, 1, 0.9), 7.0, true)
	s.draw_polyline(pts, Color(0.75, 0.45, 1.0), 4.0, true)
	var start := center + Vector2(-(_tp[0].x - mid.x), -(_tp[0].z - mid.y)) * scale
	s.draw_circle(start, 4.0, Color.WHITE)
	var mine_ids: Array[int] = []
	for v in _views:
		mine_ids.append(int(v["id"]))
	# Primero los demás y encima los de este PC.
	for pass_i in 2:
		for id in _order:
			var k: Kart = _karts[id]
			var mine := mine_ids.has(id)
			if mine != (pass_i == 1):
				continue
			var pl := _player_by_id(id)
			var q := center + Vector2(-(k.dpos.x - mid.x), -(k.dpos.z - mid.y)) * scale
			s.draw_circle(q, 7.5 if mine else 5.5, Palette.WHITE)
			s.draw_circle(q, 5.5 if mine else 4.0, pl.color if pl != null else Palette.WHITE)
	for o in _objs:
		if o.kind == Obj.BLUE:
			var q2 := center + Vector2(-(o.pos.x - mid.x), -(o.pos.z - mid.y)) * scale
			s.draw_circle(q2, 5.0, Color(0.3, 0.5, 1.0))

func _draw_standings(at: Vector2, sc: float) -> void:
	var s := surface
	var rk := _ranking_ids()
	var mine_ids: Array[int] = []
	for v in _views:
		mine_ids.append(int(v["id"]))
	for i in rk.size():
		var id := rk[i]
		var pl := _player_by_id(id)
		var k: Kart = _karts[id]
		var y := at.y + float(i) * 34.0 * sc
		var mine := mine_ids.has(id)
		var row := Rect2(at.x, y, 200.0 * sc, 30.0 * sc)
		s.rounded_rect(row, 12 * sc, Color(pl.color.r, pl.color.g, pl.color.b, 0.85) if mine else Color(0.05, 0.02, 0.15, 0.6))
		_text_at(Vector2(at.x + 8 * sc, y + 23 * sc), "%d" % (i + 1), int(22 * sc), _place_color(i + 1), int(5 * sc))
		s.draw_circle(Vector2(at.x + 46 * sc, y + 15 * sc), 9 * sc, Palette.WHITE)
		s.draw_circle(Vector2(at.x + 46 * sc, y + 15 * sc), 7 * sc, pl.color if pl != null else Palette.WHITE)
		var nm := pl.display_name if pl != null else "?"
		if nm.length() > 10:
			nm = nm.substr(0, 9) + "…"
		_text_at(Vector2(at.x + 62 * sc, y + 22 * sc), nm + (" ✓" if k.finished else ""), int(19 * sc), Palette.WHITE, int(4 * sc))

# ----------------------------------------------------------------------------
# Utilidades de depuración / pruebas (tests/rainbow_kart_test.gd)
# ----------------------------------------------------------------------------

func debug_track() -> Dictionary:
	return {"n": _n, "len": _len, "ramp": _ramp_i, "boxes": _boxes.size(), "coins": _coins.size()}

func debug_kart(id: int) -> Dictionary:
	var k: Kart = _karts.get(id)
	if k == null:
		return {}
	return {"x": k.pos.x, "y": k.pos.y, "z": k.pos.z, "yaw": k.yaw, "speed": k.speed, "seg": k.seg, "d": k.d, "lap": k.lap,
			"prog": k.prog, "finished": k.finished, "fin_time": k.fin_time, "place": k.place, "state": k.state, "item": k.item,
			"item_n": k.item_n, "roulette": k.roulette_t, "coins": k.coins, "spin": k.spin_t, "boost": k.boost_t,
			"star": k.star_t, "shrink": k.shrink_t, "drift": k.drift_dir, "drift_t": k.drift_t, "air": k.air,
			"falls": k.falls, "hits": k.hits, "best_lap": k.best_lap, "inv": k.inv_t}

## Coloca un kart en el punto `i` de la pista, a `lateral` metros del centro, mirando hacia delante.
func debug_place(id: int, i: int, lateral: float = 0.0, speed: float = 0.0) -> void:
	var k: Kart = _karts.get(id)
	if k == null:
		return
	i = _wrap(i)
	k.pos = _point(i, lateral)
	k.seg = i
	k.yaw = _yaw_of(_tt[i])
	k.speed = speed
	k.air = false
	k.vy = 0.0
	k.state = 0
	k.s = _s_of(i, 0.0)
	k.prog = float(k.lap - 1) * _len + k.s
	k.safe_seg = i

## Un paso de un kart con una entrada dada (giro, abajo/arriba, pulsaciones y botón mantenido).
func debug_step(id: int, steer: float, vert: float = 0.0, press: bool = false, press2: bool = false, held: int = -1) -> void:
	var k: Kart = _karts.get(id)
	if k == null:
		return
	_t += STEP
	k.steer = steer
	k.vert = vert
	k.bot_brake = vert > 0.5
	k.press = press
	k.press2 = press2
	k.held = held
	_kart_step(k, STEP)
	k.press = false
	k.press2 = false
	_objects_step(STEP)
	_update_places()

func debug_give(id: int, item: int, n: int = 1) -> void:
	var k: Kart = _karts.get(id)
	if k != null:
		k.item = item
		k.item_n = n
		k.roulette_t = 0.0

func debug_set(id: int, field: String, value: Variant) -> void:
	var k: Kart = _karts.get(id)
	if k != null:
		k.set(field, value)

func debug_objs() -> Array:
	var out := []
	for o in _objs:
		out.append({"kind": o.kind, "pos": o.pos, "owner": o.owner, "target": o.target})
	return out

func debug_clear_objs() -> void:
	for o in _objs:
		if o.node != null and is_instance_valid(o.node):
			o.node.queue_free()
	_objs.clear()

func debug_point(i: int, lateral: float = 0.0) -> Vector3:
	return _point(i, lateral)

func debug_rail(i: int) -> bool:
	return _trail[_wrap(i)] == 1

func debug_width(i: int) -> float:
	return _tw[_wrap(i)]

func debug_ground(p: Vector3, hint: int) -> float:
	_locate(p, hint)
	return _ground()

func debug_over() -> bool:
	return _over

func debug_winner() -> int:
	return _winner_id

func debug_time() -> float:
	return _t

func debug_views() -> int:
	return _views.size()
