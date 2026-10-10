extends Minigame
## Francotiradores (id sniper_town; modelo HOST_AUTHORITATIVE, 3D en primera persona): todos contra todos con un
## rifle de francotirador en "Villa Átomo", un barrio de los años 50 hecho para este juego (idea parecida a Nuketown:
## calle en U alrededor de una isleta, dos casas enfrentadas, coches, autobús y vallas como cobertura; ni un asset
## copiado). La partida dura 2 minutos y gana quien hace más bajas (empate: menos muertes, luego quien llegó antes).
##
## Controles (persona con ratón): RATÓN apuntar · CLIC disparar · CLIC DERECHO (mantener) o E mira telescópica ·
## WASD / flechas moverse · ESPACIO saltar. Con mando: palanca izquierda moverse, derecha apuntar, A disparar,
## B saltar, X/Y mira. Teclado 2 y pantalla táctil: "tanque" (izquierda/derecha giran) con ayuda vertical al apuntar.
##
## Reglas: un disparo = una baja (es un francotirador). Sin mira el tiro se abre mucho; con la mira puesta (tarda
## SCOPE_TIME) es exacto si estás quieto. Cerrojo: FIRE_CD entre disparos. Al morir reapareces a los RESPAWN s en el
## punto de aparición más alejado de los enemigos, con SPAWN_PROT s de protección (se pierde al disparar).
##
## Se adapta al número de jugadores: con 5 o más se abren los patios traseros (más mapa y más puntos de aparición);
## con 4 o menos, las vallas los cierran y el barrio queda más recogido.
##
## Red: el host simula a todos (60 Hz) y envía el estado (~30 Hz). La mirada la decide el PC de cada persona (como en
## cualquier shooter): cada PC envía "a:<yaw>:<pitch>:<mira>:<tanque>:<saltos>" (no fiable, 30 Hz) y, al disparar,
## "f:<yaw>:<pitch>:<mira>" (fiable) por el canal de texto del minijuego; así el tiro sale exactamente hacia donde
## apuntabas. El movimiento llega por la entrada normal (move_input). Todo lo que decide bajas lo calcula el host.

const STEP := 1.0 / 60.0
const TIME_LIMIT := 120.0
const COUNTDOWN := 3.0
const DONE_DELAY := 3.0
# --- Cuerpo ---
const EYE := 1.6
const BODY_H := 1.8
const RADIUS := 0.4
const HIT_RADIUS := 0.42
const HEAD_Y := 1.42                    # por encima de esta altura (sobre los pies) el tiro es a la cabeza
const STEP_H := 0.4                     # escalón que se sube sin saltar
const WALK := 5.2
const SCOPE_WALK := 2.5
const ACCEL := 45.0
const AIR_ACCEL := 10.0
const GRAVITY := 20.0
const JUMP_V := 6.6                     # ≈ 1,1 m: se saltan las vallas bajas
# --- Rifle ---
const FIRE_CD := 1.25
const SCOPE_TIME := 0.22
const RESPAWN := 2.6
const SPAWN_PROT := 1.5
const RANGE := 160.0
const HIP_SPREAD := 0.08                # rad: sin mira
const MOVE_SPREAD := 0.025              # con mira pero moviéndote
const AIR_SPREAD := 0.12                # en el aire
const FOV := 75.0
const SCOPE_FOV := 20.0
const MOUSE_SENS := 0.0024
const PITCH_MAX := 1.35
const TANK_TURN := 2.4                  # rad/s girando con teclado 2 / táctil
# --- Mapa ---
const BIG_MAP_PLAYERS := 5              # desde aquí se abren los patios traseros
const WALL_H := 3.0
const WALL_T := 0.3
const CELL := 0.5                       # rejilla de navegación de la IA
const RADAR_RANGE := 34.0
const BUCKET := 2.0
const NO_BOXES: Array[int] = []

class SP:
	var id: int = 0
	var idx: int = 0
	var x: float = 0.0
	var z: float = 0.0
	var h: float = 0.0
	var vx: float = 0.0
	var vz: float = 0.0
	var vh: float = 0.0
	var yaw: float = 0.0
	var pitch: float = 0.0
	var alive: bool = true
	var dead_t: float = 0.0
	var inv_t: float = 0.0
	var kills: int = 0
	var deaths: int = 0
	var streak: int = 0
	var last_kill_t: float = 0.0
	var scoped: bool = false
	var scope_t: float = 0.0
	var cd: float = 0.0
	var tank: bool = false
	var fire_pending: bool = false
	var jump_pending: bool = false
	var jump_count: int = 0
	var killer: int = -1
	var grounded: bool = true
	var text_t: float = -10.0           # (host) último mensaje de mirada recibido de su PC
	# IA
	var skill: float = 1.0
	var bot_rng: RandomNumberGenerator = null
	var bot_path: PackedVector2Array = PackedVector2Array()
	var bot_pi: int = 0
	var bot_goal_t: float = 0.0
	var bot_target: int = -1
	var bot_react: float = 0.0
	var bot_err_y: float = 0.0
	var bot_err_p: float = 0.0
	var bot_think: float = 0.0
	var bot_strafe: float = 1.0
	var bot_strafe_t: float = 0.0
	var bot_last: Vector2 = Vector2.ZERO
	var bot_stuck_t: float = 0.0
	var bot_wish: Vector2 = Vector2.ZERO
	var bot_heard: Vector2 = Vector2.ZERO
	var bot_heard_t: float = 0.0
	# Presentación
	var dx: float = 0.0
	var dz: float = 0.0
	var dh: float = 0.0
	var dyaw: float = 0.0
	var dpitch: float = 0.0
	var anim: float = 0.0
	var fall: float = 0.0
	var flash_t: float = 0.0
	var node: Node3D = null
	var body: Node3D = null
	var gun: Node3D = null
	var arm_l: Node3D = null
	var arm_r: Node3D = null
	var leg_l: Node3D = null
	var leg_r: Node3D = null
	var shield: MeshInstance3D = null
	var flash: OmniLight3D = null

const FLOATS := 16

var _sp: Dictionary = {}                # player id -> SP
var _order: Array[int] = []
var _t: float = 0.0
var _cd: float = COUNTDOWN
var _last_cd: int = 99
var _accum: float = 0.0
var _over: bool = false
var _over_t: float = 0.0
var _winner_id: int = -1
var _fire_rng: RandomNumberGenerator = RandomNumberGenerator.new()
var debug_skill: float = -1.0           # >= 0: fuerza la habilidad de todas las IAs (pruebas)

# --- Mapa (igual en todos los PC: sale solo del nº de jugadores) ---
var _big: bool = true
var _bounds: Vector2 = Vector2(30.6, 19.6)
var _solids: Array[AABB] = []
var _pieces: Array = []                 # {"b": AABB, "k": String}
var _spawns: Array[Vector3] = []        # (x, z, yaw)
var _roam: Array[Vector2] = []
var _radar_rects: Array[Rect2] = []
var _nav: AStarGrid2D = null
var _bucket: Dictionary = {}            # celda de BUCKET m -> índices de _solids cercanos (acelera choques y vista)
var _stamps: PackedInt32Array = PackedInt32Array()
var _stamp: int = 0
var _nav_size: Vector2i = Vector2i.ZERO

# --- Controles del PC (solo jugadores de este PC) ---
var _aim: Dictionary = {}               # id -> Vector2(yaw, pitch)
var _scope_toggle: Dictionary = {}      # id -> bool
var _jumps: Dictionary = {}             # id -> contador de saltos enviados
var _aim_send_t: float = 0.0
var _mouse_delta: Vector2 = Vector2.ZERO
var _lmb: bool = false
var _rmb_held: bool = false
var _space: bool = false
var _pad_scope: bool = false
var _captured: bool = false
var _view_id: int = -1

# --- HUD ---
var _anim: float = 0.0
var _hint_t: float = 8.0
var _feed: Array = []                   # {"k", "v", "hs", "t"}
var _toast: String = ""
var _toast_col: Color = Color.WHITE
var _toast_t: float = 0.0
var _hitmark_t: float = 0.0
var _hitmark_kill: bool = false
var _scope_blend: float = 0.0
var _recoil: float = 0.0
var _shake: float = 0.0
var _radar_sweep: float = 0.0

# --- Escena 3D ---
var _vp: SubViewport
var _cont: SubViewportContainer
var _gvp: SubViewport                   # arma en primera persona (mundo propio, encima)
var _gcont: SubViewportContainer
var _root3: Node3D
var _cam: Camera3D
var _gcam: Camera3D
var _viewmodel: Node3D = null
var _vm_bolt: Node3D = null
var _vm_flash: MeshInstance3D = null
var _vm_sleeve_mat: StandardMaterial3D = null
var _built: bool = false
var _tracers: Array = []                # {"n": MeshInstance3D, "t": float, "m": StandardMaterial3D}
var _puffs: Array[CPUParticles3D] = []
var _puff_i: int = 0
var _death_look: Vector3 = Vector3.ZERO
var _mat_cache: Dictionary = {}

# ----------------------------------------------------------------------------
# Utilidades
# ----------------------------------------------------------------------------

func _player_by_id(id: int) -> PlayerData:
	for pl in players:
		if pl.id == id:
			return pl
	return null

func _name_of(id: int) -> String:
	var pl := _player_by_id(id)
	return pl.display_name if pl != null else "?"

func _color_of(id: int) -> Color:
	var pl := _player_by_id(id)
	return pl.color if pl != null else Palette.WHITE

## Dirección de la mirada (yaw 0 = hacia -z; pitch > 0 = hacia arriba).
static func aim_dir(yaw: float, pitch: float) -> Vector3:
	return Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))

static func yaw_to(dx: float, dz: float) -> float:
	return atan2(-dx, -dz)

func _eye(r: SP) -> Vector3:
	return Vector3(r.x, r.h + EYE, r.z)

## Lo maneja una persona en ESTE PC (no un bot ni el autopiloto).
func _owns(p: PlayerData) -> bool:
	return p != null and p.is_local_human and not InputManager.is_simulated(p.id)

## Quién usa el ratón en este PC: online, su jugador; en local, teclado 1 (o el primero que pueda).
func _mouse_player() -> PlayerData:
	if InputManager.touch_mode:
		return null
	if local_player != null and _owns(local_player) and (local_player.device == PlayerData.DEVICE_LOCAL or local_player.device == PlayerData.DEVICE_KB1):
		return local_player
	for p in players:
		if _owns(p) and (p.device == PlayerData.DEVICE_KB1 or p.device == PlayerData.DEVICE_LOCAL):
			return p
	return null

## Jugadores que giran "en tanque" (sin ratón ni segunda palanca): teclado 2 y táctil.
func _is_tank(p: PlayerData) -> bool:
	if p == null or p == _mouse_player():
		return false
	return InputManager.touch_mode or p.device == PlayerData.DEVICE_KB2 or p.device == PlayerData.DEVICE_LOCAL

func _mine(id: int) -> bool:
	var pl := _player_by_id(id)
	return pl != null and is_audible(pl)

# ----------------------------------------------------------------------------
# Mapa "Villa Átomo": todo son cajas alineadas con los ejes (colisión, tiros y vista salen de la misma lista).
# Simétrico respecto al centro (x, z) → (-x, -z): las dos mitades son iguales para los dos lados.
# ----------------------------------------------------------------------------

## Caja de x0..x1, y0..y1, z0..z1 y, si sym, su gemela girada 180º (con otro tipo si se indica).
func _add_box(kind: String, x0: float, x1: float, y0: float, y1: float, z0: float, z1: float, sym: bool = true, kind_b: String = "", solid: bool = true) -> void:
	var b := AABB(Vector3(minf(x0, x1), y0, minf(z0, z1)), Vector3(absf(x1 - x0), y1 - y0, absf(z1 - z0)))
	_pieces.append({"b": b, "k": kind, "s": solid})
	if solid:
		_solids.append(b)
	if sym:
		var m := AABB(Vector3(-b.end.x, y0, -b.end.z), b.size)
		_pieces.append({"b": m, "k": kind_b if kind_b != "" else kind, "s": solid})
		if solid:
			_solids.append(m)

## Pared a lo largo de z (en x fija) con huecos [a, b, y0, y1] (puertas y ventanas).
func _wall_z(kind: String, x: float, z0: float, z1: float, holes: Array) -> void:
	_wall(kind, true, x, z0, z1, holes)

## Pared a lo largo de x (en z fija).
func _wall_x(kind: String, z: float, x0: float, x1: float, holes: Array) -> void:
	_wall(kind, false, z, x0, x1, holes)

func _wall(kind: String, along_z: bool, at: float, a0: float, a1: float, holes: Array) -> void:
	var hs := holes.duplicate()
	hs.sort_custom(func(p: Array, q: Array) -> bool: return float(p[0]) < float(q[0]))
	var cur := a0
	var t := WALL_T * 0.5
	for hole in hs:
		var ha: float = hole[0]
		var hb: float = hole[1]
		var hy0: float = hole[2]
		var hy1: float = hole[3]
		if ha > cur:
			_seg(kind, along_z, at, t, cur, ha, 0.0, WALL_H)
		if hy0 > 0.0:
			_seg(kind, along_z, at, t, ha, hb, 0.0, hy0)
		if hy1 < WALL_H:
			_seg(kind, along_z, at, t, ha, hb, hy1, WALL_H)
		cur = hb
	if cur < a1:
		_seg(kind, along_z, at, t, cur, a1, 0.0, WALL_H)

func _seg(kind: String, along_z: bool, at: float, t: float, a: float, b: float, y0: float, y1: float) -> void:
	var kb := kind.replace("_w", "_e")
	if along_z:
		_add_box(kind, at - t, at + t, y0, y1, a, b, true, kb)
	else:
		_add_box(kind, a, b, y0, y1, at - t, at + t, true, kb)

