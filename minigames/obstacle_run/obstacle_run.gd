extends Minigame
## Carrera de Ruinas (id obstacle_run; modelo LOCAL_PARALLEL, 3D en tercera persona): un parkour de ruinas flotantes sobre
## la niebla. Cada uno juega en su pantalla (sin verse) con la cámara detrás de su personaje, sobre el MISMO recorrido, que
## sale de la semilla común. Gana quien llega antes a la meta; quien no llega se ordena por lo lejos que ha llegado.
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
## El 3D (SubViewport con su propio mundo) es solo presentación. No hay nada de red: report_result(metros, tiempo).

const STEP := 1.0 / 60.0
const TIME_LIMIT := 100.0
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

# --- Estado del corredor ---
var _p: Vector3 = Vector3.ZERO          # pies
var _v: Vector3 = Vector3.ZERO
var _grounded: bool = false
var _gs: int = -1                       # losa sobre la que estás
var _face: float = 0.0
var _yaw: float = 0.0                   # dirección de la cámara
var _jump_buf: float = 0.0
var _coyote_t: float = 0.0
var _jump_pending: bool = false
var _stun: float = 0.0
var _respawn_t: float = -1.0
var _cp_i: int = 0
var _falls: int = 0
var _seg: int = 0
var _arc: float = 0.0
var _t: float = 0.0                     # segundos de carrera
var _cd: float = COUNTDOWN
var _last_cd: int = 99
var _accum: float = 0.0
var _done: bool = false
var _finished_race: bool = false
var _ftime: float = 0.0
var _done_t: float = 0.0
var _zone_i: int = 0
var _toast: String = ""
var _toast_t: float = 0.0
var _hint_t: float = 7.0
var _shake: float = 0.0
var _anim: float = 0.0
var _land_ev: bool = false
var _jump_ev: bool = false

# --- IA ---
var debug_skill: float = 1.0
var _bi: int = 0
var _bot_jump: bool = false
var _bot_rng: RandomNumberGenerator = RandomNumberGenerator.new()

# --- Escena 3D ---
var _vp: SubViewport
var _root3: Node3D
var _cam: Camera3D
var _pl: Node3D
var _pl_body: Node3D
var _leg_l: Node3D
var _leg_r: Node3D
var _shadow: MeshInstance3D
var _built: bool = false
var _fov: float = 68.0
var _cam_pos: Vector3 = Vector3.ZERO
var _sun: DirectionalLight3D
var _arm_l: Node3D
var _arm_r: Node3D
var _cape: Node3D
var _cloud_mats: Array[StandardMaterial3D] = []
var _debris: Array = []
var _cp_nodes: Array = []
var _run_dust: CPUParticles3D
var _land_puff: CPUParticles3D
var _fall_puff: CPUParticles3D
var _motes: CPUParticles3D
var _burst_land: bool = false
var _burst_fall: bool = false

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
	_route.append({"p": _lp(l), "mover": mover, "zone": _zones.size() - 1})

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

func _reset_state() -> void:
	_cp_i = 0
	_p = (_cps[0]["pos"] as Vector3)
	_v = Vector3.ZERO
	_grounded = false
	_gs = -1
	_face = 0.0
	_yaw = 0.0
	_jump_buf = 0.0
	_coyote_t = 0.0
	_jump_pending = false
	_stun = 0.0
	_respawn_t = -1.0
	_falls = 0
	_seg = 0
	_arc = 0.0
	_t = 0.0
	_done = false
	_finished_race = false
	_ftime = 0.0
	_done_t = 0.0
	_zone_i = 0
	_toast = ""
	_toast_t = 0.0
	_bi = 0
	_bot_jump = false
	_update_solids(true)
	_yaw = _path_yaw()

func _update_solids(snap: bool = false) -> void:
	for s in _solids:
		s.pc = s.c
		if s.amp != 0.0:
			s.c = s.c0 + s.move_dir * (s.amp * sin(s.ph + s.freq * _t))
		if snap:
			s.pc = s.c

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
func _resolve_axis(axis: int) -> void:
	for s in _solids:
		if absf(_p.x - s.c.x) > s.h.x + RADIUS or absf(_p.z - s.c.z) > s.h.z + RADIUS:
			continue
		if not _overlap_y(s, _p.y):
			continue
		var top := s.c.y + s.h.y
		if top - _p.y <= STEP_H and _v.y <= 1.0:
			_p.y = top + 0.001                          # escalón: se sube
			continue
		if axis == 0:
			_p.x = s.c.x + (s.h.x + RADIUS if _p.x > s.c.x else -(s.h.x + RADIUS))
			_v.x = 0.0
		else:
			_p.z = s.c.z + (s.h.z + RADIUS if _p.z > s.c.z else -(s.h.z + RADIUS))
			_v.z = 0.0

