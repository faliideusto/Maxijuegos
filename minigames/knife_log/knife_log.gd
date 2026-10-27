extends Minigame
## Tronco de Dagas (modelo HOST_AUTHORITATIVE): el clásico de clavar dagas en un tronco que gira. Todos ven
## la misma pantalla y juegan POR TURNOS (empieza uno al azar): en tu turno pulsas tu botón de acción y lanzas
## tu daga contra el tronco. Si se clava en un hueco, sigue el siguiente; si cae encima de otra daga (la de un
## rival o una de las del principio), RECHAZADA: quedas ELIMINADO. Gana el último que queda y el ranking sigue el
## orden de eliminación (último eliminado = 2.º...).
##
## Dificultad: cada daga clavada acelera el giro (hasta ×2,8), a partir de la 6.ª el tronco "respira" (acelera y
## frena) y cada 5 dagas invierte el sentido (frenando y volviendo a girar). Además el hueco libre se va
## estrechando: el tronco admite unas 15 dagas. Si pasas 6 s sin lanzar, la daga sale sola.
##
## Sin código de red propio: el host simula (_simulate) y los clientes dibujan el estado que reciben
## (_apply_state, ~30 Hz, con extrapolación del giro) y los eventos (throw / stick / clang / turn / win).
## Los bots esperan un hueco y lanzan con un margen variable (a veces fallan). Ver core/minigame.gd.

enum Phase { READY, WAIT, FLY, AFTER, OVER }

const CENTER := Vector2(640, 322)
const LOG_R := 136.0
const START_POS := Vector2(640, 590)    # punta de la daga que espera (la hoja y el mango quedan por debajo)
const HIT_ANGLE := 0.2                # medio ancho angular de una daga (rad): se choca por debajo de esto
const FLIGHT := 0.1                   # s que tarda la daga en llegar al tronco
const TURN_TIME := 6.0
const READY_TIME := 1.8
const AFTER_STICK := 0.55
const AFTER_ELIM := 1.5
const OVER_TIME := 3.8
const START_DAGGERS := 3
const MIN_START_GAP := 0.6
const BASE_SPEED := 1.5               # rad/s con el tronco vacío
const SPEED_PER_DAGGER := 0.09
const MAX_SPEED := 4.2
const MOD_FROM := 6                   # desde cuántas dagas el giro respira
const FLIP_EVERY := 5                 # cada cuántas dagas se invierte el sentido
const DIR_SMOOTH := 2.4               # velocidad del cambio de sentido (unidades de dirección por s)
const SMOOTHING := 18.0
const MAX_DAGGERS := 15               # lo que cabe en el tronco (referencia para tests y avisos)

class Dagger:
	var ang: float                    # ángulo LOCAL (respecto al tronco)
	var owner_id: int = -1            # -1 = de las del principio
	var pop: float = 0.0              # animación de clavado

class Faller:
	var pos: Vector2
	var vel: Vector2
	var rot: float
	var spin: float
	var color: Color
	var life: float = 1.3

var _phase: Phase = Phase.READY
var _rot: float = 0.0
var _rot_net: float = 0.0
var _spd: float = 0.0
var _dir_cur: float = 1.0
var _dir_target: float = 1.0
var _daggers: Array[Dagger] = []
var _count: int = 0                   # dagas clavadas por jugadores
var _turn: int = 0
var _cur_id: int = -1
var _turn_left: float = TURN_TIME
var _fly_t: float = 0.0
var _after_t: float = 0.0
var _over_t: float = 0.0
var _ready_t: float = READY_TIME
var _elapsed: float = 0.0
var _elim_order: Array = []           # ids eliminados por orden (primero = peor)
var _winner_id: int = -1
var _first_turn: bool = true
var _dt: float = 0.016
# Bots
var _bot_wait: float = 0.0
var _bot_need: float = 0.08
var _bot_fire_in: float = -1.0       # cuenta atrás del retraso humano entre decidir y lanzar (-1 = sin decidir)
var _bot_sloppy: float = 0.06        # retraso máximo de este bot en este turno (s)
# Solo visual
var _fallers: Array[Faller] = []
var _particles: Array = []            # {pos, vel, life, color, kind}
var _banner: String = ""
var _banner_t: float = 0.0
var _shake: float = 0.0
var _flash: float = 0.0
var _time: float = 0.0
var _cur_shake: Vector2 = Vector2.ZERO   # desplazamiento de la sacudida en este fotograma
var _last_sec: int = 99
var _tick_turn: int = -1