func _build_map(n: int) -> void:
	_big = n >= BIG_MAP_PLAYERS
	_bounds = Vector2(30.6 if _big else 25.6, 19.6)
	_solids.clear()
	_pieces.clear()
	_spawns.clear()
	_roam.clear()
	_radar_rects.clear()
	var door := [0.0, 2.3]
	var win := [1.0, 2.1]
	# --- Casa oeste (la este es su gemela): 10 × 13 m, puerta y dos ventanas a la calle ---
	_wall_z("wall_w", -16.0, -6.5, 6.5, [[-0.9, 0.9] + door, [-4.6, -2.6] + win, [2.6, 4.6] + win])
	var back_holes: Array = [[-3.8, -1.8] + win]
	if _big:
		back_holes.append([2.3, 3.9] + door)
	_wall_z("wall_w", -26.0, -6.5, 6.5, back_holes)
	_wall_x("wall_w", -6.5, -26.15, -15.85, [[-25.2, -23.6] + door, [-21.0, -19.0] + win])
	_wall_x("wall_w", 6.5, -26.15, -15.85, [[-19.6, -17.6] + win])
	_wall_z("inner_w", -21.0, -6.35, 6.35, [[-5.4, -3.6] + door, [1.2, 3.0] + door])
	_add_box("ceil_w", -26.15, -15.85, WALL_H, WALL_H + 0.25, -6.65, 6.65, true, "ceil_e")
	# Muebles (cobertura baja dentro).
	_add_box("sofa", -20.4, -19.5, 0.0, 0.85, -3.2, 0.6)
	_add_box("table", -18.6, -17.4, 0.0, 0.8, 2.9, 5.2)
	_add_box("counter", -25.85, -25.0, 0.0, 0.95, -6.35, -4.2)
	_add_box("fridge", -25.85, -25.0, 0.0, 1.95, -0.9, 0.1)
	_add_box("bed", -24.6, -22.4, 0.0, 0.6, 3.9, 6.35)
	# Garaje (cerrado) pegado a la casa.
	_add_box("garage_w", -26.15, -20.0, 0.0, WALL_H, 6.65, 11.0, true, "garage_e")
	_radar_rects.append(Rect2(-26.15, -6.65, 10.3, 13.3))
	_radar_rects.append(Rect2(-26.15, 6.65, 6.15, 4.35))
	# --- Vallas blancas del jardín delantero (se pueden saltar) ---
	_add_box("fence", -13.06, -12.94, 0.0, 1.0, -12.0, -3.0)
	_add_box("fence", -13.06, -12.94, 0.0, 1.0, 3.0, 6.8)
	_add_box("fence", -26.0, -21.0, 0.0, 1.0, -12.06, -11.94)
	_add_box("fence", -18.5, -13.0, 0.0, 1.0, -12.06, -11.94)
	# --- Isleta central con la estatua del átomo y jardineras ---
	_add_box("statue", -0.5, 0.5, 0.0, 3.4, -0.5, 0.5, false)
	_add_box("planter", -4.6, -3.4, 0.0, 0.6, -3.1, -1.9)
	_add_box("planter", -4.6, -3.4, 0.0, 0.6, 1.9, 3.1)
	# --- Coches ---
	_car(-8.5, 6.1, true)
	_car(-2.9, -10.0, false)
	_car(-16.4, 8.8, false)
	# Autobús escolar (y su gemela: una furgoneta de reparto) al fondo de la U.
	_add_box("bus", -1.0, 9.0, 0.0, 3.0, -17.6, -15.0, true, "truck")
	_radar_rects.append(Rect2(-1.0, -17.6, 10.0, 2.6))
	# Árboles, farolas y caseta del patio.
	_add_box("trunk", -12.3, -11.7, 0.0, 3.2, -17.8, -17.2)
	_add_box("trunk", -9.3, -8.7, 0.0, 3.2, 14.2, 14.8)
	_add_box("lamp", -11.6, -11.4, 0.0, 4.4, -4.9, -4.7)
	_add_box("lamp", -11.6, -11.4, 0.0, 4.4, 10.6, 10.8)
	if _big:
		_add_box("shed", -30.4, -28.2, 0.0, 2.4, -14.2, -11.2)
		_add_box("trunk", -29.3, -28.7, 0.0, 3.2, 3.2, 3.8)
		_add_box("fence", -30.6, -26.15, 0.0, 1.0, 8.94, 9.06)
		_radar_rects.append(Rect2(-30.4, -14.2, 2.2, 3.0))
	else:
		# Patios cerrados: valla alta a lo largo de la parte de atrás de las casas.
		_add_box("fence_tall", -26.2, -25.8, 0.0, 2.6, -19.6, -6.65)
		_add_box("fence_tall", -26.2, -25.8, 0.0, 2.6, 11.0, 19.6)
	# Límites: valla alta alrededor (los tiros que se salen chocan con ella).
	var bx := _bounds.x + 0.4
	var bz := _bounds.y + 0.4
	_add_box("fence_tall", -bx - 0.2, -bx + 0.2, 0.0, 2.6, -bz, bz)
	_add_box("fence_tall", -bx, bx, 0.0, 2.6, -bz - 0.2, -bz + 0.2)
	# Rectángulos del radar de la mitad este (gemelos).
	var half := _radar_rects.size()
	for i in half:
		var rc: Rect2 = _radar_rects[i]
		_radar_rects.append(Rect2(-rc.end.x, -rc.end.y, rc.size.x, rc.size.y))
	# --- Puntos de aparición (por parejas: oeste, este...) ---
	var pts: Array[Vector2] = [Vector2(-23.5, -2.0), Vector2(-9.0, -15.5), Vector2(-17.0, 15.0), Vector2(-7.0, 0.0),
			Vector2(-18.4, -2.0)]
	if _big:
		pts.append(Vector2(-28.5, 0.0))
		pts.append(Vector2(-28.5, 16.0))
	for pt in pts:
		_spawns.append(Vector3(pt.x, pt.y, yaw_to(-pt.x, -pt.y)))
		_spawns.append(Vector3(-pt.x, -pt.y, yaw_to(pt.x, pt.y)))
	# Puntos a los que pasean los bots.
	for s in _spawns:
		_roam.append(Vector2(s.x, s.y))
	for pt in [Vector2(-9.5, -2.0), Vector2(-3.0, -6.0), Vector2(-14.5, -8.0), Vector2(-20.0, -9.0), Vector2(-2.0, 13.0)]:
		_roam.append(pt)
		_roam.append(-pt)
	_build_buckets()

## Cada caja se apunta en las celdas de BUCKET m que toca (con 1 m de margen).
func _build_buckets() -> void:
	_bucket.clear()
	_stamps.resize(_solids.size())
	_stamps.fill(0)
	for i in _solids.size():
		var b := _solids[i]
		for cx in range(floori((b.position.x - 1.0) / BUCKET), floori((b.end.x + 1.0) / BUCKET) + 1):
			for cz in range(floori((b.position.z - 1.0) / BUCKET), floori((b.end.z + 1.0) / BUCKET) + 1):
				var key := Vector2i(cx, cz)
				if not _bucket.has(key):
					var arr: Array[int] = []
					_bucket[key] = arr
				(_bucket[key] as Array[int]).append(i)

func _near(x: float, z: float) -> Array[int]:
	return _bucket.get(Vector2i(floori(x / BUCKET), floori(z / BUCKET)), NO_BOXES)

## Coche: carrocería + cabina (dos cajas). along_z: el coche mira a lo largo de z.
func _car(cx: float, cz: float, along_z: bool) -> void:
	var l := 4.2
	var w := 1.9
	var hx := (w if along_z else l) * 0.5
	var hz := (l if along_z else w) * 0.5
	var k := "car_z" if along_z else "car_x"
	_add_box(k, cx - hx, cx + hx, 0.0, 1.0, cz - hz, cz + hz)
	var cl := 2.2
	var cw := 1.7
	var chx := (cw if along_z else cl) * 0.5
	var chz := (cl if along_z else cw) * 0.5
	_add_box("cab", cx - chx, cx + chx, 1.0, 1.55, cz - chz, cz + chz)
	_radar_rects.append(Rect2(cx - hx, cz - hz, hx * 2.0, hz * 2.0))

# ----------------------------------------------------------------------------
# Física (cajas)
# ----------------------------------------------------------------------------

func _blocks(b: AABB, h: float) -> bool:
	return b.end.y > h + STEP_H and b.position.y < h + BODY_H

func _circle_hits(b: AABB, x: float, z: float, rad: float) -> bool:
	var cx := clampf(x, b.position.x, b.end.x)
	var cz := clampf(z, b.position.z, b.end.z)
	return (x - cx) * (x - cx) + (z - cz) * (z - cz) < rad * rad

func _collide(r: SP) -> void:
	for pass_i in 2:
		for bi in _near(r.x, r.z):
			var b := _solids[bi]
			if not _blocks(b, r.h):
				continue
			var cx := clampf(r.x, b.position.x, b.end.x)
			var cz := clampf(r.z, b.position.z, b.end.z)
			var ddx := r.x - cx
			var ddz := r.z - cz
			var d2 := ddx * ddx + ddz * ddz
			if d2 >= RADIUS * RADIUS:
				continue
			if d2 > 1e-8:
				var d := sqrt(d2)
				r.x += ddx / d * (RADIUS - d)
				r.z += ddz / d * (RADIUS - d)
			else:
				# Dentro de la caja: sale por la cara más cercana.
				var outs := [r.x - b.position.x, b.end.x - r.x, r.z - b.position.z, b.end.z - r.z]
				var mi := 0
				for i in 4:
					if float(outs[i]) < float(outs[mi]):
						mi = i
				match mi:
					0: r.x = b.position.x - RADIUS
					1: r.x = b.end.x + RADIUS
					2: r.z = b.position.z - RADIUS
					3: r.z = b.end.z + RADIUS
	r.x = clampf(r.x, -_bounds.x, _bounds.x)
	r.z = clampf(r.z, -_bounds.y, _bounds.y)

## Altura del suelo bajo (x, z) para alguien con los pies en h (cajas a las que se puede subir).
func _floor_at(x: float, z: float, h: float) -> float:
	var f := 0.0
	for bi in _near(x, z):
		var b := _solids[bi]
		if b.end.y <= h + STEP_H + 0.001 and b.end.y > f and _circle_hits(b, x, z, RADIUS * 0.6):
			f = b.end.y
	return f

## ¿Choca el segmento a→b con el mapa?
func _los(a: Vector3, b: Vector3) -> bool:
	_stamp += 1
	var n := int(ceil(Vector2(b.x - a.x, b.z - a.z).length())) + 1
	for i in n + 1:
		var p := a.lerp(b, float(i) / float(n))
		for bi in _near(p.x, p.z):
			if _stamps[bi] == _stamp:
				continue
			_stamps[bi] = _stamp
			if _solids[bi].intersects_segment(a, b) != null:
				return false
	return true

## Rayo desde o en dirección d: lo primero que toca (mapa, suelo o jugador).
func _raycast(o: Vector3, d: Vector3, ignore: int) -> Dictionary:
	var best := RANGE
	if d.y < -0.0001:
		best = minf(best, -o.y / d.y)
	for b in _solids:
		var hit: Variant = b.intersects_ray(o, d)
		if hit != null:
			var t := ((hit as Vector3) - o).length()
			if t < best:
				best = t
	var victim := -1
	var hs := false
	for id in _order:
		if id == ignore:
			continue
		var r: SP = _sp[id]
		if not r.alive:
			continue
		var t2 := _ray_body(o, d, r)
		if t2 >= 0.0 and t2 < best:
			best = t2
			victim = id
			hs = o.y + d.y * t2 > r.h + HEAD_Y
	return {"t": best, "v": victim, "hs": hs, "p": o + d * best}

## Rayo contra el cuerpo (cilindro vertical de HIT_RADIUS y BODY_H). Devuelve t o -1.
func _ray_body(o: Vector3, d: Vector3, r: SP) -> float:
	var ox := o.x - r.x
	var oz := o.z - r.z
	var a := d.x * d.x + d.z * d.z
	if a < 1e-6:
		return -1.0
	var b := 2.0 * (ox * d.x + oz * d.z)
	var c := ox * ox + oz * oz - HIT_RADIUS * HIT_RADIUS
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return -1.0
	var sq := sqrt(disc)
	for t in [(-b - sq) / (2.0 * a), (-b + sq) / (2.0 * a)]:
		if t > 0.0:
			var y: float = o.y + d.y * t
			if y >= r.h and y <= r.h + BODY_H:
				return t
	return -1.0

# ----------------------------------------------------------------------------
# Navegación de la IA (rejilla A* sobre el mapa)
# ----------------------------------------------------------------------------

func _build_nav() -> void:
	_nav = AStarGrid2D.new()
	_nav_size = Vector2i(int(ceil(_bounds.x * 2.0 / CELL)), int(ceil(_bounds.y * 2.0 / CELL)))
	_nav.region = Rect2i(Vector2i.ZERO, _nav_size)
	_nav.cell_size = Vector2.ONE
	_nav.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_nav.update()
	var rad := RADIUS + 0.06
	for b in _solids:
		if not _blocks(b, 0.0):
			continue
		var c0 := _cell_of(Vector2(b.position.x - rad, b.position.z - rad))
		var c1 := _cell_of(Vector2(b.end.x + rad, b.end.z + rad))
		for i in range(c0.x, c1.x + 1):
			for j in range(c0.y, c1.y + 1):
				var w := _cell_center(Vector2i(i, j))
				if _circle_hits(b, w.x, w.y, rad):
					_nav.set_point_solid(Vector2i(i, j), true)

func _cell_of(p: Vector2) -> Vector2i:
	return Vector2i(clampi(int(floor((p.x + _bounds.x) / CELL)), 0, _nav_size.x - 1),
			clampi(int(floor((p.y + _bounds.y) / CELL)), 0, _nav_size.y - 1))

func _cell_center(c: Vector2i) -> Vector2:
	return Vector2(-_bounds.x + (c.x + 0.5) * CELL, -_bounds.y + (c.y + 0.5) * CELL)

func _free_cell(c: Vector2i) -> Vector2i:
	if not _nav.is_point_solid(c):
		return c
	for rad in range(1, 8):
		for i in range(-rad, rad + 1):
			for j in range(-rad, rad + 1):
				var q := c + Vector2i(i, j)
				if _nav.is_in_boundsv(q) and not _nav.is_point_solid(q):
					return q
	return c

