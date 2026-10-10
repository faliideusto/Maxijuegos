extends Minigame
## Impostor a Bordo (id impostor; modelo HOST_AUTHORITATIVE, 3D en PRIMERA PERSONA): una nave de ocho salas y pasillos.
## Al empezar, cada jugador recibe en secreto su papel. La TRIPULACIÓN recorre la nave completando sus tareas (se va a la
## consola, se pulsa ESPACIO/CLIC y se resuelve su misión: hay 5 tipos, ver T_MARK…T_MEMORY); el IMPOSTOR finge tareas y elimina
## tripulantes con E/CLIC DERECHO cuando nadie mira. Quien encuentra un cadáver lo denuncia (o se pulsa el botón de
## emergencia de la cafetería) y todos se reúnen a votar: el más votado sale por la esclusa. Gana la tripulación si termina
## todas las tareas o expulsa a los impostores; gana el impostor si iguala en número a la tripulación o se acaba el oxígeno.
## Los eliminados siguen como fantasmas (atraviesan paredes y pueden acabar sus tareas).
##
## El host simula todo (movimiento, tareas, muertes, reuniones, votos y puntos) y envía el estado a ~30 Hz; los clientes
## interpolan. La vista es local: cada PC dibuja la nave desde los ojos de SU jugador. El giro con el ratón se calcula en
## cada PC (respuesta inmediata) y viaja al host por el canal de texto del minijuego ("y<ángulo>", ver _on_player_text);
## sin ratón (teclado 2, táctil, práctica) se gira con izquierda/derecha. Los papeles y las tareas salen de la semilla
## común, así que no se envían. OJO: el estado va a todos los PC (no hay mensajes privados), así que el secreto del
## impostor es de interfaz, no criptográfico.

enum Phase { INTRO, PLAY, SPLASH, VOTE, REVEAL, EJECT, END }
const CREW := 0
const IMPOSTOR := 1
const NO_VOTE := -2
const SKIP := -1

# --- Tiempos ---
const INTRO_TIME := 4.5
const OXYGEN := 180.0
const SPLASH_TIME := 3.0
const VOTE_TIME := 25.0
const REVEAL_TIME := 4.5
const EJECT_TIME := 4.6
const END_TIME := 6.0
# --- Nave (rejilla de celdas; x → este, y → sur) ---
const CELL := 2.0
const GW := 25
const GH := 17
const WALL_H := 3.2
# --- Jugadores ---
const RADIUS := 0.38
const EYE := 1.2
const WALK := 4.4
const GHOST_SPEED := 5.6
const ACCEL := 38.0
const TURN := 2.7                        # rad/s al girar con izquierda/derecha
const MOUSE_SENS := 0.0026
const STICK_SENS := 2.8
# --- Reglas ---
const TASKS_PER := 6
const TASK_HITS := 3
const TASK_SPEED := 0.85                 # recorridos del marcador por segundo
const TASK_ZONE := 0.12                  # semiancho de la zona verde
const TASK_LOCK := 0.55
## Tipos de misión (campo "type" de cada consola).
const T_MARK := 0                        # parar el marcador en la zona verde, 3 veces
const T_MASH := 1                        # pulsar muy rápido
const T_ARROWS := 2                      # pulsar las flechas que se muestran, en orden
const T_WAIT := 3                        # esperar quieto a que termine (descargas, repostajes)
const T_MEMORY := 4                      # memorizar una secuencia de flechas y repetirla
const MEMORY_SHOW := 2.4                 # segundos que se ve la secuencia antes de ocultarse
const USE_RANGE := 1.25
const BUTTON_RANGE := 2.3
const REPORT_RANGE := 2.6
const KILL_RANGE := 2.1
const KILL_CD := 20.0
## Recarga según el nº de jugadores (ajustada con partidas de bots: ver tests/impostor_test.gd).
const KILL_CDS := {4: 42.0, 5: 22.0, 6: 13.0, 7: 9.0, 8: 50.0}
const KILL_CD_START := 10.0
const KILL_CD_MEETING := 12.0
const BUTTON_CD := 18.0
const FLOATS := 19                       # por jugador en el estado enviado
# --- Puntos (de ellos sale la clasificación) ---
const PTS_TASK := 1
const PTS_KILL := 2
const PTS_GOOD_VOTE := 2
const PTS_BAD_EJECT := -1
const PTS_SURVIVE := 2
const PTS_WIN := 10

const ROOMS: Array = [
	{"name": "Cafetería", "rect": Rect2i(9, 1, 7, 5), "color": Color(0.9, 0.92, 1.0)},
	{"name": "Armas", "rect": Rect2i(19, 1, 5, 4), "color": Color(1.0, 0.42, 0.38)},
	{"name": "Navegación", "rect": Rect2i(20, 7, 4, 4), "color": Color(0.38, 0.68, 1.0)},
	{"name": "Comunicaciones", "rect": Rect2i(19, 12, 5, 4), "color": Color(0.74, 0.52, 1.0)},
	{"name": "Almacén", "rect": Rect2i(11, 9, 6, 7), "color": Color(1.0, 0.62, 0.28)},
	{"name": "Electricidad", "rect": Rect2i(6, 8, 4, 3), "color": Color(1.0, 0.9, 0.22)},
	{"name": "Reactor", "rect": Rect2i(1, 9, 4, 6), "color": Color(0.3, 1.0, 0.9)},
	{"name": "Motores", "rect": Rect2i(1, 1, 4, 5), "color": Color(0.42, 0.92, 0.48)},
]
const HALLS: Array = [
	Rect2i(5, 3, 4, 1), Rect2i(16, 3, 3, 1), Rect2i(13, 6, 1, 3), Rect2i(2, 6, 1, 3), Rect2i(5, 12, 6, 1), Rect2i(8, 11, 1, 1),
	Rect2i(21, 5, 1, 2), Rect2i(21, 11, 1, 1), Rect2i(17, 14, 2, 1), Rect2i(7, 4, 1, 4), Rect2i(17, 9, 3, 1),
]
const TABLE_CELL := Vector2i(12, 3)
## Celdas ocupadas por muebles grandes (no se pisan, pero no tapan la vista): mesa, núcleo del reactor, motores, cajas.
const PROPS: Array = [Vector2i(12, 3), Vector2i(3, 12), Vector2i(3, 1), Vector2i(3, 5), Vector2i(14, 12)]
## Consolas de tareas: sala, celda donde te colocas y pared a la que está pegada.
const STATIONS: Array = [
	{"room": 0, "cell": Vector2i(15, 1), "dir": Vector2i(0, -1), "name": "Vaciar la basura", "type": 1},
	{"room": 0, "cell": Vector2i(9, 5), "dir": Vector2i(-1, 0), "name": "Arreglar la cafetera", "type": 0},
	{"room": 1, "cell": Vector2i(23, 1), "dir": Vector2i(1, 0), "name": "Despejar asteroides", "type": 0},
	{"room": 1, "cell": Vector2i(19, 4), "dir": Vector2i(0, 1), "name": "Recargar los cañones", "type": 1},
	{"room": 2, "cell": Vector2i(23, 8), "dir": Vector2i(1, 0), "name": "Trazar el rumbo", "type": 2},
	{"room": 2, "cell": Vector2i(22, 10), "dir": Vector2i(0, 1), "name": "Estabilizar la dirección", "type": 0},
	{"room": 3, "cell": Vector2i(23, 15), "dir": Vector2i(1, 0), "name": "Descargar datos", "type": 3},
	{"room": 3, "cell": Vector2i(19, 12), "dir": Vector2i(0, -1), "name": "Reiniciar la antena", "type": 4},
	{"room": 4, "cell": Vector2i(11, 15), "dir": Vector2i(0, 1), "name": "Repostar el bidón", "type": 3},
	{"room": 4, "cell": Vector2i(16, 11), "dir": Vector2i(1, 0), "name": "Clasificar cajas", "type": 2},
	{"room": 5, "cell": Vector2i(6, 8), "dir": Vector2i(-1, 0), "name": "Reparar los cables", "type": 4},
	{"room": 5, "cell": Vector2i(9, 10), "dir": Vector2i(1, 0), "name": "Calibrar el distribuidor", "type": 0},
	{"room": 6, "cell": Vector2i(1, 11), "dir": Vector2i(-1, 0), "name": "Desbloquear el reactor", "type": 4},
	{"room": 6, "cell": Vector2i(1, 14), "dir": Vector2i(0, 1), "name": "Arrancar el reactor", "type": 1},
	{"room": 7, "cell": Vector2i(1, 1), "dir": Vector2i(-1, 0), "name": "Alinear el motor", "type": 2},
	{"room": 7, "cell": Vector2i(1, 5), "dir": Vector2i(-1, 0), "name": "Repostar el motor", "type": 3},
]
const REASONS: Array[String] = ["Los impostores han sido expulsados", "La tripulación ha caído", "Todas las tareas completadas", "Se acabó el oxígeno"]

## Un jugador (lo simula el host; los clientes lo reciben y solo interpolan la presentación).
class PS:
	var id: int = 0
	var idx: int = 0
	var role: int = 0
	var alive: bool = true
	var pos: Vector2 = Vector2.ZERO          # (x, z)
	var vel: Vector2 = Vector2.ZERO
	var kyaw: float = 0.0                    # giro que lleva el host (teclas, reuniones, IA)
	var myaw: float = 0.0                    # giro del ratón (lo manda cada PC)
	var look: bool = false                   # true: mira con ratón (izq./der. = paso lateral)
	var tasks: PackedInt32Array = PackedInt32Array()
	var done_mask: int = 0
	var cur_station: int = -1
	var task_hits: int = 0
	var task_t: float = 0.0
	var task_lock: float = 0.0
	var kill_cd: float = 0.0
	var score: int = 0
	var kills: int = 0
	var vote: int = -2
	var cursor: int = 0
	var meetings_left: int = 1
	var prev_y: float = 0.0
	var prev_dir: int = -1
	var hold: bool = false                   # acaba de salir de una misión de flechas: no anda hasta soltar la dirección
	# IA
	var bot_rng: RandomNumberGenerator = null
	var think_t: float = 0.0
	var wait_t: float = 0.0
	var goal: int = 0                        # 0 nada, 1 tarea, 2 cadáver, 3 cazar, 4 deambular/fingir
	var goal_id: int = -1
	var goal_pos: Vector2 = Vector2.ZERO
	var hit_t: float = 0.0
	var vote_at: float = 0.0
	var desperate: float = 0.0
	var stuck_t: float = 0.0
	var last_pos: Vector2 = Vector2.ZERO
	var sus: Dictionary = {}                 # id → sospecha
	# Presentación (interpolada)
	var dpos: Vector2 = Vector2.ZERO
	var dyaw: float = 0.0
	var dk: float = 0.0
	var anim: float = 0.0
	var node: Node3D = null
	var body: Node3D = null
	var leg_l: Node3D = null
	var leg_r: Node3D = null
	var ghost: Node3D = null

var _ps: Dictionary = {}                 # id de jugador → PS
var _order: Array[int] = []
var _phase: int = Phase.INTRO
var _phase_t: float = 0.0
var _time_left: float = OXYGEN
var _button_cd: float = BUTTON_CD
var _bodies: Array = []                  # {id, pos}
var _tasks_done: int = 0
var _tasks_total: int = 1
var _meet_by: int = -1
var _meet_victim: int = -1
var _meet_room: int = -1
var _ejected: int = -1
var _winner: int = -1
var _reason: int = 0
var _meetings: int = 0
## Recarga entre eliminaciones: más larga con poca tripulación o con dos impostores (si no, arrasan).
var _kill_cd: float = KILL_CD
## (pruebas) ids que serán impostores sí o sí; vacío = al azar con la semilla.
var debug_force_impostors: Array = []

# --- Rejilla ---
var _solid: PackedByteArray = PackedByteArray()      # 1 = pared (tapa la vista)
var _blocked: PackedByteArray = PackedByteArray()    # 1 = pared o mueble (no se pisa)
var _room_of: PackedInt32Array = PackedInt32Array()  # índice de sala, -1 pasillo, -2 pared
var _desks: Array[Rect2] = []
var _fields: Dictionary = {}                         # celda destino → distancias (BFS)

# --- Vista local ---
var _view_id: int = -1
var _use_look: bool = false
var _captured: bool = false
var _local_myaw: float = 0.0
var _sent_myaw: float = 999.0
var _look_send_t: float = 0.0
var _pitch: float = 0.0
var _anim: float = 0.0
var _flash_red: float = 0.0
var _flash_ok: float = 0.0
var _toast: String = ""
var _toast_t: float = 0.0
var _last_o2: int = 999

# --- Escena 3D ---
var _vp: SubViewport
var _cont: SubViewportContainer
var _root3: Node3D
var _cam: Camera3D
var _built: bool = false
var _station_marks: Array[Label3D] = []
var _station_screens: Array[MeshInstance3D] = []
var _body_nodes: Dictionary = {}         # id de la víctima → Node3D
var _core: MeshInstance3D = null
var _button_top: MeshInstance3D = null

# ----------------------------------------------------------------------------
# Rejilla de la nave
# ----------------------------------------------------------------------------

func _ensure_grid() -> void:
	if _solid.size() == GW * GH:
		return
	_solid.resize(GW * GH)
	_solid.fill(1)
	_room_of.resize(GW * GH)
	_room_of.fill(-2)
	for i in ROOMS.size():
		var r: Rect2i = ROOMS[i]["rect"]
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				_solid[y * GW + x] = 0
				_room_of[y * GW + x] = i
	for h in HALLS:
		var hr: Rect2i = h
		for y in range(hr.position.y, hr.end.y):
			for x in range(hr.position.x, hr.end.x):
				if _room_of[y * GW + x] == -2:
					_solid[y * GW + x] = 0
					_room_of[y * GW + x] = -1
	_blocked = _solid.duplicate()
	for pc in PROPS:
		var c: Vector2i = pc
		_blocked[c.y * GW + c.x] = 1
	_desks.clear()
	for st in STATIONS:
		var d := Vector2((st["dir"] as Vector2i).x, (st["dir"] as Vector2i).y)
		var wall := _center(st["cell"]) + d * (CELL * 0.5)
		var side := Vector2(absf(d.y), absf(d.x))
		var mid := wall - d * 0.27
		_desks.append(Rect2(mid - side * 0.65 - Vector2(absf(d.x), absf(d.y)) * 0.27, side * 1.3 + Vector2(absf(d.x), absf(d.y)) * 0.54))