## Un paso de simulación. dir = dirección de movimiento deseada en el mundo (longitud <= 1).
func _sim_step(dt: float, dir: Vector3, jump: bool) -> void:
	_jump_ev = false
	_land_ev = false
	_t += dt
	# Plataformas móviles: se mueven y te arrastran.
	_update_solids()
	if _gs >= 0:
		var gsolid := _solids[_gs]
		_p += gsolid.c - gsolid.pc
	if _respawn_t >= 0.0:
		_respawn_t -= dt
		if _respawn_t < 0.0:
			_respawn()
		return
	# Velocidad horizontal.
	var want := dir * RUN_SPEED
	var acc := GROUND_ACCEL if _grounded else AIR_ACCEL
	if _done:
		want = Vector3.ZERO
	if _stun > 0.0:
		_stun = maxf(0.0, _stun - dt)
		want = Vector3(_v.x, 0.0, _v.z)
		acc = 4.0
	_v.x = move_toward(_v.x, want.x, acc * dt)
	_v.z = move_toward(_v.z, want.z, acc * dt)
	# Salto.
	if jump:
		_jump_buf = JUMP_BUFFER
	_jump_buf = maxf(0.0, _jump_buf - dt)
	if _grounded:
		_coyote_t = COYOTE
	else:
		_coyote_t = maxf(0.0, _coyote_t - dt)
	if _jump_buf > 0.0 and _coyote_t > 0.0 and not _done and _stun <= 0.0:
		_v.y = JUMP_V
		_grounded = false
		_gs = -1
		_coyote_t = 0.0
		_jump_buf = 0.0
		_jump_ev = true
	_v.y = maxf(_v.y - GRAVITY * dt, -MAX_FALL)
	# Movimiento por ejes.
	_p.x += _v.x * dt
	_resolve_axis(0)
	_p.z += _v.z * dt
	_resolve_axis(1)
	var prev_y := _p.y
	_p.y += _v.y * dt
	var was_grounded := _grounded
	_grounded = false
	_gs = -1
	var best_top := -1e9
	for i in _solids.size():
		var s := _solids[i]
		if absf(_p.x - s.c.x) >= s.h.x + RADIUS or absf(_p.z - s.c.z) >= s.h.z + RADIUS:
			continue
		var top := s.c.y + s.h.y
		var bottom := s.c.y - s.h.y
		if _v.y <= 0.0:
			if prev_y >= top - 0.12 and _p.y <= top and top > best_top:
				best_top = top
				_gs = i
		else:
			if prev_y + HEIGHT <= bottom + 0.1 and _p.y + HEIGHT > bottom:
				_p.y = bottom - HEIGHT
				_v.y = 0.0
	if _gs >= 0:
		_p.y = best_top
		_v.y = 0.0
		_grounded = true
		if not was_grounded:
			_land_ev = true
	# Barras giratorias.
	for b in _bars:
		if _p.y < b.pivot.y + b.top and _p.y + HEIGHT > b.pivot.y - 0.2:
			if absf(_p.x - b.pivot.x) < b.half_len + 1.0 and absf(_p.z - b.pivot.z) < b.half_len + 1.0:
				if _bar_dist(b, _t, _p) < RADIUS + 0.22 and _stun <= 0.0:
					var a := _bar_angle(b, _t)
					var tang := Vector3(-sin(a), 0.0, cos(a)) * signf(b.omega)
					_v.x = tang.x * BAR_KNOCK
					_v.z = tang.z * BAR_KNOCK
					_v.y = 5.0
					_grounded = false
					_gs = -1
					_stun = 0.45
					_shake = 0.5
					if _hot():
						Audio.sfx(&"thud", -4.0)
	# Niebla: caída.
	if _p.y < FALL_Y and _respawn_t < 0.0 and not _done:
		_falls += 1
		_respawn_t = RESPAWN_DELAY
		_toast = "¡A LA NIEBLA!"
		_burst_fall = true
		_toast_t = 1.0
		if _hot():
			Audio.sfx(&"splash", -6.0)
	# Progreso, puntos de control y meta.
	_track_progress()
	if not _done:
		var gd := Vector2(_p.x - _goal.x, _p.z - _goal.z).length()
		if gd < 3.2 and absf(_p.y - _goal.y) < 2.5:
			_done = true
			_finished_race = true
			_ftime = _t
			_done_t = 0.0
			if _hot():
				Audio.sfx(&"fanfare_small", -4.0)
			DevCli.log_event("ruins finished time=%.2f s falls=%d" % [_ftime, _falls])
		elif _t >= TIME_LIMIT:
			_done = true
			_done_t = 0.0
			DevCli.log_event("ruins timeout progress=%.0f m falls=%d" % [_arc, _falls])