## Camino (puntos del mundo xz) de a a b; vacío si no hay.
func nav_path(a: Vector2, b: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	if _nav == null:
		return out
	var ids := _nav.get_id_path(_free_cell(_cell_of(a)), _free_cell(_cell_of(b)))
	for c in ids:
		out.append(_cell_center(c))
	return out

## ¿Se puede ir andando en línea recta de a a b?
## (con la rejilla de la IA, que ya tiene las paredes engordadas con el radio del cuerpo)
func _walk_clear(a: Vector2, b: Vector2) -> bool:
	var n := int(ceil(a.distance_to(b) / (CELL * 0.5)))
	for i in range(1, n + 1):
		if _nav.is_point_solid(_cell_of(a.lerp(b, float(i) / float(n)))):
			return false
	return true

# ----------------------------------------------------------------------------
# Ciclo del minijuego
# ----------------------------------------------------------------------------

func _make_sp(p: PlayerData, idx: int) -> SP:
	var r := SP.new()
	r.id = p.id
	r.idx = idx
	var s: Vector3 = _spawns[idx % _spawns.size()]
	r.x = s.x
	r.z = s.y
	r.yaw = s.z
	r.dx = r.x
	r.dz = r.z
	r.dyaw = r.yaw
	r.bot_rng = RandomNumberGenerator.new()
	r.bot_rng.seed = hash([seed_value, p.id, "sniper"])
	r.skill = 0.55 + 0.4 * r.bot_rng.randf()
	r.bot_last = Vector2(r.x, r.z)
	return r

func _setup_players() -> void:
	_sp.clear()
	_order.clear()
	_aim.clear()
	_scope_toggle.clear()
	_jumps.clear()
	for i in players.size():
		var p := players[i]
		var r := _make_sp(p, i)
		_sp[p.id] = r
		_order.append(p.id)
		_aim[p.id] = Vector2(r.yaw, 0.0)

func _on_prepare() -> void:
	_build_map(players.size())
	if is_authority:
		_build_nav()
	_setup_players()
	_build_world()
	surface.draw_callback = _draw_hud

func _on_start() -> void:
	_setup_players()
	_rebuild_player_nodes()
	_fire_rng.seed = hash([seed_value, "fire"])
	_t = 0.0
	_accum = 0.0
	_cd = COUNTDOWN
	_last_cd = 99
	_over = false
	_over_t = 0.0
	_winner_id = -1
	_hint_t = 8.0
	_feed.clear()
	_toast_t = 0.0
	_view_id = _pick_view_id()
	_lmb = false
	_space = false
	if _want_capture():
		_capture()

func _exit_tree() -> void:
	_release_mouse()

func _simulate(delta: float) -> void:
	if _over:
		_over_t += delta
		if _over_t >= DONE_DELAY:
			finish(ranking_ids())
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
	_accum += delta
	var steps := 0
	while _accum >= STEP and steps < 12:
		_accum -= STEP
		steps += 1
		_t += STEP
		for pl in players:
			var r: SP = _sp[pl.id]
			if _ai(pl, r):
				_bot_step(r, STEP)
			_sim_step(r, pl, STEP)
	if _t >= TIME_LIMIT:
		_over = true
		_over_t = 0.0
		var rk := ranking_ids()
		_winner_id = rk[0] if not rk.is_empty() else -1
		send_event("over", {"w": _winner_id})
		DevCli.log_event("sniper_town over winner=%d kills=%s" % [_winner_id, str(_kills_list())])

## ¿Lo maneja la IA del host? Bots y autopiloto; también un jugador remoto cuyo PC no manda su mirada (un cliente
## con el autopiloto de pruebas, o uno que se ha quedado colgado): sin mirada no podría apuntar.
func _ai(pl: PlayerData, r: SP) -> bool:
	if InputManager.is_simulated(pl.id):
		return true
	return pl.is_remote and _t - r.text_t > 2.0

func _kills_list() -> Array[int]:
	var out: Array[int] = []
	for id in _order:
		out.append((_sp[id] as SP).kills)
	return out

func _sim_step(r: SP, pl: PlayerData, dt: float) -> void:
	r.cd = maxf(0.0, r.cd - dt)
	r.inv_t = maxf(0.0, r.inv_t - dt)
	if not r.alive:
		r.dead_t += dt
		r.fire_pending = false
		r.jump_pending = false
		if r.dead_t >= RESPAWN and not _over:
			_respawn(r)
		return
	r.scope_t = r.scope_t + dt if r.scoped else 0.0
	# Movimiento deseado (mundo xz).
	var wish := Vector2.ZERO
	if _ai(pl, r):
		wish = r.bot_wish
	else:
		var v := move_input(pl)
		var fwd := Vector2(-sin(r.yaw), -cos(r.yaw))
		var right := Vector2(cos(r.yaw), -sin(r.yaw))
		wish = fwd * (-v.y) + (Vector2.ZERO if r.tank else right * v.x)
	if wish.length() > 1.0:
		wish = wish.normalized()
	var speed := SCOPE_WALK if r.scoped else WALK
	var a := ACCEL if r.grounded else AIR_ACCEL
	r.vx = move_toward(r.vx, wish.x * speed, a * dt)
	r.vz = move_toward(r.vz, wish.y * speed, a * dt)
	if r.jump_pending and r.grounded:
		r.vh = JUMP_V
		r.grounded = false
	r.jump_pending = false
	r.x += r.vx * dt
	r.z += r.vz * dt
	_collide(r)
	var fl := _floor_at(r.x, r.z, r.h)
	if not r.grounded or r.h > fl + 0.001:
		r.vh -= GRAVITY * dt
		r.h += r.vh * dt
		if r.h <= fl:
			r.h = fl
			r.vh = 0.0
			r.grounded = true
		else:
			r.grounded = false
	else:
		r.h = fl
	# Disparo.
	if r.fire_pending:
		r.fire_pending = false
		if r.cd <= 0.0 and not _over:
			_fire(r)

func _spread(r: SP) -> float:
	if not r.grounded:
		return AIR_SPREAD
	if not r.scoped or r.scope_t < SCOPE_TIME:
		return HIP_SPREAD
	return MOVE_SPREAD if Vector2(r.vx, r.vz).length() > 0.8 else 0.0

func _fire(r: SP) -> void:
	r.cd = FIRE_CD
	r.inv_t = 0.0
	var d := aim_dir(r.yaw, r.pitch)
	var sp := _spread(r)
	if sp > 0.0:
		var ang := _fire_rng.randf() * TAU
		var off := sqrt(_fire_rng.randf()) * sp
		var up := Vector3.UP if absf(d.y) < 0.95 else Vector3.RIGHT
		var u := d.cross(up).normalized()
		var w := d.cross(u).normalized()
		d = (d + (u * cos(ang) + w * sin(ang)) * tan(off)).normalized()
	var o := _eye(r)
	var hit := _raycast(o, d, r.id)
	var victim: int = hit["v"]
	send_event("shot", {"p": r.id, "o": o, "e": hit["p"], "v": victim})
	# Los bots oyen el disparo.
	for id in _order:
		var b: SP = _sp[id]
		if b != r and Vector2(b.x - r.x, b.z - r.z).length() < 38.0:
			b.bot_heard = Vector2(r.x, r.z)
			b.bot_heard_t = 4.0
	if victim >= 0:
		var v: SP = _sp[victim]
		if v.inv_t <= 0.0:
			_kill(r, v, bool(hit["hs"]))

func _kill(k: SP, v: SP, hs: bool) -> void:
	v.alive = false
	v.dead_t = 0.0
	v.deaths += 1
	v.streak = 0
	v.killer = k.id
	v.scoped = false
	v.vx = 0.0
	v.vz = 0.0
	k.kills += 1
	k.streak += 1
	k.last_kill_t = _t
	send_event("kill", {"k": k.id, "v": v.id, "hs": hs, "st": k.streak})

## Punto de aparición más seguro: lejos de los enemigos vivos y, a ser posible, fuera de su vista.
func _pick_spawn(r: SP) -> Vector3:
	var best: Vector3 = _spawns[0]
	var best_s := -INF
	for s in _spawns:
		var p := Vector2(s.x, s.y)
		var min_d := 45.0
		var seen := false
		var crowded := false
		for id in _order:
			var o: SP = _sp[id]
			if o == r or not o.alive:
				continue
			var dd := p.distance_to(Vector2(o.x, o.z))
			if dd < 1.6:
				crowded = true
			min_d = minf(min_d, dd)
			if not seen and dd < 60.0 and _los(_eye(o), Vector3(p.x, EYE, p.y)):
				seen = true
		var score := min_d - (14.0 if seen else 0.0) - (100.0 if crowded else 0.0) + _fire_rng.randf() * 4.0
		if score > best_s:
			best_s = score
			best = s
	return best

func _respawn(r: SP) -> void:
	var s := _pick_spawn(r)
	r.x = s.x
	r.z = s.y
	r.h = 0.0
	r.vx = 0.0
	r.vz = 0.0
	r.vh = 0.0
	r.grounded = true
	r.yaw = s.z
	r.pitch = 0.0
	r.alive = true
	r.dead_t = 0.0
	r.inv_t = SPAWN_PROT
	r.scoped = false
	r.scope_t = 0.0
	r.cd = 0.3
	r.bot_path = PackedVector2Array()
	r.bot_target = -1
	r.bot_goal_t = 0.0
	send_event("spawn", {"p": r.id, "x": r.x, "z": r.z, "y": r.yaw})

## Más bajas primero; a igualdad, menos muertes y luego quien consiguió antes su última baja.
func ranking_ids() -> Array[int]:
	var scores := {}
	var ties := {}
	for id in _order:
		var r: SP = _sp[id]
		scores[id] = float(r.kills)
		ties[id] = float(r.deaths) * 1000.0 + r.last_kill_t
	return rank_by_score(scores, ties)

func _place_of(id: int) -> int:
	return ranking_ids().find(id) + 1

# ----------------------------------------------------------------------------
# Entrada de las personas de este PC (mirada en el propio PC; ver cabecera)
# ----------------------------------------------------------------------------

func _want_capture() -> bool:
	return not demo and is_running and not _over and _mouse_player() != null and DisplayServer.get_name() != "headless"

func _capture() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_captured = true

func _release_mouse() -> void:
	if _captured:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_captured = false

func _unhandled_input(event: InputEvent) -> void:
	if not is_running:
		return
	var me := _mouse_player()
	if me == null:
		return
	if event is InputEventMouseMotion:
		if _captured or demo:
			_mouse_delta += (event as InputEventMouseMotion).relative
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if _want_capture() and not _captured:
				_capture()
				return
			_lmb = true
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_rmb_held = mb.pressed
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			match k.physical_keycode:
				KEY_SPACE: _space = true
				KEY_E: _scope_toggle[me.id] = not bool(_scope_toggle.get(me.id, false))
				KEY_ESCAPE: _release_mouse()
	elif event is InputEventJoypadButton and me.device == PlayerData.DEVICE_LOCAL:
		var jb := event as InputEventJoypadButton
		if jb.pressed:
			match jb.button_index:
				JOY_BUTTON_A, JOY_BUTTON_RIGHT_SHOULDER: _lmb = true
				JOY_BUTTON_B: _space = true
				JOY_BUTTON_X, JOY_BUTTON_Y, JOY_BUTTON_LEFT_SHOULDER: _scope_toggle[me.id] = not bool(_scope_toggle.get(me.id, false))
	elif event is InputEventJoypadMotion and me.device == PlayerData.DEVICE_LOCAL:
		var jm := event as InputEventJoypadMotion
		if jm.axis == JOY_AXIS_TRIGGER_LEFT:
			_pad_scope = jm.axis_value > 0.5
		elif jm.axis == JOY_AXIS_TRIGGER_RIGHT and jm.axis_value > 0.6:
			_lmb = true

func _right_stick(p: PlayerData) -> Vector2:
	var joy := -1
	if p.device.begins_with(PlayerData.DEVICE_JOY_PREFIX):
		joy = int(p.device.substr(PlayerData.DEVICE_JOY_PREFIX.length()))
	elif p.device == PlayerData.DEVICE_LOCAL:
		var pads := Input.get_connected_joypads()
		joy = pads[0] if not pads.is_empty() else -1
	if joy < 0:
		return Vector2.ZERO
	var v := Vector2(Input.get_joy_axis(joy, JOY_AXIS_RIGHT_X), Input.get_joy_axis(joy, JOY_AXIS_RIGHT_Y))
	return v if v.length() > 0.2 else Vector2.ZERO

## Ayuda vertical (tanque/táctil): inclina la mirada hacia el enemigo que tienes delante.
func _assist_pitch(r: SP, yaw: float) -> float:
	var best := 0.0
	var best_d := INF
	var e := _eye(r)
	for id in _order:
		var o: SP = _sp[id]
		if o == r or not o.alive:
			continue
		var dx := o.x - r.x
		var dz := o.z - r.z
		var dist := sqrt(dx * dx + dz * dz)
		if dist < 0.5 or dist > 80.0:
			continue
		if absf(angle_difference(yaw, yaw_to(dx, dz))) > 0.25:
			continue
		if dist < best_d:
			best_d = dist
			best = atan2(o.h + 1.2 - e.y, dist)
	return best

## Cada frame, en todos los PC: mirada, mira, salto y disparo de las personas de este PC.
func _local_controls(delta: float) -> void:
	var me := _mouse_player()
	var send := not is_authority
	_aim_send_t -= delta
	var send_now := send and _aim_send_t <= 0.0
	if send_now:
		_aim_send_t = 1.0 / 30.0
	for p in players:
		if not _owns(p):
			continue
		var r: SP = _sp[p.id]
		var a: Vector2 = _aim.get(p.id, Vector2(r.yaw, r.pitch))
		var tank := _is_tank(p)
		var sc_toggle := bool(_scope_toggle.get(p.id, false))
		var fire := false
		var jump := false
		var sens := 0.35 if r.scoped else 1.0
		if p == me:
			a.x -= _mouse_delta.x * MOUSE_SENS * sens
			a.y -= _mouse_delta.y * MOUSE_SENS * sens
			var rs := _right_stick(p)
			a.x -= rs.x * 3.2 * sens * delta
			a.y -= rs.y * 2.2 * sens * delta
			fire = _lmb
			jump = _space
		else:
			if tank:
				a.x -= move_input(p).x * TANK_TURN * delta
				a.y = lerpf(a.y, _assist_pitch(r, a.x), 1.0 - exp(-6.0 * delta))
			else:
				var rs2 := _right_stick(p)
				a.x -= rs2.x * 3.2 * sens * delta
				a.y -= rs2.y * 2.2 * sens * delta
			fire = InputManager.action_presses(p.id) > 0
			if InputManager.action2_presses(p.id) > 0:
				sc_toggle = not sc_toggle
				_scope_toggle[p.id] = sc_toggle
		a.x = wrapf(a.x, -PI, PI)
		a.y = clampf(a.y, -PITCH_MAX, PITCH_MAX)
		var scoped := sc_toggle or (p == me and (_rmb_held or _pad_scope))
		if not r.alive or _over or _cd > 0.0:
			fire = false
			jump = false
		_aim[p.id] = a
		if jump:
			_jumps[p.id] = int(_jumps.get(p.id, 0)) + 1
		if is_authority:
			r.yaw = a.x
			r.pitch = a.y
			r.tank = tank
			r.scoped = scoped and r.alive
			if fire:
				r.fire_pending = true
			if jump:
				r.jump_pending = true
		else:
			r.scoped = scoped and r.alive          # para dibujar la mira sin esperar al host
			if fire:
				submit_text("f:%.4f:%.4f:%d" % [a.x, a.y, 1 if scoped else 0], true)
			elif send_now or jump:
				submit_text("a:%.3f:%.3f:%d:%d:%d" % [a.x, a.y, 1 if scoped else 0, 1 if tank else 0, int(_jumps.get(p.id, 0))], false)
		if fire and _mine(p.id):
			_recoil = 1.0
	_mouse_delta = Vector2.ZERO
	_lmb = false
	_space = false

## (host) Mirada, mira, saltos y disparos que envía el PC de cada persona.
func _on_player_text(player: PlayerData, text: String, _final: bool) -> void:
	if player == null:
		player = _mouse_player()
	if player == null or InputManager.is_simulated(player.id):
		return
	var r: SP = _sp.get(player.id)
	if r == null:
		return
	var parts := text.split(":")
	if parts.size() < 4 or not (parts[0] == "a" or parts[0] == "f"):
		return
	r.text_t = _t
	var yaw := parts[1].to_float()
	var pitch := parts[2].to_float()
	if not (is_finite(yaw) and is_finite(pitch)):
		return
	r.yaw = wrapf(yaw, -PI, PI)
	r.pitch = clampf(pitch, -PITCH_MAX, PITCH_MAX)
	r.scoped = parts[3] == "1" and r.alive
	if parts[0] == "f":
		if r.alive:
			r.fire_pending = true
	elif parts.size() >= 6:
		r.tank = parts[4] == "1"
		var jc := parts[5].to_int()
		if jc > r.jump_count:
			if jc - r.jump_count <= 3 and r.alive:
				r.jump_pending = true
			r.jump_count = jc

# ----------------------------------------------------------------------------
# IA (bots, autopiloto, práctica)
# ----------------------------------------------------------------------------

func _bot_move(_player: PlayerData) -> Vector2:
	return Vector2.ZERO

func _bot_action(_player: PlayerData) -> int:
	return 0

func _bot_action2(_player: PlayerData) -> int:
	return 0

func _bot_action_held(_player: PlayerData) -> bool:
	return false

func _sees(r: SP, o: SP) -> bool:
	var e := _eye(r)
	return _los(e, Vector3(o.x, o.h + 1.25, o.z)) or _los(e, Vector3(o.x, o.h + 1.65, o.z))

func _turn_to(r: SP, yaw: float, pitch: float, rate: float, dt: float) -> void:
	var dy := angle_difference(r.yaw, yaw)
	r.yaw = wrapf(r.yaw + clampf(dy, -rate * dt, rate * dt), -PI, PI)
	r.pitch = move_toward(r.pitch, pitch, rate * 0.7 * dt)

func _bot_step(r: SP, dt: float) -> void:
	r.bot_wish = Vector2.ZERO
	if not r.alive or _over:
		r.scoped = false
		return
	var sk := r.skill if debug_skill < 0.0 else debug_skill
	r.bot_heard_t = maxf(0.0, r.bot_heard_t - dt)
	# --- Buscar a quién disparar (cada ~0,1 s) ---
	r.bot_think -= dt
	var thought := r.bot_think <= 0.0
	if thought:
		r.bot_think = 0.12 + r.bot_rng.randf() * 0.1
		var keep := false
		if r.bot_target >= 0:
			var cur: SP = _sp.get(r.bot_target)
			keep = cur != null and cur.alive and _sees(r, cur)
		if not keep:
			r.bot_target = -1
			# Candidatos en su campo de visión, del más cercano al más lejano; se queda con el primero que ve.
			var cands: Array = []
			for id in _order:
				var o: SP = _sp[id]
				if o == r or not o.alive:
					continue
				var ddx := o.x - r.x
				var ddz := o.z - r.z
				var dist := sqrt(ddx * ddx + ddz * ddz)
				if dist > 90.0:
					continue
				if absf(angle_difference(r.yaw, yaw_to(ddx, ddz))) < 1.15 or r.bot_heard_t > 0.0 or dist < 6.0:
					cands.append([dist, id])
			cands.sort_custom(func(p: Array, q: Array) -> bool: return float(p[0]) < float(q[0]))
			for ci in mini(cands.size(), 3):
				if _sees(r, _sp[int(cands[ci][1])]):
					r.bot_target = int(cands[ci][1])
					break
			if r.bot_target >= 0:
				r.bot_react = lerpf(0.9, 0.35, sk) + r.bot_rng.randf() * 0.3
				r.bot_err_y = r.bot_rng.randf_range(-1.0, 1.0) * lerpf(0.22, 0.1, sk)
				r.bot_err_p = r.bot_rng.randf_range(-1.0, 1.0) * 0.06
	if r.bot_target >= 0:
		var t: SP = _sp[r.bot_target]
		var ddx2 := t.x - r.x
		var ddz2 := t.z - r.z
		var dist2 := sqrt(ddx2 * ddx2 + ddz2 * ddz2)
		var want_y := yaw_to(ddx2, ddz2)
		var want_p := atan2(t.h + 1.25 - (r.h + EYE), dist2)
		var decay := exp(-dt * lerpf(1.6, 3.4, sk))
		r.bot_err_y *= decay
		r.bot_err_p *= decay
		_turn_to(r, want_y + r.bot_err_y, want_p + r.bot_err_p, lerpf(3.0, 6.5, sk), dt)
		r.scoped = dist2 > 7.0
		r.bot_react -= dt
		# Se mueve poco mientras apunta (de lado, para no ser un blanco fijo).
		r.bot_strafe_t -= dt
		if r.bot_strafe_t <= 0.0:
			r.bot_strafe_t = r.bot_rng.randf_range(0.6, 1.5)
			r.bot_strafe = [-1.0, 0.0, 1.0][r.bot_rng.randi() % 3]
		var right := Vector2(cos(r.yaw), -sin(r.yaw))
		r.bot_wish = right * r.bot_strafe * (0.5 if sk > 0.7 else 0.0)
		var aimed := absf(angle_difference(r.yaw, want_y + r.bot_err_y)) < 0.03 and absf(r.pitch - (want_p + r.bot_err_p)) < 0.04
		var ready := r.cd <= 0.0 and (not r.scoped or r.scope_t >= SCOPE_TIME)
		if r.bot_react <= 0.0 and ready and aimed:
			# Pulso imperfecto: un poco de ruido en cada tiro; tras disparar vuelve a afinar.
			r.yaw += r.bot_rng.randf_range(-1.0, 1.0) * (1.0 - sk) * 0.025
			r.pitch += r.bot_rng.randf_range(-1.0, 1.0) * (1.0 - sk) * 0.015
			r.fire_pending = true
			r.bot_err_y = r.bot_rng.randf_range(-1.0, 1.0) * 0.05
			r.bot_err_p = r.bot_rng.randf_range(-1.0, 1.0) * 0.02
			r.bot_react = r.bot_rng.randf_range(0.1, 0.3)
		return
	r.scoped = false
	# --- Moverse: hacia un disparo oído, hacia el enemigo más cercano (lo ve en el radar) o a pasear ---
	r.bot_goal_t -= dt
	var pos := Vector2(r.x, r.z)
	if r.bot_goal_t <= 0.0 or r.bot_pi >= r.bot_path.size():
		r.bot_goal_t = r.bot_rng.randf_range(2.0, 3.5)
		var goal: Vector2 = _roam[r.bot_rng.randi() % _roam.size()]
		if r.bot_heard_t > 0.0:
			goal = r.bot_heard
		elif r.bot_rng.randf() < 0.55:
			var nd := INF
			for id in _order:
				var o2: SP = _sp[id]
				if o2 != r and o2.alive and pos.distance_to(Vector2(o2.x, o2.z)) < nd:
					nd = pos.distance_to(Vector2(o2.x, o2.z))
					goal = Vector2(o2.x, o2.z)
		r.bot_path = nav_path(pos, goal)
		r.bot_pi = 0
	if r.bot_pi < r.bot_path.size():
		# Atajo (de vez en cuando): el punto más lejano del camino al que se llega en línea recta.
		if thought or r.bot_pi == 0:
			var look := mini(r.bot_pi + 8, r.bot_path.size() - 1)
			while look > r.bot_pi and not _walk_clear(pos, r.bot_path[look]):
				look -= 1
			r.bot_pi = look
		var tgt: Vector2 = r.bot_path[r.bot_pi]
		if pos.distance_to(tgt) < 0.35:
			r.bot_pi += 1
		var dirv := (tgt - pos)
		if dirv.length() > 0.01:
			r.bot_wish = dirv.normalized()
			_turn_to(r, yaw_to(dirv.x, dirv.y), 0.0, 5.0, dt)
	# Atascado: salta y busca otro camino.
	r.bot_stuck_t += dt
	if r.bot_stuck_t >= 1.0:
		if pos.distance_to(r.bot_last) < 0.3 and r.bot_wish != Vector2.ZERO:
			r.jump_pending = true
			r.bot_goal_t = 0.0
		r.bot_last = pos
		r.bot_stuck_t = 0.0

# ----------------------------------------------------------------------------
# Red
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var arr := PackedFloat32Array()
	for id in _order:
		var r: SP = _sp[id]
		arr.append_array(PackedFloat32Array([r.x, r.z, r.h, r.yaw, r.pitch, 1.0 if r.alive else 0.0, r.inv_t,
				float(r.kills), float(r.deaths), float(r.streak), 1.0 if r.scoped else 0.0, r.cd, r.dead_t,
				float(r.killer), r.vx, r.vz]))
	return {"r": arr, "t": _t, "cd": _cd, "o": _over, "w": _winner_id}

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
			var r: SP = _sp[_order[i]]
			var o := i * FLOATS
			r.x = arr[o]
			r.z = arr[o + 1]
			r.h = arr[o + 2]
			r.yaw = arr[o + 3]
			r.pitch = arr[o + 4]
			r.alive = arr[o + 5] > 0.5
			r.inv_t = arr[o + 6]
			r.kills = int(arr[o + 7])
			r.deaths = int(arr[o + 8])
			r.streak = int(arr[o + 9])
			var pl := _player_by_id(r.id)
			if not _owns(pl):
				r.scoped = arr[o + 10] > 0.5
			r.cd = arr[o + 11]
			r.dead_t = arr[o + 12]
			r.killer = int(arr[o + 13])
			r.vx = arr[o + 14]
			r.vz = arr[o + 15]

func _on_event(event_name: String, data: Variant) -> void:
	var d: Dictionary = data if data is Dictionary else {}
	match event_name:
		"beep":
			Audio.sfx(&"beep", -7.0)
		"go":
			Audio.sfx(&"beep_go", -5.0)
		"shot":
			_on_shot(d)
		"kill":
			_on_kill(d)
		"spawn":
			var id := int(d.get("p", -1))
			var r: SP = _sp.get(id)
			if r == null:
				return
			r.alive = true
			r.x = float(d.get("x", r.x))
			r.z = float(d.get("z", r.z))
			r.dx = r.x
			r.dz = r.z
			r.fall = 0.0
			r.yaw = float(d.get("y", r.yaw))
			r.dyaw = r.yaw
			if _owns(_player_by_id(id)):
				_aim[id] = Vector2(r.yaw, 0.0)
				_scope_toggle[id] = false
			if id == _view_id:
				Audio.sfx(&"pop", -8.0)
		"over":
			_winner_id = int(d.get("w", -1))
			_over = true
			_release_mouse()

func _on_shot(d: Dictionary) -> void:
	var id := int(d.get("p", -1))
	var r: SP = _sp.get(id)
	var o: Vector3 = d.get("o", Vector3.ZERO)
	var e: Vector3 = d.get("e", Vector3.ZERO)
	if r != null:
		r.flash_t = 0.08
		r.scope_t = 0.0
	var me: SP = _sp.get(_view_id)
	var dist := 0.0 if me == null else Vector2(o.x - me.x, o.z - me.z).length()
	if id == _view_id:
		Audio.sfx(&"shot", -2.0, 0.55)
		_recoil = 1.0
		_shake = 0.35
		get_tree().create_timer(0.45).timeout.connect(func() -> void:
			if is_instance_valid(self):
				Audio.sfx(&"snap", -14.0, 1.3), CONNECT_ONE_SHOT)
	else:
		Audio.sfx(&"shot", clampf(-6.0 - dist * 0.35, -26.0, -6.0), 0.5)
	_add_tracer(o, e, _color_of(id), id == _view_id)

func _on_kill(d: Dictionary) -> void:
	var k := int(d.get("k", -1))
	var v := int(d.get("v", -1))
	var hs := bool(d.get("hs", false))
	var st := int(d.get("st", 1))
	_feed.append({"k": k, "v": v, "hs": hs, "t": 5.0})
	if _feed.size() > 5:
		_feed.pop_front()
	var vr: SP = _sp.get(v)
	if vr != null:
		vr.alive = false
		vr.killer = k
		vr.dead_t = 0.0
		if vr.node != null:
			_puff_at(Vector3(vr.dx, vr.dh + 1.2, vr.dz), _color_of(v))
	if k == _view_id:
		_hitmark_t = 0.45
		_hitmark_kill = true
		Audio.sfx(&"hit_gold" if hs else &"hit", -3.0)
		var msg := "¡A LA CABEZA!" if hs else "+1 BAJA"
		match st:
			2: msg = "¡DOBLE BAJA!"
			3: msg = "¡TRIPLE BAJA!"
			4: msg = "¡CUÁDRUPLE!"
		if st >= 5:
			msg = "¡IMPARABLE! ×%d" % st
		_toast = msg
		_toast_col = Palette.YELLOW if hs or st >= 2 else Palette.MINT
		_toast_t = 1.4
	elif v == _view_id:
		Audio.sfx(&"crash", -6.0)
		_shake = 0.8
		var vk: SP = _sp.get(k)
		if vk != null:
			_death_look = Vector3(vk.x, vk.h + 1.4, vk.z)
		_scope_toggle[v] = false
	elif _mine(k) or _mine(v):
		Audio.sfx(&"thud", -10.0)

# ----------------------------------------------------------------------------
# Cada frame (todos los PC)
# ----------------------------------------------------------------------------

func _pick_view_id() -> int:
	var me := _mouse_player()
	if me != null:
		return me.id
	for p in players:
		if _owns(p):
			return p.id
	if local_player != null and _sp.has(local_player.id):
		return local_player.id
	return _order[0] if not _order.is_empty() else -1

func _animate(delta: float) -> void:
	_anim += delta
	_toast_t = maxf(0.0, _toast_t - delta)
	_hitmark_t = maxf(0.0, _hitmark_t - delta)
	_shake = maxf(0.0, _shake - delta * 2.0)
	_recoil = maxf(0.0, _recoil - delta * 3.5)
	_radar_sweep = fmod(_radar_sweep + delta * 2.2, TAU)
	if _cd <= 0.0:
		_hint_t = maxf(0.0, _hint_t - delta)
	for f in _feed:
		f["t"] = float(f["t"]) - delta
	_feed = _feed.filter(func(f: Dictionary) -> bool: return float(f["t"]) > 0.0)
	if is_running:
		_local_controls(delta)
	if not is_authority:
		for id in _order:
			var r: SP = _sp[id]
			if not r.alive:
				r.dead_t += delta
	if _view_id < 0 or not _sp.has(_view_id):
		_view_id = _pick_view_id()
	var vr: SP = _sp.get(_view_id)
	var scoped_now := vr != null and vr.alive and vr.scoped and _cd <= 0.0
	_scope_blend = move_toward(_scope_blend, 1.0 if scoped_now else 0.0, delta / SCOPE_TIME)
	_update_world(delta)

# ----------------------------------------------------------------------------
# Escena 3D: barrio soleado de los años 50 con montañas al fondo
# ----------------------------------------------------------------------------

func _mat(c: Color, emission: float = 0.0, rough: float = 0.85) -> StandardMaterial3D:
	var key := "%s|%.2f|%.2f" % [c.to_html(), emission, rough]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emission
	_mat_cache[key] = m
	return m

func _toon(c: Color, emission: float = 0.0, outline: float = 0.028) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.55
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emission
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

func _cyl(radius: float, height: float, segs: int = 16) -> CylinderMesh:
	var cm := CylinderMesh.new()
	cm.top_radius = radius
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

func _flat(parent: Node3D, x0: float, x1: float, z0: float, z1: float, y: float, mat: Material) -> MeshInstance3D:
	var mi := _box(parent, Vector3(x1 - x0, 0.04, z1 - z0), Vector3((x0 + x1) * 0.5, y - 0.02, (z0 + z1) * 0.5), mat)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

const PIECE_COLORS := {
	"wall_w": Color(0.55, 0.78, 0.82), "wall_e": Color(0.98, 0.84, 0.5),
	"inner_w": Color(0.93, 0.9, 0.82), "inner_e": Color(0.93, 0.9, 0.82),
	"ceil_w": Color(0.95, 0.95, 0.92), "ceil_e": Color(0.95, 0.95, 0.92),
	"garage_w": Color(0.45, 0.66, 0.72), "garage_e": Color(0.9, 0.74, 0.42),
	"fence": Color(0.97, 0.97, 0.95), "fence_tall": Color(0.62, 0.45, 0.3),
	"sofa": Color(0.82, 0.32, 0.36), "table": Color(0.55, 0.38, 0.24), "counter": Color(0.92, 0.92, 0.9),
	"fridge": Color(0.85, 0.92, 0.95), "bed": Color(0.5, 0.55, 0.85),
	"statue": Color(0.75, 0.76, 0.8), "planter": Color(0.6, 0.55, 0.5),
	"bus": Color(1.0, 0.76, 0.12), "truck": Color(0.92, 0.94, 0.96),
	"trunk": Color(0.42, 0.28, 0.18), "lamp": Color(0.25, 0.26, 0.3), "shed": Color(0.7, 0.35, 0.3),
	"cab": Color(0.25, 0.32, 0.42),
}
const CAR_COLORS: Array[Color] = [Color(0.9, 0.32, 0.38), Color(0.35, 0.75, 0.75), Color(0.98, 0.6, 0.75),
		Color(0.4, 0.55, 0.95), Color(0.55, 0.85, 0.5), Color(0.95, 0.95, 0.9)]

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
	# --- Día soleado ---
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.22, 0.48, 0.9)
	sky_mat.sky_horizon_color = Color(0.72, 0.84, 0.97)
	sky_mat.ground_horizon_color = Color(0.72, 0.8, 0.88)
	sky_mat.ground_bottom_color = Color(0.4, 0.45, 0.4)
	sky_mat.sun_angle_max = 20.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.78, 0.92)
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 5.0
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_hdr_threshold = 1.2
	env.fog_enabled = true
	env.fog_light_color = Color(0.75, 0.84, 0.95)
	env.fog_density = 0.0035
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	_root3.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -35.0, 0.0)
	sun.light_energy = 1.25
	sun.light_color = Color(1.0, 0.95, 0.85)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 90.0
	_root3.add_child(sun)
	_build_ground()
	_build_pieces()
	_build_decor()
	# Restos de los disparos.
	for i in 6:
		var pt := _particles(Color(1, 1, 1, 0.9), 14, 0.5, 0.07, 1.5, 4.5, Vector3(0, -9.0, 0))
		_root3.add_child(pt)
		_puffs.append(pt)
	_cam = Camera3D.new()
	_cam.fov = FOV
	_cam.near = 0.05
	_cam.far = 700.0
	_root3.add_child(_cam)
	_cam.current = true
	_build_viewmodel()
	_rebuild_player_nodes()

