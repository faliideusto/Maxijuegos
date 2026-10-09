extends Minigame
## Carrera de Ruinas (id obstacle_run; modelo HOST_AUTHORITATIVE, 3D en tercera persona): un parkour de ruinas flotantes
## sobre la niebla. Todos corren A LA VEZ por el mismo recorrido (que sale de la semilla común) y se ven unos a otros; la
## cámara de cada PC va detrás de SU personaje. Gana quien llega antes a la meta; quien no llega se ordena por lo lejos que ha
## llegado. La partida acaba cuando llegan todos, 20 s después de que llegue el primero, o a los 90 s.
## Controles: WASD / flechas (o palanca) para moverte respecto a la cámara y ESPACIO o CLIC para saltar.
##
## El recorrido es una sucesión de ZONAS (cada una pide algo distinto):
##   SALIDA → PIEDRAS (pilares sueltos con huecos: saltos de precisión) → VIGA (pasarela estrecha con un hueco y una
##   esquina) → ESCALERAS (se suben corriendo) → PLATAFORMAS (losas que se deslizan de lado sobre el vacío) →
##   BARRA (una barra giratoria que hay que saltar o esquivar) → COLUMNAS (columnas cada vez más altas) → FINAL
##   (saltos largos hasta el arco de meta).
## Si caes a la niebla vuelves al último punto de control (el inicio de cada zona); caer cuesta tiempo, nada más.
##
## Física propia (nada de motor de físicas): un cuerpo con colisión contra cajas alineadas a los ejes, paso fijo de 60 Hz,
## subida automática de escalones, salto con "coyote time" y buffer, plataformas móviles que te arrastran y barras que
## te lanzan. Todo es determinista con la semilla, y una IA (bots, autopiloto y pruebas) sigue la ruta guardada.
## Red: el host simula a todos (60 Hz) y envía ~30 Hz el estado de cada corredor; los clientes interpolan. El 3D
## (SubViewport con su propio mundo) es solo presentación. La entrada se interpreta respecto a la cámara de cada jugador
## (su `yaw`, que sigue el recorrido y va en el estado), así que es igual en todos los PCs.

const STEP := 1.0 / 60.0
const TIME_LIMIT := 90.0
const COUNTDOWN := 3.0
const DONE_DELAY := 2.2
# --- Cuerpo ---
const RADIUS := 0.42
const HEIGHT := 1.7
const RUN_SPEED := 7.5
const GROUND_ACCEL := 70.0
const AIR_ACCEL := 26.0
const GRAVITY := 28.0
const JUMP_V := 9.6
const MAX_FALL := 30.0
const STEP_H := 0.55                    # se sube solo un escalón de hasta esta altura
const COYOTE := 0.10
const JUMP_BUFFER := 0.12
const FALL_Y := -11.0                   # por debajo de esta altura estás en la niebla: vuelves al punto de control
const RESPAWN_DELAY := 0.9
const BAR_KNOCK := 11.0
# --- Plataformas y estilos ---
enum Style { STONE, BEAM, COLUMN, GOAL }

class Solid:
	var c0: Vector3 = Vector3.ZERO      # centro (en reposo)
	var h: Vector3 = Vector3.ZERO       # semitamaño
	var c: Vector3 = Vector3.ZERO       # centro actual
	var pc: Vector3 = Vector3.ZERO      # centro en el paso anterior (para arrastrar)
	var move_dir: Vector3 = Vector3.ZERO
	var amp: float = 0.0
	var freq: float = 0.0
	var ph: float = 0.0
	var style: int = 0
	var node: Node3D = null

class Bar:
	var pivot: Vector3 = Vector3.ZERO
	var half_len: float = 5.4
	var omega: float = 1.15
	var ph: float = 0.0
	var top: float = 0.8
	var node: Node3D = null

var _solids: Array[Solid] = []
var _bars: Array[Bar] = []
var _path: Array[Vector3] = []          # línea central del recorrido (progreso, cámara y minimapa)
var _cum: PackedFloat32Array = PackedFloat32Array()
var _route: Array = []                  # Dictionary: p (Vector3), mover (índice de losa móvil o -1), zone
var _cps: Array = []                    # Dictionary: pos, route_i, arc
var _zones: Array = []                  # Dictionary: name, arc
var _goal: Vector3 = Vector3.ZERO
var _total: float = 1.0
var _level_ready: bool = false
# Cursor del generador (marco local de la zona actual).
var _o: Vector3 = Vector3.ZERO
var _th: float = 0.0
var _grng: RandomNumberGenerator

# --- Estado de la carrera ---
## Un corredor: lo simula el host y los clientes lo reciben (se interpola solo la presentación).
class RS:
	var id: int = 0
	var idx: int = 0
	var p: Vector3 = Vector3.ZERO           # pies
	var v: Vector3 = Vector3.ZERO
	var grounded: bool = false
	var gs: int = -1                        # losa sobre la que está
	var yaw: float = 0.0                    # dirección de su cámara (el movimiento es relativo a ella)
	var face: float = 0.0                   # hacia dónde mira el personaje
	var jump_buf: float = 0.0
	var coyote: float = 0.0
	var jump_pending: bool = false          # pulsación aún sin aplicar (en pantallas rápidas hay fotogramas sin paso de 60 Hz)
	var stun: float = 0.0
	var respawn_t: float = -1.0
	var cp_i: int = 0
	var falls: int = 0
	var seg: int = 0
	var arc: float = 0.0
	var zone_i: int = 0
	var done: bool = false                  # ya no corre (meta o fin de la partida)
	var finished: bool = false              # ha llegado a la meta
	var ftime: float = 0.0
	# Eventos de este paso (los recoge quien simula).
	var ev_jump: bool = false
	var ev_land: bool = false
	var ev_fall: bool = false
	var ev_bar: bool = false
	var ev_cp: bool = false
	var ev_zone: bool = false
	var ev_fin: bool = false
	# IA
	var skill: float = 1.0
	var lane: float = 0.0                   # carril preferido de la IA (reparte a los corredores por las losas anchas)
	var bi: int = 0
	var bot_jump: bool = false
	var bot_rng: RandomNumberGenerator = null
	# Presentación
	var dp: Vector3 = Vector3.ZERO
	var dyaw: float = 0.0
	var dface: float = 0.0
	var anim: float = 0.0
	var node: Node3D = null
	var body: Node3D = null
	var arm_l: Node3D = null
	var arm_r: Node3D = null
	var leg_l: Node3D = null
	var leg_r: Node3D = null
	var cape: Node3D = null
	var shadow: MeshInstance3D = null
	var dust: CPUParticles3D = null
	var puff: CPUParticles3D = null
	var burst: bool = false
	var burst_fall: bool = false

const FLOATS := 18                      # por corredor en el estado enviado
const CATCH_UP := 0.10                  # empujón máximo de velocidad (fracción) para los rezagados
const CATCH_DIST := 60.0
const FIRST_FINISH_GRACE := 20.0        # segundos que se espera a los demás cuando llega el primero

var _rs: Dictionary = {}                # player id -> RS
var _order: Array[int] = []             # ids en el orden del reparto (= orden del estado enviado)
var _t: float = 0.0                     # segundos de carrera (iguales para todos: mueven las losas y la barra)
var _t_vis: float = 0.0                 # lo mismo, suavizado en los clientes
var _cd: float = COUNTDOWN
var _last_cd: int = 99
var _accum: float = 0.0
var _over: bool = false
var _over_t: float = 0.0
var _first_finish_t: float = -1.0
var _finish_order: Array[int] = []
var _winner_id: int = -1
var _toast: String = ""
var _toast_t: float = 0.0
var _hint_t: float = 7.0
var _shake: float = 0.0
var _anim: float = 0.0

# --- IA ---
var debug_skill: float = -1.0           # >= 0: fuerza la habilidad de todas las IAs (pruebas)

# --- Escena 3D ---
var _vp: SubViewport
var _root3: Node3D
var _cam: Camera3D
var _built: bool = false
var _fov: float = 68.0
var _cam_pos: Vector3 = Vector3.ZERO
var _sun: DirectionalLight3D
var _cloud_mats: Array[StandardMaterial3D] = []
var _debris: Array = []
var _cp_nodes: Array = []
var _motes: CPUParticles3D

# ----------------------------------------------------------------------------
# Generador del recorrido
# ----------------------------------------------------------------------------

func _fwd(th: float) -> Vector3:
	return Vector3(sin(th), 0.0, cos(th))

func _rgt(th: float) -> Vector3:
	return Vector3(-cos(th), 0.0, sin(th))

## Punto local (x derecha, y arriba, z adelante) → mundo, según el cursor del generador.
func _lp(l: Vector3) -> Vector3:
	return _o + _rgt(_th) * l.x + Vector3.UP * l.y + _fwd(_th) * l.z

func _add_solid(lc: Vector3, lh: Vector3, style: int = Style.STONE) -> int:
	var f := _fwd(_th)
	var r := _rgt(_th)
	var s := Solid.new()
	s.h = Vector3(absf(r.x) * lh.x + absf(f.x) * lh.z, lh.y, absf(r.z) * lh.x + absf(f.z) * lh.z)
	s.c0 = _lp(lc)
	s.c = s.c0
	s.pc = s.c0
	s.style = style
	_solids.append(s)
	return _solids.size() - 1

## Losa con la cara superior a altura `top` (local), centro (lx, lz) y semitamaños.
func _slab(lx: float, top: float, lz: float, hx: float, hz: float, thick: float = 1.0, style: int = Style.STONE) -> int:
	var hy := thick * 0.5
	return _add_solid(Vector3(lx, top - hy, lz), Vector3(hx, hy, hz), style)

func _node(l: Vector3, mover: int = -1) -> void:
	var wp := _lp(l)
	var rg := _rgt(_th)
	# Semianchura (en lateral) de la losa donde está el punto: la IA reparte a los corredores por ella.
	var hw := 0.8
	var idx := mover
	if idx < 0:
		for i in range(_solids.size() - 1, -1, -1):
			var s := _solids[i]
			if absf(wp.x - s.c0.x) <= s.h.x + 0.01 and absf(wp.z - s.c0.z) <= s.h.z + 0.01 and absf(wp.y - (s.c0.y + s.h.y)) < 1.2:
				idx = i
				break
	if idx >= 0:
		var sd := _solids[idx]
		hw = absf(rg.x) * sd.h.x + absf(rg.z) * sd.h.z
	_route.append({"p": wp, "mover": mover, "zone": _zones.size() - 1, "rgt": rg, "hw": hw})