func _in_grid(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < GW and c.y < GH

func _cell_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / CELL + GW * 0.5), floori(p.y / CELL + GH * 0.5))

func _center(c: Vector2i) -> Vector2:
	return Vector2((c.x + 0.5 - GW * 0.5) * CELL, (c.y + 0.5 - GH * 0.5) * CELL)

func _is_blocked(c: Vector2i) -> bool:
	return not _in_grid(c) or _blocked[c.y * GW + c.x] == 1

func _is_solid(c: Vector2i) -> bool:
	return not _in_grid(c) or _solid[c.y * GW + c.x] == 1

## Sala bajo el punto: índice en ROOMS, -1 pasillo.
func _room_index(p: Vector2) -> int:
	var c := _cell_of(p)
	if not _in_grid(c):
		return -1
	return maxi(_room_of[c.y * GW + c.x], -1)

func _room_name(i: int) -> String:
	return String(ROOMS[i]["name"]) if i >= 0 and i < ROOMS.size() else "Pasillo"

func _station_pos(s: int) -> Vector2:
	return _center(STATIONS[s]["cell"])

func _table_pos() -> Vector2:
	return _center(TABLE_CELL)

## ¿Se ven los dos puntos? (solo tapan las paredes)
func _los(a: Vector2, b: Vector2) -> bool:
	var d := a.distance_to(b)
	var n := maxi(1, ceili(d / 0.35))
	for i in range(1, n):
		if _is_solid(_cell_of(a.lerp(b, float(i) / float(n)))):
			return false
	return true

## ¿Se puede ir andando en línea recta de a hasta b?
func _walk_clear(a: Vector2, b: Vector2) -> bool:
	var d := a.distance_to(b)
	if d > 14.0:
		return false
	var n := maxi(1, ceili(d / 0.4))
	for i in range(0, n + 1):
		var q := a.lerp(b, float(i) / float(n))
		for off in [Vector2(0.44, 0), Vector2(-0.44, 0), Vector2(0, 0.44), Vector2(0, -0.44)]:
			if _is_blocked(_cell_of(q + off)):
				return false
	return true

## Saca el círculo del jugador de paredes, muebles y consolas.
func _collide(pos: Vector2) -> Vector2:
	for iter in 2:
		var c := _cell_of(pos)
		for oy in range(-1, 2):
			for ox in range(-1, 2):
				var n := Vector2i(c.x + ox, c.y + oy)
				if not _is_blocked(n):
					continue
				var lo := _center(n) - Vector2(CELL, CELL) * 0.5
				pos = _push_out(pos, Rect2(lo, Vector2(CELL, CELL)))
		for r in _desks:
			pos = _push_out(pos, r)
	return pos

func _push_out(pos: Vector2, r: Rect2) -> Vector2:
	var q := Vector2(clampf(pos.x, r.position.x, r.end.x), clampf(pos.y, r.position.y, r.end.y))
	var d := pos - q
	var l := d.length()
	if l >= RADIUS:
		return pos
	if l > 0.0001:
		return q + d / l * RADIUS
	# Centro dentro del rectángulo: sale por el lado más cercano.
	var left := pos.x - r.position.x
	var right := r.end.x - pos.x
	var top := pos.y - r.position.y
	var bottom := r.end.y - pos.y
	var m := minf(minf(left, right), minf(top, bottom))
	if m == left:
		return Vector2(r.position.x - RADIUS, pos.y)
	if m == right:
		return Vector2(r.end.x + RADIUS, pos.y)
	if m == top:
		return Vector2(pos.x, r.position.y - RADIUS)
	return Vector2(pos.x, r.end.y + RADIUS)

## Distancias en pasos (BFS) desde todas las celdas hasta `target`; 9999 = inalcanzable.
func _field(target: Vector2i) -> PackedInt32Array:
	var key := target.y * GW + target.x
	if _fields.has(key):
		return _fields[key]
	var f := PackedInt32Array()
	f.resize(GW * GH)
	f.fill(9999)
	if _in_grid(target):
		f[key] = 0
		var queue: Array[int] = [key]
		var head := 0
		while head < queue.size():
			var cur := queue[head]
			head += 1
			var cx := cur % GW
			var cy := cur / GW
			for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n := Vector2i(cx + off.x, cy + off.y)
				if _is_blocked(n):
					continue
				var ni := n.y * GW + n.x
				if f[ni] > f[cur] + 1:
					f[ni] = f[cur] + 1
					queue.append(ni)
	_fields[key] = f
	return f

func _path_dist(from: Vector2, to: Vector2) -> int:
	var c := _cell_of(from)
	if not _in_grid(c):
		return 9999
	return _field(_cell_of(to))[c.y * GW + c.x]

# ----------------------------------------------------------------------------
# Reparto y utilidades de reglas
# ----------------------------------------------------------------------------

func _setup_round() -> void:
	_ensure_grid()
	_free_player_nodes()
	_ps.clear()
	_order.clear()
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	var n := players.size()
	var imp_count := 2 if n >= 8 else 1
	var imps: Array = []
	if not debug_force_impostors.is_empty():
		imps = debug_force_impostors.duplicate()
	else:
		var pool: Array = []
		for pl in players:
			pool.append(pl.id)
		while imps.size() < imp_count and not pool.is_empty():
			var k := r.randi_range(0, pool.size() - 1)
			imps.append(pool[k])
			pool.remove_at(k)
	var crew := 0
	for i in n:
		var pl := players[i]
		var p := PS.new()
		p.id = pl.id
		p.idx = i
		p.role = IMPOSTOR if imps.has(pl.id) else CREW
		if p.role == CREW:
			crew += 1
		# Tareas: TASKS_PER consolas distintas al azar (el impostor recibe una lista para fingir).
		var bag: Array = []
		for s in STATIONS.size():
			bag.append(s)
		for t in TASKS_PER:
			var k2 := r.randi_range(0, bag.size() - 1)
			p.tasks.append(int(bag[k2]))
			bag.remove_at(k2)
		p.pos = _seat_pos(i, n)
		p.kyaw = _seat_yaw(i, n)
		p.dpos = p.pos
		p.dk = p.kyaw
		p.dyaw = p.kyaw
		p.last_pos = p.pos
		p.kill_cd = KILL_CD_START
		p.bot_rng = RandomNumberGenerator.new()
		p.bot_rng.seed = seed_value * 31 + pl.id * 977 + 5
		p.think_t = 0.05 * i
		_ps[pl.id] = p
		_order.append(pl.id)
	_tasks_total = maxi(1, crew * TASKS_PER)
	_kill_cd = float(KILL_CDS.get(n, KILL_CD))
	_tasks_done = 0
	_bodies.clear()
	_phase = Phase.INTRO
	_phase_t = 0.0
	_time_left = OXYGEN
	_button_cd = BUTTON_CD
	_meet_by = -1
	_meet_victim = -1
	_meet_room = -1
	_ejected = -1
	_winner = -1
	_reason = 0
	_meetings = 0
	_pick_view()

## Sitio alrededor de la mesa de la cafetería (inicio y reuniones) y giro para mirarla.
func _seat_pos(i: int, n: int) -> Vector2:
	var a := TAU * float(i) / float(maxi(n, 1))
	return _table_pos() + Vector2(sin(a), cos(a)) * 2.7

func _seat_yaw(i: int, n: int) -> float:
	return wrapf(TAU * float(i) / float(maxi(n, 1)), -PI, PI)

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

func _yaw(p: PS) -> float:
	return p.kyaw + p.myaw

func _fwd(p: PS) -> Vector2:
	var y := _yaw(p)
	return Vector2(-sin(y), -cos(y))

func _pending(p: PS, s: int) -> bool:
	var k := p.tasks.find(s)
	return k >= 0 and (p.done_mask & (1 << k)) == 0

func _tasks_left(p: PS) -> int:
	var n := 0
	for k in p.tasks.size():
		if (p.done_mask & (1 << k)) == 0:
			n += 1
	return n

## Centro de la zona verde del marcador (igual en todos los PC).
func _zone(p: PS) -> float:
	var h := (seed_value & 0xFFFF) * 31 + p.id * 7919 + (p.cur_station + 3) * 104729 + p.task_hits * 1299709
	return 0.16 + 0.68 * float(posmod(h * 2654435 + 12345, 1000)) / 1000.0

func _marker(p: PS) -> float:
	return pingpong(p.task_t * TASK_SPEED, 1.0)

func _type(s: int) -> int:
	return int(STATIONS[s]["type"]) if s >= 0 else T_MARK

## Pasos que pide la misión de esa consola (en T_WAIT, segundos).
func _needed(s: int) -> int:
	match _type(s):
		T_MASH: return 14
		T_ARROWS: return 5
		T_WAIT: return 6
		T_MEMORY: return 4
	return TASK_HITS

func _uses_arrows(s: int) -> bool:
	return s >= 0 and (_type(s) == T_ARROWS or _type(s) == T_MEMORY)

## Secuencia de flechas de la misión en curso (0 arriba, 1 derecha, 2 abajo, 3 izquierda); igual en todos los PC.
func _seq(p: PS) -> Array[int]:
	var out: Array[int] = []
	var h := (seed_value & 0xFFFF) * 31 + p.id * 7919 + (p.cur_station + 3) * 104729
	for i in _needed(p.cur_station):
		var d := posmod(((h + i * 1299709) * 2654435 + 12345) / 7, 4)
		if i > 0 and d == out[i - 1]:
			d = (d + 1) % 4
		out.append(d)
	return out

## Flecha que marca una entrada de movimiento (-1: ninguna).
func _dir_of(mv: Vector2) -> int:
	if absf(mv.x) < 0.6 and absf(mv.y) < 0.6:
		return -1
	if absf(mv.y) >= absf(mv.x):
		return 0 if mv.y < 0.0 else 2
	return 1 if mv.x > 0.0 else 3

## Consola usable más cercana (para la tripulación, solo las de sus tareas pendientes).
func _find_station(p: PS) -> int:
	var best := -1
	var bd := USE_RANGE
	for k in p.tasks.size():
		var s := p.tasks[k]
		if p.role == CREW and (p.done_mask & (1 << k)) != 0:
			continue
		var d := p.pos.distance_to(_station_pos(s))
		if d <= bd:
			bd = d
			best = s
	return best

func _find_body(p: PS) -> int:
	if not p.alive:
		return -1
	var best := -1
	var bd := REPORT_RANGE
	for b in _bodies:
		var bp: Vector2 = b["pos"]
		var d := p.pos.distance_to(bp)
		if d <= bd and _los(p.pos, bp):
			bd = d
			best = int(b["id"])
	return best

func _can_button(p: PS) -> bool:
	return p.alive and p.meetings_left > 0 and _button_cd <= 0.0 and p.pos.distance_to(_table_pos()) <= BUTTON_RANGE

## Tripulante al alcance del impostor (`front`: tiene que tenerlo delante).
func _find_victim(p: PS, front: bool) -> PS:
	var best: PS = null
	var bd := KILL_RANGE
	for id in _order:
		var q: PS = _ps[id]
		if q.id == p.id or not q.alive or q.role == IMPOSTOR:
			continue
		var d := q.pos.distance_to(p.pos)
		if d > bd:
			continue
		if front and d > 0.7 and _fwd(p).dot((q.pos - p.pos) / d) < 0.1:
			continue
		if not _los(p.pos, q.pos):
			continue
		bd = d
		best = q
	return best

## Opciones de voto de un jugador: los demás vivos y, al final, saltar.
func _options(p: PS) -> Array[int]:
	var out: Array[int] = []
	for id in _order:
		if id != p.id and (_ps[id] as PS).alive:
			out.append(id)
	out.append(SKIP)
	return out

func _alive_count(role: int) -> int:
	var n := 0
	for id in _order:
		var p: PS = _ps[id]
		if p.alive and p.role == role:
			n += 1
	return n

# ----------------------------------------------------------------------------
# Simulación (solo el host)
# ----------------------------------------------------------------------------

func _intro_time() -> float:
	return 1.6 if demo else INTRO_TIME

func _set_phase(ph: int) -> void:
	_phase = ph
	_phase_t = 0.0

func _simulate(delta: float) -> void:
	_phase_t += delta
	match _phase:
		Phase.INTRO:
			if _phase_t >= _intro_time():
				_set_phase(Phase.PLAY)
				send_event("go", null)
		Phase.PLAY:
			_sim_play(delta)
		Phase.SPLASH:
			_hold_seats()
			if _phase_t >= SPLASH_TIME:
				_begin_vote()
		Phase.VOTE:
			_hold_seats()
			_sim_vote()
		Phase.REVEAL:
			_hold_seats()
			if _phase_t >= REVEAL_TIME:
				_begin_eject()
		Phase.EJECT:
			_hold_seats()
			if _phase_t >= (EJECT_TIME if _ejected >= 0 else 2.6):
				_after_eject()
		Phase.END:
			if _phase_t >= END_TIME:
				finish(_ranking())