func _build_ground() -> void:
	var grass := _mat(Color(0.42, 0.7, 0.34), 0.0, 0.95)
	var g := _box(_root3, Vector3(400, 0.2, 400), Vector3(0, -0.1, 0), grass)
	g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var asphalt := _mat(Color(0.3, 0.31, 0.34), 0.0, 0.9)
	var walk := _mat(Color(0.78, 0.77, 0.73), 0.0, 0.9)
	# Calle en U alrededor de la isleta (y entradas a los garajes).
	_flat(_root3, -11.5, 11.5, -19.6, 19.6, 0.02, asphalt)
	_flat(_root3, -12.5, -11.5, -19.6, 19.6, 0.04, walk)
	_flat(_root3, 11.5, 12.5, -19.6, 19.6, 0.04, walk)
	_flat(_root3, -20.0, -12.5, 7.0, 10.6, 0.03, _mat(Color(0.55, 0.55, 0.55), 0.0, 0.9))
	_flat(_root3, 12.5, 20.0, -10.6, -7.0, 0.03, _mat(Color(0.55, 0.55, 0.55), 0.0, 0.9))
	_flat(_root3, -16.0, -12.5, -0.9, 0.9, 0.035, walk)
	_flat(_root3, 12.5, 16.0, -0.9, 0.9, 0.035, walk)
	# Isleta de césped con bordillo.
	_flat(_root3, -5.2, 5.2, -3.7, 3.7, 0.08, _mat(Color(0.75, 0.75, 0.72)))
	_flat(_root3, -5.0, 5.0, -3.5, 3.5, 0.1, _mat(Color(0.38, 0.68, 0.32), 0.0, 0.95))
	# Líneas de la calle.
	var line_m := _mat(Color(0.97, 0.88, 0.4), 0.2)
	var z := -18.0
	while z < 18.0:
		if absf(z) > 4.5:
			_flat(_root3, -0.1, 0.1, z, z + 1.6, 0.03, line_m)
		z += 3.2
	for sx in [-8.0, 8.0]:
		_flat(_root3, sx - 0.08, sx + 0.08, -3.8, 3.8, 0.03, _mat(Color(0.95, 0.95, 0.95), 0.1))
	# Suelo de madera dentro de las casas.
	var wood := _mat(Color(0.66, 0.48, 0.32), 0.0, 0.8)
	_flat(_root3, -26.0, -16.0, -6.5, 6.5, 0.03, wood)
	_flat(_root3, 16.0, 26.0, -6.5, 6.5, 0.03, wood)