func _zone(zname: String, l_start: Vector3 = Vector3.ZERO) -> void:
	_zones.append({"name": zname, "arc": 0.0, "pt": _path.size()})
	_path.append(_lp(l_start))

func _pt(l: Vector3) -> void:
	_path.append(_lp(l))

func _checkpoint(l: Vector3) -> void:
	_cps.append({"pos": _lp(l), "route_i": _route.size(), "path_i": _path.size()})

func _advance(l: Vector3) -> void:
	_o = _lp(l)

func _ensure_level() -> void:
	if _level_ready:
		return
	_level_ready = true
	_grng = RandomNumberGenerator.new()
	_grng.seed = seed_value
	var rng := _grng
	_o = Vector3.ZERO
	_th = 0.0
	# --- SALIDA ---
	_zone("SALIDA")
	_slab(0.0, 0.0, 7.0, 5.5, 7.0, 1.2)
	_checkpoint(Vector3(0, 0, 3))
	_node(Vector3(0, 0, 3))
	_pt(Vector3(0, 0, 14))
	_advance(Vector3(0, 0, 14))
	# --- PIEDRAS: pilares sueltos con huecos (saltos de precisión) ---
	_zone("PIEDRAS")
	var z := 0.0
	var y := 0.0
	var lx_prev := 0.0
	for i in 7:
		var gap := rng.randf_range(1.7 + 0.08 * i, 2.7 + 0.12 * i)
		var lx := clampf(lx_prev + rng.randf_range(-2.6, 2.6), -3.2, 3.2)
		y = clampf(y + rng.randf_range(-0.45, 0.45), -1.5, 1.2)
		z += gap + 1.3
		_slab(lx, y, z, 1.3, 1.3, 1.0)
		_node(Vector3(lx, y, z))
		z += 1.3
		lx_prev = lx
	_pt(Vector3(0, y, z))
	_advance(Vector3(0, y, z + rng.randf_range(2.0, 2.6)))
	_slab(0.0, 0.0, 4.0, 4.0, 4.0, 1.2)
	_checkpoint(Vector3(0, 0, 2))
	_node(Vector3(0, 0, 4.0))
	_pt(Vector3(0, 0, 8))
	_advance(Vector3(0, 0, 8))
	# --- VIGA: pasarela estrecha con un hueco y una esquina ---
	_zone("VIGA")
	_slab(0.0, 0.0, 4.4, 0.75, 4.4, 0.5, Style.BEAM)       # z 0..8.8 (la pasarela empieza pegada al descansillo)
	_node(Vector3(0, 0, 8.0))
	var gap_b := rng.randf_range(2.4, 3.0)
	var z2 := 8.8 + gap_b
	_slab(0.0, 0.0, z2 + 4.2, 0.75, 4.2, 0.5, Style.BEAM)  # segunda mitad
	_node(Vector3(0, 0, z2 + 3.0))
	var zc := z2 + 8.4
	_slab(0.0, 0.0, zc + 2.5, 2.5, 2.5, 1.0)               # esquina
	_checkpoint(Vector3(0, 0, zc + 2.5))
	_node(Vector3(0, 0, zc + 2.5))
	_pt(Vector3(0, 0, zc + 2.5))
	_advance(Vector3(0, 0, zc + 2.5))
	_th -= PI * 0.5                                         # giro a la derecha
	_advance(Vector3(0, 0, 2.5))
	# --- ESCALERAS ---
	_zone("ESCALERAS")
	var rise := 0.42
	var steps := 12
	for i in steps:
		var top := (i + 1) * rise
		_add_solid(Vector3(0, top - 0.3, 0.45 + 0.9 * i), Vector3(3.0, 0.3, 0.45))
		if i % 4 == 3:
			_node(Vector3(0, top, 0.45 + 0.9 * i))
	var sz := steps * 0.9
	var st := steps * rise
	_slab(0.0, st, sz + 4.0, 4.0, 4.0, 1.2)
	_checkpoint(Vector3(0, st, sz + 2.0))
	_node(Vector3(0, st, sz + 4.0))
	_pt(Vector3(0, st, sz + 8.0))
	_advance(Vector3(0, st, sz + 8.0))
	# --- PLATAFORMAS: losas que se deslizan de lado sobre el vacío ---
	_zone("PLATAFORMAS")
	var phase := rng.randf_range(0.0, TAU)
	for i in 3:
		var mz := 2.9 + 7.0 * i
		var idx := _add_solid(Vector3(0, -0.25, mz), Vector3(1.7, 0.25, 1.7))
		var m := _solids[idx]
		m.move_dir = _rgt(_th)
		m.amp = 3.0
		m.freq = 0.9 + 0.1 * i
		m.ph = phase + 0.55 * i
		_node(Vector3(0, 0, mz), idx)
	var mend := 2.9 + 14.0 + 1.7
	_slab(0.0, 0.0, mend + 3.6 + 3.0, 4.0, 3.0, 1.2)
	_checkpoint(Vector3(0, 0, mend + 3.6 + 2.0))
	_node(Vector3(0, 0, mend + 3.6 + 3.0))
	_pt(Vector3(0, 0, mend + 3.6 + 6.0))
	_advance(Vector3(0, 0, mend + 3.6 + 6.0))
	_th += PI * 0.5                                         # giro a la izquierda
	# --- BARRA GIRATORIA ---
	_zone("BARRA")
	_slab(0.0, 0.0, 7.0, 6.0, 7.0, 1.2)
	_checkpoint(Vector3(0, 0, 2))
	_node(Vector3(0, 0, 2))
	var bar := Bar.new()
	bar.pivot = _lp(Vector3(0, 0, 7.0))
	bar.omega = 1.15 * (1.0 if rng.randf() < 0.5 else -1.0)
	bar.ph = rng.randf_range(0.0, TAU)
	_bars.append(bar)
	_node(Vector3(0, 0, 12.5))                              # (la ruta no se para en el centro: ahí la barra pasa siempre)
	_pt(Vector3(0, 0, 14))
	_advance(Vector3(0, 0, 14))
	# --- COLUMNAS: cada vez más altas ---
	_zone("COLUMNAS")
	z = 0.0
	y = 0.0
	for i in 7:
		var gap2 := rng.randf_range(1.9, 2.6 + 0.1 * i)
		var lx2 := (1.6 if i % 2 == 0 else -1.6) * rng.randf_range(0.5, 1.0)
		y += rng.randf_range(0.2, 0.55)
		z += gap2 + 1.0
		_add_solid(Vector3(lx2, y - 3.0, z), Vector3(1.0, 3.0, 1.0), Style.COLUMN)
		_node(Vector3(lx2, y, z))
		z += 1.0
	_pt(Vector3(0, y, z))
	_advance(Vector3(0, y, z + rng.randf_range(2.0, 2.6)))
	_slab(0.0, 0.0, 4.0, 4.0, 4.0, 1.2)
	_checkpoint(Vector3(0, 0, 2))
	_node(Vector3(0, 0, 4.0))
	_pt(Vector3(0, 0, 8))
	_advance(Vector3(0, 0, 8))
	# --- FINAL: saltos largos hasta el arco de meta ---
	_zone("FINAL")
	z = 0.0
	y = 0.0
	lx_prev = 0.0
	for i in 4:
		var gap3 := rng.randf_range(3.0, 3.9)
		var lx3 := clampf(lx_prev + (2.0 if i % 2 == 0 else -2.0) * rng.randf_range(0.6, 1.0), -3.0, 3.0)
		y = clampf(y + rng.randf_range(-0.3, 0.45), -1.0, 1.2)
		z += gap3 + 1.5
		_slab(lx3, y, z, 1.5, 1.5, 1.0)
		_node(Vector3(lx3, y, z))
		z += 1.5
		lx_prev = lx3
	_pt(Vector3(0, y, z))
	var gap4 := rng.randf_range(2.8, 3.4)
	_advance(Vector3(0, y, z + gap4))
	_slab(0.0, 0.0, 5.0, 5.0, 5.0, 1.4, Style.GOAL)
	_checkpoint(Vector3(0, 0, 2))
	_node(Vector3(0, 0, 5.0))
	_goal = _lp(Vector3(0, 0, 6.0))
	_pt(Vector3(0, 0, 6.0))
	_finish_path()

func _finish_path() -> void:
	_cum = PackedFloat32Array([0.0])
	for i in range(1, _path.size()):
		_cum.append(_cum[i - 1] + (_path[i] - _path[i - 1]).length())
	_total = maxf(_cum[_cum.size() - 1], 1.0)
	for zn in _zones:
		zn["arc"] = _cum[mini(int(zn["pt"]), _cum.size() - 1)]
	for cp in _cps:
		cp["arc"] = _cum[mini(int(cp["path_i"]), _cum.size() - 1)]

# ----------------------------------------------------------------------------
# Simulación
# ----------------------------------------------------------------------------

func _make_rs(p: PlayerData, idx: int, count: int) -> RS:
	var s := RS.new()
	s.id = p.id
	s.idx = idx
	var lx := 0.0 if count <= 1 else lerpf(-3.6, 3.6, float(idx) / float(count - 1))
	var start: Vector3 = (_cps[0]["pos"] as Vector3)
	s.p = start + _rgt(0.0) * lx
	s.dp = s.p
	s.bot_rng = RandomNumberGenerator.new()
	s.bot_rng.seed = hash([seed_value, p.id])
	s.skill = 0.78 + 0.22 * s.bot_rng.randf()
	s.lane = clampf((float(idx) - float(count - 1) * 0.5) * 1.15, -2.8, 2.8)
	s.yaw = _path_yaw(s)
	s.dyaw = s.yaw
	s.face = s.yaw
	s.dface = s.yaw
	return s

func _setup_runners() -> void:
	for old in _rs.values():
		for n in [(old as RS).node, (old as RS).shadow, (old as RS).dust, (old as RS).puff]:
			if n != null and is_instance_valid(n):
				(n as Node).queue_free()
	_rs.clear()
	_order.clear()
	for i in players.size():
		var pl := players[i]
		_rs[pl.id] = _make_rs(pl, i, players.size())
		_order.append(pl.id)
	_t = 0.0
	_t_vis = 0.0
	_update_solids(true)

func _update_solids(snap: bool = false) -> void:
	for s in _solids:
		s.pc = s.c
		if s.amp != 0.0:
			s.c = s.c0 + s.move_dir * (s.amp * sin(s.ph + s.freq * _t))
		if snap:
			s.pc = s.c

func _leader_arc() -> float:
	var m := 0.0
	for id in _order:
		m = maxf(m, (_rs[id] as RS).arc)
	return m