# ----------------------------------------------------------------------------
# Preparación
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	surface.draw_callback = _draw_game

func _on_start() -> void:
	if not is_authority:
		return
	_daggers.clear()
	_elim_order.clear()
	_count = 0
	_rot = randf() * TAU
	_rot_net = _rot
	_dir_cur = 1.0
	_dir_target = 1.0 if randf() < 0.5 else -1.0
	_dir_cur = _dir_target
	# Dagas iniciales repartidas al azar, separadas entre sí.
	var tries := 0
	while _daggers.size() < START_DAGGERS and tries < 200:
		tries += 1
		var a := randf() * TAU
		var ok := true
		for d in _daggers:
			if absf(_wrap(d.ang - a)) < MIN_START_GAP:
				ok = false
		if ok:
			var nd := Dagger.new()
			nd.ang = a
			nd.pop = 1.0
			_daggers.append(nd)
	_turn = randi() % players.size()           # empieza uno al azar
	_first_turn = true
	_phase = Phase.READY
	_ready_t = READY_TIME
	_cur_id = players[_turn].id
	DevCli.log_event("knife start first=%d daggers=%d" % [_cur_id, _daggers.size()])
	send_event("turn", {"p": _cur_id, "first": true})

# ----------------------------------------------------------------------------
# Simulación (solo host)
# ----------------------------------------------------------------------------

## Normaliza un ángulo a (-π, π].
static func _wrap(a: float) -> float:
	return wrapf(a, -PI, PI)

## Velocidad base del giro con n dagas clavadas.
static func speed_for(n: int) -> float:
	return minf(BASE_SPEED + SPEED_PER_DAGGER * float(n), MAX_SPEED)

func _alive_count() -> int:
	return players.size() - _elim_order.size()

func _is_alive(id: int) -> bool:
	return not _elim_order.has(id)

func _next_alive(from: int) -> int:
	var i := from
	for k in players.size():
		i = (i + 1) % players.size()
		if _is_alive(players[i].id):
			return i
	return from

func _simulate(delta: float) -> void:
	_dt = delta
	_elapsed += delta
	_update_log(delta)
	# Se consumen las pulsaciones de todos (solo vale la del jugador al que le toca).
	var pressed := false
	for p in players:
		var n := action_presses(p)
		if n > 0 and p.id == _cur_id and _is_alive(p.id):
			pressed = true
	match _phase:
		Phase.READY:
			_ready_t -= delta
			if _ready_t <= 0.0:
				_begin_turn()
		Phase.WAIT:
			_turn_left -= delta
			if pressed or _turn_left <= 0.0:
				_throw()
		Phase.FLY:
			_fly_t += delta
			if _fly_t >= FLIGHT:
				_impact()
		Phase.AFTER:
			_after_t -= delta
			if _after_t <= 0.0:
				if _alive_count() <= 1:
					_phase = Phase.OVER
					_over_t = OVER_TIME
					_winner_id = _last_alive()
					DevCli.log_event("knife win id=%d daggers=%d" % [_winner_id, _daggers.size()])
					send_event("win", {"id": _winner_id})
				else:
					_begin_turn()
		Phase.OVER:
			_over_t -= delta
			if _over_t <= 0.0:
				finish(_build_ranking())

func _last_alive() -> int:
	for p in players:
		if _is_alive(p.id):
			return p.id
	return -1

## Gira el tronco: velocidad según las dagas clavadas, con "respiración" a partir de la 6.ª y sentido
## que se invierte despacio (pasa por cero) cada FLIP_EVERY dagas.
func _update_log(delta: float) -> void:
	_dir_cur = move_toward(_dir_cur, _dir_target, delta * DIR_SMOOTH)
	var mod := 1.0
	if _count >= MOD_FROM:
		mod += 0.35 * sin(_elapsed * 1.4)
	_spd = _dir_cur * speed_for(_count) * mod
	_rot += _spd * delta

func _begin_turn() -> void:
	if _first_turn:
		_first_turn = false               # el primer turno es el que se sorteó
	else:
		_turn = _next_alive(_turn)
	_cur_id = players[_turn].id
	_turn_left = TURN_TIME
	_phase = Phase.WAIT
	_bot_wait = randf_range(0.5, 1.6)
	_bot_need = randf_range(0.03, 0.14)
	_bot_fire_in = -1.0
	_bot_sloppy = randf_range(0.02, 0.12)
	send_event("turn", {"p": _cur_id, "first": false})