func _build_pieces() -> void:
	var car_i := 0
	for pc in _pieces:
		var b: AABB = pc["b"]
		var k: String = pc["k"]
		var center := b.get_center()
		match k:
			"fence":
				_fence(b)
				continue
			"car_x", "car_z":
				_car_visual(b, k == "car_z", CAR_COLORS[car_i % CAR_COLORS.size()])
				car_i += 1
				continue
			"bus", "truck":
				_bus_visual(b, k)
				continue
			"trunk":
				_box(_root3, b.size, center, _mat(PIECE_COLORS[k]))
				var top := Vector3(center.x, b.end.y + 0.9, center.z)
				var leaf := _mat(Color(0.3, 0.6, 0.3), 0.0, 0.95)
				_sphere(_root3, 1.7, top, leaf, 10)
				_sphere(_root3, 1.2, top + Vector3(0.9, 0.6, 0.3), leaf, 10)
				_sphere(_root3, 1.1, top + Vector3(-0.7, 0.8, -0.6), _mat(Color(0.36, 0.66, 0.34), 0.0, 0.95), 10)
				continue
			"lamp":
				_box(_root3, b.size, center, _mat(PIECE_COLORS[k], 0.0, 0.5))
				var arm_dir := 1.0 if center.x < 0.0 else -1.0
				_box(_root3, Vector3(1.2, 0.08, 0.08), Vector3(center.x + arm_dir * 0.6, b.end.y - 0.1, center.z), _mat(PIECE_COLORS[k]))
				_box(_root3, Vector3(0.45, 0.14, 0.3), Vector3(center.x + arm_dir * 1.15, b.end.y - 0.2, center.z), _mat(Color(1.0, 0.95, 0.75), 1.5))
				continue
			"statue":
				_statue(center)
				continue
			"planter":
				_box(_root3, b.size, center, _mat(PIECE_COLORS[k]))
				_sphere(_root3, 0.55, Vector3(center.x, b.end.y + 0.25, center.z), _mat(Color(0.95, 0.45, 0.6), 0.0, 0.9), 10)
				continue
		var col: Color = PIECE_COLORS.get(k, Color(0.8, 0.8, 0.8))
		var mi := _box(_root3, b.size, center, _mat(col, 0.0, 0.9))
		if k.begins_with("ceil"):
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if k.begins_with("garage"):
			# Puerta del garaje hacia la calle.
			var gx := b.end.x + 0.02 if center.x < 0.0 else b.position.x - 0.02
			_box(_root3, Vector3(0.06, 2.4, b.size.z - 0.9), Vector3(gx, 1.2, center.z), _mat(Color(0.95, 0.95, 0.92)))
			for i in 4:
				_box(_root3, Vector3(0.08, 0.05, b.size.z - 0.9), Vector3(gx, 0.5 + 0.55 * i, center.z), _mat(Color(0.75, 0.75, 0.72)))
	# Tejados a dos aguas sobre las casas y garajes.
	for sx in [-1.0, 1.0]:
		var roof := PrismMesh.new()
		roof.size = Vector3(11.2, 2.2, 14.0)
		_mesh(_root3, roof, Vector3(sx * 21.0, WALL_H + 0.25 + 1.1, 0.0), _mat(Color(0.62, 0.28, 0.26) if sx < 0.0 else Color(0.35, 0.36, 0.45), 0.0, 0.9))
		var groof := PrismMesh.new()
		groof.size = Vector3(6.6, 1.2, 4.7)
		_mesh(_root3, groof, Vector3(sx * 23.07, WALL_H + 0.6, sx * 8.82), _mat(Color(0.62, 0.28, 0.26) if sx < 0.0 else Color(0.35, 0.36, 0.45), 0.0, 0.9))
		# Chimenea.
		_box(_root3, Vector3(0.8, 1.8, 0.8), Vector3(sx * 24.0, WALL_H + 2.2, sx * -3.5), _mat(Color(0.6, 0.35, 0.3)))
		# Luz interior.
		for rz in [-3.0, 3.0]:
			var lamp := OmniLight3D.new()
			lamp.position = Vector3(sx * 21.0 + sx * rz * 0.8, 2.6, rz)
			lamp.omni_range = 7.0
			lamp.light_energy = 0.9
			lamp.light_color = Color(1.0, 0.9, 0.75)
			_root3.add_child(lamp)