func _sim_play(delta: float) -> void:
	_time_left = maxf(0.0, _time_left - delta)
	_button_cd = maxf(0.0, _button_cd - delta)
	if _time_left <= 0.0:
		_end_game(IMPOSTOR, 3)
		return
	for pl in players:
		var p: PS = _ps[pl.id]
		p.kill_cd = maxf(0.0, p.kill_cd - delta)
		p.task_lock = maxf(0.0, p.task_lock - delta)
		var dir := Vector2.ZERO
		if InputManager.is_simulated(pl.id):
			dir = _bot_step(p, delta)
			if dir.length() > 0.1:
				p.myaw = 0.0
				p.kyaw = lerp_angle(p.kyaw, atan2(-dir.x, -dir.y), 1.0 - exp(-9.0 * delta))
		else:
			var mv := move_input(pl)
			var f := _fwd(p)
			if _uses_arrows(p.cur_station):
				# Misión de flechas: el movimiento son las flechas (no se anda); el segundo botón la cancela.
				var d := _dir_of(mv)
				if d >= 0 and d != p.prev_dir:
					_task_arrow(p, d)
				p.prev_dir = d
				p.hold = true
				if action2_presses(pl) > 0:
					p.cur_station = -1
			else:
				p.prev_dir = _dir_of(mv)
				if p.hold:
					if p.prev_dir < 0:
						p.hold = false
					mv = Vector2.ZERO
				if p.look:
					dir = f * (-mv.y) + Vector2(-f.y, f.x) * mv.x
				else:
					p.kyaw = wrapf(p.kyaw - mv.x * TURN * delta, -PI, PI)
					dir = _fwd(p) * (-mv.y)
				if action_presses(pl) > 0:
					_do_use(p)
				if action2_presses(pl) > 0:
					_do_secondary(p)
		if _phase != Phase.PLAY:
			return                       # una acción abrió una reunión o terminó la partida
		_move(p, dir, delta)
		if p.cur_station >= 0:
			p.task_t += delta
			if p.pos.distance_to(_station_pos(p.cur_station)) > USE_RANGE + 0.35:
				p.cur_station = -1
			elif _type(p.cur_station) == T_WAIT and int(p.task_t) > p.task_hits:
				_task_advance(p, 1)

func _move(p: PS, dir: Vector2, delta: float) -> void:
	if dir.length() > 1.0:
		dir = dir.normalized()
	p.vel = p.vel.move_toward(dir * (WALK if p.alive else GHOST_SPEED), ACCEL * delta)
	p.pos += p.vel * delta
	if p.alive:
		p.pos = _collide(p.pos)
	else:
		# Los fantasmas atraviesan las paredes, pero no salen de la nave.
		p.pos.x = clampf(p.pos.x, -(GW * 0.5 - 1.2) * CELL, (GW * 0.5 - 1.2) * CELL)
		p.pos.y = clampf(p.pos.y, -(GH * 0.5 - 1.2) * CELL, (GH * 0.5 - 1.2) * CELL)

## ESPACIO / clic: acertar el marcador de la tarea, denunciar, botón de emergencia o empezar una tarea.
func _do_use(p: PS) -> void:
	if _phase != Phase.PLAY:
		return
	if p.cur_station >= 0:
		match _type(p.cur_station):
			T_MARK:
				_task_hit(p, absf(_marker(p) - _zone(p)) <= TASK_ZONE)
			T_MASH:
				if p.task_lock <= 0.0:
					_task_advance(p, 1)
		return
	var body := _find_body(p)
	if body >= 0:
		_start_meeting(p, body)
		return
	if _can_button(p):
		p.meetings_left -= 1
		_start_meeting(p, -1)
		return
	var s := _find_station(p)
	if s >= 0:
		_start_task(p, s)

## E / clic derecho: eliminar (impostor) o denunciar.
func _do_secondary(p: PS) -> void:
	if _phase != Phase.PLAY or not p.alive:
		return
	if p.role == IMPOSTOR and p.kill_cd <= 0.0:
		var v := _find_victim(p, true)
		if v != null:
			_kill(p, v)
			return
	var body := _find_body(p)
	if body >= 0:
		_start_meeting(p, body)

func _start_task(p: PS, s: int) -> void:
	p.cur_station = s
	p.task_hits = 0
	p.task_t = 0.0
	p.task_lock = 0.25
	p.hit_t = p.bot_rng.randf_range(1.0, 1.8)

## Un intento con resultado (marcador): acierto o fallo.
func _task_hit(p: PS, ok: bool) -> void:
	if p.cur_station < 0 or p.task_lock > 0.0:
		return
	if ok:
		p.task_lock = 0.2
		_task_advance(p, 1)
	else:
		_task_fail(p)

## Una flecha pulsada en una misión de flechas o de memoria.
func _task_arrow(p: PS, d: int) -> void:
	if p.cur_station < 0 or p.task_lock > 0.0:
		return
	if _type(p.cur_station) == T_MEMORY and p.task_t < MEMORY_SHOW:
		return                           # aún se está mostrando la secuencia
	if d == _seq(p)[mini(p.task_hits, _needed(p.cur_station) - 1)]:
		_task_advance(p, 1)
	else:
		_task_fail(p)

## Fallo: bloqueo breve; en la de memoria se vuelve a enseñar la secuencia desde el principio.
func _task_fail(p: PS) -> void:
	if p.cur_station < 0:
		return
	p.task_lock = TASK_LOCK
	if _type(p.cur_station) == T_MEMORY:
		p.task_hits = 0
		p.task_t = 0.0
	send_event("hit", {"p": p.id, "ok": false})

## Avanza la misión en curso `n` pasos; al llegar a los que pide, queda hecha.
func _task_advance(p: PS, n: int) -> void:
	if p.cur_station < 0:
		return
	p.task_hits += n
	if p.task_hits < _needed(p.cur_station):
		if _type(p.cur_station) != T_MASH and _type(p.cur_station) != T_WAIT:
			send_event("hit", {"p": p.id, "ok": true})
		return
	var s := p.cur_station
	p.cur_station = -1
	if p.role == CREW:
		p.done_mask |= 1 << p.tasks.find(s)
		p.score += PTS_TASK
		_tasks_done += 1
	send_event("task", {"p": p.id, "s": s})
	_check_end()

func _kill(k: PS, v: PS) -> void:
	var seen_from := k.pos
	v.alive = false
	v.cur_station = -1
	v.vel = Vector2.ZERO
	_bodies.append({"id": v.id, "pos": v.pos})
	k.pos = v.pos
	k.vel = Vector2.ZERO
	k.cur_station = -1
	k.kill_cd = _kill_cd
	k.kills += 1
	k.score += PTS_KILL
	k.desperate = -k.bot_rng.randf_range(1.0, 6.0)
	# Los bots que lo han visto ya saben quién ha sido; los que andaban cerca se quedan con la mosca detrás de la oreja.
	for id in _order:
		var w: PS = _ps[id]
		if not w.alive or w.role != CREW:
			continue
		if _sees_kill(w, seen_from, v.pos):
			w.sus[k.id] = 1000.0
		elif _path_dist(w.pos, v.pos) <= 6:
			w.sus[k.id] = float(w.sus.get(k.id, 0.0)) + 30.0
	send_event("kill", {"k": k.id, "v": v.id})
	DevCli.log_event("impostor kill k=%d v=%d" % [k.id, v.id])
	_check_end()

func _sees_kill(w: PS, killer_pos: Vector2, victim_pos: Vector2) -> bool:
	return w.pos.distance_to(victim_pos) <= 12.0 and (_los(w.pos, victim_pos) or _los(w.pos, killer_pos))

func _witnesses(k: PS, v: PS) -> int:
	var n := 0
	for id in _order:
		var w: PS = _ps[id]
		if w.id != k.id and w.id != v.id and w.alive and w.role == CREW and _sees_kill(w, k.pos, v.pos):
			n += 1
	return n

func _start_meeting(by: PS, victim_id: int) -> void:
	_meet_by = by.id
	_meet_victim = victim_id
	_meet_room = _room_index(by.pos)
	for b in _bodies:
		if int(b["id"]) == victim_id:
			_meet_room = _room_index(b["pos"])
	_bodies.clear()
	_meetings += 1
	_ejected = -1
	for id in _order:
		var p: PS = _ps[id]
		p.cur_station = -1
		p.vote = NO_VOTE
		p.cursor = 0
		p.prev_y = 0.0
		p.goal = 0
		p.wait_t = 0.0
	_hold_seats()
	_set_phase(Phase.SPLASH)
	send_event("meet", {"by": by.id, "v": victim_id})
	DevCli.log_event("impostor meeting by=%d body=%d" % [by.id, victim_id])

## Durante la reunión todos están en su sitio de la mesa, mirándola.
func _hold_seats() -> void:
	var n := _order.size()
	for id in _order:
		var p: PS = _ps[id]
		p.pos = _seat_pos(p.idx, n)
		p.vel = Vector2.ZERO
		p.kyaw = wrapf(_seat_yaw(p.idx, n) - p.myaw, -PI, PI)

func _begin_vote() -> void:
	_set_phase(Phase.VOTE)
	for id in _order:
		var p: PS = _ps[id]
		p.vote_at = p.bot_rng.randf_range(1.2, 3.0) if demo else p.bot_rng.randf_range(2.5, 9.0)

func _sim_vote() -> void:
	var pending := 0
	for pl in players:
		var p: PS = _ps[pl.id]
		if not p.alive or p.vote != NO_VOTE:
			continue
		if InputManager.is_simulated(pl.id):
			if _phase_t >= p.vote_at:
				_cast(p, _bot_vote(p))
		else:
			var mv := move_input(pl)
			var opts := _options(p)
			if mv.y < -0.5 and p.prev_y >= -0.5:
				p.cursor = posmod(p.cursor - 1, opts.size())
			elif mv.y > 0.5 and p.prev_y <= 0.5:
				p.cursor = posmod(p.cursor + 1, opts.size())
			p.prev_y = mv.y
			if action_presses(pl) > 0 and _phase_t > 0.5:
				_cast(p, opts[clampi(p.cursor, 0, opts.size() - 1)])
		if p.vote == NO_VOTE:
			pending += 1
	# Con todos los votos dentro no se espera al reloj.
	if pending == 0 and _phase_t < VOTE_TIME - 1.2:
		_phase_t = VOTE_TIME - 1.2
	if _phase_t >= VOTE_TIME:
		_begin_reveal()

func _cast(p: PS, target: int) -> void:
	if p.vote != NO_VOTE or not p.alive:
		return
	p.vote = target
	send_event("voted", {"p": p.id})

func _begin_reveal() -> void:
	var counts: Dictionary = {}
	var skips := 0
	for id in _order:
		var p: PS = _ps[id]
		if not p.alive:
			continue
		if p.vote == NO_VOTE:
			p.vote = SKIP
		if p.vote == SKIP:
			skips += 1
		else:
			counts[p.vote] = int(counts.get(p.vote, 0)) + 1
	var best := -1
	var best_n := 0
	var tie := false
	for id in _order:
		var c := int(counts.get(id, 0))
		if c > best_n:
			best = id
			best_n = c
			tie = false
		elif c == best_n and c > 0:
			tie = true
	_ejected = best if (best >= 0 and not tie and best_n > skips) else -1
	# Puntos de la votación.
	for id in _order:
		var p: PS = _ps[id]
		if not p.alive or p.role != CREW or p.vote < 0:
			continue
		var t: PS = _ps[p.vote]
		if t.role == IMPOSTOR:
			p.score += PTS_GOOD_VOTE
		elif p.vote == _ejected:
			p.score += PTS_BAD_EJECT
	_set_phase(Phase.REVEAL)
	send_event("reveal", {"e": _ejected})

func _begin_eject() -> void:
	if _ejected >= 0:
		(_ps[_ejected] as PS).alive = false
	_set_phase(Phase.EJECT)
	send_event("eject", {"e": _ejected})
	DevCli.log_event("impostor eject id=%d" % _ejected)

func _after_eject() -> void:
	if _check_end():
		return
	for id in _order:
		var p: PS = _ps[id]
		p.kill_cd = maxf(p.kill_cd, KILL_CD_MEETING)
		p.desperate = -p.bot_rng.randf_range(1.0, 6.0)
		for sid in p.sus.keys():
			if float(p.sus[sid]) < 500.0:
				p.sus[sid] = float(p.sus[sid]) * 0.5
	_button_cd = BUTTON_CD
	_set_phase(Phase.PLAY)
	send_event("resume", null)

func _check_end() -> bool:
	if _phase == Phase.END:
		return true
	var imp := _alive_count(IMPOSTOR)
	var crew := _alive_count(CREW)
	if imp == 0:
		_end_game(CREW, 0)
	elif imp >= crew:
		_end_game(IMPOSTOR, 1)
	elif _tasks_done >= _tasks_total:
		_end_game(CREW, 2)
	else:
		return false
	return true

func _end_game(team: int, reason: int) -> void:
	if _phase == Phase.END:
		return
	_winner = team
	_reason = reason
	for id in _order:
		var p: PS = _ps[id]
		p.cur_station = -1
		p.vel = Vector2.ZERO
		if p.role == team:
			p.score += PTS_WIN
		if p.alive:
			p.score += PTS_SURVIVE
	_set_phase(Phase.END)
	send_event("end", {"w": team})
	DevCli.log_event("impostor over winner=%d reason=%d" % [team, reason])

## Juego por bandos: los puntos de partida no van por posición. En los demás minijuegos el ganador se lleva N puntos (N =
## nº de jugadores); aquí, si gana la tripulación, cada tripulante recibe 3/4 de eso (son muchos) y el impostor 1; si gana
## el impostor, él recibe 7/4 (lo tenía más difícil) y cada tripulante 1. Con 4 jugadores: 3 y 1, o 7 y 1.
func _result_points() -> Dictionary:
	var n := _order.size()
	var win_pts := maxi(1, roundi(n * (0.75 if _winner == CREW else 1.75)))
	var out: Dictionary = {}
	for id in _order:
		out[id] = win_pts if (_ps[id] as PS).role == _winner else 1
	return out