func _throw() -> void:
	_phase = Phase.FLY
	_fly_t = 0.0
	send_event("throw", {"p": _cur_id})

## Ángulo LOCAL en el que se clavaría una daga que llega ahora (entra por abajo, ángulo π/2 en pantalla).
func _impact_angle(rot: float) -> float:
	return _wrap(PI * 0.5 - rot)

## Distancia angular libre hasta la daga más cercana (menos el medio ancho de la daga): < 0 = choca.
func _free_margin(local_angle: float) -> float:
	var best := PI
	for d in _daggers:
		best = minf(best, absf(_wrap(d.ang - local_angle)))
	return best - HIT_ANGLE

func _impact() -> void:
	var cur := _current_player()
	var a := _impact_angle(_rot)
	var margin := _free_margin(a)
	if margin < 0.0:
		# Choca con otra daga: rebota y el jugador queda eliminado.
		_elim_order.append(cur.id)
		_phase = Phase.AFTER
		_after_t = AFTER_ELIM
		DevCli.log_event("knife clang id=%d daggers=%d left=%d" % [cur.id, _daggers.size(), _alive_count()])
		send_event("clang", {"p": cur.id, "a": a, "left": _alive_count()})
	else:
		var nd := Dagger.new()
		nd.ang = a
		nd.owner_id = cur.id
		_daggers.append(nd)
		_count += 1
		if _count % FLIP_EVERY == 0 and _count >= FLIP_EVERY:
			_dir_target = -_dir_target
		_phase = Phase.AFTER
		_after_t = AFTER_STICK
		send_event("stick", {"p": cur.id, "a": a, "n": _count})

func _current_player() -> PlayerData:
	return players[_turn]

func _build_ranking() -> Array[int]:
	var ranking: Array[int] = []
	for p in players:
		if _is_alive(p.id):
			ranking.append(p.id)
	for i in range(_elim_order.size() - 1, -1, -1):
		ranking.append(int(_elim_order[i]))
	return ranking

# --- Bots: esperan un hueco y lanzan cuando la daga caerá con margen suficiente ---
func _bot_action(player: PlayerData) -> int:
	if _phase != Phase.WAIT or player.id != _cur_id:
		return 0
	_bot_wait -= _dt
	if _bot_wait > 0.0:
		return 0
	if _bot_fire_in >= 0.0:
		_bot_fire_in -= _dt
		return 1 if _bot_fire_in < 0.0 else 0
	# Dónde caería si lanzara ahora (el tronco sigue girando mientras vuela la daga).
	var impact := _impact_angle(_rot + _spd * FLIGHT)
	if _free_margin(impact) >= _bot_need:
		# Decide lanzar, pero con el retraso de un humano: a más velocidad del tronco, más fácil fallar.
		_bot_fire_in = randf_range(0.0, _bot_sloppy)
		if _bot_fire_in <= 0.0:
			return 1
	return 0

# ----------------------------------------------------------------------------
# Estado hacia los clientes
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var d := PackedFloat32Array()
	for dg in _daggers:
		d.append_array(PackedFloat32Array([dg.ang, float(dg.owner_id)]))
	return {"ph": int(_phase), "rot": _rot, "spd": _spd, "cur": _cur_id, "tl": _turn_left, "fl": _fly_t,
			"d": d, "x": _elim_order, "w": _winner_id, "n": _count}

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	var st: Dictionary = state
	_phase = int(st.get("ph", _phase)) as Phase
	_rot_net = float(st.get("rot", _rot_net))
	_spd = float(st.get("spd", _spd))
	_cur_id = int(st.get("cur", _cur_id))
	_turn_left = float(st.get("tl", _turn_left))
	_fly_t = float(st.get("fl", _fly_t))
	_elim_order = st.get("x", _elim_order)
	_winner_id = int(st.get("w", _winner_id))
	_count = int(st.get("n", _count))
	var d: Variant = st.get("d")
	if d is PackedFloat32Array:
		var n: int = d.size() / 2
		while _daggers.size() > n:
			_daggers.pop_back()
		while _daggers.size() < n:
			var nd := Dagger.new()
			nd.pop = 1.0
			_daggers.append(nd)
		for i in n:
			_daggers[i].ang = d[i * 2]
			_daggers[i].owner_id = int(d[i * 2 + 1])
	if _rot == 0.0 and _rot_net != 0.0:
		_rot = _rot_net