func _bar_angle(b: Bar, t: float) -> float:
	return b.ph + b.omega * t

## Distancia (en el suelo) del punto al segmento de la barra en el instante t.
func _bar_dist(b: Bar, t: float, q: Vector3) -> float:
	var a := _bar_angle(b, t)
	var d := Vector3(cos(a), 0.0, sin(a))
	var rel := Vector3(q.x - b.pivot.x, 0.0, q.z - b.pivot.z)
	var along := clampf(rel.dot(d), -b.half_len, b.half_len)
	return (rel - d * along).length()

func _overlap_y(s: Solid, py: float) -> bool:
	return py < s.c.y + s.h.y - 0.001 and py + HEIGHT > s.c.y - s.h.y + 0.001

## Resuelve los choques laterales en un eje (0 = x, 1 = z); sube solo los escalones bajos.
func _resolve_axis(r: RS, axis: int) -> void:
	for s in _solids:
		if absf(r.p.x - s.c.x) > s.h.x + RADIUS or absf(r.p.z - s.c.z) > s.h.z + RADIUS:
			continue
		if not _overlap_y(s, r.p.y):
			continue
		var top := s.c.y + s.h.y
		if top - r.p.y <= STEP_H and r.v.y <= 1.0:
			r.p.y = top + 0.001                          # escalón: se sube
			continue
		if axis == 0:
			r.p.x = s.c.x + (s.h.x + RADIUS if r.p.x > s.c.x else -(s.h.x + RADIUS))
			r.v.x = 0.0
		else:
			r.p.z = s.c.z + (s.h.z + RADIUS if r.p.z > s.c.z else -(s.h.z + RADIUS))
			r.v.z = 0.0

## Un paso de simulación de un corredor. dir = dirección de movimiento deseada en el mundo (longitud <= 1).
func _sim_step(r: RS, dt: float, dir: Vector3, jump: bool, leader_arc: float) -> void:
	# (las losas ya se han movido en este paso: _update_solids)
	if r.gs >= 0:
		var gsolid := _solids[r.gs]
		r.p += gsolid.c - gsolid.pc                      # las losas móviles te arrastran
	if r.respawn_t >= 0.0:
		r.respawn_t -= dt
		if r.respawn_t < 0.0:
			_respawn(r)
		return
	# Velocidad horizontal (quien va muy rezagado corre algo más para no perderse la carrera).
	var boost := 1.0 + CATCH_UP * clampf((leader_arc - r.arc) / CATCH_DIST, 0.0, 1.0)
	var want := dir * RUN_SPEED * boost
	var acc := GROUND_ACCEL if r.grounded else AIR_ACCEL
	if r.done:
		want = Vector3.ZERO
	if r.stun > 0.0:
		r.stun = maxf(0.0, r.stun - dt)
		want = Vector3(r.v.x, 0.0, r.v.z)
		acc = 4.0
	r.v.x = move_toward(r.v.x, want.x, acc * dt)
	r.v.z = move_toward(r.v.z, want.z, acc * dt)
	# Salto.
	if jump:
		r.jump_buf = JUMP_BUFFER
	r.jump_buf = maxf(0.0, r.jump_buf - dt)
	if r.grounded:
		r.coyote = COYOTE
	else:
		r.coyote = maxf(0.0, r.coyote - dt)
	if r.jump_buf > 0.0 and r.coyote > 0.0 and not r.done and r.stun <= 0.0:
		r.v.y = JUMP_V
		r.grounded = false
		r.gs = -1
		r.coyote = 0.0
		r.jump_buf = 0.0
		r.ev_jump = true
	r.v.y = maxf(r.v.y - GRAVITY * dt, -MAX_FALL)
	# Movimiento por ejes.
	r.p.x += r.v.x * dt
	_resolve_axis(r, 0)
	r.p.z += r.v.z * dt
	_resolve_axis(r, 1)
	var prev_y := r.p.y
	r.p.y += r.v.y * dt
	var was_grounded := r.grounded
	r.grounded = false
	r.gs = -1
	var best_top := -1e9
	for i in _solids.size():
		var s := _solids[i]
		if absf(r.p.x - s.c.x) >= s.h.x + RADIUS or absf(r.p.z - s.c.z) >= s.h.z + RADIUS:
			continue
		var top := s.c.y + s.h.y
		var bottom := s.c.y - s.h.y
		if r.v.y <= 0.0:
			if prev_y >= top - 0.12 and r.p.y <= top and top > best_top:
				best_top = top
				r.gs = i
		else:
			if prev_y + HEIGHT <= bottom + 0.1 and r.p.y + HEIGHT > bottom:
				r.p.y = bottom - HEIGHT
				r.v.y = 0.0
	if r.gs >= 0:
		r.p.y = best_top
		r.v.y = 0.0
		r.grounded = true
		if not was_grounded:
			r.ev_land = true
	# Barras giratorias.
	for b in _bars:
		if r.p.y < b.pivot.y + b.top and r.p.y + HEIGHT > b.pivot.y - 0.2:
			if absf(r.p.x - b.pivot.x) < b.half_len + 1.0 and absf(r.p.z - b.pivot.z) < b.half_len + 1.0:
				if _bar_dist(b, _t, r.p) < RADIUS + 0.22 and r.stun <= 0.0:
					var a := _bar_angle(b, _t)
					var tang := Vector3(-sin(a), 0.0, cos(a)) * signf(b.omega)
					r.v.x = tang.x * BAR_KNOCK
					r.v.z = tang.z * BAR_KNOCK
					r.v.y = 5.0
					r.grounded = false
					r.gs = -1
					r.stun = 0.45
					r.ev_bar = true
	# Niebla: caída.
	if r.p.y < FALL_Y and r.respawn_t < 0.0 and not r.done:
		r.falls += 1
		r.respawn_t = RESPAWN_DELAY
		r.ev_fall = true
	# Progreso, puntos de control y meta.
	_track_progress(r)
	if not r.done:
		var gd := Vector2(r.p.x - _goal.x, r.p.z - _goal.z).length()
		if gd < 3.2 and absf(r.p.y - _goal.y) < 2.5:
			r.done = true
			r.finished = true
			r.ftime = _t
			r.ev_fin = true

func _respawn(r: RS) -> void:
	var cp: Dictionary = _cps[r.cp_i]
	r.p = (cp["pos"] as Vector3) + _rgt(_path_yaw_at(int(cp["path_i"]))) * (float(r.idx % 5) - 2.0) * 0.8
	r.v = Vector3.ZERO
	r.grounded = false
	r.gs = -1
	r.stun = 0.0
	r.bi = int(cp["route_i"])
	r.seg = maxi(int(cp["path_i"]) - 1, 0)
	r.yaw = _path_yaw(r)
	r.dp = r.p

## Posición sobre la línea central → progreso (m); también la zona y el punto de control actuales.
func _track_progress(r: RS) -> void:
	var best_d := 1e9
	var best_i := r.seg
	var best_t := 0.0
	var lo := maxi(r.seg - 1, 0)
	var hi := mini(r.seg + 3, _path.size() - 2)
	for i in range(lo, hi + 1):
		var a := _path[i]
		var b := _path[i + 1]
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var l2 := ab.length_squared()
		var tt := 0.0
		if l2 > 0.0001:
			tt = clampf(Vector2(r.p.x - a.x, r.p.z - a.z).dot(ab) / l2, 0.0, 1.0)
		var qx := a.x + ab.x * tt
		var qz := a.z + ab.y * tt
		var d := Vector2(r.p.x - qx, r.p.z - qz).length()
		if d < best_d:
			best_d = d
			best_i = i
			best_t = tt
	r.seg = best_i
	var arc := _cum[best_i] + best_t * (_cum[best_i + 1] - _cum[best_i])
	if arc > r.arc and r.respawn_t < 0.0:
		r.arc = arc
	# Zona.
	while r.zone_i + 1 < _zones.size() and r.arc >= float(_zones[r.zone_i + 1]["arc"]):
		r.zone_i += 1
		r.ev_zone = true
	# Punto de control (al pisar el inicio de la zona).
	while r.cp_i + 1 < _cps.size() and r.grounded:
		var nxt: Dictionary = _cps[r.cp_i + 1]
		var npos: Vector3 = nxt["pos"]
		if Vector2(r.p.x - npos.x, r.p.z - npos.z).length() < 3.2 and absf(r.p.y - npos.y) < 2.0:
			r.cp_i += 1
			r.ev_cp = true
		else:
			break

func _path_yaw_at(seg: int) -> float:
	var i := clampi(seg, 0, _path.size() - 2)
	var d := _path[i + 1] - _path[i]
	d.y = 0.0
	if d.length() < 0.01:
		return 0.0
	return atan2(d.x, d.z)

func _path_yaw(r: RS) -> float:
	var i := clampi(r.seg, 0, _path.size() - 2)
	var d := _path[i + 1] - _path[i]
	d.y = 0.0
	if d.length() < 0.01:
		return r.yaw
	return atan2(d.x, d.z)

## ¿Suena lo de este corredor en este PC?
func _mine(r: RS) -> bool:
	var pl := _player_by_id(r.id)
	return pl != null and is_audible(pl)

func _player_by_id(id: int) -> PlayerData:
	for pl in players:
		if pl.id == id:
			return pl
	return null

# ----------------------------------------------------------------------------
# Ciclo del minijuego (el host simula a todos)
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
	_accum = 0.0
	_cd = COUNTDOWN
	_last_cd = 99
	_over = false
	_over_t = 0.0
	_first_finish_t = -1.0
	_finish_order.clear()
	_winner_id = -1
	_hint_t = 7.0
	_toast = ""
	_toast_t = 0.0
	var cs := _cam_runner()
	if cs != null:
		_cam_pos = cs.p - _fwd(cs.yaw) * 5.0 + Vector3(0, 3.0, 0)