func _ranking() -> Array[int]:
	var scores: Dictionary = {}
	var ties: Dictionary = {}
	for id in _order:
		var p: PS = _ps[id]
		scores[id] = p.score
		ties[id] = 0.0 if p.alive else 1.0
	return rank_by_score(scores, ties)

# ----------------------------------------------------------------------------
# IA (bots, autopiloto, desconectados, práctica)
# ----------------------------------------------------------------------------

## Dirección (en el mundo) hacia la que anda el bot este fotograma; las acciones las ejecuta directamente.
func _bot_step(p: PS, delta: float) -> Vector2:
	p.think_t -= delta
	if p.think_t <= 0.0:
		p.think_t = 0.2
		_bot_think(p)
		if _phase != Phase.PLAY:
			return Vector2.ZERO
	if p.cur_station >= 0:
		p.hit_t -= delta
		if p.hit_t <= 0.0:
			p.hit_t = p.bot_rng.randf_range(1.0, 1.9)
			p.task_lock = 0.0
			if _type(p.cur_station) != T_WAIT and p.bot_rng.randf() < 0.85:
				_task_advance(p, ceili(_needed(p.cur_station) / 3.0))
		return Vector2.ZERO
	if p.wait_t > 0.0:
		p.wait_t -= delta
		return Vector2.ZERO
	if p.goal == 0:
		return Vector2.ZERO
	return _steer(p, p.goal_pos)

func _steer(p: PS, target: Vector2) -> Vector2:
	var to := target - p.pos
	if to.length() < 0.25:
		return Vector2.ZERO
	if not p.alive or _walk_clear(p.pos, target):
		return to.normalized()
	var c := _cell_of(p.pos)
	var tc := _cell_of(target)
	if not _in_grid(c) or c == tc:
		return to.normalized()
	var f := _field(tc)
	var best := c
	for step in 2:
		var nxt := best
		for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n := Vector2i(best.x + off.x, best.y + off.y)
			if not _is_blocked(n) and f[n.y * GW + n.x] < f[nxt.y * GW + nxt.x]:
				nxt = n
		# El segundo paso solo si se puede ir recto hasta él (recorta las esquinas).
		if step == 1 and not _walk_clear(p.pos, _center(nxt)):
			break
		best = nxt
	if best == c:
		return to.normalized()
	return (_center(best) - p.pos).normalized()

func _bot_think(p: PS) -> void:
	# ¿Atascado? Cambia de plan.
	if p.goal != 0 and p.wait_t <= 0.0 and p.cur_station < 0:
		p.stuck_t = p.stuck_t + 0.2 if p.pos.distance_to(p.last_pos) < 0.15 else 0.0
		if p.stuck_t > 2.5:
			p.goal = 0
			p.stuck_t = 0.0
	p.last_pos = p.pos
	if p.role == IMPOSTOR:
		_think_impostor(p)
	else:
		_think_crew(p)

func _think_crew(p: PS) -> void:
	if p.cur_station >= 0:
		return
	if p.alive:
		# Un cadáver a la vista: a denunciarlo.
		for b in _bodies:
			var bp: Vector2 = b["pos"]
			var d := p.pos.distance_to(bp)
			if d <= 9.0 and _los(p.pos, bp):
				if d <= REPORT_RANGE * 0.85:
					for id in _order:
						var q: PS = _ps[id]
						if q.id != p.id and q.alive and q.pos.distance_to(bp) <= 5.0 and _los(p.pos, q.pos):
							p.sus[q.id] = float(p.sus.get(q.id, 0.0)) + 35.0
					_start_meeting(p, int(b["id"]))
					return
				p.goal = 2
				p.goal_pos = bp
				p.wait_t = 0.0
				return
		if p.goal == 2:
			p.goal = 0
	if p.goal == 1 and _pending(p, p.goal_id):
		if p.pos.distance_to(p.goal_pos) <= USE_RANGE * 0.6:
			_start_task(p, p.goal_id)
		return
	if p.goal == 4 and p.pos.distance_to(p.goal_pos) > 1.0:
		return
	# Siguiente tarea: la pendiente más cercana andando.
	var best := -1
	var bd := 99999
	for k in p.tasks.size():
		if (p.done_mask & (1 << k)) != 0:
			continue
		var d2 := _path_dist(p.pos, _station_pos(p.tasks[k]))
		if d2 < bd:
			bd = d2
			best = p.tasks[k]
	if best >= 0:
		p.goal = 1
		p.goal_id = best
		p.goal_pos = _station_pos(best)
		p.wait_t = p.bot_rng.randf_range(1.0, 3.5)       # se lo piensa un poco (los humanos también se orientan)
	else:
		p.goal = 4
		p.goal_pos = _station_pos(p.bot_rng.randi_range(0, STATIONS.size() - 1))
		p.wait_t = p.bot_rng.randf_range(1.0, 3.0)

func _think_impostor(p: PS) -> void:
	if not p.alive:
		p.goal = 0
		return
	if p.kill_cd <= 0.0:
		p.desperate += 0.2
	# Con la recarga lista aún disimula un rato antes de salir de caza.
	if p.kill_cd <= 0.0 and p.desperate >= 0.0:
		var v := _find_victim(p, false)
		if v != null:
			var w := _witnesses(p, v)
			if w == 0 or (p.desperate > 12.0 and w <= 1) or p.desperate > 22.0:
				_kill(p, v)
				if _phase != Phase.PLAY:
					return
				# Se aleja del cadáver hacia la consola más lejana.
				var far := 0
				var fd := -1
				for s in STATIONS.size():
					var d := _path_dist(p.pos, _station_pos(s))
					if d < 9999 and d > fd:
						fd = d
						far = s
				p.goal = 4
				p.goal_pos = _station_pos(far)
				p.wait_t = 0.0
				return
		# A la caza del tripulante más cercano.
		var prey: PS = null
		var pd := 99999
		for id in _order:
			var q: PS = _ps[id]
			if not q.alive or q.role == IMPOSTOR:
				continue
			var d2 := _path_dist(p.pos, q.pos)
			if d2 < pd:
				pd = d2
				prey = q
		if prey != null:
			p.goal = 3
			p.goal_pos = prey.pos
			p.wait_t = 0.0
			return
	if p.goal == 3:
		p.goal = 0
	# Mientras recarga: va de consola en consola fingiendo tareas.
	if p.goal == 4 and p.pos.distance_to(p.goal_pos) > 0.9:
		return
	if p.goal == 4:
		p.wait_t = p.bot_rng.randf_range(2.5, 4.5)
	p.goal = 4
	p.goal_pos = _station_pos(p.tasks[p.bot_rng.randi_range(0, p.tasks.size() - 1)])

func _bot_vote(p: PS) -> int:
	var opts := _options(p)
	opts.pop_back()
	if opts.is_empty():
		return SKIP
	if p.role == IMPOSTOR:
		var crew: Array[int] = []
		for id in opts:
			if (_ps[id] as PS).role == CREW:
				crew.append(id)
		if not crew.is_empty() and p.bot_rng.randf() < 0.45:
			return crew[p.bot_rng.randi_range(0, crew.size() - 1)]
		return SKIP
	var best := SKIP
	var bs := 0.0
	for id in opts:
		var s := float(p.sus.get(id, 0.0))
		if s > bs:
			bs = s
			best = id
	if bs >= 500.0 or (bs >= 35.0 and p.bot_rng.randf() < 0.75):
		return best
	if p.bot_rng.randf() < 0.12:
		return opts[p.bot_rng.randi_range(0, opts.size() - 1)]
	return SKIP

# ----------------------------------------------------------------------------
# Red
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var arr := PackedFloat32Array()
	for id in _order:
		var p: PS = _ps[id]
		arr.append_array(PackedFloat32Array([p.pos.x, p.pos.y, p.vel.x, p.vel.y, p.kyaw, p.myaw, 1.0 if p.alive else 0.0,
				float(p.done_mask), float(p.cur_station), float(p.task_hits), p.task_t, p.task_lock, p.kill_cd, float(p.score),
				float(p.vote), float(p.cursor), float(p.meetings_left), 1.0 if p.look else 0.0, float(p.kills)]))
	var bod := PackedFloat32Array()
	for b in _bodies:
		bod.append_array(PackedFloat32Array([float(b["id"]), (b["pos"] as Vector2).x, (b["pos"] as Vector2).y]))
	return {"p": arr, "b": bod, "ph": _phase, "pt": _phase_t, "o2": _time_left, "bc": _button_cd, "td": _tasks_done,
			"mb": _meet_by, "mv": _meet_victim, "mr": _meet_room, "ej": _ejected, "w": _winner, "rs": _reason}

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	var st: Dictionary = state
	_phase = int(st.get("ph", _phase))
	_phase_t = float(st.get("pt", _phase_t))
	_time_left = float(st.get("o2", _time_left))
	_button_cd = float(st.get("bc", _button_cd))
	_tasks_done = int(st.get("td", _tasks_done))
	_meet_by = int(st.get("mb", _meet_by))
	_meet_victim = int(st.get("mv", _meet_victim))
	_meet_room = int(st.get("mr", _meet_room))
	_ejected = int(st.get("ej", _ejected))
	_winner = int(st.get("w", _winner))
	_reason = int(st.get("rs", _reason))
	var bod: Variant = st.get("b")
	if bod is PackedFloat32Array:
		_bodies.clear()
		for i in range(0, bod.size() - 2, 3):
			_bodies.append({"id": int(bod[i]), "pos": Vector2(bod[i + 1], bod[i + 2])})
	var arr: Variant = st.get("p")
	if not arr is PackedFloat32Array or arr.size() < _order.size() * FLOATS:
		return
	for i in _order.size():
		var p: PS = _ps[_order[i]]
		var o := i * FLOATS
		p.pos = Vector2(arr[o], arr[o + 1])
		p.vel = Vector2(arr[o + 2], arr[o + 3])
		p.kyaw = arr[o + 4]
		p.myaw = arr[o + 5]
		p.alive = arr[o + 6] > 0.5
		p.done_mask = int(arr[o + 7])
		p.cur_station = int(arr[o + 8])
		p.task_hits = int(arr[o + 9])
		p.task_t = arr[o + 10]
		p.task_lock = arr[o + 11]
		p.kill_cd = arr[o + 12]
		p.score = int(arr[o + 13])
		p.vote = int(arr[o + 14])
		p.cursor = int(arr[o + 15])
		p.meetings_left = int(arr[o + 16])
		p.look = arr[o + 17] > 0.5
		p.kills = int(arr[o + 18])

## (host) Giro del ratón de un jugador remoto: "y<ángulo>".
func _on_player_text(player: PlayerData, text: String, _final: bool) -> void:
	if player == null or not text.begins_with("y"):
		return
	var p: PS = _ps.get(player.id)
	if p == null or not text.substr(1).is_valid_float():
		return
	var v := text.substr(1).to_float()
	if not is_finite(v):
		return
	p.look = true
	if _phase == Phase.PLAY or _phase == Phase.INTRO:
		p.myaw = wrapf(v, -PI, PI)

func _on_event(event_name: String, data: Variant) -> void:
	var d: Dictionary = data if data is Dictionary else {}
	var mine := int(d.get("p", -1)) == _view_id
	match event_name:
		"go":
			Audio.sfx(&"beep_go", -8.0)
		"hit":
			if mine:
				Audio.sfx(&"claim" if bool(d.get("ok", false)) else &"error", -8.0)
		"task":
			if mine:
				_flash_ok = 1.0
				_toast = "¡Tarea completada!" if _view().role == CREW else "Tarea fingida"
				_toast_t = 1.8
				Audio.sfx(&"milestone", -6.0)
		"kill":
			if int(d.get("v", -1)) == _view_id:
				_flash_red = 1.0
				_toast = "¡%s te ha eliminado!" % _name_of(int(d.get("k", -1)))
				_toast_t = 3.5
				Audio.sfx(&"crash", -4.0)
				Audio.sfx(&"zap", -8.0)
			elif int(d.get("k", -1)) == _view_id:
				_flash_red = 0.45
				Audio.sfx(&"thud", -5.0)
				Audio.sfx(&"swish", -8.0)
		"meet":
			_pitch = 0.0
			Audio.sfx(&"stinger", -4.0)
		"voted":
			Audio.sfx(&"lock", -12.0)
		"reveal":
			Audio.sfx(&"score_pop", -8.0)
		"eject":
			if int(d.get("e", -1)) >= 0:
				Audio.sfx(&"swoosh", -5.0)
		"end":
			Audio.sfx(&"fanfare_big", -6.0)

# ----------------------------------------------------------------------------
# Ciclo del minijuego
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	_setup_round()
	_build_world()
	surface.draw_callback = _draw_hud

func _on_start() -> void:
	_setup_round()
	_rebuild_player_nodes()
	_local_myaw = 0.0
	_sent_myaw = 999.0
	_pitch = 0.0
	_flash_red = 0.0
	_flash_ok = 0.0
	_toast_t = 0.0
	_last_o2 = 999
	var vp := _player_by_id(_view_id)
	var human := vp != null and vp.is_local_human and not InputManager.is_simulated(vp.id)
	_use_look = human and not demo and not InputManager.touch_mode and vp.device != PlayerData.DEVICE_KB2 \
			and DisplayServer.get_name() != "headless"
	if _use_look and not vp.device.begins_with(PlayerData.DEVICE_JOY_PREFIX):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_captured = true

func _exit_tree() -> void:
	if _captured:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_captured = false

func _pick_view() -> void:
	_view_id = -1
	if local_player != null and _ps.has(local_player.id):
		_view_id = local_player.id
		return
	for pl in players:
		if pl.is_local_human:
			_view_id = pl.id
			return
	if not _order.is_empty():
		_view_id = _order[0]

func _view() -> PS:
	return _ps.get(_view_id)

func _can_turn() -> bool:
	return is_running and (_phase == Phase.PLAY or _phase == Phase.INTRO or _phase == Phase.END)