func _fence(b: AABB) -> void:
	var white := _mat(PIECE_COLORS["fence"], 0.0, 0.7)
	var along_z := b.size.z > b.size.x
	var length := b.size.z if along_z else b.size.x
	var c := b.get_center()
	for y in [0.35, 0.75]:
		_box(_root3, Vector3(0.06 if along_z else length, 0.08, length if along_z else 0.06), Vector3(c.x, y, c.z), white)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var pick := BoxMesh.new()
	pick.size = Vector3(0.12, 1.0, 0.04) if not along_z else Vector3(0.04, 1.0, 0.12)
	mm.mesh = pick
	var n := int(length / 0.28)
	mm.instance_count = n
	for i in n:
		var t := -length * 0.5 + (i + 0.5) * length / n
		var pos := Vector3(c.x, 0.5, c.z + t) if along_z else Vector3(c.x + t, 0.5, c.z)
		mm.set_instance_transform(i, Transform3D(Basis(), pos))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = white
	_root3.add_child(mmi)

func _car_visual(b: AABB, along_z: bool, col: Color) -> void:
	var c := b.get_center()
	var n := Node3D.new()
	n.position = Vector3(c.x, 0.0, c.z)
	n.rotation.y = 0.0 if along_z else PI * 0.5
	_root3.add_child(n)
	var paint := _mat(col, 0.0, 0.35)
	_box(n, Vector3(1.9, 0.62, 4.2), Vector3(0, 0.62, 0), paint)
	_box(n, Vector3(1.94, 0.12, 4.26), Vector3(0, 0.36, 0), _mat(Color(0.85, 0.85, 0.88), 0.0, 0.25))   # cromado
	_box(n, Vector3(1.7, 0.55, 2.2), Vector3(0, 1.27, 0.15), _mat(Color(0.3, 0.42, 0.55), 0.0, 0.15))
	_box(n, Vector3(1.74, 0.08, 2.26), Vector3(0, 1.58, 0.15), paint)
	# Aletas traseras de los 50.
	for sx in [-0.8, 0.8]:
		var fin := _box(n, Vector3(0.1, 0.35, 0.9), Vector3(sx, 1.05, 1.7), paint)
		fin.rotation.x = -0.25
	for sx in [-1.0, 1.0]:
		for sz in [-1.35, 1.35]:
			var w := _mesh(n, _cyl(0.38, 0.28, 12), Vector3(sx * 0.9, 0.38, sz), _mat(Color(0.08, 0.08, 0.1)))
			w.rotation.z = PI * 0.5
		_box(n, Vector3(0.3, 0.18, 0.06), Vector3(sx * 0.6, 0.72, -2.12), _mat(Color(1.0, 0.95, 0.75), 1.2))
		_box(n, Vector3(0.22, 0.14, 0.06), Vector3(sx * 0.7, 0.75, 2.12), _mat(Color(1.0, 0.2, 0.2), 1.0))

func _bus_visual(b: AABB, kind: String) -> void:
	var c := b.get_center()
	var col: Color = PIECE_COLORS[kind]
	_box(_root3, b.size - Vector3(0, 0.4, 0), c + Vector3(0, 0.2, 0), _mat(col, 0.0, 0.5))
	_box(_root3, Vector3(b.size.x + 0.02, 0.15, b.size.z + 0.02), Vector3(c.x, 1.2, c.z), _mat(Color(0.12, 0.12, 0.14)))
	var glass := _mat(Color(0.3, 0.42, 0.55), 0.0, 0.15)
	if kind == "bus":
		var x := b.position.x + 1.0
		while x < b.end.x - 0.8:
			for sz in [b.position.z - 0.01, b.end.z + 0.01]:
				_box(_root3, Vector3(1.0, 0.75, 0.04), Vector3(x + 0.5, 2.2, sz), glass)
			x += 1.3
	else:
		for sz in [b.position.z - 0.01, b.end.z + 0.01]:
			_box(_root3, Vector3(3.0, 1.2, 0.04), Vector3(c.x, 1.9, sz), _mat(Color(0.9, 0.35, 0.3), 0.0, 0.6))
	for x2 in [b.position.x + 1.4, b.end.x - 1.4]:
		for sz2 in [b.position.z, b.end.z]:
			var w := _mesh(_root3, _cyl(0.5, 0.3, 12), Vector3(x2, 0.5, sz2), _mat(Color(0.08, 0.08, 0.1)))
			w.rotation.x = PI * 0.5

## La estatua del átomo de la isleta (diseño propio).
func _statue(c: Vector3) -> void:
	var stone := _mat(PIECE_COLORS["statue"], 0.0, 0.6)
	_box(_root3, Vector3(1.6, 0.5, 1.6), Vector3(c.x, 0.25, c.z), stone)
	_box(_root3, Vector3(1.0, 2.4, 1.0), Vector3(c.x, 1.7, c.z), stone)
	var core := _sphere(_root3, 0.35, Vector3(c.x, 3.6, c.z), _mat(Color(1.0, 0.75, 0.25), 1.5, 0.3), 14)
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for i in 3:
		var tor := TorusMesh.new()
		tor.inner_radius = 0.75
		tor.outer_radius = 0.85
		tor.rings = 32
		tor.ring_segments = 6
		var ring := _mesh(_root3, tor, Vector3(c.x, 3.6, c.z), _mat(Color(0.4, 0.85, 1.0), 1.2, 0.3))
		ring.rotation = Vector3(PI * 0.5, float(i) * PI / 3.0, 0.35)

func _build_decor() -> void:
	# Montañas lejanas y nubes.
	var mrng := RandomNumberGenerator.new()
	mrng.seed = 77
	for i in 26:
		var ang := float(i) / 26.0 * TAU + mrng.randf_range(-0.1, 0.1)
		var dist := mrng.randf_range(150.0, 230.0)
		var hgt := mrng.randf_range(25.0, 70.0)
		var cone := CylinderMesh.new()
		cone.top_radius = mrng.randf_range(2.0, 8.0)
		cone.bottom_radius = mrng.randf_range(40.0, 70.0)
		cone.height = hgt
		cone.radial_segments = 7
		var m := _mesh(_root3, cone, Vector3(cos(ang) * dist, hgt * 0.5 - 2.0, sin(ang) * dist), _mat(Color(0.62, 0.55, 0.48).lerp(Color(0.5, 0.56, 0.62), mrng.randf()), 0.0, 1.0))
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var cloud := _unshaded(Color(1, 1, 1, 0.85), true)
	for i in 14:
		var ang2 := mrng.randf() * TAU
		var p := Vector3(cos(ang2) * mrng.randf_range(60.0, 160.0), mrng.randf_range(45.0, 70.0), sin(ang2) * mrng.randf_range(60.0, 160.0))
		for j in 3:
			var s := _sphere(_root3, mrng.randf_range(6.0, 10.0), p + Vector3(j * 8.0 - 8.0, mrng.randf_range(-1.5, 1.5), mrng.randf_range(-3.0, 3.0)), cloud, 10)
			s.scale = Vector3(1.0, 0.45, 0.8)
			s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Buzones delante de las casas (decoración).
	for sx in [-1.0, 1.0]:
		var mb := Vector3(sx * -13.6, 0.0, sx * -1.6)
		_box(_root3, Vector3(0.08, 1.1, 0.08), mb + Vector3(0, 0.55, 0), _mat(Color(0.3, 0.3, 0.32)))
		_box(_root3, Vector3(0.3, 0.3, 0.5), mb + Vector3(0, 1.2, 0), _mat(Color(0.25, 0.4, 0.85) if sx < 0.0 else Color(0.85, 0.3, 0.3)))
	# Marcos blancos bajo los dinteles de puertas y ventanas.
	var trim := _mat(Color(1, 1, 1), 0.0, 0.6)
	for pc in _pieces:
		var k: String = pc["k"]
		var b: AABB = pc["b"]
		if k.begins_with("wall") and b.position.y > 0.5 and b.size.y < 1.5:
			var c := b.get_center()
			_box(_root3, Vector3(b.size.x + 0.06, 0.1, b.size.z + 0.06), Vector3(c.x, b.position.y + 0.05, c.z), trim)

func _particles(color: Color, amount: int, life: float, radius: float, vel_min: float, vel_max: float, grav: Vector3) -> CPUParticles3D:
	var pt := CPUParticles3D.new()
	pt.amount = amount
	pt.lifetime = life
	pt.one_shot = true
	pt.emitting = false
	pt.explosiveness = 0.95
	pt.direction = Vector3.UP
	pt.spread = 85.0
	pt.initial_velocity_min = vel_min
	pt.initial_velocity_max = vel_max
	pt.gravity = grav
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(1.0, 0.0))
	pt.scale_amount_curve = curve
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 6
	sm.rings = 3
	var mat := _unshaded(color, true)
	mat.vertex_color_use_as_albedo = true
	sm.material = mat
	pt.mesh = sm
	return pt

func _puff_at(p: Vector3, col: Color) -> void:
	if _puffs.is_empty():
		return
	var pt := _puffs[_puff_i % _puffs.size()]
	_puff_i += 1
	pt.position = p
	pt.color = col
	pt.restart()
	pt.emitting = true

func _add_tracer(o: Vector3, e: Vector3, col: Color, mine: bool) -> void:
	if not _built:
		return
	var from := o + Vector3(0, -0.12, 0) + (e - o).normalized() * (0.6 if mine else 0.3)
	var len := from.distance_to(e)
	if len < 0.2:
		return
	var m := _unshaded(Color(col.r, col.g, col.b, 0.9), true)
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.disable_fog = true
	var mi := _box(_root3, Vector3(0.035, 0.035, len), (from + e) * 0.5, m)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if absf((e - from).normalized().dot(Vector3.UP)) < 0.99:
		mi.look_at_from_position((from + e) * 0.5, e, Vector3.UP)
	_tracers.append({"n": mi, "t": 0.4, "m": m})
	_puff_at(e, Color(0.85, 0.82, 0.75))

# --- Personajes ---

func _rebuild_player_nodes() -> void:
	if not _built:
		return
	for id in _order:
		var r: SP = _sp[id]
		if r.node != null and is_instance_valid(r.node):
			r.node.queue_free()
		_build_player(r, _player_by_id(id))

## El personaje: mono del color del jugador, gorra, visera, brazos sujetando el rifle (mira hacia -z).
func _build_player(r: SP, pl: PlayerData) -> void:
	r.node = Node3D.new()
	_root3.add_child(r.node)
	var col: Color = pl.color if pl != null else Palette.YELLOW
	var dark := col.darkened(0.45)
	var skin := Color(1.0, 0.86, 0.7)
	r.body = Node3D.new()
	r.node.add_child(r.body)
	var body := r.body
	_capsule(body, 0.32, 0.95, Vector3(0, 0.82, 0), _toon(col))
	_sphere(body, 0.3, Vector3(0, 1.47, 0), _toon(skin))
	var cap := _sphere(body, 0.32, Vector3(0, 1.57, 0.0), _toon(col.lightened(0.1)))
	cap.scale = Vector3(1.0, 0.65, 1.0)
	_box(body, Vector3(0.36, 0.05, 0.26), Vector3(0, 1.6, -0.3), _toon(col.darkened(0.2)))     # visera de la gorra
	_box(body, Vector3(0.4, 0.1, 0.06), Vector3(0, 1.48, -0.27), _mat(Color(0.12, 0.12, 0.16), 0.0, 0.2))   # gafas
	r.arm_l = Node3D.new()
	r.arm_l.position = Vector3(-0.38, 1.15, 0)
	body.add_child(r.arm_l)
	r.arm_r = Node3D.new()
	r.arm_r.position = Vector3(0.38, 1.15, 0)
	body.add_child(r.arm_r)
	for arm in [r.arm_l, r.arm_r]:
		_capsule(arm, 0.09, 0.55, Vector3(0, -0.24, 0), _toon(col))
		_sphere(arm, 0.095, Vector3(0, -0.5, 0), _toon(skin, 0.0, 0.02))
	r.leg_l = Node3D.new()
	r.leg_l.position = Vector3(-0.15, 0.5, 0)
	body.add_child(r.leg_l)
	r.leg_r = Node3D.new()
	r.leg_r.position = Vector3(0.15, 0.5, 0)
	body.add_child(r.leg_r)
	for leg in [r.leg_l, r.leg_r]:
		_capsule(leg, 0.115, 0.5, Vector3(0, -0.22, 0), _toon(dark))
		_box(leg, Vector3(0.22, 0.12, 0.34), Vector3(0, -0.44, -0.06), _toon(Color(0.2, 0.18, 0.2), 0.0, 0.02))
	# Rifle (gira con la mirada).
	r.gun = Node3D.new()
	r.gun.position = Vector3(0.12, 1.25, -0.25)
	body.add_child(r.gun)
	_rifle(r.gun, 1.0)
	r.flash = OmniLight3D.new()
	r.flash.position = Vector3(0, 0.05, -1.25)
	r.flash.light_color = Color(1.0, 0.8, 0.45)
	r.flash.omni_range = 4.0
	r.flash.light_energy = 0.0
	r.gun.add_child(r.flash)
	# Escudo de aparición.
	var sm := _unshaded(Color(col.r, col.g, col.b, 0.22), true)
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	r.shield = _sphere(r.node, 1.0, Vector3(0, 0.95, 0), sm, 18)
	r.shield.scale = Vector3(0.75, 1.05, 0.75)
	r.shield.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var tag := Label3D.new()
	tag.text = pl.display_name if pl != null else ""
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.pixel_size = 0.0045
	tag.font_size = 48
	tag.outline_size = 18
	tag.modulate = col.lightened(0.35)
	tag.outline_modulate = Palette.PURPLE_DARK
	tag.position = Vector3(0, 2.15, 0)
	r.node.add_child(tag)
	r.dx = r.x
	r.dz = r.z
	r.dh = r.h
	r.dyaw = r.yaw