func _simulate(delta: float) -> void:
	if _over:
		_over_t += delta
		if _over_t >= DONE_DELAY:
			finish(_ranking_ids())
		else:
			_t += delta
			_update_solids()
			var la := _leader_arc()
			for id in _order:
				_sim_step(_rs[id] as RS, delta, Vector3.ZERO, false, la)
				_collect_events(_rs[id] as RS)
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
	# Entrada de cada jugador (una lectura por fotograma). El movimiento es relativo a la cámara de cada uno.
	var dirs: Dictionary = {}
	for pl in players:
		var r: RS = _rs[pl.id]
		r.yaw = lerp_angle(r.yaw, _path_yaw(r), 1.0 - exp(-2.2 * delta))
		var inp := move_input(pl)
		if action_presses(pl) > 0:
			r.jump_pending = true
		var d := _rgt(r.yaw) * inp.x + _fwd(r.yaw) * (-inp.y)
		if d.length() > 1.0:
			d = d.normalized()
		dirs[pl.id] = d
		if d.length() > 0.2 and not r.done:
			r.face = lerp_angle(r.face, atan2(d.x, d.z), 1.0 - exp(-14.0 * delta))
	_accum += delta
	var steps := 0
	while _accum >= STEP and steps < 12:
		_accum -= STEP
		steps += 1
		_t += STEP
		_update_solids()
		var la2 := _leader_arc()
		for pl in players:
			var r2: RS = _rs[pl.id]
			_sim_step(r2, STEP, dirs[pl.id] as Vector3, r2.jump_pending, la2)
			r2.jump_pending = false
			_collect_events(r2)
	# ¿Se acaba?
	var all_done := true
	for id in _order:
		if not (_rs[id] as RS).done:
			all_done = false
	if _first_finish_t < 0.0 and not _finish_order.is_empty():
		_first_finish_t = _t
	var grace_over := _first_finish_t >= 0.0 and _t - _first_finish_t >= FIRST_FINISH_GRACE
	if all_done or grace_over or _t >= TIME_LIMIT:
		_over = true
		_over_t = 0.0
		for id in _order:
			(_rs[id] as RS).done = true
		_winner_id = _finish_order[0] if not _finish_order.is_empty() else _best_by_distance()
		send_event("over", {"w": _winner_id})
		DevCli.log_event("ruins over winner=%d finished=%d" % [_winner_id, _finish_order.size()])

func _best_by_distance() -> int:
	var best := -1
	var ba := -1.0
	for id in _order:
		var r: RS = _rs[id]
		if r.arc > ba:
			ba = r.arc
			best = id
	return best

func _collect_events(r: RS) -> void:
	if r.ev_jump:
		send_event("jump", {"p": r.id})
	if r.ev_land:
		send_event("land", {"p": r.id})
	if r.ev_fall:
		send_event("fall", {"p": r.id})
	if r.ev_bar:
		send_event("bar", {"p": r.id})
	if r.ev_cp:
		send_event("cp", {"p": r.id, "i": r.cp_i})
	if r.ev_zone:
		send_event("zone", {"p": r.id, "i": r.zone_i})
	if r.ev_fin:
		_finish_order.append(r.id)
		send_event("fin", {"p": r.id, "n": _finish_order.size(), "t": r.ftime})
	r.ev_jump = false
	r.ev_land = false
	r.ev_fall = false
	r.ev_bar = false
	r.ev_cp = false
	r.ev_zone = false
	r.ev_fin = false

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
		if not sa.finished and not is_equal_approx(sa.arc, sb.arc):
			return sa.arc > sb.arc
		return a < b)
	return ids

func _place_of(id: int) -> int:
	return _ranking_ids().find(id) + 1

# ----------------------------------------------------------------------------
# Red: el host envía el estado de todos; los eventos suenan/animan en cada PC
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var arr := PackedFloat32Array()
	for id in _order:
		var r: RS = _rs[id]
		arr.append_array(PackedFloat32Array([r.p.x, r.p.y, r.p.z, r.v.x, r.v.y, r.v.z, r.yaw, r.face,
				1.0 if r.grounded else 0.0, r.stun, 1.0 if r.respawn_t < 0.0 or r.respawn_t > RESPAWN_DELAY * 0.5 else 0.0,
				1.0 if r.done else 0.0, r.ftime if r.finished else -1.0, float(r.falls), r.arc, float(r.cp_i), float(r.zone_i),
				float(r.gs)]))
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
	if not arr is PackedFloat32Array or arr.size() < _order.size() * FLOATS:
		return
	for i in _order.size():
		var r: RS = _rs[_order[i]]
		var o := i * FLOATS
		r.p = Vector3(arr[o], arr[o + 1], arr[o + 2])
		r.v = Vector3(arr[o + 3], arr[o + 4], arr[o + 5])
		r.yaw = arr[o + 6]
		r.face = arr[o + 7]
		r.grounded = arr[o + 8] > 0.5
		r.stun = arr[o + 9]
		r.respawn_t = -1.0 if arr[o + 10] > 0.5 else 0.0
		r.done = arr[o + 11] > 0.5
		var ft: float = arr[o + 12]
		r.finished = ft >= 0.0
		if r.finished:
			r.ftime = ft
		r.falls = int(arr[o + 13])
		r.arc = arr[o + 14]
		r.cp_i = int(arr[o + 15])
		r.zone_i = int(arr[o + 16])
		r.gs = int(arr[o + 17])

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
					Audio.sfx(&"jump", -7.0)
		"land":
			if r != null:
				r.burst = true
				if _mine(r):
					Audio.sfx(&"land", -13.0)
		"fall":
			if r != null:
				r.burst_fall = true
				if _mine(r):
					Audio.sfx(&"splash", -6.0)
					_toast = "¡A LA NIEBLA!"
					_toast_t = 1.0
		"bar":
			if r != null and _mine(r):
				_shake = 0.5
				Audio.sfx(&"thud", -4.0)
		"cp":
			if r != null and _mine(r):
				Audio.sfx(&"coin", -9.0)
		"zone":
			if r != null and _mine(r):
				Audio.sfx(&"claim", -8.0)
				_toast = String(_zones[int(d.get("i", 0))]["name"])
				_toast_t = 1.6
		"fin":
			if r != null:
				Audio.sfx(&"fanfare_small" if _mine(r) else &"swish", -5.0)
		"over":
			_winner_id = int(d.get("w", -1))

func _animate(delta: float) -> void:
	_shake = maxf(0.0, _shake - delta * 2.5)
	_toast_t = maxf(0.0, _toast_t - delta)
	_anim += delta
	if _cd <= 0.0:
		_hint_t = maxf(0.0, _hint_t - delta)
	# Tiempo de carrera suavizado (en los clientes llega a ~30 Hz).
	if is_authority:
		_t_vis = _t
	else:
		_t_vis += delta if _cd <= 0.0 else 0.0
		if absf(_t_vis - _t) > 0.25:
			_t_vis = _t
		else:
			_t_vis = lerpf(_t_vis, _t, 0.1)
	_update_world(delta)

# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# IA (bots, autopiloto, práctica): sigue la ruta guardada, salta en los bordes y esquiva la barra
# ----------------------------------------------------------------------------

func _support_at(x: float, z: float, lo: float, hi: float) -> bool:
	for s in _solids:
		if absf(x - s.c.x) <= s.h.x + 0.05 and absf(z - s.c.z) <= s.h.z + 0.05:
			var top := s.c.y + s.h.y
			if top >= lo and top <= hi:
				return true
	return false

func _lane_off(nd: Dictionary, r: RS) -> float:
	var m := maxf(float(nd["hw"]) - 0.9, 0.0)
	return clampf(r.lane, -m, m)

func _route_target(nd: Dictionary, r: RS) -> Vector3:
	return (nd["p"] as Vector3) + (nd["rgt"] as Vector3) * _lane_off(nd, r)

func _bot_decide(r: RS, sk: float) -> Vector3:
	r.bot_jump = false
	if r.respawn_t >= 0.0 or r.done or _route.is_empty():
		return Vector3.ZERO
	r.bi = clampi(r.bi, 0, _route.size() - 1)
	# Avanza por la ruta.
	while r.bi < _route.size() - 1:
		var nd: Dictionary = _route[r.bi]
		var np: Vector3 = _route_target(nd, r)
		var mv := int(nd["mover"])
		var reached := false
		if mv >= 0:
			reached = r.gs == mv
		else:
			reached = Vector2(r.p.x - np.x, r.p.z - np.z).length() < 1.0 and absf(r.p.y - np.y) < 1.6
		if reached:
			r.bi += 1
		else:
			break
	var node: Dictionary = _route[r.bi]
	var target: Vector3 = _route_target(node, r)
	var mvi := int(node["mover"])
	if mvi >= 0:
		var ms := _solids[mvi]
		target = ms.c + Vector3(0, ms.h.y, 0) + (node["rgt"] as Vector3) * _lane_off(node, r)
		var vel := ms.move_dir * (ms.amp * ms.freq * cos(ms.ph + ms.freq * _t))
		target += vel * 0.45
	var to := Vector3(target.x - r.p.x, 0, target.z - r.p.z)
	var dist := to.length()
	var dir := to / maxf(dist, 0.001)
	# Esperar en el borde, alineado con la losa móvil.
	if mvi >= 0 and r.gs != mvi and r.grounded:
		var ms2 := _solids[mvi]
		var lat := Vector3(ms2.c.x - r.p.x, 0, ms2.c.z - r.p.z)
		var lat_off := lat.dot(ms2.move_dir)
		var ahead_free := not _support_at(r.p.x + dir.x * 1.0, r.p.z + dir.z * 1.0, r.p.y - 0.7, r.p.y + STEP_H)
		if absf(lat_off) > 1.0 and lat.length() < 6.5 and ahead_free:
			return ms2.move_dir * signf(lat_off) * clampf(absf(lat_off), 0.0, 1.0)
	# Barra giratoria: salta cuando está a punto de pasar por encima.
	if r.grounded:
		for b in _bars:
			if Vector2(r.p.x - b.pivot.x, r.p.z - b.pivot.z).length() < b.half_len + 1.5 and absf(r.p.y - b.pivot.y) < 1.0:
				if _bar_dist(b, _t + 0.16, r.p) < 1.15 or _bar_dist(b, _t, r.p) < 1.15:
					r.bot_jump = true
	# Bordes y muros: saltar.
	if r.grounded and dist > 1.0:
		var probe := 0.9
		var supported := _support_at(r.p.x + dir.x * probe, r.p.z + dir.z * probe, r.p.y - 0.7, r.p.y + STEP_H)
		var wall := _support_at(r.p.x + dir.x * 0.9, r.p.z + dir.z * 0.9, r.p.y + STEP_H + 0.02, r.p.y + 1.7)
		if wall:
			r.bot_jump = true
		elif not supported and target.y > r.p.y - 4.0:
			r.bot_jump = true
	if sk < 1.0 and r.bot_jump and r.bot_rng.randf() < (1.0 - sk) * 0.05:
		r.bot_jump = false
	# En el aire se frena para caer sobre la losa y no pasarse de largo.
	if not r.grounded and dist > 0.5:
		var tl := (r.v.y + sqrt(maxf(r.v.y * r.v.y + 2.0 * GRAVITY * (r.p.y - target.y), 0.0))) / GRAVITY
		var want_speed := maxf(dist - 0.6, 0.0) / maxf(tl, 0.05)
		dir *= clampf(want_speed / RUN_SPEED, 0.12, 1.0)
	return dir