func _input(event: InputEvent) -> void:
	if not _use_look or not _captured:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and _can_turn():
		var rel: Vector2 = (event as InputEventMouseMotion).relative
		_local_myaw = wrapf(_local_myaw - rel.x * MOUSE_SENS, -PI, PI)
		_pitch = clampf(_pitch - rel.y * MOUSE_SENS, -1.1, 1.1)
	elif event is InputEventKey and (event as InputEventKey).pressed and (event as InputEventKey).physical_keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE          # ESC suelta el ratón; un clic lo vuelve a coger
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## Giro local (ratón y palanca derecha del mando): se aplica aquí al instante y se le cuenta al host.
func _update_look(delta: float) -> void:
	if not _use_look or not is_running:
		return
	var v := _view()
	if v == null:
		return
	if _can_turn():
		var pl := _player_by_id(_view_id)
		var pads: Array[int] = Input.get_connected_joypads()
		if pl != null and pl.device.begins_with(PlayerData.DEVICE_JOY_PREFIX):
			pads = [int(pl.device.substr(PlayerData.DEVICE_JOY_PREFIX.length()))]
		for pad in pads:
			var ax := Input.get_joy_axis(pad, JOY_AXIS_RIGHT_X)
			var ay := Input.get_joy_axis(pad, JOY_AXIS_RIGHT_Y)
			if absf(ax) > 0.2:
				_local_myaw = wrapf(_local_myaw - ax * STICK_SENS * delta, -PI, PI)
			if absf(ay) > 0.2:
				_pitch = clampf(_pitch - ay * STICK_SENS * 0.6 * delta, -1.1, 1.1)
	else:
		_local_myaw = v.myaw             # en la reunión manda el host (todos miran a la mesa)
	if is_authority:
		v.look = true
		v.myaw = _local_myaw
		return
	_look_send_t -= delta
	if (_look_send_t <= 0.0 and absf(_local_myaw - _sent_myaw) > 0.002) or _look_send_t <= -0.4:
		_look_send_t = 0.05
		_sent_myaw = _local_myaw
		submit_text("y%.3f" % _local_myaw, false)

func _animate(delta: float) -> void:
	_anim += delta
	_flash_red = maxf(0.0, _flash_red - delta * 0.9)
	_flash_ok = maxf(0.0, _flash_ok - delta * 2.0)
	_toast_t = maxf(0.0, _toast_t - delta)
	_update_look(delta)
	if not is_authority and is_running:
		for id in _order:
			var p: PS = _ps[id]
			if p.cur_station >= 0:
				p.task_t += delta            # el marcador sigue moviéndose entre snapshots
	if is_running and _phase == Phase.PLAY:
		var sec := ceili(_time_left)
		if sec != _last_o2 and sec <= 10 and sec > 0:
			Audio.sfx(&"beep", -9.0)
		_last_o2 = sec
	_update_world(delta)

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

func _glow(c: Color, energy: float = 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(c.r * energy, c.g * energy, c.b * energy)
	return m

func _toon(c: Color, outline: float = 0.025) -> StandardMaterial3D:
	var m := _mat(c, 0.0, 0.5)
	var o := StandardMaterial3D.new()
	o.albedo_color = Color(0.03, 0.03, 0.06)
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
	sm.radial_segments = 20
	sm.rings = 10
	return _mesh(parent, sm, pos, mat)

func _cyl(parent: Node3D, radius: float, height: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = 24
	return _mesh(parent, cm, pos, mat)

func _label(parent: Node3D, text: String, pos: Vector3, size: int, color: Color, billboard: bool = false) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = size
	l.pixel_size = 0.005
	l.outline_size = maxi(6, size / 6)
	l.outline_modulate = Color(0.02, 0.03, 0.06)
	l.modulate = color
	l.shaded = false
	l.double_sided = false
	if billboard:
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.position = pos
	parent.add_child(l)
	return l

func _multi(mesh: Mesh, xforms: Array, colors: Array, mat: StandardMaterial3D) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = not colors.is_empty()
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		if mm.use_colors:
			mm.set_instance_color(i, colors[i])
	if mm.use_colors:
		mat.vertex_color_use_as_albedo = true
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	_root3.add_child(mmi)
	return mmi

## Transformación pegada a la cara interior de una pared: origen en la pared, a ras de suelo, +Z hacia dentro de la sala.
func _wall_xf(cell: Vector2i, dir: Vector2i) -> Transform3D:
	var c := _center(cell) + Vector2(dir.x, dir.y) * (CELL * 0.5)
	return Transform3D(Basis(Vector3.UP, atan2(-float(dir.x), -float(dir.y))), Vector3(c.x, 0.0, c.y))

# --- Texturas procedurales (una vez) ---
static var _tex_floor: ImageTexture = null
static var _tex_wall: ImageTexture = null
static var _tex_stars: ImageTexture = null

func _floor_texture() -> ImageTexture:
	if _tex_floor != null:
		return _tex_floor
	var n := FastNoiseLite.new()
	n.seed = 21
	n.frequency = 0.06
	var nn := n.get_seamless_image(128, 128)
	var img := Image.create(128, 128, false, Image.FORMAT_RGB8)
	for y in 128:
		for x in 128:
			var v := 0.62 + 0.16 * (nn.get_pixel(x, y).r - 0.5)
			var gx := x % 64
			var gy := y % 64
			if gx < 2 or gy < 2:
				v *= 0.5                                  # juntas entre losas
			elif gx < 4 or gy < 4:
				v *= 1.18
			var rx := minf(float(gx), float(63 - gx))
			var ry := minf(float(gy), float(63 - gy))
			if Vector2(rx - 8.0, ry - 8.0).length() < 2.2:
				v *= 1.35                                 # remaches
			img.set_pixel(x, y, Color(v, v, v))
	img.generate_mipmaps()
	_tex_floor = ImageTexture.create_from_image(img)
	return _tex_floor

func _wall_texture() -> ImageTexture:
	if _tex_wall != null:
		return _tex_wall
	var n := FastNoiseLite.new()
	n.seed = 37
	n.frequency = 0.04
	var nn := n.get_seamless_image(128, 128)
	var img := Image.create(128, 128, false, Image.FORMAT_RGB8)
	for y in 128:
		for x in 128:
			var v := 0.5 + 0.12 * (nn.get_pixel(x, y).r - 0.5)
			if x < 3 or y < 3:
				v *= 0.55                                 # juntas de los paneles
			elif x < 5 or y < 5:
				v *= 1.2
			if y > 96 and y < 100:
				v *= 0.7                                  # moldura
			if (x == 20 or x == 108) and y > 14 and y < 86:
				v *= 0.8
			img.set_pixel(x, y, Color(v * 0.86, v * 0.94, v * 1.06))
	img.generate_mipmaps()
	_tex_wall = ImageTexture.create_from_image(img)
	return _tex_wall

func _stars_texture() -> ImageTexture:
	if _tex_stars != null:
		return _tex_stars
	var img := Image.create(256, 128, false, Image.FORMAT_RGB8)
	img.fill(Color(0.01, 0.012, 0.035))
	var r := RandomNumberGenerator.new()
	r.seed = 99
	for y in 128:
		for x in 256:
			var neb := 0.06 * maxf(0.0, sin(x * 0.03 + y * 0.05) * cos(y * 0.04 - x * 0.02))
			img.set_pixel(x, y, Color(0.01 + neb * 0.9, 0.012 + neb * 0.3, 0.035 + neb * 1.6))
	for i in 260:
		var b := r.randf_range(0.45, 1.6)
		var px := r.randi_range(0, 255)
		var py := r.randi_range(0, 127)
		img.set_pixel(px, py, Color(b, b, b * 1.1))
		if b > 1.3 and px < 255 and py < 127:
			img.set_pixel(px + 1, py, Color(b * 0.5, b * 0.5, b * 0.6))
			img.set_pixel(px, py + 1, Color(b * 0.5, b * 0.5, b * 0.6))
	_tex_stars = ImageTexture.create_from_image(img)
	return _tex_stars

func _build_world() -> void:
	if _built:
		return
	_built = true
	var cont := SubViewportContainer.new()
	cont.stretch = true
	cont.top_level = true                          # toda la ventana, aunque el minijuego esté en una capa centrada
	cont.set_anchors_preset(Control.PRESET_TOP_LEFT)
	cont.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cont = cont
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
	# --- Ambiente: nave en penumbra; cada jugador lleva su propia luz (se ve bien lo cercano y el fondo se pierde) ---
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.008, 0.01, 0.02)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.6, 0.8)
	env.ambient_light_energy = 0.42
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_bloom = 0.1
	env.glow_hdr_threshold = 0.95
	env.fog_enabled = true
	env.fog_light_color = Color(0.02, 0.03, 0.06)
	env.fog_density = 0.028
	var we := WorldEnvironment.new()
	we.environment = env
	_root3.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-70.0, 25.0, 0.0)
	sun.light_energy = 0.35
	sun.light_color = Color(0.75, 0.85, 1.0)
	_root3.add_child(sun)
	_build_ship()
	_build_props()
	_build_stations()
	_rebuild_player_nodes()
	_cam = Camera3D.new()
	_cam.fov = 78.0
	_cam.near = 0.06
	_cam.far = 80.0
	_root3.add_child(_cam)
	_cam.current = true
	var lamp := OmniLight3D.new()
	lamp.light_color = Color(1.0, 0.96, 0.88)
	lamp.light_energy = 1.5
	lamp.omni_range = 15.0
	lamp.omni_attenuation = 1.1
	_cam.add_child(lamp)
	_update_world(0.0)

## Suelo, paredes, techo, franjas de color de cada sala y luces del techo.
func _build_ship() -> void:
	var floor_x: Array = []
	var floor_c: Array = []
	var wall_x: Array = []
	var band_x: Array = []
	var band_c: Array = []
	var lamp_x: Array = []
	var lamp_c: Array = []
	var hall_col := Color(0.42, 0.47, 0.55)
	for y in GH:
		for x in GW:
			var c := Vector2i(x, y)
			var w := _center(c)
			if _is_solid(c):
				var near := false
				for oy in range(-1, 2):
					for ox in range(-1, 2):
						if not _is_solid(Vector2i(x + ox, y + oy)):
							near = true
				if near:
					wall_x.append(Transform3D(Basis(), Vector3(w.x, WALL_H * 0.5, w.y)))
				continue
			var ri := _room_of[y * GW + x]
			var rc: Color = ROOMS[ri]["color"] if ri >= 0 else hall_col
			floor_x.append(Transform3D(Basis(), Vector3(w.x, 0.0, w.y)))
			floor_c.append(hall_col if ri < 0 else Color(0.5, 0.52, 0.56).lerp(rc, 0.42))
			for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if _is_solid(c + dir):
					var xf := _wall_xf(c, dir)
					band_x.append(xf * Transform3D(Basis(), Vector3(0.0, 1.55, 0.02)))
					band_c.append(rc if ri >= 0 else Color(0.5, 0.75, 0.9))
			# Luces del techo: una de cada dos celdas.
			if (x + y) % 2 == 0:
				lamp_x.append(Transform3D(Basis(), Vector3(w.x, WALL_H - 0.03, w.y)))
				lamp_c.append(Color(0.9, 0.95, 1.0).lerp(rc, 0.35) if ri >= 0 else Color(0.75, 0.85, 1.0))
	var floor_mat := _mat(Color.WHITE, 0.0, 0.5, 0.3)
	floor_mat.albedo_texture = _floor_texture()
	floor_mat.uv1_scale = Vector3(2.0, 2.0, 1.0)
	floor_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var pm := PlaneMesh.new()
	pm.size = Vector2(CELL, CELL)
	_multi(pm, floor_x, floor_c, floor_mat)
	var wall_mat := _mat(Color(0.8, 0.85, 0.92), 0.0, 0.6, 0.25)
	wall_mat.albedo_texture = _wall_texture()
	wall_mat.uv1_triplanar = true
	wall_mat.uv1_world_triplanar = true
	wall_mat.uv1_scale = Vector3(0.5, 0.5, 0.5)
	wall_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var wm := BoxMesh.new()
	wm.size = Vector3(CELL, WALL_H, CELL)
	_multi(wm, wall_x, [], wall_mat)
	var bm := BoxMesh.new()
	bm.size = Vector3(CELL, 0.14, 0.04)
	_multi(bm, band_x, band_c, _glow(Color.WHITE, 0.95))
	var lm := BoxMesh.new()
	lm.size = Vector3(1.1, 0.05, 0.36)
	_multi(lm, lamp_x, lamp_c, _glow(Color.WHITE, 1.5))
	_box(_root3, Vector3(GW * CELL, 0.3, GH * CELL), Vector3(0, WALL_H + 0.15, 0), _mat(Color(0.1, 0.12, 0.16), 0.0, 0.8))
	# Rótulo de cada sala colgado del techo.
	for i in ROOMS.size():
		var r: Rect2i = ROOMS[i]["rect"]
		var mid := (_center(r.position) + _center(r.end - Vector2i.ONE)) * 0.5
		if i == 0:
			mid += Vector2(0, -2.6)
		var sign_l := _label(_root3, String(ROOMS[i]["name"]).to_upper(), Vector3(mid.x, WALL_H - 0.42, mid.y), 64, ROOMS[i]["color"], true)
		sign_l.pixel_size = 0.0048
	# Ventanas al espacio.
	var star_mat := _glow(Color.WHITE, 1.0)
	star_mat.albedo_texture = _stars_texture()
	var frame_mat := _mat(Color(0.16, 0.19, 0.24), 0.0, 0.4, 0.7)
	for wdef in [[Vector2i(23, 9), Vector2i(1, 0)], [Vector2i(23, 7), Vector2i(1, 0)], [Vector2i(21, 1), Vector2i(0, -1)],
			[Vector2i(23, 3), Vector2i(1, 0)], [Vector2i(11, 1), Vector2i(0, -1)], [Vector2i(13, 1), Vector2i(0, -1)],
			[Vector2i(21, 15), Vector2i(0, 1)], [Vector2i(1, 3), Vector2i(-1, 0)], [Vector2i(14, 15), Vector2i(0, 1)]]:
		var holder := Node3D.new()
		holder.transform = _wall_xf(wdef[0], wdef[1])
		_root3.add_child(holder)
		_box(holder, Vector3(1.86, 1.36, 0.08), Vector3(0, 1.95, 0.03), frame_mat)
		var qm := QuadMesh.new()
		qm.size = Vector2(1.66, 1.16)
		_mesh(holder, qm, Vector3(0, 1.95, 0.08), star_mat)