func _respawn() -> void:
	var cp: Dictionary = _cps[_cp_i]
	_p = cp["pos"]
	_v = Vector3.ZERO
	_grounded = false
	_gs = -1
	_stun = 0.0
	_bi = int(cp["route_i"])
	_seg = maxi(int(cp["path_i"]) - 1, 0)
	_yaw = _path_yaw()

## Posición sobre la línea central → progreso (m); también la zona y el punto de control actuales.
func _track_progress() -> void:
	var best_d := 1e9
	var best_i := _seg
	var best_t := 0.0
	var lo := maxi(_seg - 1, 0)
	var hi := mini(_seg + 3, _path.size() - 2)
	for i in range(lo, hi + 1):
		var a := _path[i]
		var b := _path[i + 1]
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var l2 := ab.length_squared()
		var tt := 0.0
		if l2 > 0.0001:
			tt = clampf(Vector2(_p.x - a.x, _p.z - a.z).dot(ab) / l2, 0.0, 1.0)
		var qx := a.x + ab.x * tt
		var qz := a.z + ab.y * tt
		var d := Vector2(_p.x - qx, _p.z - qz).length()
		if d < best_d:
			best_d = d
			best_i = i
			best_t = tt
	_seg = best_i
	var arc := _cum[best_i] + best_t * (_cum[best_i + 1] - _cum[best_i])
	if arc > _arc and _respawn_t < 0.0:
		_arc = arc
	# Zona.
	while _zone_i + 1 < _zones.size() and _arc >= float(_zones[_zone_i + 1]["arc"]):
		_zone_i += 1
		_toast = String(_zones[_zone_i]["name"])
		_toast_t = 1.6
		if _hot():
			Audio.sfx(&"claim", -8.0)
	# Punto de control (al pisar el inicio de la zona).
	while _cp_i + 1 < _cps.size() and _grounded:
		var nxt: Dictionary = _cps[_cp_i + 1]
		var npos: Vector3 = nxt["pos"]
		if Vector2(_p.x - npos.x, _p.z - npos.z).length() < 3.2 and absf(_p.y - npos.y) < 2.0:
			_cp_i += 1
			if _hot():
				Audio.sfx(&"coin", -9.0)
		else:
			break

func _path_yaw() -> float:
	var i := clampi(_seg, 0, _path.size() - 2)
	var d := _path[i + 1] - _path[i]
	d.y = 0.0
	if d.length() < 0.01:
		return _yaw
	return atan2(d.x, d.z)

func _hot() -> bool:
	return local_player != null and is_audible(local_player)

# ----------------------------------------------------------------------------
# Ciclo del minijuego
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	_ensure_level()
	_build_world()
	surface.draw_callback = _draw_hud

func _on_start() -> void:
	_ensure_level()
	_reset_state()
	_accum = 0.0
	_cd = COUNTDOWN
	_last_cd = 99
	_hint_t = 7.0
	_bot_rng.seed = hash([seed_value, local_player.id if local_player != null else 0])
	_cam_pos = _p - _fwd(_yaw) * 5.0 + Vector3(0, 3.0, 0)