func _bot_move(player: PlayerData) -> Vector2:
	var r: RS = _rs.get(player.id)
	if r == null:
		return Vector2.ZERO
	var sk := r.skill if debug_skill < 0.0 else debug_skill
	var d := _bot_decide(r, sk)
	# Entrada relativa a la cámara de este corredor: x = derecha, y = (-adelante).
	return Vector2(d.dot(_rgt(r.yaw)), -d.dot(_fwd(r.yaw)))

func _bot_action(player: PlayerData) -> int:
	var r: RS = _rs.get(player.id)
	if r == null:
		return 0
	var v := 1 if r.bot_jump else 0
	r.bot_jump = false
	return v

func _bot_action_held(_player: PlayerData) -> bool:
	return false

# --- Resultado simulado de un bot / desconectado (lo calcula el host) ---
func _bot_result(_player: PlayerData, r: RandomNumberGenerator) -> Dictionary:
	_ensure_level()
	if r.randf() < 0.6:
		return {"score": snappedf(_total, 0.1), "tiebreak": snappedf(r.randf_range(40.0, 85.0), 0.01)}
	return {"score": snappedf(r.randf_range(0.3, 0.95) * _total, 0.1), "tiebreak": TIME_LIMIT}

# --- Plausibilidad: no se llega a la meta más deprisa que corriendo recto, ni más lejos de lo que mide el recorrido ---
func _validate_result(score: float, tiebreak: float) -> bool:
	_ensure_level()
	if score < 0.0 or score > _total + 0.2 or tiebreak < 0.0 or tiebreak > TIME_LIMIT + 3.0:
		return false
	if score >= _total - 0.2:
		return tiebreak >= _total / (RUN_SPEED * 1.3) - 0.5
	return score <= RUN_SPEED * 1.3 * (TIME_LIMIT + 2.0)

# ----------------------------------------------------------------------------
# Escena 3D
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

## Material "dibujo animado": color liso con un contorno oscuro (casco invertido que crece por las normales).
func _toon(c: Color, emission: float = 0.0, outline: float = 0.028) -> StandardMaterial3D:
	var m := _mat(c, emission, 0.55)
	var o := StandardMaterial3D.new()
	o.albedo_color = Color(0.16, 0.08, 0.06)
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

# --- Texturas procedurales (se generan una vez y se reutilizan) ---
static var _tex_stone: ImageTexture = null
static var _tex_cloud: ImageTexture = null

func _stone_texture() -> ImageTexture:
	if _tex_stone != null:
		return _tex_stone
	var n := FastNoiseLite.new()
	n.seed = 7
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 0.035
	n.fractal_octaves = 4
	var nn := n.get_seamless_image(256, 256)
	var n2 := FastNoiseLite.new()
	n2.seed = 21
	n2.frequency = 0.25
	var gr := n2.get_seamless_image(256, 256)
	var img := Image.create(256, 256, false, Image.FORMAT_RGB8)
	for y in 256:
		var row := y / 64
		for x in 256:
			var v := 0.78 + 0.34 * (nn.get_pixel(x, y).r - 0.5) + 0.06 * (gr.get_pixel(x, y).r - 0.5)
			var bx := (x + (row % 2) * 64) % 128
			var by := y % 64
			if by < 3 or bx < 3:
				v *= 0.68                                # juntas entre los bloques
			elif by < 6 or bx < 6:
				v *= 0.9
			img.set_pixel(x, y, Color(v, v * 0.92, v * 0.82))
	img.generate_mipmaps()
	_tex_stone = ImageTexture.create_from_image(img)
	return _tex_stone

func _cloud_texture() -> ImageTexture:
	if _tex_cloud != null:
		return _tex_cloud
	var n := FastNoiseLite.new()
	n.seed = 3
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 0.012
	n.fractal_octaves = 4
	var nn := n.get_seamless_image(256, 256)
	var img := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	for y in 256:
		for x in 256:
			var v := nn.get_pixel(x, y).r
			var a := clampf((v - 0.36) / 0.34, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 0.95, 0.85, a * a * (3.0 - 2.0 * a) * 0.9))
	img.generate_mipmaps()
	_tex_cloud = ImageTexture.create_from_image(img)
	return _tex_cloud

func _particles(color: Color, amount: int, life: float, one_shot: bool, radius: float, vel_min: float, vel_max: float, spread: float, grav: Vector3, emissive: bool = false) -> CPUParticles3D:
	var pt := CPUParticles3D.new()
	pt.amount = amount
	pt.lifetime = life
	pt.one_shot = one_shot
	pt.emitting = false
	pt.explosiveness = 0.9 if one_shot else 0.0
	pt.direction = Vector3.UP
	pt.spread = spread
	pt.initial_velocity_min = vel_min
	pt.initial_velocity_max = vel_max
	pt.gravity = grav
	pt.scale_amount_min = 0.6
	pt.scale_amount_max = 1.2
	pt.scale_amount_curve = _shrink_curve()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 8
	sm.rings = 4
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	if emissive:
		mat.emission_enabled = true
		mat.emission = color
	sm.material = mat
	pt.mesh = sm
	return pt

func _shrink_curve() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 1.0))
	c.add_point(Vector2(1.0, 0.0))
	return c