## Muebles grandes: mesa con el botón de emergencia, núcleo del reactor, motores y cajas.
func _build_props() -> void:
	var metal := _mat(Color(0.34, 0.39, 0.46), 0.0, 0.4, 0.6)
	var t := _table_pos()
	_cyl(_root3, 0.3, 0.8, Vector3(t.x, 0.4, t.y), metal)
	_cyl(_root3, 0.98, 0.12, Vector3(t.x, 0.86, t.y), _mat(Color(0.75, 0.8, 0.9), 0.0, 0.35, 0.2))
	_cyl(_root3, 0.3, 0.08, Vector3(t.x, 0.96, t.y), _mat(Color(0.95, 0.8, 0.15), 0.0, 0.5))
	_button_top = _cyl(_root3, 0.2, 0.12, Vector3(t.x, 1.04, t.y), _mat(Color(1.0, 0.15, 0.12), 1.2, 0.3))
	# Núcleo del reactor.
	var rc := _center(Vector2i(3, 12))
	_core = _cyl(_root3, 0.55, WALL_H, Vector3(rc.x, WALL_H * 0.5, rc.y), _glow(Color(0.3, 1.0, 0.9), 1.3))
	for h in [0.25, 1.6, 2.95]:
		_cyl(_root3, 0.85, 0.3, Vector3(rc.x, h, rc.y), metal)
	# Motores (dos cilindros tumbados con el interior encendido).
	for cell in [Vector2i(3, 1), Vector2i(3, 5)]:
		var ec := _center(cell)
		var eng := _cyl(_root3, 0.85, 1.9, Vector3(ec.x, 1.0, ec.y), _mat(Color(0.3, 0.36, 0.42), 0.0, 0.35, 0.7))
		eng.rotation_degrees = Vector3(0, 0, 90)
		var fire := _cyl(_root3, 0.6, 1.94, Vector3(ec.x, 1.0, ec.y), _glow(Color(1.0, 0.55, 0.2), 1.4))
		fire.rotation_degrees = Vector3(0, 0, 90)
		_box(_root3, Vector3(1.7, 0.3, 1.5), Vector3(ec.x, 0.15, ec.y), metal)
	# Cajas del almacén.
	var crate := _mat(Color(0.62, 0.45, 0.25), 0.0, 0.85)
	var crate2 := _mat(Color(0.3, 0.5, 0.42), 0.0, 0.8)
	var cc := _center(Vector2i(14, 12))
	_box(_root3, Vector3(1.7, 1.1, 1.7), Vector3(cc.x, 0.55, cc.y), crate)
	_box(_root3, Vector3(1.0, 0.8, 1.0), Vector3(cc.x - 0.2, 1.5, cc.y + 0.15), crate2).rotation_degrees = Vector3(0, 22, 0)
	for extra in [[Vector2i(16, 15), 0.7, crate2], [Vector2i(11, 9), 0.6, crate], [Vector2i(16, 9), 0.55, crate]]:
		var xc := _center(extra[0]) + Vector2(0.45, 0.45) * (1.0 if (extra[0] as Vector2i).x > 12 else -1.0)
		var sz: float = extra[1]
		_box(_root3, Vector3(sz, sz, sz), Vector3(xc.x, sz * 0.5, xc.y), extra[2])

## Consolas de tareas: mesa, pantalla del color de la sala, nombre y aviso "!" (solo en las tuyas pendientes).
func _build_stations() -> void:
	_station_marks.clear()
	_station_screens.clear()
	var desk := _mat(Color(0.22, 0.26, 0.33), 0.0, 0.45, 0.5)
	for s in STATIONS.size():
		var st: Dictionary = STATIONS[s]
		var col: Color = ROOMS[st["room"]]["color"]
		var holder := Node3D.new()
		holder.transform = _wall_xf(st["cell"], st["dir"])
		_root3.add_child(holder)
		_box(holder, Vector3(1.3, 0.85, 0.54), Vector3(0, 0.425, 0.27), desk)
		var top := _box(holder, Vector3(1.3, 0.06, 0.6), Vector3(0, 0.9, 0.3), _mat(Color(0.4, 0.45, 0.55), 0.0, 0.3, 0.6))
		top.rotation_degrees = Vector3(12, 0, 0)
		for kx in 4:
			_box(holder, Vector3(0.16, 0.04, 0.1), Vector3(-0.42 + 0.28 * kx, 0.96, 0.36), _glow(col.lerp(Color.WHITE, 0.3), 0.9 if kx % 2 == 0 else 0.5))
		_box(holder, Vector3(1.2, 0.74, 0.07), Vector3(0, 1.62, 0.05), desk)
		var screen := _box(holder, Vector3(1.08, 0.62, 0.04), Vector3(0, 1.62, 0.09), _glow(col, 0.55))
		_station_screens.append(screen)
		var name_l := _label(holder, String(st["name"]), Vector3(0, 1.62, 0.12), 30, Color.WHITE)
		name_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_l.width = 200.0
		var mark := _label(holder, "!", Vector3(0, 2.45, 0.3), 150, Color(1.0, 0.85, 0.1), true)
		mark.visible = false
		_station_marks.append(mark)

func _free_player_nodes() -> void:
	for old in _ps.values():
		for n in [(old as PS).node, (old as PS).ghost]:
			if n != null and is_instance_valid(n):
				(n as Node).queue_free()
	for n2 in _body_nodes.values():
		if is_instance_valid(n2):
			(n2 as Node).queue_free()
	_body_nodes.clear()

func _rebuild_player_nodes() -> void:
	if not _built:
		return
	for id in _order:
		var p: PS = _ps[id]
		for n in [p.node, p.ghost]:
			if n != null and is_instance_valid(n):
				(n as Node).queue_free()
		_build_player(p)

## Un tripulante: cuerpo de cápsula, visera, mochila y dos patitas. Mira hacia +Z.
func _build_bean(parent: Node3D, col: Color) -> Node3D:
	var b := Node3D.new()
	parent.add_child(b)
	_capsule(b, 0.36, 1.08, Vector3(0, 0.84, 0), _toon(col))
	_box(b, Vector3(0.44, 0.56, 0.22), Vector3(0, 0.8, -0.38), _toon(col.darkened(0.25)))
	var visor := _sphere(b, 0.24, Vector3(0, 1.04, 0.24), _mat(Color(0.62, 0.9, 1.0), 0.35, 0.15, 0.3))
	visor.scale = Vector3(1.15, 0.72, 0.62)
	return b

func _build_player(p: PS) -> void:
	var col := _color_of(p.id)
	p.node = Node3D.new()
	_root3.add_child(p.node)
	p.body = _build_bean(p.node, col)
	p.leg_l = Node3D.new()
	p.leg_l.position = Vector3(-0.17, 0.42, 0)
	p.body.add_child(p.leg_l)
	p.leg_r = Node3D.new()
	p.leg_r.position = Vector3(0.17, 0.42, 0)
	p.body.add_child(p.leg_r)
	var leg_mat := _toon(col.darkened(0.12))
	for leg in [p.leg_l, p.leg_r]:
		_capsule(leg, 0.15, 0.46, Vector3(0, -0.2, 0), leg_mat)
	var tag := _label(p.node, _name_of(p.id), Vector3(0, 1.72, 0), 46, col.lightened(0.25), true)
	tag.pixel_size = 0.0052
	# Fantasma (solo lo ven los eliminados): translúcido y flotando.
	p.ghost = Node3D.new()
	_root3.add_child(p.ghost)
	var gm := StandardMaterial3D.new()
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gm.albedo_color = Color(col.r, col.g, col.b, 0.4).lightened(0.3)
	gm.albedo_color.a = 0.4
	_capsule(p.ghost, 0.34, 1.0, Vector3(0, 1.0, 0), gm)
	var gv := gm.duplicate() as StandardMaterial3D
	gv.albedo_color = Color(0.8, 0.95, 1.0, 0.55)
	_sphere(p.ghost, 0.2, Vector3(0, 1.2, 0.22), gv).scale = Vector3(1.15, 0.72, 0.62)
	var gt := _label(p.ghost, _name_of(p.id), Vector3(0, 1.85, 0), 40, Color(1, 1, 1, 0.6), true)
	gt.pixel_size = 0.0052
	p.ghost.visible = false
	p.dpos = p.pos
	p.dk = p.kyaw
	p.dyaw = _yaw(p)

## Cadáver: medio cuerpo del color del jugador, con el hueso asomando.
func _build_body(id: int, pos: Vector2) -> Node3D:
	var col := _color_of(id)
	var n := Node3D.new()
	_root3.add_child(n)
	n.position = Vector3(pos.x, 0.0, pos.y)
	n.rotation.y = float(id) * 1.7
	_cyl(n, 0.36, 0.42, Vector3(0, 0.21, 0), _toon(col))
	_cyl(n, 0.3, 0.03, Vector3(0, 0.43, 0), _mat(Color(0.6, 0.05, 0.08), 0.0, 0.3))
	var white := _mat(Color(0.95, 0.95, 0.9), 0.2, 0.5)
	_cyl(n, 0.06, 0.34, Vector3(0, 0.6, 0), white)
	_sphere(n, 0.09, Vector3(-0.07, 0.78, 0), white)
	_sphere(n, 0.09, Vector3(0.07, 0.78, 0), white)
	_box(n, Vector3(0.44, 0.3, 0.22), Vector3(0, 0.18, -0.38), _toon(col.darkened(0.25)))
	_cyl(n, 0.62, 0.02, Vector3(0, 0.012, 0), _mat(Color(0.5, 0.04, 0.07), 0.0, 0.25))
	return n

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
	var v := _view()
	if v == null:
		return
	var k := 1.0 if delta <= 0.0 else 1.0 - exp(-24.0 * delta)
	var ghost_view := not v.alive
	for id in _order:
		var p: PS = _ps[id]
		if p.node == null:
			continue
		if p.dpos.distance_to(p.pos) > 4.0:
			p.dpos = p.pos
		else:
			p.dpos = p.dpos.lerp(p.pos, k)
		p.dk = lerp_angle(p.dk, p.kyaw, k)
		p.dyaw = lerp_angle(p.dyaw, _yaw(p), k)
		p.anim += delta
		var speed := p.vel.length()
		var mine := id == _view_id
		# Los demás no chocan entre sí: al cruzarse con uno, se oculta para no ver su interior.
		p.node.visible = p.alive and not mine and p.dpos.distance_to(v.dpos) > 0.6
		p.ghost.visible = not p.alive and ghost_view and not mine and _phase != Phase.END
		if p.alive:
			p.node.position = Vector3(p.dpos.x, 0.0, p.dpos.y)
			p.body.rotation.y = p.dyaw + PI
			var swing := clampf(speed / WALK, 0.0, 1.0)
			var ph := p.anim * 11.0
			p.leg_l.rotation.x = sin(ph) * 0.9 * swing
			p.leg_r.rotation.x = -sin(ph) * 0.9 * swing
			p.body.position.y = absf(sin(ph)) * 0.06 * swing
			p.body.rotation.z = sin(ph) * 0.05 * swing
		else:
			p.ghost.position = Vector3(p.dpos.x, 0.25 + 0.12 * sin(p.anim * 2.2), p.dpos.y)
			p.ghost.rotation.y = p.dyaw + PI
	# Cadáveres: aparecen y desaparecen según el estado.
	var present: Dictionary = {}
	for b in _bodies:
		var bid := int(b["id"])
		present[bid] = true
		if not _body_nodes.has(bid):
			_body_nodes[bid] = _build_body(bid, b["pos"])
	for bid2 in _body_nodes.keys():
		if not present.has(bid2):
			(_body_nodes[bid2] as Node).queue_free()
			_body_nodes.erase(bid2)
	# Avisos "!" sobre las consolas con tarea pendiente del jugador de este PC.
	for s in _station_marks.size():
		var mark := _station_marks[s]
		mark.visible = _pending(v, s) and _phase == Phase.PLAY
		if mark.visible:
			mark.position.y = 2.45 + 0.08 * sin(_anim * 4.0 + s)
	if _core != null:
		var pulse := 1.0 + 0.25 * sin(_anim * 3.0)
		(_core.material_override as StandardMaterial3D).albedo_color = Color(0.3 * pulse, 1.0 * pulse, 0.9 * pulse)
	if _button_top != null:
		var armed := _button_cd <= 0.0
		(_button_top.material_override as StandardMaterial3D).emission_energy_multiplier = (1.4 + 0.8 * sin(_anim * 5.0)) if armed else 0.15
	# Cámara en los ojos del jugador de este PC.
	var yaw := (v.dk + _local_myaw) if _use_look else v.dyaw
	var in_meeting := _phase == Phase.SPLASH or _phase == Phase.VOTE or _phase == Phase.REVEAL or _phase == Phase.EJECT
	if in_meeting:
		yaw = _seat_yaw(v.idx, _order.size())
		_pitch = lerpf(_pitch, -0.12, k * 0.3)
	var bob := 0.0
	if v.alive and _phase == Phase.PLAY:
		bob = sin(v.anim * 11.0) * 0.035 * clampf(v.vel.length() / WALK, 0.0, 1.0)
	var eye := EYE + bob if v.alive else EYE + 0.35 + 0.08 * sin(_anim * 2.2)
	_cam.position = Vector3(v.dpos.x, eye, v.dpos.y)
	_cam.rotation = Vector3(_pitch, yaw, 0.0)