func _play(delta: float) -> void:
	if local_player == null:
		return
	_anim += delta
	if _cd > 0.0:
		var c := ceili(_cd)
		if c != _last_cd:
			_last_cd = c
			if _hot():
				Audio.sfx(&"beep", -7.0)
		_cd -= delta
		if _cd <= 0.0 and _hot():
			Audio.sfx(&"beep_go", -5.0)
		return
	_hint_t = maxf(0.0, _hint_t - delta)
	# La cámara gira poco a poco hacia donde va el recorrido; el movimiento es relativo a ella.
	_yaw = lerp_angle(_yaw, _path_yaw(), 1.0 - exp(-2.2 * delta))
	var inp := move_input(local_player)
	if action_presses(local_player) > 0:
		_jump_pending = true
	var fwd := _fwd(_yaw)
	var rgt := _rgt(_yaw)
	var dir := (rgt * inp.x + fwd * (-inp.y))
	if dir.length() > 1.0:
		dir = dir.normalized()
	_accum += delta
	var steps := 0
	while _accum >= STEP and steps < 12:
		_accum -= STEP
		steps += 1
		_sim_step(STEP, dir, _jump_pending)
		_jump_pending = false
		if _jump_ev:
			_burst_land = true
			if _hot():
				Audio.sfx(&"jump", -7.0)
		if _land_ev:
			_burst_land = true
			if _hot():
				Audio.sfx(&"land", -13.0)
	if dir.length() > 0.2 and not _done:
		_face = lerp_angle(_face, atan2(dir.x, dir.z), 1.0 - exp(-14.0 * delta))

func _animate(delta: float) -> void:
	_shake = maxf(0.0, _shake - delta * 2.5)
	_toast_t = maxf(0.0, _toast_t - delta)
	_update_world(delta)
	if _done:
		_done_t += delta
		if _done_t >= DONE_DELAY and not _reported:
			if _finished_race:
				report_result(snappedf(_total, 0.1), snappedf(_ftime, 0.01))
			else:
				report_result(snappedf(_arc, 0.1), TIME_LIMIT)

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

func _bot_decide() -> Vector3:
	_bot_jump = false
	if _respawn_t >= 0.0 or _done or _route.is_empty():
		return Vector3.ZERO
	_bi = clampi(_bi, 0, _route.size() - 1)
	# Avanza por la ruta.
	while _bi < _route.size() - 1:
		var nd: Dictionary = _route[_bi]
		var np: Vector3 = nd["p"]
		var mv := int(nd["mover"])
		var reached := false
		if mv >= 0:
			reached = _gs == mv
		else:
			reached = Vector2(_p.x - np.x, _p.z - np.z).length() < 1.0 and absf(_p.y - np.y) < 1.6
		if reached:
			_bi += 1
		else:
			break
	var node: Dictionary = _route[_bi]
	var target: Vector3 = node["p"]
	var mvi := int(node["mover"])
	if mvi >= 0:
		var ms := _solids[mvi]
		target = ms.c + Vector3(0, ms.h.y, 0)
		var vel := ms.move_dir * (ms.amp * ms.freq * cos(ms.ph + ms.freq * _t))
		target += vel * 0.45
	var to := Vector3(target.x - _p.x, 0, target.z - _p.z)
	var dist := to.length()
	var dir := to / maxf(dist, 0.001)
	var sk := clampf(debug_skill, 0.0, 1.0)
	# Esperar en el borde, alineado con la losa móvil.
	if mvi >= 0 and _gs != mvi and _grounded:
		var ms2 := _solids[mvi]
		var lat := Vector3(ms2.c.x - _p.x, 0, ms2.c.z - _p.z)
		var lat_off := lat.dot(ms2.move_dir)
		var ahead_free := not _support_at(_p.x + dir.x * 1.0, _p.z + dir.z * 1.0, _p.y - 0.7, _p.y + STEP_H)
		if absf(lat_off) > 1.0 and lat.length() < 6.5 and ahead_free:
			return ms2.move_dir * signf(lat_off) * clampf(absf(lat_off), 0.0, 1.0)
	# Barra giratoria: salta cuando está a punto de pasar por encima.
	if _grounded:
		for b in _bars:
			if Vector2(_p.x - b.pivot.x, _p.z - b.pivot.z).length() < b.half_len + 1.5 and absf(_p.y - b.pivot.y) < 1.0:
				if _bar_dist(b, _t + 0.16, _p) < 1.15 or _bar_dist(b, _t, _p) < 1.15:
					_bot_jump = true
	# Bordes y muros: saltar.
	if _grounded and dist > 1.0:
		var probe := 0.9
		var supported := _support_at(_p.x + dir.x * probe, _p.z + dir.z * probe, _p.y - 0.7, _p.y + STEP_H)
		var wall := _support_at(_p.x + dir.x * 0.9, _p.z + dir.z * 0.9, _p.y + STEP_H + 0.02, _p.y + 1.7)
		if wall:
			_bot_jump = true
		elif not supported and target.y > _p.y - 4.0:
			_bot_jump = true
	if sk < 1.0 and _bot_jump and _bot_rng.randf() < (1.0 - sk) * 0.05:
		_bot_jump = false
	# En el aire se frena para caer sobre la losa y no pasarse de largo.
	if not _grounded and dist > 0.5:
		var tl := (_v.y + sqrt(maxf(_v.y * _v.y + 2.0 * GRAVITY * (_p.y - target.y), 0.0))) / GRAVITY
		var want_speed := maxf(dist - 0.6, 0.0) / maxf(tl, 0.05)
		dir *= clampf(want_speed / RUN_SPEED, 0.12, 1.0)
	return dir