func _build_world() -> void:
	if _built:
		return
	_built = true
	var cont := SubViewportContainer.new()
	cont.stretch = true
	cont.set_anchors_preset(Control.PRESET_FULL_RECT)
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
	# --- Cielo de atardecer, niebla cálida, brillo y sombras ---
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.55, 0.42, 0.78)
	sky_mat.sky_horizon_color = Color(1.0, 0.72, 0.45)
	sky_mat.sky_curve = 0.18
	sky_mat.ground_horizon_color = Color(1.0, 0.76, 0.5)
	sky_mat.ground_bottom_color = Color(1.0, 0.82, 0.58)
	sky_mat.sun_angle_max = 30.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1.0, 0.84, 0.7)
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 5.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.18
	env.adjustment_contrast = 1.06
	env.glow_enabled = true
	env.glow_intensity = 0.7
	env.glow_bloom = 0.08
	env.glow_hdr_threshold = 0.95
	env.fog_enabled = true
	env.fog_light_color = Color(1.0, 0.78, 0.55)
	env.fog_density = 0.0085
	env.fog_sky_affect = 0.25
	var we := WorldEnvironment.new()
	we.environment = env
	_root3.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-30.0, -40.0, 0.0)
	sun.light_energy = 1.25
	sun.light_color = Color(1.0, 0.86, 0.66)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 70.0
	sun.shadow_bias = 0.05
	sun.shadow_normal_bias = 1.0
	_root3.add_child(sun)
	_sun = sun
	# El sol grande en el horizonte.
	var sun_dir := Basis.from_euler(sun.rotation) * Vector3(0, 0, -1)
	var sun_disc := _sphere(_root3, 34.0, Vector3(-sun_dir.x, 0.0, -sun_dir.z).normalized() * 540.0 + Vector3(0, 70.0, 0), _sun_mat())
	sun_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# --- Mar de nubes bajo las ruinas (varias capas que se desplazan despacio) ---
	var cloud_tex := _cloud_texture()
	for i in 4:
		var cm := StandardMaterial3D.new()
		cm.albedo_texture = cloud_tex
		cm.albedo_color = Color(1.0, 0.9 - 0.04 * i, 0.72 - 0.05 * i, 1.0)
		cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		cm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		cm.uv1_scale = Vector3(9.0 + 3.0 * i, 9.0 + 3.0 * i, 1.0)
		cm.disable_fog = true
		cm.cull_mode = BaseMaterial3D.CULL_DISABLED
		var pm := PlaneMesh.new()
		pm.size = Vector2(1800.0, 1800.0)
		var plane := _mesh(_root3, pm, Vector3(0, -7.5 - 2.6 * i, 0), cm)
		plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_cloud_mats.append(cm)
	var sea := StandardMaterial3D.new()
	sea.albedo_color = Color(1.0, 0.8, 0.58)
	sea.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sea.disable_fog = true
	_box(_root3, Vector3(3000.0, 0.2, 3000.0), Vector3(0, -19.0, 0), sea)
	# --- Piedra con textura (bloques, juntas y grano) ---
	var stone := _mat(Color(1.0, 0.93, 0.82), 0.0, 0.92)
	stone.albedo_texture = _stone_texture()
	stone.uv1_triplanar = true
	stone.uv1_scale = Vector3(0.28, 0.28, 0.28)
	stone.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var stone_dark := stone.duplicate() as StandardMaterial3D
	stone_dark.albedo_color = Color(0.82, 0.68, 0.58)
	var stone_light := stone.duplicate() as StandardMaterial3D
	stone_light.albedo_color = Color(1.0, 0.98, 0.9)
	var trim := _mat(Color(0.78, 0.38, 0.26), 0.0, 0.7)
	var gold := _mat(Color(1.0, 0.8, 0.3), 0.35, 0.4)
	var goal_mat := _mat(Color(0.25, 0.9, 0.8), 0.6)
	var mover_mat := _mat(Color(0.28, 0.8, 0.82), 0.25, 0.6)
	# --- Losas, escaleras, columnas y meta ---
	for s in _solids:
		var root := Node3D.new()
		_root3.add_child(root)
		s.node = root
		root.position = s.c
		var moving := s.amp != 0.0
		match s.style:
			Style.COLUMN:
				var cm := CylinderMesh.new()
				cm.top_radius = s.h.x * 1.0
				cm.bottom_radius = s.h.x * 1.08
				cm.height = s.h.y * 2.0
				cm.radial_segments = 14
				_mesh(root, cm, Vector3.ZERO, stone_dark)
				_mesh(root, _cyl(s.h.x * 1.28, 0.34), Vector3(0, s.h.y - 0.15, 0), stone_light)
				_mesh(root, _cyl(s.h.x * 1.14, 0.12), Vector3(0, s.h.y - 0.4, 0), trim)
			Style.BEAM:
				_box(root, s.h * 2.0, Vector3.ZERO, stone_dark)
				_box(root, Vector3(s.h.x * 2.0 + 0.12, 0.16, s.h.z * 2.0 + 0.04), Vector3(0, s.h.y - 0.26, 0), trim)
				_box(root, Vector3(s.h.x * 2.0 + 0.02, 0.08, s.h.z * 2.0 + 0.02), Vector3(0, s.h.y - 0.04, 0), stone_light)
			Style.GOAL:
				_box(root, s.h * 2.0, Vector3.ZERO, stone_light)
				_box(root, Vector3(s.h.x * 2.0 + 0.2, 0.16, s.h.z * 2.0 + 0.2), Vector3(0, s.h.y - 0.3, 0), goal_mat)
				_box(root, Vector3(s.h.x * 2.0 - 2.4, 0.04, s.h.z * 2.0 - 2.4), Vector3(0, s.h.y + 0.004, 0), _mat(Color(0.55, 0.95, 0.88), 0.25))
			_:
				if moving:
					_box(root, s.h * 2.0, Vector3.ZERO, stone_dark)
					_box(root, Vector3(s.h.x * 2.0 + 0.14, 0.14, s.h.z * 2.0 + 0.14), Vector3(0, s.h.y - 0.25, 0), mover_mat)
					_box(root, Vector3(s.h.x * 2.0 - 0.7, 0.04, s.h.z * 2.0 - 0.7), Vector3(0, s.h.y + 0.005, 0), mover_mat)
				else:
					_box(root, s.h * 2.0, Vector3.ZERO, stone)
					_box(root, Vector3(s.h.x * 2.0 + 0.14, 0.18, s.h.z * 2.0 + 0.14), Vector3(0, s.h.y - 0.3, 0), trim)
					_box(root, Vector3(s.h.x * 2.0 + 0.04, 0.07, s.h.z * 2.0 + 0.04), Vector3(0, s.h.y - 0.035, 0), stone_light)
	# --- Barras giratorias con franjas de aviso ---
	var red := _mat(Color(0.9, 0.25, 0.22), 0.25, 0.5)
	var yel := _mat(Color(1.0, 0.85, 0.25), 0.35, 0.5)
	for b in _bars:
		var broot := Node3D.new()
		_root3.add_child(broot)
		b.node = broot
		broot.position = b.pivot + Vector3(0, 0.38, 0)
		var seg := 9
		var seg_len := b.half_len * 2.0 / seg
		for k in seg:
			_box(broot, Vector3(seg_len + 0.01, 0.62, 0.5), Vector3(-b.half_len + seg_len * (k + 0.5), 0, 0), red if k % 2 == 0 else yel)
		_mesh(broot, _cyl(0.85, 1.0), Vector3(0, -0.12, 0), stone_dark)
		_mesh(broot, _cyl(0.5, 0.2), Vector3(0, 0.5, 0), gold)
	# --- Puntos de control: anillo y bandera ---
	for i in _cps.size():
		var cp: Dictionary = _cps[i]
		var cpos: Vector3 = cp["pos"]
		var ring := Node3D.new()
		_root3.add_child(ring)
		ring.position = cpos + Vector3(0, 0.05, 0)
		var tm := TorusMesh.new()
		tm.inner_radius = 1.05
		tm.outer_radius = 1.35
		var cmat := _mat(Color(0.95, 0.95, 0.95), 0.0, 0.5)
		_mesh(ring, tm, Vector3.ZERO, cmat)
		var pole := _box(ring, Vector3(0.1, 2.6, 0.1), Vector3(1.6, 1.3, 0), stone_light)
		pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var flag := _box(ring, Vector3(0.05, 0.6, 0.9), Vector3(1.6, 2.2, 0.5), cmat)
		_cp_nodes.append({"mat": cmat, "flag": flag})
	# --- Arco de meta (mira hacia donde llegas) ---
	var gdir := _path[_path.size() - 1] - _path[_path.size() - 2]
	gdir.y = 0.0
	var gth := atan2(gdir.x, gdir.z)
	var grt := _rgt(gth)
	for sx in [-1.0, 1.0]:
		_mesh(_root3, _cyl(0.55, 6.4), _goal + grt * (sx * 4.0) + Vector3(0, 3.2, 0), stone_light)
		_mesh(_root3, _cyl(0.8, 0.5), _goal + grt * (sx * 4.0) + Vector3(0, 0.25, 0), trim)
		_mesh(_root3, _cyl(0.8, 0.5), _goal + grt * (sx * 4.0) + Vector3(0, 6.4, 0), trim)
	var lintel := _box(_root3, Vector3(9.4, 1.0, 0.9), _goal + Vector3(0, 6.9, 0), stone_light)
	lintel.rotation.y = gth
	var banner := _box(_root3, Vector3(7.0, 0.75, 0.12), _goal + Vector3(0, 6.9, 0.0) + _fwd(gth) * 0.5, goal_mat)
	banner.rotation.y = gth
	var glow_gate := _box(_root3, Vector3(7.2, 5.2, 0.05), _goal + Vector3(0, 3.1, 0), _gate_glow_mat())
	glow_gate.rotation.y = gth
	glow_gate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# --- Ruinas lejanas: arcos, templos y muros que salen de la niebla ---
	var dr := RandomNumberGenerator.new()
	dr.seed = seed_value + 99
	for i in 46:
		var idx := dr.randi_range(0, _path.size() - 1)
		var base := _path[idx]
		var ang := dr.randf_range(0.0, TAU)
		var off := dr.randf_range(34.0, 100.0)
		var pos := Vector3(base.x + cos(ang) * off, base.y + dr.randf_range(-14.0, 8.0), base.z + sin(ang) * off)
		var too_close := false
		for q in _path:
			if Vector2(q.x - pos.x, q.z - pos.z).length() < 30.0:
				too_close = true
				break
		if too_close:
			continue
		var kind := dr.randi() % 4
		var rot := dr.randf_range(0.0, PI)
		var ruin := Node3D.new()
		_root3.add_child(ruin)
		ruin.position = pos
		ruin.rotation.y = rot
		match kind:
			0:   # arco
				for sx in [-1.0, 1.0]:
					_mesh(ruin, _cyl(1.5, 40.0), Vector3(sx * 5.0, -17.0, 0), stone_dark)
					_mesh(ruin, _cyl(2.0, 0.8), Vector3(sx * 5.0, 3.2, 0), stone_light)
				_box(ruin, Vector3(13.5, 1.8, 2.6), Vector3(0, 4.4, 0), stone_light)
				_box(ruin, Vector3(14.2, 0.5, 3.0), Vector3(0, 5.5, 0), trim)
			1:   # templo: hilera de columnas con losa
				for k in 5:
					_mesh(ruin, _cyl(1.3, 40.0 - dr.randf_range(0.0, 4.0)), Vector3(-8.0 + 4.0 * k, -16.0, 0), stone_dark)
				_box(ruin, Vector3(20.0, 1.4, 5.0), Vector3(0, 4.2, 0), stone_light)
				_box(ruin, Vector3(21.0, 0.5, 5.6), Vector3(0, 5.2, 0), trim)
			2:   # muro roto
				for k in 4:
					var hh := dr.randf_range(6.0, 16.0)
					_box(ruin, Vector3(4.0, hh + 30.0, 2.2), Vector3(-6.0 + 4.0 * k, hh * 0.5 - 15.0, 0), stone)
			_:   # gran columna caída en pie
				_mesh(ruin, _cyl(dr.randf_range(1.8, 3.0), 60.0), Vector3(0, -22.0, 0), stone_dark)
				_mesh(ruin, _cyl(3.6, 0.9), Vector3(0, 8.4, 0), stone_light)
	# --- Escombros flotantes cerca del recorrido (suben y bajan despacio) ---
	for i in 55:
		var idx2 := dr.randi_range(0, _path.size() - 1)
		var b2 := _path[idx2]
		var a2 := dr.randf_range(0.0, TAU)
		var o2 := dr.randf_range(7.0, 22.0)
		var sz := dr.randf_range(0.5, 2.0)
		var rock := _box(_root3, Vector3(sz * dr.randf_range(0.8, 1.6), sz * dr.randf_range(0.5, 1.0), sz * dr.randf_range(0.8, 1.6)), Vector3.ZERO, stone if dr.randf() < 0.7 else trim)
		var rp := Vector3(b2.x + cos(a2) * o2, b2.y + dr.randf_range(-8.0, 5.0), b2.z + sin(a2) * o2)
		rock.position = rp
		rock.rotation = Vector3(dr.randf_range(0, 3), dr.randf_range(0, 3), dr.randf_range(0, 3))
		_debris.append({"n": rock, "y": rp.y, "ph": dr.randf_range(0.0, TAU), "sp": dr.randf_range(0.3, 0.8), "rot": Vector3(dr.randf_range(-0.3, 0.3), dr.randf_range(-0.4, 0.4), dr.randf_range(-0.3, 0.3))})
	# --- Corredores (uno por jugador), motas de luz y cámara ---
	_rebuild_runner_nodes()
	_motes = _particles(Color(1.0, 0.86, 0.5, 0.75), 70, 5.0, false, 0.05, 0.0, 0.25, 180.0, Vector3(0, 0.12, 0), true)
	_motes.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_motes.emission_box_extents = Vector3(14.0, 7.0, 14.0)
	_root3.add_child(_motes)
	_motes.emitting = true
	_cam = Camera3D.new()
	_cam.fov = _fov
	_cam.far = 900.0
	_root3.add_child(_cam)
	_cam.current = true
	_update_world(0.0)

func _cyl(radius: float, height: float) -> CylinderMesh:
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = 14
	return cm

func _sun_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.93, 0.7)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.disable_fog = true
	m.emission_enabled = true
	m.emission = Color(1.0, 0.85, 0.5)
	m.emission_energy_multiplier = 1.6
	return m

func _gate_glow_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.3, 1.0, 0.9, 0.22)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

## Crea (o recrea) el modelo 3D de cada corredor, con su nombre flotando encima.
func _rebuild_runner_nodes() -> void:
	if not _built:
		return
	for id in _order:
		var r: RS = _rs[id]
		for n in [r.node, r.shadow, r.dust, r.puff]:
			if n != null and is_instance_valid(n):
				(n as Node).queue_free()
		_build_runner(r, _player_by_id(id))