# ----------------------------------------------------------------------------
# HUD (dibujo 2D encima del 3D)
# ----------------------------------------------------------------------------

func _txt(pos: Vector2, s: String, size: int, col: Color = Color.WHITE, outline: int = 5) -> void:
	var font := surface.get_theme_default_font()
	if outline > 0:
		surface.draw_string_outline(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, outline, Color(0.02, 0.03, 0.07, col.a))
	surface.draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)

func _ctxt(center: Vector2, s: String, size: int, col: Color = Color.WHITE, outline: int = 6) -> void:
	var font := surface.get_theme_default_font()
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	_txt(Vector2(center.x - w * 0.5, center.y + size * 0.35), s, size, col, outline)

func _full_rect(col: Color) -> void:
	surface.draw_rect(Rect2(-2400, -1400, 6080, 3520), col)

## Tripulante en 2D (iconos de la votación y la expulsión).
func _bean2d(center: Vector2, sc: float, col: Color, rot: float = 0.0, dead: bool = false) -> void:
	var s := surface
	s.draw_set_transform(center, rot, Vector2(sc, sc))
	var c := col.darkened(0.45) if dead else col
	s.draw_rect(Rect2(-27, -8, 12, 26), c.darkened(0.25))
	s.draw_circle(Vector2(0, -12), 18.0, c)
	s.draw_rect(Rect2(-18, -12, 36, 30), c)
	s.draw_rect(Rect2(-18, 16, 14, 12), c)
	s.draw_rect(Rect2(4, 16, 14, 12), c)
	s.draw_rect(Rect2(-2, -20, 24, 15), Color(0.2, 0.3, 0.4) if dead else Color(0.62, 0.9, 1.0))
	if dead:
		s.draw_line(Vector2(-22, -30), Vector2(22, 30), Color(1.0, 0.25, 0.2), 5.0)
		s.draw_line(Vector2(22, -30), Vector2(-22, 30), Color(1.0, 0.25, 0.2), 5.0)
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _check(pos: Vector2, size: float, col: Color) -> void:
	surface.draw_polyline(PackedVector2Array([pos + Vector2(-size, 0), pos + Vector2(-size * 0.3, size * 0.7), pos + Vector2(size, -size * 0.7)]), col, 4.0)

func _draw_hud() -> void:
	var v := _view()
	if v == null:
		return
	var s := surface
	if not is_running and _phase == Phase.INTRO:
		return                            # cuenta atrás del runner: solo se ve la nave
	match _phase:
		Phase.INTRO:
			_draw_play_hud(v)
			_draw_intro(v)
		Phase.PLAY:
			_draw_play_hud(v)
		Phase.SPLASH, Phase.VOTE, Phase.REVEAL:
			_draw_meeting(v)
		Phase.EJECT:
			_draw_eject()
		Phase.END:
			_draw_end(v)
	if _flash_red > 0.0:
		_full_rect(Color(0.9, 0.05, 0.05, 0.55 * _flash_red))
	if _toast_t > 0.0 and _phase == Phase.PLAY:
		_ctxt(Vector2(640, 250), _toast, 40, Color(1, 1, 1, clampf(_toast_t * 2.0, 0.0, 1.0)), 8)
	if demo and _phase == Phase.PLAY and not _use_look:
		s.rounded_rect(Rect2(330, 664, 620, 44), 12, Color(0, 0, 0, 0.6))
		_ctxt(Vector2(640, 686), "En la partida mirarás con el RATÓN. Aquí giras con A / D.", 22, Color(1, 1, 1, 0.9), 4)

func _draw_play_hud(v: PS) -> void:
	var s := surface
	if not v.alive:
		_full_rect(Color(0.25, 0.4, 0.7, 0.14))
	# Barra de tareas de toda la tripulación.
	s.rounded_rect(Rect2(20, 16, 340, 34), 10, Color(0.03, 0.05, 0.1, 0.85))
	var frac := clampf(float(_tasks_done) / float(_tasks_total), 0.0, 1.0)
	if frac > 0.0:
		s.rounded_rect(Rect2(24, 20, 332.0 * frac, 26), 8, Color(0.3, 0.9, 0.45))
	_txt(Vector2(34, 41), "TAREAS DE LA NAVE", 18, Color.WHITE, 4)
	# Lista de tareas propias.
	var y := 78.0
	var impostor := v.role == IMPOSTOR
	s.rounded_rect(Rect2(14, 58, 346, 30.0 + 25.0 * v.tasks.size()), 10, Color(0.03, 0.05, 0.1, 0.6))
	_txt(Vector2(24, y), "FINGE ESTAS TAREAS" if impostor else "TUS TAREAS", 18, Color(1.0, 0.4, 0.35) if impostor else Color(1.0, 0.85, 0.2), 4)
	for k in v.tasks.size():
		y += 25.0
		var st: Dictionary = STATIONS[v.tasks[k]]
		var done := (v.done_mask & (1 << k)) != 0
		var line := "%s: %s" % [String(ROOMS[st["room"]]["name"]), String(st["name"])]
		_txt(Vector2(44, y), line, 17, Color(0.55, 1.0, 0.6, 0.75) if done else Color.WHITE, 4)
		if done:
			_check(Vector2(32, y - 6), 6.0, Color(0.4, 1.0, 0.5))
		else:
			s.draw_circle(Vector2(32, y - 6), 4.0, Color(1.0, 0.85, 0.2))
	# Oxígeno.
	var left := ceili(_time_left)
	var cen := Vector2(1212, 44)
	s.draw_circle(cen, 34.0, Color(0.03, 0.05, 0.1, 0.9))
	s.draw_arc(cen, 30.0, -PI * 0.5, -PI * 0.5 + TAU * clampf(_time_left / OXYGEN, 0.0, 1.0), 48, Color(0.4, 0.85, 1.0) if left > 30 else Palette.CORAL, 6.0)
	_ctxt(cen, "%d:%02d" % [left / 60, left % 60], 22, Color.WHITE, 4)
	_ctxt(cen + Vector2(0, 46), "OXÍGENO", 14, Color(1, 1, 1, 0.8), 3)
	_draw_minimap(v, Vector2(1084, 108))
	# Sala actual.
	_txt(Vector2(24, 700), _room_name(_room_index(v.pos)).to_upper(), 24, Color(1, 1, 1, 0.9), 5)
	if not v.alive:
		_ctxt(Vector2(640, 40), "ERES UN FANTASMA" + ("" if impostor else " · termina tus tareas"), 24, Color(0.75, 0.9, 1.0), 5)
	# Punto de mira.
	s.draw_circle(Vector2(640, 360), 3.0, Color(1, 1, 1, 0.55))
	if _phase != Phase.PLAY:
		return
	# Misión en curso: su panel (cada tipo de misión se juega distinto).
	if v.cur_station >= 0:
		_draw_task(v)
	else:
		var prompt := ""
		var body := _find_body(v)
		var st2 := _find_station(v)
		if body >= 0:
			prompt = "ESPACIO / CLIC  ·  DENUNCIAR el cadáver de %s" % _name_of(body)
		elif _can_button(v):
			prompt = "ESPACIO / CLIC  ·  REUNIÓN DE EMERGENCIA"
		elif st2 >= 0 and (v.alive or not impostor):
			prompt = "ESPACIO / CLIC  ·  %s" % ("Fingir: " if impostor else "") + String(STATIONS[st2]["name"])
		elif v.alive and v.pos.distance_to(_table_pos()) <= BUTTON_RANGE:
			prompt = "Botón de emergencia: ya lo has usado" if v.meetings_left <= 0 else "Botón de emergencia: listo en %d s" % ceili(_button_cd)
		if prompt != "":
			var font := s.get_theme_default_font()
			var w := font.get_string_size(prompt, HORIZONTAL_ALIGNMENT_LEFT, -1, 24).x
			s.rounded_rect(Rect2(640 - w * 0.5 - 18, 566, w + 36, 44), 12, Color(0.03, 0.05, 0.1, 0.85))
			_ctxt(Vector2(640, 588), prompt, 24, Color(1.0, 0.9, 0.3), 4)
	# Botón del impostor.
	if impostor and v.alive:
		var kc := Vector2(1180, 630)
		var target := _find_victim(v, true)
		var armed := v.kill_cd <= 0.0
		s.draw_circle(kc, 58.0, Color(0.03, 0.05, 0.1, 0.85))
		s.draw_circle(kc, 50.0, Color(0.9, 0.15, 0.15, 1.0 if (armed and target != null) else 0.35))
		if armed:
			_ctxt(kc + Vector2(0, -6), "ELIMINAR", 18, Color.WHITE, 4)
			_ctxt(kc + Vector2(0, 16), "E / clic der.", 13, Color(1, 1, 1, 0.85), 3)
			if target != null:
				_ctxt(kc + Vector2(0, -78), "a %s" % _name_of(target.id), 20, _color_of(target.id).lightened(0.3), 4)
		else:
			_ctxt(kc, str(ceili(v.kill_cd)), 40, Color.WHITE, 6)

## Panel de la misión en curso, según su tipo.
func _draw_task(v: PS) -> void:
	var s := surface
	var st := v.cur_station
	var need := _needed(st)
	var green := Color(0.3, 0.9, 0.45)
	var dim := Color(0.2, 0.24, 0.32)
	s.rounded_rect(Rect2(390, 486, 500, 112), 14, Color(0.03, 0.05, 0.1, 0.9))
	_ctxt(Vector2(640, 506), String(STATIONS[st]["name"]).to_upper(), 20, Color.WHITE, 4)
	var bar := Rect2(420, 536, 440, 24)
	var hint := ""
	match _type(st):
		T_MARK:
			s.draw_rect(bar, Color(0.15, 0.18, 0.26))
			var z := _zone(v)
			s.draw_rect(Rect2(bar.position.x + (z - TASK_ZONE) * bar.size.x, bar.position.y, TASK_ZONE * 2.0 * bar.size.x, bar.size.y), green)
			var mx := bar.position.x + _marker(v) * bar.size.x
			s.draw_rect(Rect2(mx - 4, bar.position.y - 6, 8, bar.size.y + 12), Color(1.0, 0.3, 0.25) if v.task_lock > 0.25 else Color.WHITE)
			for h in need:
				s.draw_circle(Vector2(610 + 30 * h, 580), 8.0, green if h < v.task_hits else dim)
			hint = "ESPACIO / CLIC con el marcador en la zona verde"
		T_MASH:
			s.draw_rect(bar, Color(0.15, 0.18, 0.26))
			s.draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(float(v.task_hits) / float(need), 0.0, 1.0), bar.size.y)), Color(1.0, 0.75, 0.2))
			_ctxt(Vector2(640, 580), "%d / %d" % [mini(v.task_hits, need), need], 20, Color.WHITE, 4)
			hint = "¡Pulsa ESPACIO / CLIC muy rápido!"
		T_WAIT:
			s.draw_rect(bar, Color(0.15, 0.18, 0.26))
			s.draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(v.task_t / float(need), 0.0, 1.0), bar.size.y)), Color(0.4, 0.8, 1.0))
			_ctxt(Vector2(640, 580), "%d %%" % int(clampf(v.task_t / float(need), 0.0, 1.0) * 100.0), 20, Color.WHITE, 4)
			hint = "Espera sin alejarte de la consola…"
		T_ARROWS, T_MEMORY:
			var seq := _seq(v)
			var showing := _type(st) == T_ARROWS or v.task_t < MEMORY_SHOW
			var x0 := 640.0 - (need - 1) * 35.0
			for i in need:
				var c := Vector2(x0 + i * 70.0, 552)
				var done := i < v.task_hits
				s.rounded_rect(Rect2(c - Vector2(28, 28), Vector2(56, 56)), 10, Color(0.12, 0.3, 0.18) if done else Color(0.12, 0.15, 0.24))
				if done or showing:
					var col := green if done else Color.WHITE
					if not done and _type(st) == T_ARROWS and i == v.task_hits:
						col = Color(1.0, 0.3, 0.25) if v.task_lock > 0.25 else Color(1.0, 0.9, 0.3)
					_arrow(c, seq[i], 17.0, col)
				else:
					_ctxt(c, "?", 30, Color(1.0, 0.3, 0.25) if v.task_lock > 0.25 else Color(1, 1, 1, 0.6), 4)
			if _type(st) == T_ARROWS:
				hint = "Pulsa las flechas (WASD) en orden  ·  E cancela"
			elif showing:
				hint = "Memoriza la secuencia…"
			else:
				hint = "Repítela con las flechas (WASD)  ·  E cancela"
	_ctxt(Vector2(640, 620), hint, 18, Color(1, 1, 1, 0.9), 4)

## Flecha (0 arriba, 1 derecha, 2 abajo, 3 izquierda).
func _arrow(center: Vector2, dir: int, size: float, col: Color) -> void:
	var f := [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)][dir % 4] as Vector2
	var side := Vector2(-f.y, f.x)
	surface.draw_colored_polygon(PackedVector2Array([center + f * size, center + side * size * 0.9, center - side * size * 0.9]), col)
	surface.draw_line(center - f * size * 0.95, center + f * size * 0.1, col, size * 0.55)