func _on_event(event_name: String, data: Variant) -> void:
	if not data is Dictionary:
		return
	var d: Dictionary = data
	var who := _player_by_id(int(d.get("p", -1)))
	match event_name:
		"turn":
			_tick_turn = int(d.get("p", -1))
			_last_sec = 99
			if who != null and is_audible(who):
				Audio.sfx(&"ui_confirm", -4.0)
			else:
				Audio.sfx(&"ui_hover", -6.0)
			if bool(d.get("first", false)) and who != null:
				_banner = "¡EMPIEZA %s!" % who.display_name.to_upper()
				_banner_t = READY_TIME
		"throw":
			Audio.sfx(&"throw", -3.0)
		"stick":
			Audio.sfx(&"stick", -2.0)
			_shake = maxf(_shake, 0.35)
			var wa := float(d.get("a", 0.0)) + _rot
			var pos := CENTER + Vector2.from_angle(wa) * LOG_R
			for i in 10:
				_spawn_particle(pos, Color(0.78, 0.55, 0.32), 1)
			for dg in _daggers:
				dg.pop = minf(dg.pop, 1.0)
			if not _daggers.is_empty():
				_daggers[_daggers.size() - 1].pop = 0.0
		"clang":
			Audio.sfx(&"clang", -1.0)
			Audio.sfx(&"crash", -9.0)
			_shake = 1.2
			_flash = 0.35
			var wa2 := float(d.get("a", 0.0)) + _rot
			var pos2 := CENTER + Vector2.from_angle(wa2) * LOG_R
			for i in 18:
				_spawn_particle(pos2, Color(1.0, 0.92, 0.5), 0)
			var f := Faller.new()
			f.pos = pos2
			f.vel = Vector2(randf_range(-260.0, 260.0), 260.0)
			f.rot = PI * 0.5
			f.spin = randf_range(-9.0, 9.0)
			f.color = who.color if who != null else Palette.WHITE
			_fallers.append(f)
			if who != null:
				_banner = "¡%s ELIMINADO!" % who.display_name.to_upper()
				_banner_t = AFTER_ELIM
				if is_audible(who):
					Audio.sfx(&"error", -3.0)
		"win":
			_banner = ""

func _player_by_id(id: int) -> PlayerData:
	for p in players:
		if p.id == id:
			return p
	return null

func _spawn_particle(pos: Vector2, color: Color, kind: int) -> void:
	_particles.append({"pos": pos, "vel": Vector2.from_angle(randf() * TAU) * randf_range(80.0, 330.0),
			"life": randf_range(0.3, 0.8), "color": color, "kind": kind})

# ----------------------------------------------------------------------------
# Animación (todos los PC)
# ----------------------------------------------------------------------------

func _animate(delta: float) -> void:
	_time += delta
	_shake = maxf(0.0, _shake - delta * 2.5)
	_flash = maxf(0.0, _flash - delta * 2.0)
	_banner_t = maxf(0.0, _banner_t - delta)
	if not is_authority:
		# El tronco gira entre snapshots y se corrige suavemente hacia el valor real.
		_rot_net += _spd * delta
		_rot = lerpf(_rot, _rot_net, 1.0 - exp(-SMOOTHING * delta))
		if _phase == Phase.FLY:
			_fly_t += delta
	for d in _daggers:
		d.pop = minf(d.pop + delta * 5.0, 1.0)
	# Pitidos cuando le quedan 2 s al jugador de este PC.
	if is_running and _phase == Phase.WAIT:
		var cur := _player_by_id(_cur_id)
		var sec := ceili(_turn_left)
		if cur != null and is_audible(cur) and sec != _last_sec and sec <= 2 and sec > 0:
			Audio.sfx(&"beep", -6.0)
		_last_sec = sec
	for f in _fallers:
		f.vel.y += 900.0 * delta
		f.pos += f.vel * delta
		f.rot += f.spin * delta
		f.life -= delta
	_fallers = _fallers.filter(func(x: Faller) -> bool: return x.life > 0.0)
	for p in _particles:
		p.pos += p.vel * delta
		p.vel *= (1.0 - 2.4 * delta)
		p.vel.y += 300.0 * delta
		p.life -= delta
	_particles = _particles.filter(func(x: Dictionary) -> bool: return x.life > 0.0)

# ----------------------------------------------------------------------------
# Dibujo
# ----------------------------------------------------------------------------