func _bot_move(player: PlayerData) -> Vector2:
	if player != local_player:
		return Vector2.ZERO
	var d := _bot_decide()
	# Entrada relativa a la cámara: x = derecha, y = (-adelante).
	return Vector2(d.dot(_rgt(_yaw)), -d.dot(_fwd(_yaw)))

func _bot_action(player: PlayerData) -> int:
	if player != local_player:
		return 0
	var v := 1 if _bot_jump else 0
	_bot_jump = false
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
	# --- Personaje, partículas y cámara ---
	_build_player()
	_run_dust = _particles(Color(1.0, 0.88, 0.7, 0.6), 10, 0.5, false, 0.09, 0.4, 1.2, 45.0, Vector3(0, 0.6, 0))
	_root3.add_child(_run_dust)
	_land_puff = _particles(Color(1.0, 0.88, 0.7, 0.7), 12, 0.45, true, 0.1, 1.0, 2.6, 85.0, Vector3(0, -2.0, 0))
	_root3.add_child(_land_puff)
	_fall_puff = _particles(Color(1.0, 0.93, 0.8, 0.9), 26, 0.9, true, 0.3, 2.0, 5.5, 55.0, Vector3(0, -3.0, 0))
	_root3.add_child(_fall_puff)
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

## El personaje: un explorador con gorro de pompón, bufanda-capa que ondea, mochila, brazos y piernas que se mueven.
func _build_player() -> void:
	_pl = Node3D.new()
	_root3.add_child(_pl)
	var col: Color = local_player.color if local_player != null else Palette.YELLOW
	var dark := col.darkened(0.35)
	var skin := Color(1.0, 0.86, 0.7)
	_pl_body = Node3D.new()
	_pl.add_child(_pl_body)
	# Torso y cabeza.
	_capsule(_pl_body, 0.34, 0.96, Vector3(0, 0.82, 0), _toon(col))
	_mesh(_pl_body, _cyl(0.355, 0.1), Vector3(0, 0.62, 0), _toon(dark, 0.0, 0.02))       # cinturón
	_sphere(_pl_body, 0.34, Vector3(0, 1.5, 0), _toon(skin))
	# Gorro con pompón.
	var hat := _sphere(_pl_body, 0.375, Vector3(0, 1.64, -0.015), _toon(col.lightened(0.1)))
	hat.scale = Vector3(1.0, 0.72, 1.0)
	_mesh(_pl_body, _cyl(0.375, 0.1), Vector3(0, 1.5, -0.01), _toon(dark, 0.0, 0.02))      # ala del gorro
	_sphere(_pl_body, 0.11, Vector3(0, 1.98, -0.02), _toon(Color.WHITE, 0.15))
	# Cara (se ve al arrancar y al llegar): ojos y sonrisa.
	for sx in [-1.0, 1.0]:
		_sphere(_pl_body, 0.07, Vector3(sx * 0.13, 1.5, 0.3), _mat(Color(0.12, 0.08, 0.1), 0.0, 0.2))
		_sphere(_pl_body, 0.025, Vector3(sx * 0.13 + 0.02, 1.53, 0.36), _mat(Color.WHITE, 0.5, 0.2))
	var smile := _box(_pl_body, Vector3(0.14, 0.03, 0.03), Vector3(0, 1.38, 0.32), _mat(Color(0.5, 0.2, 0.2)))
	smile.rotation.x = 0.1
	# Mochila y capa.
	_box(_pl_body, Vector3(0.5, 0.55, 0.25), Vector3(0, 0.95, -0.38), _toon(Color(0.62, 0.42, 0.28)))
	_box(_pl_body, Vector3(0.52, 0.14, 0.27), Vector3(0, 1.17, -0.38), _toon(Color(0.45, 0.28, 0.2)))
	_cape = Node3D.new()
	_cape.position = Vector3(0, 1.18, -0.3)
	_pl_body.add_child(_cape)
	_box(_cape, Vector3(0.5, 0.72, 0.04), Vector3(0, -0.36, -0.1), _mat(dark.lerp(Color(0.6, 0.3, 0.2), 0.3), 0.0, 0.8))
	_box(_cape, Vector3(0.52, 0.07, 0.05), Vector3(0, -0.72, -0.1), _mat(Color(1.0, 0.8, 0.3), 0.3, 0.5))
	# Brazos y piernas (con pivote en hombro / cadera).
	_arm_l = Node3D.new()
	_arm_l.position = Vector3(-0.42, 1.15, 0)
	_pl_body.add_child(_arm_l)
	_arm_r = Node3D.new()
	_arm_r.position = Vector3(0.42, 1.15, 0)
	_pl_body.add_child(_arm_r)
	var arm_mat := _toon(col)
	_capsule(_arm_l, 0.095, 0.56, Vector3(0, -0.24, 0), arm_mat)
	_capsule(_arm_r, 0.095, 0.56, Vector3(0, -0.24, 0), arm_mat)
	_sphere(_arm_l, 0.1, Vector3(0, -0.5, 0), _toon(skin, 0.0, 0.02))
	_sphere(_arm_r, 0.1, Vector3(0, -0.5, 0), _toon(skin, 0.0, 0.02))
	_leg_l = Node3D.new()
	_leg_l.position = Vector3(-0.16, 0.5, 0)
	_pl_body.add_child(_leg_l)
	_leg_r = Node3D.new()
	_leg_r.position = Vector3(0.16, 0.5, 0)
	_pl_body.add_child(_leg_r)
	var leg_mat := _toon(dark)
	var shoe_mat := _toon(Color(0.4, 0.26, 0.18), 0.0, 0.02)
	for leg in [_leg_l, _leg_r]:
		_capsule(leg, 0.12, 0.5, Vector3(0, -0.2, 0), leg_mat)
		_box(leg, Vector3(0.24, 0.13, 0.36), Vector3(0, -0.44, 0.06), shoe_mat)
	# Sombra bajo los pies.
	var sh := _cyl(0.55, 0.02)
	var sm := StandardMaterial3D.new()
	sm.albedo_color = Color(0.2, 0.08, 0.02, 0.38)
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shadow = _mesh(_root3, sh, Vector3.ZERO, sm)
	_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

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
	for s in _solids:
		if s.node != null and s.amp != 0.0:
			s.node.position = s.c
	for b in _bars:
		if b.node != null:
			b.node.rotation.y = -_bar_angle(b, _t)
	# Personaje.
	_pl.position = _p
	_pl.visible = _respawn_t < 0.0 or _respawn_t > RESPAWN_DELAY * 0.5
	_pl.rotation.y = _face
	var speed_h := Vector2(_v.x, _v.z).length()
	var running := _grounded and speed_h > 1.0 and not _done
	var ph := _anim * (6.0 + speed_h * 0.9)
	var swing := clampf(speed_h / RUN_SPEED, 0.0, 1.0)
	if running:
		_leg_l.rotation.x = sin(ph) * 1.0 * swing
		_leg_r.rotation.x = -sin(ph) * 1.0 * swing
		_arm_l.rotation.x = -sin(ph) * 0.9 * swing
		_arm_r.rotation.x = sin(ph) * 0.9 * swing
		_pl_body.position.y = absf(sin(ph)) * 0.09 * swing
	elif not _grounded:
		_leg_l.rotation.x = -0.6 if _v.y > 0.0 else 0.4          # en el aire: una pierna adelante y otra atrás
		_leg_r.rotation.x = 0.5 if _v.y > 0.0 else -0.3
		_arm_l.rotation.x = -2.5 if _v.y > 0.0 else -1.3         # brazos arriba al saltar
		_arm_r.rotation.x = -2.5 if _v.y > 0.0 else -1.3
		_pl_body.position.y = 0.0
	else:
		var idle := sin(_anim * 2.2)
		_leg_l.rotation.x = lerpf(_leg_l.rotation.x, 0.0, 0.3)
		_leg_r.rotation.x = lerpf(_leg_r.rotation.x, 0.0, 0.3)
		_arm_l.rotation.x = lerpf(_arm_l.rotation.x, 0.06 * idle, 0.3)
		_arm_r.rotation.x = lerpf(_arm_r.rotation.x, -0.06 * idle, 0.3)
		_pl_body.position.y = 0.012 * idle
	_pl_body.rotation.x = 0.16 * swing + (0.0 if _grounded else (-0.18 if _v.y > 0 else 0.22))
	# Estirar al saltar, achatar al caer (un poco de "jugo").
	var squash := 1.0
	if not _grounded:
		squash = 1.0 + clampf(absf(_v.y) * 0.012, 0.0, 0.12)
	_pl_body.scale = Vector3(1.0 / sqrt(squash), squash, 1.0 / sqrt(squash))
	# La capa ondea hacia atrás cuanto más rápido vas.
	_cape.rotation.x = 0.25 + 0.75 * swing + 0.16 * sin(_anim * 11.0 + 1.0) * (0.3 + swing) + (0.25 if not _grounded else 0.0)
	_cape.rotation.z = 0.07 * sin(_anim * 7.0)
	if _stun > 0.0:
		_pl_body.rotation.x = -0.5
		_arm_l.rotation.x = -2.2
		_arm_r.rotation.x = -2.2
	var fy := _floor_under(_p.x, _p.z, _p.y)
	_shadow.visible = fy > -1e8
	_shadow.position = Vector3(_p.x, fy + 0.03, _p.z)
	var sc := clampf(1.0 - (_p.y - fy) * 0.12, 0.4, 1.0)
	_shadow.scale = Vector3(sc, 1.0, sc)
	# Polvo al correr, nubecitas al saltar/aterrizar y motas de luz alrededor.
	_run_dust.position = Vector3(_p.x, _p.y + 0.05, _p.z)
	_run_dust.emitting = running and speed_h > 3.0
	_motes.position = Vector3(_p.x, _p.y + 2.5, _p.z)
	if _burst_land:
		_burst_land = false
		_land_puff.position = Vector3(_p.x, _p.y + 0.05, _p.z)
		_land_puff.restart()
		_land_puff.emitting = true
	if _burst_fall:
		_burst_fall = false
		_fall_puff.position = Vector3(_p.x, FALL_Y + 1.0, _p.z)
		_fall_puff.restart()
		_fall_puff.emitting = true
	# Escenario vivo: nubes que se desplazan, escombros que flotan, banderas de los puntos de control.
	for i in _cloud_mats.size():
		_cloud_mats[i].uv1_offset = Vector3(_anim * 0.0045 * (1.0 + 0.5 * i), _anim * 0.0022 * (1.0 + 0.3 * i), 0.0)
	for d in _debris:
		var rn: Node3D = d["n"]
		rn.position.y = float(d["y"]) + sin(_anim * float(d["sp"]) + float(d["ph"])) * 0.5
		rn.rotation += (d["rot"] as Vector3) * delta
	for i in _cp_nodes.size():
		var on := i <= _cp_i
		var cmat: StandardMaterial3D = _cp_nodes[i]["mat"]
		cmat.albedo_color = Color(0.25, 1.0, 0.7) if on else Color(0.92, 0.92, 0.92)
		cmat.emission_enabled = on
		cmat.emission = Color(0.25, 1.0, 0.7)
		cmat.emission_energy_multiplier = 1.2
	# Cámara en tercera persona: detrás y arriba, mirando a tu personaje y un poco por delante.
	var fwd := _fwd(_yaw)
	var focus := _p + Vector3(0, 1.2, 0)
	var tgt := focus - fwd * 5.4 + Vector3(0, 2.9, 0)
	if delta <= 0.0:
		_cam_pos = tgt
	else:
		_cam_pos = _cam_pos.lerp(tgt, 1.0 - exp(-9.0 * delta))
	var shake := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * _shake * 0.15
	_cam.position = _cam_pos + shake
	_cam.look_at(focus + fwd * 2.2 + Vector3(0, 0.2, 0), Vector3.UP)

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
	# Minimapa (arriba a la derecha): el recorrido visto desde arriba, con las zonas y tu posición.
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
		var passed := _cum[i + 1] <= _arc
		s.draw_line(a, b, zc if passed else Color(zc.r, zc.g, zc.b, 0.45), 6.0)
	for cp in _cps:
		s.draw_circle(_to_map(cp["pos"], bnd, origin, sc), 3.5, Palette.WHITE)
	s.draw_circle(_to_map(_goal, bnd, origin, sc), 6.0, Palette.YELLOW)
	var me := _to_map(_p, bnd, origin, sc)
	var col: Color = local_player.color if local_player != null else Palette.YELLOW
	s.draw_circle(me, 7.5, Palette.WHITE)
	s.draw_circle(me, 5.5, col)
	# Progreso y tiempo.
	var frac := clampf(_arc / _total, 0.0, 1.0)
	s.text_centered(Vector2(640, 40), "%d %%" % int(100.0 * frac), 48, Palette.WHITE, 9)
	var bar := Rect2(440, 74, 400, 14)
	s.rounded_rect(bar.grow(4), 10, Color(0, 0, 0, 0.45))
	s.rounded_rect(Rect2(bar.position, Vector2(maxf(bar.size.x * frac, 14.0), bar.size.y)), 7, Palette.MINT)
	var zname := String(_zones[_zone_i]["name"]) if _zones.size() > 0 else ""
	s.text_centered(Vector2(640, 108), zname, 24, Color(1, 1, 1, 0.85), 5)
	var left := maxi(0, ceili(TIME_LIMIT - _t))
	s.text_centered(Vector2(120, 44), "%d s" % left, 40, Palette.YELLOW if left > 15 else Palette.CORAL, 8)
	if _falls > 0:
		s.text_centered(Vector2(120, 88), "Caídas: %d" % _falls, 22, Color(1, 1, 1, 0.8), 5)
	if _toast_t > 0.0:
		s.text_centered(Vector2(640, 220), _toast, 64, Color(1, 1, 1, clampf(_toast_t * 2.0, 0.0, 1.0)), 12)
	if _cd > 0.0:
		var n := ceili(_cd)
		var frac_c := _cd - floorf(_cd)
		s.text_centered(Vector2(640, 300), str(n), int(130.0 + 60.0 * frac_c), Palette.YELLOW, 16)
	elif _t < 0.8:
		s.text_centered(Vector2(640, 300), "¡YA!", 130, Palette.MINT, 16)
	if _hint_t > 0.0 and not _done and _cd <= 0.0:
		s.text_centered(Vector2(640, 670), "WASD / flechas para moverte  ·  ESPACIO o CLIC para saltar", 28, Color(1, 1, 1, clampf(_hint_t, 0.0, 1.0)), 7)
	if _done:
		if _finished_race:
			s.text_centered(Vector2(640, 300), "¡META!", 100, Palette.YELLOW, 14)
			if _done_t > 0.4:
				s.text_centered(Vector2(640, 390), "%.2f s" % _ftime, 60, Palette.WHITE, 10)
		else:
			s.text_centered(Vector2(640, 300), "¡TIEMPO!", 90, Palette.CORAL, 14)
			if _done_t > 0.4:
				s.text_centered(Vector2(640, 390), "%d %%" % int(100.0 * frac), 60, Palette.WHITE, 10)

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

func debug_state() -> Dictionary:
	return {"p": _p, "v": _v, "grounded": _grounded, "arc": _arc, "t": _t, "falls": _falls, "done": _done, "finished": _finished_race,
			"ftime": _ftime, "cp": _cp_i, "gs": _gs, "zone": _zone_i}

func debug_place(p: Vector3) -> void:
	_p = p
	_v = Vector3.ZERO

## Simula una partida con una política: "bot" (la IA) o "idle" (no hace nada).
func debug_run(policy: String, skill: float = 1.0, seconds: float = TIME_LIMIT + 1.0) -> Dictionary:
	_ensure_level()
	_reset_state()
	debug_skill = skill
	_bot_rng.seed = seed_value
	var t := 0.0
	while t < seconds and not _done:
		var dir := Vector3.ZERO
		var jump := false
		if policy == "bot":
			dir = _bot_decide()
			jump = _bot_jump
			_bot_jump = false
		_sim_step(STEP, dir, jump)
		t += STEP
	return {"finished": _finished_race, "time": _t, "progress": _arc, "falls": _falls, "total": _total}