## Rifle de francotirador low-poly (apunta a -z). s = escala.
func _rifle(parent: Node3D, s: float, vm: bool = false) -> void:
	var wood := _mat(Color(0.48, 0.3, 0.17), 0.0, 0.6) if not vm else _vm_mat(Color(0.48, 0.3, 0.17), 0.6)
	var metal := _mat(Color(0.18, 0.19, 0.22), 0.0, 0.35) if not vm else _vm_mat(Color(0.18, 0.19, 0.22), 0.35)
	var lens := _mat(Color(0.4, 0.8, 1.0), 0.8, 0.1) if not vm else _vm_mat(Color(0.4, 0.8, 1.0), 0.1, 0.8)
	_box(parent, Vector3(0.08, 0.12, 0.7) * s, Vector3(0, -0.02, 0.05) * s, wood)           # culata y guardamanos
	_box(parent, Vector3(0.07, 0.16, 0.22) * s, Vector3(0, -0.06, 0.38) * s, wood)
	var barrel := _mesh(parent, _cyl(0.022 * s, 0.75 * s, 8), Vector3(0, 0.03, -0.62) * s, metal)
	barrel.rotation.x = PI * 0.5
	var scope := _mesh(parent, _cyl(0.045 * s, 0.4 * s, 10), Vector3(0, 0.12, -0.08) * s, metal)
	scope.rotation.x = PI * 0.5
	var glass := _mesh(parent, _cyl(0.04 * s, 0.01 * s, 10), Vector3(0, 0.12, -0.285) * s, lens)
	glass.rotation.x = PI * 0.5
	_box(parent, Vector3(0.03, 0.06, 0.03) * s, Vector3(0, 0.07, -0.0) * s, metal)
	_box(parent, Vector3(0.03, 0.06, 0.03) * s, Vector3(0, 0.07, -0.16) * s, metal)

# --- Arma en primera persona ---

func _vm_mat(c: Color, rough: float, emission: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emission
	return m

func _build_viewmodel() -> void:
	var gc := SubViewportContainer.new()
	gc.stretch = true
	gc.top_level = true
	gc.set_anchors_preset(Control.PRESET_TOP_LEFT)
	gc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_gcont = gc
	add_child(gc)
	move_child(gc, surface.get_index())
	_gvp = SubViewport.new()
	_gvp.own_world_3d = true
	_gvp.transparent_bg = true
	_gvp.handle_input_locally = false
	_gvp.msaa_3d = Viewport.MSAA_4X
	_gvp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	gc.add_child(_gvp)
	var groot := Node3D.new()
	_gvp.add_child(groot)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.8, 0.95)
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	groot.add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-40.0, -30.0, 0.0)
	key.light_energy = 1.1
	groot.add_child(key)
	_gcam = Camera3D.new()
	_gcam.fov = 62.0
	_gcam.near = 0.02
	groot.add_child(_gcam)
	_gcam.current = true
	_viewmodel = Node3D.new()
	groot.add_child(_viewmodel)
	var gun := Node3D.new()
	gun.scale = Vector3.ONE * 0.5
	_viewmodel.add_child(gun)
	_rifle(gun, 1.0, true)
	_vm_bolt = Node3D.new()
	_vm_bolt.position = Vector3(0.06, 0.04, 0.12)
	gun.add_child(_vm_bolt)
	_box(_vm_bolt, Vector3(0.08, 0.02, 0.02), Vector3(0.04, 0, 0), _vm_mat(Color(0.7, 0.7, 0.75), 0.3))
	_sphere(_vm_bolt, 0.022, Vector3(0.085, 0, 0), _vm_mat(Color(0.7, 0.7, 0.75), 0.3), 8)
	# Manos y mangas (del color del jugador).
	_vm_sleeve_mat = _vm_mat(Palette.YELLOW, 0.6)
	var skin := _vm_mat(Color(1.0, 0.84, 0.68), 0.6)
	var hand_r := _sphere(gun, 0.055, Vector3(0.0, -0.08, 0.3), skin, 10)
	hand_r.scale = Vector3(1.0, 1.2, 1.4)
	var sleeve_r := _mesh(gun, _cyl(0.06, 0.5, 10), Vector3(0.08, -0.16, 0.55), _vm_sleeve_mat)
	sleeve_r.rotation = Vector3(1.2, 0.0, 0.35)
	var hand_l := _sphere(gun, 0.055, Vector3(0.0, -0.06, -0.2), skin, 10)
	hand_l.scale = Vector3(1.2, 1.0, 1.4)
	var sleeve_l := _mesh(gun, _cyl(0.06, 0.55, 10), Vector3(-0.2, -0.17, -0.05), _vm_sleeve_mat)
	sleeve_l.rotation = Vector3(1.25, 0.0, -0.9)
	_vm_flash = _sphere(gun, 0.08, Vector3(0, 0.03, -1.02), _vm_mat(Color(1.0, 0.8, 0.4), 0.1, 4.0), 8)
	_vm_flash.scale = Vector3(1.0, 1.0, 2.0)
	_vm_flash.visible = false

func _fit_view() -> void:
	if _cont == null:
		return
	var off := Vector2.ZERO
	var par := get_parent()
	if par is CanvasLayer:
		off = -(par as CanvasLayer).offset
	var sz := get_viewport().get_visible_rect().size
	_cont.position = off
	_cont.size = sz
	if _gcont != null:
		_gcont.position = off
		_gcont.size = sz

func _update_world(delta: float) -> void:
	_fit_view()
	if not _built or _cam == null:
		return
	var k := 1.0 if delta <= 0.0 else 1.0 - exp(-18.0 * delta)
	for id in _order:
		var r: SP = _sp[id]
		if r.node == null:
			continue
		if absf(r.dz - r.z) > 4.0 or absf(r.dx - r.x) > 4.0:
			r.dx = r.x
			r.dz = r.z
		else:
			r.dx = lerpf(r.dx, r.x, k)
			r.dz = lerpf(r.dz, r.z, k)
		r.dh = lerpf(r.dh, r.h, k)
		var yaw_src := r.yaw
		var pitch_src := r.pitch
		if _owns(_player_by_id(id)):
			var a: Vector2 = _aim.get(id, Vector2(r.yaw, r.pitch))
			yaw_src = a.x
			pitch_src = a.y
		r.dyaw = lerp_angle(r.dyaw, yaw_src, 1.0 if delta <= 0.0 else 1.0 - exp(-20.0 * delta))
		r.dpitch = lerpf(r.dpitch, pitch_src, 1.0 if delta <= 0.0 else 1.0 - exp(-20.0 * delta))
		r.anim += delta
		r.node.position = Vector3(r.dx, r.dh, r.dz)
		r.node.rotation.y = r.dyaw
		# Caída al morir; desaparece un poco después.
		r.fall = move_toward(r.fall, 1.0 if not r.alive else 0.0, delta * (3.0 if not r.alive else 100.0))
		r.body.rotation.x = r.fall * PI * 0.48
		r.node.visible = (r.alive or r.dead_t < 1.6) and id != _view_id
		r.shield.visible = r.alive and r.inv_t > 0.0
		if r.shield.visible:
			(r.shield.material_override as StandardMaterial3D).albedo_color.a = 0.15 + 0.12 * sin(_anim * 12.0)
		var speed := Vector2(r.vx, r.vz).length()
		var ph := r.anim * (6.0 + speed * 1.2)
		var swing := clampf(speed / WALK, 0.0, 1.0) if r.alive else 0.0
		r.leg_l.rotation.x = sin(ph) * 0.9 * swing
		r.leg_r.rotation.x = -sin(ph) * 0.9 * swing
		var aim_p := r.dpitch if r.alive else 0.0
		r.gun.rotation.x = aim_p
		r.arm_r.rotation.x = -1.35 - aim_p * 0.9
		r.arm_l.rotation.x = -1.55 - aim_p * 0.9
		r.arm_l.rotation.z = -0.45
		r.flash_t = maxf(0.0, r.flash_t - delta)
		r.flash.light_energy = 4.0 if r.flash_t > 0.0 else 0.0
	for tr in _tracers:
		tr["t"] = float(tr["t"]) - delta
		var m: StandardMaterial3D = tr["m"]
		m.albedo_color.a = clampf(float(tr["t"]) / 0.4, 0.0, 1.0) * 0.9
		if float(tr["t"]) <= 0.0:
			(tr["n"] as Node).queue_free()
	_tracers = _tracers.filter(func(tr: Dictionary) -> bool: return float(tr["t"]) > 0.0)
	# --- Cámara en primera persona ---
	var vr: SP = _sp.get(_view_id)
	if vr == null:
		return
	var yaw := vr.dyaw
	var pitch := vr.dpitch
	if _owns(_player_by_id(_view_id)):
		var a2: Vector2 = _aim.get(_view_id, Vector2(vr.yaw, vr.pitch))
		yaw = a2.x
		pitch = a2.y
	var eye := Vector3(vr.dx, vr.dh + EYE, vr.dz)
	var shake := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * _shake * 0.04
	if vr.alive:
		var bob := sin(vr.anim * 9.0) * 0.035 * clampf(Vector2(vr.vx, vr.vz).length() / WALK, 0.0, 1.0)
		_cam.position = eye + Vector3(0, bob, 0) + shake
		_cam.rotation = Vector3(pitch + _recoil * 0.05, yaw, 0.0)
	else:
		# Muerto: la cámara cae al suelo y mira a quien te ha eliminado.
		var low := Vector3(vr.dx, vr.dh + lerpf(EYE, 0.9, clampf(vr.dead_t * 3.0, 0.0, 1.0)), vr.dz)
		_cam.position = low + shake
		var kr: SP = _sp.get(vr.killer)
		if kr != null:
			_death_look = _death_look.lerp(Vector3(kr.dx, kr.dh + 1.3, kr.dz), 1.0 - exp(-3.0 * delta))
		if _cam.position.distance_to(_death_look) > 0.5:
			var target_basis := Basis.looking_at(_death_look - _cam.position, Vector3.UP)
			_cam.basis = _cam.basis.slerp(target_basis, 1.0 - exp(-4.0 * delta)).orthonormalized()
	_cam.fov = lerpf(FOV, SCOPE_FOV, _ease(_scope_blend))
	# Arma en primera persona: balanceo al andar, retroceso y cerrojo.
	if _viewmodel != null:
		var pl := _player_by_id(_view_id)
		if pl != null and _vm_sleeve_mat != null:
			_vm_sleeve_mat.albedo_color = pl.color
		_viewmodel.visible = vr.alive and _scope_blend < 0.85
		var spd := clampf(Vector2(vr.vx, vr.vz).length() / WALK, 0.0, 1.0)
		var sway := Vector3(sin(vr.anim * 4.5) * 0.012, absf(cos(vr.anim * 4.5)) * 0.012, 0.0) * spd
		var down := _ease(_scope_blend)
		_viewmodel.position = Vector3(lerpf(0.23, 0.0, down), lerpf(-0.2, -0.08, down), lerpf(-0.3, -0.2, down)) + sway + Vector3(0, 0, _recoil * 0.12)
		_viewmodel.rotation = Vector3(_recoil * 0.22, 0.04 * (1.0 - down), 0.0)
		var cyc := 1.0 - clampf(vr.cd / FIRE_CD, 0.0, 1.0)            # 0 justo al disparar → 1 listo
		var bolt := 0.0
		if vr.cd > 0.0 and cyc > 0.25 and cyc < 0.85:
			bolt = sin((cyc - 0.25) / 0.6 * PI)
		_vm_bolt.rotation.z = bolt * 1.2
		_vm_bolt.position.z = 0.12 + bolt * 0.08
		_vm_flash.visible = _recoil > 0.85

func _ease(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)

# ----------------------------------------------------------------------------
# HUD: clasificación (izquierda), tiempo (arriba), radar (arriba a la derecha), bajas, mira
# ----------------------------------------------------------------------------

func _text(pos: Vector2, s: String, size: int, col: Color, align: int = 0, outline: int = 5) -> void:
	var font := surface.get_theme_default_font()
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var p := pos
	if align == 1:
		p.x -= w * 0.5
	elif align == 2:
		p.x -= w
	p.y += font.get_ascent(size) * 0.5 - font.get_descent(size) * 0.5
	if outline > 0:
		surface.draw_string_outline(font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, outline, Palette.PURPLE_DARK)
	surface.draw_string(font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)

func _text_w(s: String, size: int) -> float:
	return surface.get_theme_default_font().get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x