func _draw_game() -> void:
	var s := surface
	_cur_shake = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * _shake * 7.0
	s.draw_set_transform(_cur_shake, 0.0, Vector2.ONE)
	_draw_log()
	for d in _daggers:
		_draw_stuck(d)
	_draw_flying_and_pending()
	for f in _fallers:
		_draw_dagger_shape(f.pos, f.rot, f.color, 1.0, true)
	for p in _particles:
		var a := clampf(p.life / 0.8, 0.0, 1.0)
		if int(p.kind) == 0:
			s.draw_line(p.pos, p.pos - p.vel.normalized() * 10.0, Color(p.color.r, p.color.g, p.color.b, a), 3.0)
		else:
			s.draw_rect(Rect2(p.pos - Vector2(3, 3), Vector2(6, 6)), Color(p.color.r, p.color.g, p.color.b, a))
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_hud()
	if _flash > 0.0:
		s.draw_rect(view_rect(), Color(1, 1, 1, _flash * 0.4))

func _draw_log() -> void:
	var s := surface
	s.draw_circle(CENTER + Vector2(0, 14), LOG_R + 12.0, Color(0, 0, 0, 0.28))
	s.draw_circle(CENTER, LOG_R + 8.0, Color(0.30, 0.17, 0.09))            # corteza
	s.draw_circle(CENTER, LOG_R + 2.0, Color(0.43, 0.26, 0.13))
	s.draw_circle(CENTER, LOG_R - 4.0, Color(0.80, 0.58, 0.35))            # madera
	# Anillos de crecimiento y grietas (giran con el tronco).
	for i in 4:
		var rr := (LOG_R - 4.0) * (0.82 - 0.2 * i)
		s.draw_arc(CENTER, rr, 0.0, TAU, 48, Color(0.58, 0.38, 0.2, 0.7), 3.0, true)
	for k in 6:
		var a := _rot + k * 1.07 + 0.3
		var p0 := CENTER + Vector2.from_angle(a) * 14.0
		var p1 := CENTER + Vector2.from_angle(a + 0.06 * (k % 2 * 2 - 1)) * (60.0 + 12.0 * (k % 3))
		s.draw_line(p0, p1, Color(0.5, 0.32, 0.17, 0.8), 3.0)
	s.draw_circle(CENTER, 15.0, Color(0.62, 0.42, 0.24))
	s.draw_circle(CENTER, 8.0, Color(0.5, 0.32, 0.17))
	# Brillo fijo (da volumen).
	s.draw_arc(CENTER, LOG_R - 14.0, PI * 1.15, PI * 1.5, 16, Color(1, 1, 1, 0.22), 7.0, true)

## Daga clavada: solo asoma el mango (la hoja está dentro del tronco).
func _draw_stuck(d: Dagger) -> void:
	var s := surface
	var wa := d.ang + _rot
	var dir := Vector2.from_angle(wa)
	var col := Color(0.62, 0.64, 0.7)
	var p := _player_by_id(d.owner_id)
	if p != null:
		col = p.color
	var wob := (1.0 - d.pop) * 10.0           # rebote al clavarse
	var base := CENTER + dir * (LOG_R - 6.0 + wob)
	s.draw_set_transform(base + _cur_shake, wa, Vector2.ONE)
	s.draw_rect(Rect2(2, -5, 56, 10), Color(0.12, 0.08, 0.2))                  # contorno del mango
	s.draw_rect(Rect2(4, -3.5, 52, 7), col)
	s.draw_rect(Rect2(0, -13, 8, 26), Color(0.85, 0.85, 0.9))                  # guarda
	s.draw_circle(Vector2(60, 0), 6.0, Color(0.12, 0.08, 0.2))
	s.draw_circle(Vector2(60, 0), 4.5, col.lightened(0.25))
	s.draw_set_transform(_cur_shake, 0.0, Vector2.ONE)

## Hoja + mango apuntando en la dirección `rot` (0 = hacia la derecha) con la punta en `pos`.
func _draw_dagger_shape(pos: Vector2, rot: float, col: Color, scale: float, blade_first: bool) -> void:
	var s := surface
	s.draw_set_transform(pos + _cur_shake, rot, Vector2.ONE * scale)
	var blade := PackedVector2Array([Vector2(0, 0), Vector2(-26, -8), Vector2(-62, -6), Vector2(-62, 6), Vector2(-26, 8)])
	s.draw_colored_polygon(blade, Color(0.86, 0.9, 0.96))
	s.draw_polyline(PackedVector2Array([blade[0], blade[1], blade[2], blade[3], blade[4], blade[0]]), Color(0.12, 0.08, 0.2), 3.0, true)
	s.draw_line(Vector2(-6, 0), Vector2(-58, 0), Color(0.6, 0.66, 0.78), 2.0)
	s.draw_rect(Rect2(-68, -14, 8, 28), Color(0.85, 0.85, 0.9))
	s.draw_rect(Rect2(-112, -5, 46, 10), Color(0.12, 0.08, 0.2))
	s.draw_rect(Rect2(-110, -3.5, 42, 7), col)
	s.draw_circle(Vector2(-114, 0), 6.0, Color(0.12, 0.08, 0.2))
	s.draw_circle(Vector2(-114, 0), 4.5, col.lightened(0.25))
	s.draw_set_transform(_cur_shake, 0.0, Vector2.ONE)