func _draw_minimap(v: PS, origin: Vector2) -> void:
	var s := surface
	var cs := 7.0
	s.draw_rect(Rect2(origin - Vector2(6, 6), Vector2(GW * cs + 12, GH * cs + 12)), Color(0.02, 0.03, 0.07, 0.8))
	for y in GH:
		for x in GW:
			var ri := _room_of[y * GW + x]
			if ri == -2:
				continue
			var col := Color(0.45, 0.5, 0.58, 0.9)
			if ri >= 0:
				col = (ROOMS[ri]["color"] as Color).darkened(0.35)
				col.a = 0.9
			s.draw_rect(Rect2(origin + Vector2(x * cs, y * cs), Vector2(cs, cs)), col)
	var blink := 0.6 + 0.4 * sin(_anim * 6.0)
	for k in v.tasks.size():
		if (v.done_mask & (1 << k)) == 0:
			var c: Vector2i = STATIONS[v.tasks[k]]["cell"]
			s.draw_circle(origin + Vector2((c.x + 0.5) * cs, (c.y + 0.5) * cs), 4.0, Color(1.0, 0.85, 0.1, blink))
	var mp := origin + Vector2((v.dpos.x / CELL + GW * 0.5) * cs, (v.dpos.y / CELL + GH * 0.5) * cs)
	var yaw := (v.dk + _local_myaw) if _use_look else v.dyaw
	var f := Vector2(-sin(yaw), -cos(yaw))
	var side := Vector2(-f.y, f.x)
	s.draw_colored_polygon(PackedVector2Array([mp + f * 8.0, mp - f * 4.0 + side * 5.0, mp - f * 4.0 - side * 5.0]), Color.WHITE)

func _draw_intro(v: PS) -> void:
	var t := _phase_t
	var total := _intro_time()
	var a := clampf((total - t) / 0.6, 0.0, 1.0)
	_full_rect(Color(0, 0, 0, 0.93 * a))
	var impostor := v.role == IMPOSTOR
	var col := Color(1.0, 0.25, 0.22, a) if impostor else Color(0.4, 0.85, 1.0, a)
	var grow := 1.0 + 0.2 * clampf(1.0 - t / 0.4, 0.0, 1.0)
	_ctxt(Vector2(640, 250), "IMPOSTOR" if impostor else "TRIPULANTE", int(110.0 * grow), col, 14)
	var imps: Array[String] = []
	var n_imp := 0
	for id in _order:
		if (_ps[id] as PS).role == IMPOSTOR:
			n_imp += 1
			if id != v.id:
				imps.append(_name_of(id))
	var sub := ""
	if impostor:
		sub = "Elimina a la tripulación sin que te descubran"
		if not imps.is_empty():
			sub += "  ·  Tu cómplice: " + ", ".join(imps)
	else:
		sub = "Haz tus tareas y descubre al impostor" if n_imp == 1 else "Haz tus tareas. Hay %d impostores entre nosotros" % n_imp
	_ctxt(Vector2(640, 350), sub, 30, Color(1, 1, 1, a), 6)
	_bean2d(Vector2(640, 470), 1.8, _color_of(v.id) * Color(1, 1, 1, a))

func _draw_meeting(v: PS) -> void:
	var s := surface
	_full_rect(Color(0, 0, 0, 0.35))
	var title := "REUNIÓN DE EMERGENCIA" if _meet_victim < 0 else "¡CADÁVER ENCONTRADO!"
	var sub := "%s ha pulsado el botón" % _name_of(_meet_by)
	if _meet_victim >= 0:
		sub = "%s encontró a %s en %s" % [_name_of(_meet_by), _name_of(_meet_victim), _room_name(_meet_room)]
	if _phase == Phase.SPLASH:
		var g := clampf(_phase_t / 0.35, 0.0, 1.0)
		s.draw_rect(Rect2(-2400, 250, 6080, 220), Color(0.75, 0.08, 0.1, 0.92 * g))
		_ctxt(Vector2(640, 330), title, int(lerpf(110.0, 72.0, g)), Color.WHITE, 12)
		_ctxt(Vector2(640, 410), sub, 30, Color(1, 1, 1, g), 6)
		return
	var n := _order.size()
	var row_h := 46.0
	var panel := Rect2(260, 60, 760, 150.0 + row_h * (n + 1))
	s.rounded_rect(panel, 18, Color(0.04, 0.06, 0.12, 0.93))
	_ctxt(Vector2(640, 92), title, 34, Color(1.0, 0.35, 0.3), 6)
	_ctxt(Vector2(640, 128), sub, 20, Color(1, 1, 1, 0.9), 4)
	var reveal := _phase == Phase.REVEAL
	var opts := _options(v)
	var my_sel := opts[clampi(v.cursor, 0, opts.size() - 1)] if (v.alive and v.vote == NO_VOTE and not reveal) else -99
	var y := 158.0
	for i in n + 1:
		var id := _order[i] if i < n else SKIP
		var row := Rect2(panel.position.x + 24, y, panel.size.x - 48, row_h - 6)
		var p: PS = _ps[id] if id >= 0 else null
		var dead := p != null and not p.alive
		var bg := Color(0.1, 0.13, 0.2, 0.9)
		if id == my_sel:
			bg = Color(0.2, 0.42, 0.75, 0.95)
		elif v.vote == id and v.vote != NO_VOTE and v.alive:
			bg = Color(0.15, 0.4, 0.22, 0.95)
		if reveal and id == _ejected and id >= 0:
			bg = Color(0.6, 0.12, 0.12, 0.95)
		s.rounded_rect(row, 10, bg)
		if p != null:
			_bean2d(row.position + Vector2(28, 21), 0.55, _color_of(id), 0.0, dead)
			var nm := _name_of(id) + ("  (tú)" if id == v.id else "")
			_txt(row.position + Vector2(58, 27), nm, 22, Color(1, 1, 1, 0.4 if dead else 1.0), 4)
			if not dead and not reveal and p.vote != NO_VOTE:
				_txt(row.position + Vector2(row.size.x - 120, 27), "HA VOTADO", 15, Color(0.5, 1.0, 0.6), 3)
		else:
			_txt(row.position + Vector2(58, 27), "SALTAR VOTO", 22, Color(1, 1, 1, 0.9), 4)
		if reveal:
			# Quién ha votado a quién: una ficha del color de cada votante.
			var vx := row.position.x + 330.0
			for vid in _order:
				var q: PS = _ps[vid]
				if q.alive and q.vote == id:
					_bean2d(Vector2(vx, row.position.y + 21), 0.4, _color_of(vid))
					vx += 34.0
		y += row_h
	var foot := Vector2(640, y + 26)
	if reveal:
		_ctxt(foot, "Recuento de votos", 24, Color.WHITE, 5)
	elif not v.alive:
		_ctxt(foot, "Los fantasmas no votan  ·  %d s" % ceili(VOTE_TIME - _phase_t), 22, Color(0.75, 0.9, 1.0), 5)
	elif v.vote != NO_VOTE:
		_ctxt(foot, "Voto enviado. Esperando al resto…  %d s" % ceili(VOTE_TIME - _phase_t), 22, Color(0.6, 1.0, 0.7), 5)
	else:
		_ctxt(foot, "W / S eligen  ·  ESPACIO vota  ·  %d s" % ceili(VOTE_TIME - _phase_t), 22, Color(1.0, 0.9, 0.3), 5)

func _draw_eject() -> void:
	var s := surface
	_full_rect(Color(0.005, 0.008, 0.02))
	var r := RandomNumberGenerator.new()
	r.seed = 7
	for i in 140:
		var sx := fposmod(r.randf_range(-400.0, 1680.0) - _phase_t * r.randf_range(6.0, 40.0), 2080.0) - 400.0
		s.draw_circle(Vector2(sx, r.randf_range(-100.0, 820.0)), r.randf_range(0.8, 2.4), Color(1, 1, 1, r.randf_range(0.3, 1.0)))
	var text := "Nadie ha sido expulsado"
	if _ejected >= 0:
		var was := (_ps[_ejected] as PS).role == IMPOSTOR
		text = "%s %s" % [_name_of(_ejected), "era un impostor" if was else "no era un impostor"]
		var k := clampf(_phase_t / EJECT_TIME, 0.0, 1.0)
		_bean2d(Vector2(lerpf(-120.0, 1400.0, k), 330.0 + 40.0 * sin(k * 5.0)), 2.2, _color_of(_ejected), _phase_t * 2.4)
	var shown := text.substr(0, int(clampf((_phase_t - 0.5) * 22.0, 0.0, float(text.length()))))
	_ctxt(Vector2(640, 520), shown, 44, Color.WHITE, 8)
	if _phase_t > 2.2:
		var left := _alive_count(IMPOSTOR)
		_ctxt(Vector2(640, 580), "Queda %d impostor" % left if left == 1 else "Quedan %d impostores" % left, 26, Color(1, 1, 1, 0.8), 5)

func _draw_end(v: PS) -> void:
	var s := surface
	_full_rect(Color(0, 0, 0, 0.72 * clampf(_phase_t / 0.5, 0.0, 1.0)))
	var crew_won := _winner == CREW
	var won := v.role == _winner
	var col := Color(0.4, 0.85, 1.0) if crew_won else Color(1.0, 0.25, 0.22)
	_ctxt(Vector2(640, 96), "¡VICTORIA!" if won else "DERROTA", 86, col, 12)
	_ctxt(Vector2(640, 166), "Gana la tripulación" if crew_won else "Gana el impostor", 32, Color.WHITE, 6)
	_ctxt(Vector2(640, 204), REASONS[clampi(_reason, 0, REASONS.size() - 1)], 22, Color(1, 1, 1, 0.8), 4)
	_ctxt(Vector2(640, 236), "Ganadores: +%d puntos  ·  Perdedores: +1" % maxi(1, roundi(_order.size() * (0.75 if crew_won else 1.75))), 18, Color(1.0, 0.9, 0.3), 4)
	var rk := _ranking()
	var y := 258.0
	for i in rk.size():
		var p: PS = _ps.get(rk[i])
		if p == null:
			continue
		var row := Rect2(360, y, 560, 40)
		s.rounded_rect(row, 10, Color(0.45, 0.1, 0.12, 0.92) if p.role == IMPOSTOR else Color(0.08, 0.14, 0.24, 0.92))
		_bean2d(row.position + Vector2(26, 20), 0.5, _color_of(p.id), 0.0, not p.alive)
		_txt(row.position + Vector2(54, 27), _name_of(p.id) + ("  (tú)" if p.id == v.id else ""), 21, Color.WHITE, 4)
		_txt(row.position + Vector2(300, 27), "IMPOSTOR" if p.role == IMPOSTOR else "Tripulante", 17, Color(1.0, 0.55, 0.5) if p.role == IMPOSTOR else Color(0.7, 0.9, 1.0), 3)
		var detail := "%d eliminaciones" % p.kills if p.role == IMPOSTOR else "%d/%d tareas" % [TASKS_PER - _tasks_left(p), TASKS_PER]
		_txt(row.position + Vector2(420, 27), detail, 17, Color(1, 1, 1, 0.85), 3)
		y += 46.0

# ----------------------------------------------------------------------------
# Utilidades de depuración / pruebas (tests/impostor_test.gd)
# ----------------------------------------------------------------------------

func debug_player(id: int) -> Dictionary:
	var p: PS = _ps.get(id)
	if p == null:
		return {}
	return {"pos": p.pos, "role": p.role, "alive": p.alive, "score": p.score, "tasks": p.tasks, "done": p.done_mask,
			"left": _tasks_left(p), "station": p.cur_station, "hits": p.task_hits, "kill_cd": p.kill_cd, "vote": p.vote,
			"cursor": p.cursor, "yaw": _yaw(p), "meetings": p.meetings_left}

func debug_place(id: int, pos: Vector2, yaw: float = 0.0) -> void:
	var p: PS = _ps.get(id)
	if p != null:
		p.pos = pos
		p.vel = Vector2.ZERO
		p.kyaw = yaw
		p.myaw = 0.0

func debug_phase() -> int:
	return _phase

func debug_skip_intro() -> void:
	if _phase == Phase.INTRO:
		_set_phase(Phase.PLAY)

func debug_set_cd(id: int, kill_cd: float, button_cd: float = -1.0) -> void:
	(_ps[id] as PS).kill_cd = kill_cd
	if button_cd >= 0.0:
		_button_cd = button_cd

func debug_use(id: int) -> void:
	_do_use(_ps[id])

func debug_secondary(id: int) -> void:
	_do_secondary(_ps[id])

func debug_task_hit(id: int, ok: bool) -> void:
	var p: PS = _ps[id]
	p.task_lock = 0.0
	if ok:
		_task_advance(p, ceili(_needed(p.cur_station) / 3.0))
	else:
		_task_fail(p)

func debug_cast(id: int, target: int) -> void:
	_cast(_ps[id], target)

func debug_info() -> Dictionary:
	return {"phase": _phase, "bodies": _bodies.size(), "done": _tasks_done, "total": _tasks_total, "ejected": _ejected,
			"winner": _winner, "reason": _reason, "meetings": _meetings, "o2": _time_left, "by": _meet_by, "victim": _meet_victim}

func debug_seq(id: int) -> Array:
	return _seq(_ps[id])

func debug_station_of_type(id: int, type: int) -> int:
	for s in (_ps[id] as PS).tasks:
		if _type(s) == type:
			return s
	return -1

func debug_station_pos(s: int) -> Vector2:
	return _station_pos(s)

func debug_station_wall_ok(s: int) -> bool:
	_ensure_grid()
	var c: Vector2i = STATIONS[s]["cell"]
	return not _is_blocked(c) and _is_solid(c + (STATIONS[s]["dir"] as Vector2i)) and _room_of[c.y * GW + c.x] == int(STATIONS[s]["room"])

func debug_path_dist(a: Vector2, b: Vector2) -> int:
	_ensure_grid()
	return _path_dist(a, b)

func debug_los(a: Vector2, b: Vector2) -> bool:
	_ensure_grid()
	return _los(a, b)

func debug_collide(p: Vector2) -> Vector2:
	_ensure_grid()
	return _collide(p)

func debug_table_pos() -> Vector2:
	return _table_pos()

func debug_floor_cells() -> Array:
	_ensure_grid()
	var out: Array = []
	for y in GH:
		for x in GW:
			if not _is_blocked(Vector2i(x, y)):
				out.append(_center(Vector2i(x, y)))
	return out