## El personaje: un explorador con gorro de pompón, capa que ondea, mochila, brazos y piernas que se mueven.
func _build_runner(r: RS, pl: PlayerData) -> void:
	r.node = Node3D.new()
	_root3.add_child(r.node)
	var col: Color = pl.color if pl != null else Palette.YELLOW
	var dark := col.darkened(0.35)
	var skin := Color(1.0, 0.86, 0.7)
	r.body = Node3D.new()
	r.node.add_child(r.body)
	var body := r.body
	# Torso y cabeza.
	_capsule(body, 0.34, 0.96, Vector3(0, 0.82, 0), _toon(col))
	_mesh(body, _cyl(0.355, 0.1), Vector3(0, 0.62, 0), _toon(dark, 0.0, 0.02))       # cinturón
	_sphere(body, 0.34, Vector3(0, 1.5, 0), _toon(skin))
	# Gorro con pompón.
	var hat := _sphere(body, 0.375, Vector3(0, 1.64, -0.015), _toon(col.lightened(0.1)))
	hat.scale = Vector3(1.0, 0.72, 1.0)
	_mesh(body, _cyl(0.375, 0.1), Vector3(0, 1.5, -0.01), _toon(dark, 0.0, 0.02))      # ala del gorro
	_sphere(body, 0.11, Vector3(0, 1.98, -0.02), _toon(Color.WHITE, 0.15))
	# Cara (se ve al arrancar y al llegar): ojos y sonrisa.
	for sx in [-1.0, 1.0]:
		_sphere(body, 0.07, Vector3(sx * 0.13, 1.5, 0.3), _mat(Color(0.12, 0.08, 0.1), 0.0, 0.2))
		_sphere(body, 0.025, Vector3(sx * 0.13 + 0.02, 1.53, 0.36), _mat(Color.WHITE, 0.5, 0.2))
	var smile := _box(body, Vector3(0.14, 0.03, 0.03), Vector3(0, 1.38, 0.32), _mat(Color(0.5, 0.2, 0.2)))
	smile.rotation.x = 0.1
	# Mochila y capa.
	_box(body, Vector3(0.5, 0.55, 0.25), Vector3(0, 0.95, -0.38), _toon(Color(0.62, 0.42, 0.28)))
	_box(body, Vector3(0.52, 0.14, 0.27), Vector3(0, 1.17, -0.38), _toon(Color(0.45, 0.28, 0.2)))
	r.cape = Node3D.new()
	r.cape.position = Vector3(0, 1.18, -0.3)
	body.add_child(r.cape)
	_box(r.cape, Vector3(0.5, 0.72, 0.04), Vector3(0, -0.36, -0.1), _mat(dark.lerp(Color(0.6, 0.3, 0.2), 0.3), 0.0, 0.8))
	_box(r.cape, Vector3(0.52, 0.07, 0.05), Vector3(0, -0.72, -0.1), _mat(Color(1.0, 0.8, 0.3), 0.3, 0.5))
	# Brazos y piernas (con pivote en hombro / cadera).
	r.arm_l = Node3D.new()
	r.arm_l.position = Vector3(-0.42, 1.15, 0)
	body.add_child(r.arm_l)
	r.arm_r = Node3D.new()
	r.arm_r.position = Vector3(0.42, 1.15, 0)
	body.add_child(r.arm_r)
	var arm_mat := _toon(col)
	for arm in [r.arm_l, r.arm_r]:
		_capsule(arm, 0.095, 0.56, Vector3(0, -0.24, 0), arm_mat)
		_sphere(arm, 0.1, Vector3(0, -0.5, 0), _toon(skin, 0.0, 0.02))
	r.leg_l = Node3D.new()
	r.leg_l.position = Vector3(-0.16, 0.5, 0)
	body.add_child(r.leg_l)
	r.leg_r = Node3D.new()
	r.leg_r.position = Vector3(0.16, 0.5, 0)
	body.add_child(r.leg_r)
	var leg_mat := _toon(dark)
	var shoe_mat := _toon(Color(0.4, 0.26, 0.18), 0.0, 0.02)
	for leg in [r.leg_l, r.leg_r]:
		_capsule(leg, 0.12, 0.5, Vector3(0, -0.2, 0), leg_mat)
		_box(leg, Vector3(0.24, 0.13, 0.36), Vector3(0, -0.44, 0.06), shoe_mat)
	# Nombre flotando encima (y una flecha sobre el jugador de este PC).
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
	tag.position = Vector3(0, 2.55, 0)
	r.node.add_child(tag)
	# Sombra bajo los pies y partículas propias.
	var sm := StandardMaterial3D.new()
	sm.albedo_color = Color(0.2, 0.08, 0.02, 0.38)
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	r.shadow = _mesh(_root3, _cyl(0.55, 0.02), Vector3.ZERO, sm)
	r.shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	r.dust = _particles(Color(1.0, 0.88, 0.7, 0.6), 10, 0.5, false, 0.09, 0.4, 1.2, 45.0, Vector3(0, 0.6, 0))
	_root3.add_child(r.dust)
	r.puff = _particles(Color(1.0, 0.88, 0.7, 0.7), 12, 0.45, true, 0.1, 1.0, 2.6, 85.0, Vector3(0, -2.0, 0))
	_root3.add_child(r.puff)
	r.dp = r.p
	r.dyaw = r.yaw
	r.dface = r.face
	r.node.position = r.p

## El corredor que sigue la cámara: el de este PC; si no hay (varios en un mismo PC), el que va primero.
func _cam_runner() -> RS:
	if local_player != null and _rs.has(local_player.id):
		return _rs[local_player.id]
	# Varias personas en un mismo PC (modo local): la cámara sigue a la que va primero de las humanas.
	var best: RS = null
	for id in _order:
		var pl := _player_by_id(id)
		if pl == null or not pl.is_local_human:
			continue
		var r: RS = _rs[id]
		if best == null or r.arc > best.arc:
			best = r
	if best != null:
		return best
	for id in _order:
		var r2: RS = _rs[id]
		if best == null or r2.arc > best.arc:
			best = r2
	return best

## Altura de la superficie bajo (x, z) por debajo de `y` (para la sombra).
func _floor_under(x: float, z: float, y: float) -> float:
	var best := -1e9
	for s in _solids:
		if absf(x - s.c.x) <= s.h.x and absf(z - s.c.z) <= s.h.z:
			var top := s.c.y + s.h.y
			if top <= y + 0.3 and top > best:
				best = top
	return best

func _update_world(delta: float) -> void:
	if not _built or _cam == null:
		return
	# Losas móviles y barra giratoria (con el tiempo de carrera suavizado).
	for s in _solids:
		if s.node != null and s.amp != 0.0:
			s.node.position = s.c0 + s.move_dir * (s.amp * sin(s.ph + s.freq * _t_vis))
	for b in _bars:
		if b.node != null:
			b.node.rotation.y = -_bar_angle(b, _t_vis)
	var k := 1.0 if delta <= 0.0 else 1.0 - exp(-22.0 * delta)
	for id in _order:
		var r: RS = _rs[id]
		if r.node == null:
			continue
		if r.dp.distance_to(r.p) > 6.0:
			r.dp = r.p
		else:
			r.dp = r.dp.lerp(r.p, k)
		r.dyaw = lerp_angle(r.dyaw, r.yaw, 1.0 if delta <= 0.0 else 1.0 - exp(-8.0 * delta))
		r.dface = lerp_angle(r.dface, r.face, 1.0 if delta <= 0.0 else 1.0 - exp(-16.0 * delta))
		r.anim += delta
		r.node.position = r.dp
		r.node.rotation.y = r.dface
		r.node.visible = r.respawn_t < 0.0 or r.respawn_t > RESPAWN_DELAY * 0.5
		var speed_h := Vector2(r.v.x, r.v.z).length()
		var running := r.grounded and speed_h > 1.0 and not r.done
		var ph := r.anim * (6.0 + speed_h * 0.9)
		var swing := clampf(speed_h / RUN_SPEED, 0.0, 1.0)
		if running:
			r.leg_l.rotation.x = sin(ph) * 1.0 * swing
			r.leg_r.rotation.x = -sin(ph) * 1.0 * swing
			r.arm_l.rotation.x = -sin(ph) * 0.9 * swing
			r.arm_r.rotation.x = sin(ph) * 0.9 * swing
			r.body.position.y = absf(sin(ph)) * 0.09 * swing
		elif not r.grounded:
			r.leg_l.rotation.x = -0.6 if r.v.y > 0.0 else 0.4          # en el aire: una pierna adelante y otra atrás
			r.leg_r.rotation.x = 0.5 if r.v.y > 0.0 else -0.3
			r.arm_l.rotation.x = -2.5 if r.v.y > 0.0 else -1.3         # brazos arriba al saltar
			r.arm_r.rotation.x = -2.5 if r.v.y > 0.0 else -1.3
			r.body.position.y = 0.0
		else:
			var idle := sin(r.anim * 2.2)
			r.leg_l.rotation.x = lerpf(r.leg_l.rotation.x, 0.0, 0.3)
			r.leg_r.rotation.x = lerpf(r.leg_r.rotation.x, 0.0, 0.3)
			r.arm_l.rotation.x = lerpf(r.arm_l.rotation.x, 0.06 * idle, 0.3)
			r.arm_r.rotation.x = lerpf(r.arm_r.rotation.x, -0.06 * idle, 0.3)
			r.body.position.y = 0.012 * idle
		r.body.rotation.x = 0.16 * swing + (0.0 if r.grounded else (-0.18 if r.v.y > 0 else 0.22))
		var squash := 1.0
		if not r.grounded:
			squash = 1.0 + clampf(absf(r.v.y) * 0.012, 0.0, 0.12)
		r.body.scale = Vector3(1.0 / sqrt(squash), squash, 1.0 / sqrt(squash))
		r.cape.rotation.x = 0.25 + 0.75 * swing + 0.16 * sin(r.anim * 11.0 + 1.0) * (0.3 + swing) + (0.25 if not r.grounded else 0.0)
		r.cape.rotation.z = 0.07 * sin(r.anim * 7.0)
		if r.stun > 0.0:
			r.body.rotation.x = -0.5
			r.arm_l.rotation.x = -2.2
			r.arm_r.rotation.x = -2.2
		var fy := _floor_under(r.dp.x, r.dp.z, r.dp.y)
		r.shadow.visible = fy > -1e8 and r.node.visible
		r.shadow.position = Vector3(r.dp.x, fy + 0.03, r.dp.z)
		var sc := clampf(1.0 - (r.dp.y - fy) * 0.12, 0.4, 1.0)
		r.shadow.scale = Vector3(sc, 1.0, sc)
		r.dust.position = Vector3(r.dp.x, r.dp.y + 0.05, r.dp.z)
		r.dust.emitting = running and speed_h > 3.0
		if r.burst:
			r.burst = false
			r.puff.position = Vector3(r.dp.x, r.dp.y + 0.05, r.dp.z)
			r.puff.restart()
			r.puff.emitting = true
		if r.burst_fall:
			r.burst_fall = false
			r.puff.position = Vector3(r.dp.x, FALL_Y + 1.0, r.dp.z)
			r.puff.restart()
			r.puff.emitting = true
	# Escenario vivo: nubes que se desplazan, escombros que flotan, banderas de los puntos de control.
	for i in _cloud_mats.size():
		_cloud_mats[i].uv1_offset = Vector3(_anim * 0.0045 * (1.0 + 0.5 * i), _anim * 0.0022 * (1.0 + 0.3 * i), 0.0)
	for d in _debris:
		var rn: Node3D = d["n"]
		rn.position.y = float(d["y"]) + sin(_anim * float(d["sp"]) + float(d["ph"])) * 0.5
		rn.rotation += (d["rot"] as Vector3) * delta
	var cs := _cam_runner()
	var my_cp := cs.cp_i if cs != null else 0
	for i in _cp_nodes.size():
		var on := i <= my_cp
		var cmat: StandardMaterial3D = _cp_nodes[i]["mat"]
		cmat.albedo_color = Color(0.25, 1.0, 0.7) if on else Color(0.92, 0.92, 0.92)
		cmat.emission_enabled = on
		cmat.emission = Color(0.25, 1.0, 0.7)
		cmat.emission_energy_multiplier = 1.2
	if cs == null:
		return
	# Cámara en tercera persona sobre TU personaje: detrás y arriba, mirando un poco por delante.
	var fwd := _fwd(cs.dyaw)
	var focus := cs.dp + Vector3(0, 1.2, 0)
	var tgt := focus - fwd * 5.4 + Vector3(0, 2.9, 0)
	if delta <= 0.0:
		_cam_pos = tgt
	else:
		_cam_pos = _cam_pos.lerp(tgt, 1.0 - exp(-9.0 * delta))
	var shake := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * _shake * 0.15
	_cam.position = _cam_pos + shake
	_cam.look_at(focus + fwd * 2.2 + Vector3(0, 0.2, 0), Vector3.UP)
	_motes.position = Vector3(cs.dp.x, cs.dp.y + 2.5, cs.dp.z)