func _draw_flying_and_pending() -> void:
	var cur := _player_by_id(_cur_id)
	if cur == null or _phase == Phase.OVER:
		return
	var col: Color = cur.color
	if _phase == Phase.WAIT or _phase == Phase.READY:
		var bob := sin(_time * 6.0) * 4.0
		_draw_dagger_shape(START_POS + Vector2(0, bob), -PI * 0.5, col, 1.0, true)
	elif _phase == Phase.FLY:
		var k := clampf(_fly_t / FLIGHT, 0.0, 1.0)
		var target := CENTER + Vector2(0, LOG_R - 4.0)
		_draw_dagger_shape(START_POS.lerp(target, k), -PI * 0.5, col, 1.0, true)

func _draw_hud() -> void:
	var s := surface
	var n := players.size()
	var x0 := 640.0 - (n - 1) * 46.0
	# Fila de jugadores: el actual, grande y con su cuenta atrás; los eliminados, apagados con ✕.
	for i in n:
		var p := players[i]
		var c := Vector2(x0 + i * 92.0, 58.0)
		var alive := _is_alive(p.id)
		var cur := p.id == _cur_id and _phase != Phase.OVER
		var r := 27.0 if cur else 21.0
		var col: Color = p.color if alive else p.color.darkened(0.7)
		if cur and alive:
			s.draw_circle(c, r + 11.0, Color(1, 0.8, 0.15, 0.35))
			if _phase == Phase.WAIT:
				var frac := clampf(_turn_left / TURN_TIME, 0.0, 1.0)
				var ac := Palette.YELLOW if frac > 0.33 else Palette.CORAL
				s.draw_arc(c, r + 8.0, -PI * 0.5, -PI * 0.5 + TAU * frac, 32, ac, 5.0, true)
		AvatarPainter.paint(s, c, r, col)
		if not alive:
			s.draw_line(c + Vector2(-9, -9), c + Vector2(9, 9), Palette.WHITE, 4.0)
			s.draw_line(c + Vector2(-9, 9), c + Vector2(9, -9), Palette.WHITE, 4.0)
		if is_local_player(p) and NetworkManager.is_online:
			draw_local_marker(c + Vector2(0, -2), r)
		s.text_centered(c + Vector2(0, r + 15.0), p.display_name, 16, Palette.WHITE if alive else Color(1, 1, 1, 0.5), 4)
	s.text_centered(Vector2(1150, 44), "DAGAS %d" % _daggers.size(), 28, Palette.WHITE, 6)
	s.text_centered(Vector2(130, 44), "VIVOS %d" % _alive_count(), 28, Palette.WHITE, 6)
	# Quién tira y qué hacer.
	var cur_p := _player_by_id(_cur_id)
	if cur_p != null and (_phase == Phase.WAIT or _phase == Phase.READY):
		s.text_centered(Vector2(900, 600), cur_p.display_name, 44, cur_p.color.lightened(0.3), 9)
		var hint := "¡Pulsa para lanzar!" if is_audible(cur_p) else "Su turno..."
		s.text_centered(Vector2(900, 648), hint, 28, Color(1, 1, 1, 0.85), 6)
	if _banner_t > 0.0 and _banner != "" and _phase != Phase.OVER:
		s.text_centered(Vector2(640, 552), _banner, 46, Color(1, 1, 1, clampf(_banner_t / 0.4, 0.0, 1.0)), 10)
	if _phase == Phase.OVER and _winner_id >= 0:
		var w := _player_by_id(_winner_id)
		s.text_centered(Vector2(640, 322), "¡%s GANA!" % (w.display_name.to_upper() if w != null else ""), 84, Palette.YELLOW, 14)
		if w != null:
			AvatarPainter.paint_crown(s, Vector2(640, 520), 40.0)
			AvatarPainter.paint(s, Vector2(640, 540), 40.0, w.color)