func _draw_hud() -> void:
	var s := surface
	var vr: SP = _sp.get(_view_id)
	var center := Vector2(640, 360)
	# --- Mira telescópica ---
	if _scope_blend > 0.6 and vr != null and vr.alive:
		var a := clampf((_scope_blend - 0.6) / 0.4, 0.0, 1.0)
		var rad := 300.0
		s.draw_arc(center, rad + 600.0, 0.0, TAU, 96, Color(0, 0, 0, a), 1200.0, false)
		s.draw_arc(center, rad, 0.0, TAU, 96, Color(0.05, 0.05, 0.05, a), 10.0, true)
		s.draw_circle(center, rad, Color(0.3, 0.6, 0.9, 0.06 * a))
		var ln := Color(0, 0, 0, 0.9 * a)
		s.draw_line(center + Vector2(-rad, 0), center + Vector2(-14, 0), ln, 2.0)
		s.draw_line(center + Vector2(14, 0), center + Vector2(rad, 0), ln, 2.0)
		s.draw_line(center + Vector2(0, -rad), center + Vector2(0, -14), ln, 2.0)
		s.draw_line(center + Vector2(0, 14), center + Vector2(0, rad), ln, 2.0)
		for i in range(1, 5):
			s.draw_line(center + Vector2(-6, 40 * i), center + Vector2(6, 40 * i), ln, 2.0)
		var ready := vr.scope_t >= SCOPE_TIME or not is_authority
		s.draw_circle(center, 2.5, Color(1.0, 0.2, 0.2, a) if ready else Color(1, 1, 1, 0.5 * a))
	elif vr != null and vr.alive and _cd <= 0.0 and not _over:
		# Punto de mira sin mira: se abre (dispara impreciso).
		var gap := 9.0 + 26.0 * (1.0 - _scope_blend)
		var c := Color(1, 1, 1, 0.9)
		for d in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
			s.draw_line(center + d * gap, center + d * (gap + 10.0), Color(0, 0, 0, 0.5), 4.0)
			s.draw_line(center + d * gap, center + d * (gap + 10.0), c, 2.0)
		s.draw_circle(center, 2.0, c)
	# Recarga del cerrojo.
	if vr != null and vr.alive and vr.cd > 0.0 and _cd <= 0.0:
		var f := 1.0 - vr.cd / FIRE_CD
		s.draw_arc(center, 22.0, -PI * 0.5, -PI * 0.5 + TAU * f, 32, Color(1, 1, 1, 0.75), 3.0, true)
	# Marca de impacto.
	if _hitmark_t > 0.0:
		var hc := Color(1.0, 0.25, 0.25, _hitmark_t / 0.45) if _hitmark_kill else Color(1, 1, 1, _hitmark_t / 0.45)
		for d2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			s.draw_line(center + d2 * 8.0, center + d2 * 18.0, hc, 3.0)
	# Muerto: velo rojo, quién te ha eliminado y cuenta de reaparición.
	if vr != null and not vr.alive and not _over:
		s.draw_rect(Rect2(-400, -200, 2080, 1120), Color(0.5, 0.0, 0.05, 0.28))
		_text(Vector2(640, 250), "TE HA ELIMINADO", 40, Palette.WHITE, 1, 8)
		if vr.killer >= 0:
			_text(Vector2(640, 305), _name_of(vr.killer), 58, _color_of(vr.killer).lightened(0.3), 1, 10)
		_text(Vector2(640, 380), "Reapareces en %.1f" % maxf(0.0, RESPAWN - vr.dead_t), 28, Color(1, 1, 1, 0.9), 1, 6)
	elif vr != null and vr.inv_t > 0.0 and vr.alive:
		_text(Vector2(640, 430), "PROTEGIDO", 22, Palette.MINT, 1, 5)
	_draw_leaderboard()
	_draw_timer()
	_draw_radar(vr)
	_draw_feed()
	# Tus bajas (abajo).
	if vr != null:
		var pl := _player_by_id(_view_id)
		var col: Color = pl.color if pl != null else Palette.WHITE
		var r := Rect2(560, 640, 160, 64)
		s.rounded_rect(r.grow(3), 18, col)
		s.rounded_rect(r, 16, Color(0.05, 0.05, 0.14, 0.88))
		_text(Vector2(640, 656), "BAJAS", 16, Color(1, 1, 1, 0.75), 1, 3)
		_text(Vector2(640, 684), str(vr.kills), 34, Palette.YELLOW, 1, 6)
		if vr.streak >= 2 and vr.alive:
			_text(Vector2(745, 672), "racha ×%d" % vr.streak, 20, Palette.CORAL, 0, 4)
	if _toast_t > 0.0:
		var al := clampf(_toast_t * 2.0, 0.0, 1.0)
		var sc := 1.0 + maxf(0.0, _toast_t - 1.1) * 1.2
		_text(Vector2(640, 520), _toast, int(46 * sc), Color(_toast_col.r, _toast_col.g, _toast_col.b, al), 1, 9)
	if _cd > 0.0:
		var nn := ceili(_cd)
		var frac_c := _cd - floorf(_cd)
		s.text_centered(Vector2(640, 300), str(nn), int(130.0 + 60.0 * frac_c), Palette.YELLOW, 16)
		s.text_centered(Vector2(640, 420), "Gana quien haga más bajas en 2 minutos", 30, Palette.WHITE, 7)
	elif _t < 0.9 and not _over:
		s.text_centered(Vector2(640, 300), "¡A CAZAR!", 110, Palette.MINT, 16)
	if _hint_t > 0.0 and not _over and _cd <= 0.0:
		var me := _mouse_player()
		var hint := "RATÓN apuntar · CLIC disparar · CLIC DERECHO mira · WASD moverse · ESPACIO saltar" if me != null \
				else "Izquierda/derecha giran · ACCIÓN dispara · 2.º botón: mira"
		s.text_centered(Vector2(640, 600), hint, 22, Color(1, 1, 1, clampf(_hint_t, 0.0, 1.0)), 6)
	if not demo and is_running and not _over and _mouse_player() != null and not _captured and DisplayServer.get_name() != "headless":
		s.text_centered(Vector2(640, 560), "Haz clic para apuntar con el ratón", 26, Palette.YELLOW, 7)
	if _over:
		var w := _player_by_id(_winner_id)
		s.draw_rect(Rect2(-400, -200, 2080, 1120), Color(0.05, 0.02, 0.15, 0.35))
		s.text_centered(Vector2(640, 280), "¡FIN!", 100, Palette.YELLOW, 14)
		if w != null:
			var wr: SP = _sp.get(_winner_id)
			s.text_centered(Vector2(640, 370), "Gana %s con %d bajas" % [w.display_name, wr.kills if wr != null else 0], 50, w.color.lightened(0.25), 10)

func _draw_leaderboard() -> void:
	var s := surface
	var rk := ranking_ids()
	var row_h := 30.0
	var panel := Rect2(14, 14, 258, 44 + row_h * rk.size())
	s.rounded_rect(panel, 16, Color(0.05, 0.05, 0.14, 0.72))
	_text(Vector2(28, 34), "CLASIFICACIÓN", 18, Palette.YELLOW, 0, 4)
	_text(Vector2(258, 34), "BAJAS", 13, Color(1, 1, 1, 0.6), 2, 3)
	for i in rk.size():
		var id := rk[i]
		var r: SP = _sp[id]
		var y := 62.0 + row_h * i
		var col := _color_of(id)
		if id == _view_id:
			s.rounded_rect(Rect2(20, y - 13, 246, 27), 10, Color(col.r, col.g, col.b, 0.3))
		_text(Vector2(30, y), "%d" % (i + 1), 18, Palette.YELLOW if i == 0 else Color(1, 1, 1, 0.8), 0, 4)
		s.draw_circle(Vector2(56, y), 7.0, col)
		if not r.alive:
			s.draw_line(Vector2(51, y - 5), Vector2(61, y + 5), Palette.WHITE, 2.0)
		var nm := _name_of(id)
		if nm.length() > 11:
			nm = nm.substr(0, 10) + "…"
		_text(Vector2(70, y), nm, 18, Palette.WHITE if r.alive else Color(1, 1, 1, 0.55), 0, 4)
		_text(Vector2(222, y), str(r.kills), 20, col.lightened(0.3), 2, 4)
		_text(Vector2(258, y), "/%d" % r.deaths, 14, Color(1, 1, 1, 0.55), 2, 3)

func _draw_timer() -> void:
	var s := surface
	var left := clampf(TIME_LIMIT - _t, 0.0, TIME_LIMIT)
	var r := Rect2(570, 12, 140, 54)
	var low := left <= 10.0 and _cd <= 0.0
	s.rounded_rect(r.grow(3), 20, Palette.CORAL if low else Palette.YELLOW)
	s.rounded_rect(r, 18, Color(0.05, 0.05, 0.14, 0.88))
	var secs := ceili(left)
	_text(Vector2(640, 39), "%d:%02d" % [secs / 60, secs % 60], 34, Palette.CORAL if low else Palette.WHITE, 1, 6)

## Radar (arriba a la derecha): gira contigo (arriba = hacia donde miras) y marca a todos los enemigos.
func _draw_radar(vr: SP) -> void:
	var s := surface
	var c := Vector2(1166, 116)
	var rad := 96.0
	s.draw_circle(c, rad + 5.0, Color(0.02, 0.06, 0.04, 0.85))
	s.draw_circle(c, rad, Color(0.06, 0.22, 0.12, 0.85))
	for f in [0.33, 0.66]:
		s.draw_arc(c, rad * f, 0.0, TAU, 48, Color(0.4, 1.0, 0.6, 0.18), 1.0, true)
	s.draw_line(c + Vector2(-rad, 0), c + Vector2(rad, 0), Color(0.4, 1.0, 0.6, 0.15), 1.0)
	s.draw_line(c + Vector2(0, -rad), c + Vector2(0, rad), Color(0.4, 1.0, 0.6, 0.15), 1.0)
	s.draw_arc(c, rad, 0.0, TAU, 64, Color(0.4, 1.0, 0.6, 0.6), 2.5, true)
	_text(Vector2(c.x, c.y + rad + 16), "RADAR", 13, Color(0.6, 1.0, 0.75, 0.85), 1, 3)
	if vr == null:
		return
	var yaw := vr.dyaw
	if _owns(_player_by_id(vr.id)):
		yaw = (_aim.get(vr.id, Vector2(vr.yaw, 0.0)) as Vector2).x
	var scale := rad / RADAR_RANGE
	var fwd := Vector2(-sin(yaw), -cos(yaw))
	var right := Vector2(cos(yaw), -sin(yaw))
	var me := Vector2(vr.dx, vr.dz)
	var to_screen := func(w: Vector2) -> Vector2:
		var d := w - me
		return Vector2(d.dot(right), -d.dot(fwd)) * scale
	# Casas, coches y autobús (siluetas).
	var disc := PackedVector2Array()
	for i in 32:
		disc.append(c + Vector2.from_angle(TAU * i / 32.0) * (rad - 1.0))
	for rc in _radar_rects:
		var pts := PackedVector2Array()
		for corner in [rc.position, Vector2(rc.end.x, rc.position.y), rc.end, Vector2(rc.position.x, rc.end.y)]:
			pts.append(c + (to_screen.call(corner) as Vector2))
		for clip in Geometry2D.intersect_polygons(pts, disc):
			if clip.size() >= 3 and not Geometry2D.triangulate_polygon(clip).is_empty():
				s.draw_colored_polygon(clip, Color(0.5, 1.0, 0.65, 0.22))
	# Barrido.
	var sw := Vector2.from_angle(_radar_sweep - PI * 0.5) * rad
	s.draw_line(c, c + sw, Color(0.5, 1.0, 0.65, 0.35), 2.0)
	# Enemigos.
	for id in _order:
		if id == vr.id:
			continue
		var r: SP = _sp[id]
		if not r.alive:
			continue
		var p2: Vector2 = to_screen.call(Vector2(r.dx, r.dz))
		var edge := p2.length() > rad - 6.0
		p2 = p2.limit_length(rad - 6.0)
		var col := _color_of(id)
		var pulse := 1.0 + 0.25 * sin(_anim * 8.0 + float(id))
		s.draw_circle(c + p2, (5.0 if edge else 6.5) * pulse, Palette.CORAL)
		s.draw_circle(c + p2, (3.0 if edge else 4.5) * pulse, col)
	# Tú (flecha en el centro, mirando arriba).
	s.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -10), c + Vector2(7, 7), c + Vector2(0, 3), c + Vector2(-7, 7)]), Palette.WHITE)

func _draw_feed() -> void:
	var y := 250.0
	for f in _feed:
		var a := clampf(float(f["t"]), 0.0, 1.0)
		var kn := _name_of(int(f["k"]))
		var vn := _name_of(int(f["v"]))
		var mid := "  ⌖ " if not bool(f["hs"]) else "  ☠ "
		var x := 1262.0
		var vw := _text_w(vn, 17)
		var mw := _text_w(mid, 17)
		surface.rounded_rect(Rect2(x - vw - mw - _text_w(kn, 17) - 16, y - 13, vw + mw + _text_w(kn, 17) + 20, 26), 9, Color(0.05, 0.05, 0.14, 0.6 * a))
		var vc := _color_of(int(f["v"])).lightened(0.3)
		var kc := _color_of(int(f["k"])).lightened(0.3)
		_text(Vector2(x, y), vn, 17, Color(vc.r, vc.g, vc.b, a), 2, 3)
		_text(Vector2(x - vw, y), mid, 17, Color(1, 1, 1, a), 2, 3)
		_text(Vector2(x - vw - mw, y), kn, 17, Color(kc.r, kc.g, kc.b, a), 2, 3)
		y += 30.0

# ----------------------------------------------------------------------------
# Utilidades de depuración / pruebas (tests/sniper_test.gd)
# ----------------------------------------------------------------------------

func debug_sp(id: int) -> Dictionary:
	var r: SP = _sp[id]
	return {"x": r.x, "z": r.z, "h": r.h, "yaw": r.yaw, "pitch": r.pitch, "alive": r.alive, "kills": r.kills,
			"deaths": r.deaths, "inv": r.inv_t, "cd": r.cd, "scoped": r.scoped}

func debug_place(id: int, x: float, z: float, yaw: float, pitch: float = 0.0) -> void:
	var r: SP = _sp[id]
	r.x = x
	r.z = z
	r.h = 0.0
	r.vx = 0.0
	r.vz = 0.0
	r.yaw = yaw
	r.pitch = pitch
	r.inv_t = 0.0
	r.alive = true
	r.grounded = true

func debug_aim_at(id: int, target: int) -> void:
	var r: SP = _sp[id]
	var t: SP = _sp[target]
	r.yaw = yaw_to(t.x - r.x, t.z - r.z)
	r.pitch = atan2(t.h + 1.2 - (r.h + EYE), Vector2(t.x - r.x, t.z - r.z).length())

func debug_fire(id: int, scoped: bool = true) -> void:
	var r: SP = _sp[id]
	r.scoped = scoped
	r.scope_t = SCOPE_TIME if scoped else 0.0
	r.cd = 0.0
	_fire(r)

## Un paso de 1/60 s de un jugador (sin IA) con entrada en coordenadas de mundo.
func debug_step(id: int, wish: Vector2, jump: bool = false) -> void:
	var r: SP = _sp[id]
	r.jump_pending = jump
	var keep_sim := r.bot_wish
	r.bot_wish = wish
	var pl := _player_by_id(id)
	_t += STEP
	if InputManager.is_simulated(id):
		_sim_step(r, pl, STEP)
	r.bot_wish = keep_sim

func debug_skip_countdown() -> void:
	_cd = 0.0

func debug_over() -> bool:
	return _over

func debug_winner() -> int:
	return _winner_id

func debug_time() -> float:
	return _t

func debug_spawns() -> Array[Vector3]:
	return _spawns

func debug_big() -> bool:
	return _big

func debug_bounds() -> Vector2:
	return _bounds

func debug_blocked(x: float, z: float) -> bool:
	for b in _solids:
		if _blocks(b, 0.0) and _circle_hits(b, x, z, RADIUS):
			return true
	return false

func debug_raycast(o: Vector3, d: Vector3, ignore: int) -> Dictionary:
	return _raycast(o, d, ignore)