# ----------------------------------------------------------------------------
# HUD (dibujo 2D encima del 3D): minimapa del recorrido, progreso, tiempo
# ----------------------------------------------------------------------------

func _map_bounds() -> Rect2:
	var mn := Vector2(1e9, 1e9)
	var mx := Vector2(-1e9, -1e9)
	for q in _path:
		mn.x = minf(mn.x, q.x)
		mn.y = minf(mn.y, q.z)
		mx.x = maxf(mx.x, q.x)
		mx.y = maxf(mx.y, q.z)
	return Rect2(mn, mx - mn)

func _draw_hud() -> void:
	var s := surface
	var cs := _cam_runner()
	var arc_me := cs.arc if cs != null else 0.0
	# Minimapa (arriba a la derecha): el recorrido visto desde arriba, con las zonas y todos los corredores.
	var box := Rect2(1050, 70, 200, 200)
	s.rounded_rect(box.grow(8), 16, Color(0, 0, 0, 0.45))
	var bnd := _map_bounds()
	var sc := minf((box.size.x - 24.0) / maxf(bnd.size.x, 1.0), (box.size.y - 24.0) / maxf(bnd.size.y, 1.0))
	var origin := box.position + (box.size - bnd.size * sc) * 0.5
	var zone_cols: Array[Color] = [Palette.MINT, Palette.YELLOW, Palette.CORAL, Color(0.6, 0.55, 1.0), Color(1.0, 0.6, 0.3), Color(0.35, 0.85, 1.0), Color(1.0, 0.5, 0.75), Palette.MINT]
	for i in range(0, _path.size() - 1):
		var zi := 0
		for k in _zones.size():
			if i >= int(_zones[k]["pt"]):
				zi = k
		var a := _to_map(_path[i], bnd, origin, sc)
		var b := _to_map(_path[i + 1], bnd, origin, sc)
		var zc: Color = zone_cols[zi % zone_cols.size()]
		var passed := _cum[i + 1] <= arc_me
		s.draw_line(a, b, zc if passed else Color(zc.r, zc.g, zc.b, 0.45), 6.0)
	for cp in _cps:
		s.draw_circle(_to_map(cp["pos"], bnd, origin, sc), 3.5, Palette.WHITE)
	s.draw_circle(_to_map(_goal, bnd, origin, sc), 6.0, Palette.YELLOW)
	for id in _order:
		var r: RS = _rs[id]
		var pl := _player_by_id(id)
		var col: Color = pl.color if pl != null else Palette.WHITE
		var mine := cs != null and r == cs
		var pt := _to_map(r.dp, bnd, origin, sc)
		s.draw_circle(pt, 8.5 if mine else 6.0, Palette.WHITE)
		s.draw_circle(pt, 6.5 if mine else 4.2, col)
	# Posición, progreso y tiempo.
	var frac := clampf(arc_me / _total, 0.0, 1.0)
	if cs != null:
		s.text_centered(Vector2(640, 40), "%d.º de %d" % [_place_of(cs.id), _order.size()], 46, Palette.YELLOW, 9)
	var bar := Rect2(440, 74, 400, 14)
	s.rounded_rect(bar.grow(4), 10, Color(0, 0, 0, 0.45))
	s.rounded_rect(Rect2(bar.position, Vector2(maxf(bar.size.x * frac, 14.0), bar.size.y)), 7, Palette.MINT)
	for id in _order:
		var r2: RS = _rs[id]
		var pl2 := _player_by_id(id)
		var c2: Color = pl2.color if pl2 != null else Palette.WHITE
		var px := bar.position.x + bar.size.x * clampf(r2.arc / _total, 0.0, 1.0)
		s.draw_circle(Vector2(px, bar.position.y + 7.0), 8.0, Palette.WHITE)
		s.draw_circle(Vector2(px, bar.position.y + 7.0), 5.5, c2)
	var zname := String(_zones[cs.zone_i]["name"]) if cs != null and _zones.size() > 0 else ""
	s.text_centered(Vector2(640, 108), zname, 24, Color(1, 1, 1, 0.85), 5)
	var left := maxi(0, ceili(TIME_LIMIT - _t))
	s.text_centered(Vector2(120, 44), "%d s" % left, 40, Palette.YELLOW if left > 15 else Palette.CORAL, 8)
	if cs != null and cs.falls > 0:
		s.text_centered(Vector2(120, 88), "Caídas: %d" % cs.falls, 22, Color(1, 1, 1, 0.8), 5)
	if _toast_t > 0.0:
		s.text_centered(Vector2(640, 220), _toast, 64, Color(1, 1, 1, clampf(_toast_t * 2.0, 0.0, 1.0)), 12)
	if _cd > 0.0:
		var n := ceili(_cd)
		var frac_c := _cd - floorf(_cd)
		s.text_centered(Vector2(640, 300), str(n), int(130.0 + 60.0 * frac_c), Palette.YELLOW, 16)
	elif _t < 0.8:
		s.text_centered(Vector2(640, 300), "¡YA!", 130, Palette.MINT, 16)
	if _hint_t > 0.0 and not _over and _cd <= 0.0:
		s.text_centered(Vector2(640, 670), "WASD / flechas para moverte  ·  ESPACIO o CLIC para saltar", 28, Color(1, 1, 1, clampf(_hint_t, 0.0, 1.0)), 7)
	if cs != null and cs.finished and not _over:
		var pos := _finish_order.find(cs.id) + 1
		s.text_centered(Vector2(640, 300), "¡META!  %d.º" % maxi(pos, 1), 90, Palette.YELLOW, 14)
	if _over:
		var w := _player_by_id(_winner_id)
		s.text_centered(Vector2(640, 280), "¡FIN!", 100, Palette.YELLOW, 14)
		if w != null:
			s.text_centered(Vector2(640, 370), "Gana %s" % w.display_name, 56, w.color.lightened(0.25), 10)

## Mundo → minimapa: +z hacia arriba y +x hacia la izquierda (igual que la vista al salir).
func _to_map(q: Vector3, bnd: Rect2, origin: Vector2, sc: float) -> Vector2:
	return Vector2(origin.x + (bnd.position.x + bnd.size.x - q.x) * sc, origin.y + (bnd.position.y + bnd.size.y - q.z) * sc)

# ----------------------------------------------------------------------------
# Utilidades de depuración / pruebas (tests/obstacle_test.gd)
# ----------------------------------------------------------------------------

func debug_signature() -> String:
	_ensure_level()
	var parts: PackedStringArray = []
	for s in _solids:
		parts.append("%.2f:%.2f:%.2f:%.2f" % [s.c0.x, s.c0.y, s.c0.z, s.h.x])
	return "|".join(parts)

func debug_info() -> Dictionary:
	_ensure_level()
	return {"solids": _solids.size(), "total": _total, "zones": _zones.size(), "cps": _cps.size(), "route": _route.size(), "bars": _bars.size()}

func debug_runner(id: int) -> Dictionary:
	var r: RS = _rs.get(id)
	if r == null:
		return {}
	return {"p": r.p, "v": r.v, "grounded": r.grounded, "arc": r.arc, "falls": r.falls, "done": r.done, "finished": r.finished,
			"ftime": r.ftime, "cp": r.cp_i, "gs": r.gs, "zone": r.zone_i}

func debug_place(id: int, p: Vector3) -> void:
	var r: RS = _rs.get(id)
	if r != null:
		r.p = p
		r.v = Vector3.ZERO

func debug_over() -> bool:
	return _over

func debug_winner() -> int:
	return _winner_id

## Un corredor SOLO con una política: "bot" (la IA) o "idle" (no hace nada). Devuelve el resultado.
func debug_run(policy: String, skill: float = 1.0, seconds: float = TIME_LIMIT + 1.0) -> Dictionary:
	_ensure_level()
	var fake := PlayerData.new()
	fake.id = 999
	var r := _make_rs(fake, 0, 1)
	r.bot_rng.seed = seed_value
	_t = 0.0
	_update_solids(true)
	var t := 0.0
	while t < seconds and not r.done:
		_t += STEP
		_update_solids()
		var dir := Vector3.ZERO
		var jump := false
		if policy == "bot":
			dir = _bot_decide(r, skill)
			jump = r.bot_jump
			r.bot_jump = false
		_sim_step(r, STEP, dir, jump, r.arc)
		if _t >= TIME_LIMIT and not r.done:
			r.done = true
		t += STEP
	return {"finished": r.finished, "time": r.ftime if r.finished else _t, "progress": r.arc, "falls": r.falls, "total": _total}
