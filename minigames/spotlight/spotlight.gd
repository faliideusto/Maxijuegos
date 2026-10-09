extends Minigame
## Caza del Foco (modelo HOST_AUTHORITATIVE): sillas musicales con luces. Hay UN FOCO MENOS que jugadores
## y los focos se mueven por la pista cada vez más rápido. Entra en un foco LIBRE para quedártelo (mientras
## sigas dentro es tuyo; nadie más puede reclamarlo: si entras en uno ocupado, sale una ✕ roja) y no te salgas: cuando acaba la ronda, quien se queda sin
## foco queda ELIMINADO y desaparece un foco. Se repite hasta que solo queda uno: gana, y el ranking sigue el
## orden de eliminación (último eliminado = 2.º...).
##
## Controles: moverse (WASD / flechas / mando) y la acción da un EMPUJÓN (impulso corto con enfriamiento):
## sirve para alcanzar un foco que se escapa o para sacar a un rival de su foco.
##
## Dificultad (por ronda): los focos van más rápido (hasta ×2,2), son más pequeños y la ronda dura menos.
## La ronda termina antes si todos los focos están ocupados durante un segundo.
##
## Sin código de red propio: el host simula (_simulate) y los clientes dibujan el estado que reciben
## (_apply_state, a ~30 Hz, con suavizado y extrapolación) y los eventos (round / claim / unclaim / lock /
## win / dash / bump). Los bots persiguen el foco libre más cercano con algo de torpeza. Ver core/minigame.gd.

enum Phase { READY, PLAY, LOCK, OVER }

const ARENA := Rect2(80, 112, 1120, 510)
const PLAYER_RADIUS := 22.0
const ACCEL := 2100.0
const DRAG := 4.6                    # velocidad máxima ≈ ACCEL / DRAG ≈ 456 px/s
const DASH_SPEED := 650.0
const DASH_COOLDOWN := 1.3
const SPOT_R0 := 62.0                # un foco es poco más ancho que un jugador (radio 22): cabe uno solo
const SPOT_R_MIN := 42.0
const SPOT_R_STEP := 3.0
const SPOT_SPEED0 := 190.0
const SPOT_SPEED_STEP := 26.0
const SPOT_SPEED_MAX := 390.0        # siempre por debajo de lo que corre un jugador: se puede seguir un foco
const ROUND_TIME0 := 10.0
const ROUND_TIME_MIN := 5.5
const ROUND_TIME_STEP := 0.8
const READY_TIME := 1.0               # los focos aparecen y aún no se pueden reclamar
const LOCK_TIME := 2.4
const OVER_TIME := 3.4
const FULL_HOLD := 1.0                # focos todos ocupados este tiempo = fin anticipado de la ronda
const RELEASE_GRACE := 0.3            # s fuera del foco antes de perderlo
const SMOOTHING := 18.0
const FLOATS_PER_TOKEN := 7           # x, y, vx, vy, vivo, enfriamiento del empujón, foco (+1)
const FLOATS_PER_SPOT := 5            # x, y, vx, vy, dueño (id + 1)

class Token:
	var player: PlayerData
	var pos: Vector2
	var net_pos: Vector2
	var vel: Vector2 = Vector2.ZERO
	var facing: Vector2 = Vector2.DOWN
	var alive: bool = true
	var dash_cd: float = 0.0
	var dash_flash: float = 0.0
	var spot: int = -1                 # foco que tiene (-1 = ninguno)
	var out_t: float = 0.0             # animación de eliminado
	var bot_target: Vector2 = Vector2.ZERO
	var bot_retarget: float = 0.0
	var bot_skill: float = 1.0

class Spot:
	var pos: Vector2
	var net_pos: Vector2
	var vel: Vector2 = Vector2.ZERO
	var owner_id: int = -1             # id del jugador que lo tiene (-1 = libre)
	var grace: float = 0.0             # (host) tiempo que el dueño lleva fuera
	var ang: float = 0.0
	var freq: float = 1.0
	var phase: float = 0.0

var _tokens: Array[Token] = []
var _spots: Array[Spot] = []
var _phase: Phase = Phase.READY
var _round: int = 0
var _time_left: float = ROUND_TIME0
var _round_total: float = ROUND_TIME0
var _radius: float = SPOT_R0
var _speed: float = SPOT_SPEED0
var _ready_t: float = READY_TIME
var _lock_t: float = 0.0
var _over_t: float = 0.0
var _full_t: float = 0.0
var _elapsed: float = 0.0
var _bump_cd: float = 0.0
var _dt: float = 0.016                # delta del último _simulate (lo usan los bots)
var _elim_order: Array[int] = []      # ids por orden de eliminación (primero = peor)
var _winner_id: int = -1
var _got_state: bool = false
# Solo visual
var _banner: String = ""
var _banner_t: float = 0.0
var _out_names: String = ""
var _last_sec: int = 99
var _time: float = 0.0
var _flash: float = 0.0
var _particles: Array = []            # {pos, vel, life, color}

# ----------------------------------------------------------------------------
# Preparación
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	var n := players.size()
	for i in n:
		var t := Token.new()
		t.player = players[i]
		t.bot_skill = randf_range(0.8, 1.0)
		var a := TAU * float(i) / float(n)
		t.pos = ARENA.get_center() + Vector2.from_angle(a) * 230.0
		t.net_pos = t.pos
		_tokens.append(t)
	surface.draw_callback = _draw_game

func _on_start() -> void:
	if is_authority:
		_round = 0
		_start_round()

# ----------------------------------------------------------------------------
# Simulación (solo host)
# ----------------------------------------------------------------------------

func _alive_count() -> int:
	var n := 0
	for t in _tokens:
		if t.alive:
			n += 1
	return n

func _token_of(player: PlayerData) -> Token:
	for t in _tokens:
		if t.player == player:
			return t
	return null

func _token_by_id(id: int) -> Token:
	for t in _tokens:
		if t.player.id == id:
			return t
	return null

## Parámetros de la ronda r (1, 2, 3...).
static func radius_for(r: int) -> float:
	return maxf(SPOT_R_MIN, SPOT_R0 - SPOT_R_STEP * float(r - 1))

static func speed_for(r: int) -> float:
	return minf(SPOT_SPEED0 + SPOT_SPEED_STEP * float(r - 1), SPOT_SPEED_MAX)

static func time_for(r: int) -> float:
	return maxf(ROUND_TIME_MIN, ROUND_TIME0 - ROUND_TIME_STEP * float(r - 1))

func _start_round() -> void:
	_round += 1
	var alive := _alive_count()
	var k := maxi(alive - 1, 1)               # un foco menos que jugadores vivos
	_radius = radius_for(_round)
	_speed = speed_for(_round)
	_round_total = time_for(_round)
	_time_left = _round_total
	_ready_t = READY_TIME
	_full_t = 0.0
	_phase = Phase.READY
	_spots.clear()
	var inner := ARENA.grow(-_radius)
	for i in k:
		var s := Spot.new()
		s.pos = Vector2(randf_range(inner.position.x, inner.end.x), randf_range(inner.position.y, inner.end.y))
		s.net_pos = s.pos
		s.ang = randf() * TAU
		s.freq = randf_range(0.6, 1.6)
		s.phase = randf() * TAU
		s.vel = Vector2.from_angle(s.ang) * _speed
		_spots.append(s)
	for t in _tokens:
		t.spot = -1
	DevCli.log_event("spot round=%d alive=%d spots=%d speed=%.0f radius=%.0f" % [_round, alive, k, _speed, _radius])
	send_event("round", {"r": _round, "k": k})

func _simulate(delta: float) -> void:
	_dt = delta
	_elapsed += delta
	_bump_cd = maxf(0.0, _bump_cd - delta)
	match _phase:
		Phase.READY:
			_update_players(delta)
			_update_spots(delta)
			_ready_t -= delta
			if _ready_t <= 0.0:
				_phase = Phase.PLAY
		Phase.PLAY:
			_time_left -= delta
			_update_players(delta)
			_update_spots(delta)
			_update_claims(delta)
			if _all_spots_taken():
				_full_t += delta
			else:
				_full_t = 0.0
			if _time_left <= 0.0 or _full_t >= FULL_HOLD:
				_time_left = maxf(_time_left, 0.0)
				_lock_round()
		Phase.LOCK:
			_update_players(delta)
			_lock_t -= delta
			if _lock_t <= 0.0:
				_after_lock()
		Phase.OVER:
			_update_players(delta)
			_over_t -= delta
			if _over_t <= 0.0:
				finish(_build_ranking())

func _all_spots_taken() -> bool:
	for s in _spots:
		if s.owner_id < 0:
			return false
	return not _spots.is_empty()

func _update_players(delta: float) -> void:
	var alive: Array[Token] = []
	for t in _tokens:
		if t.alive:
			alive.append(t)
		t.dash_flash = maxf(0.0, t.dash_flash - delta * 3.0)
	for t in alive:
		var dir := move_input(t.player)
		if dir.length() > 0.2:
			t.facing = dir.normalized()
		t.vel += dir * ACCEL * delta
		t.vel *= exp(-DRAG * delta)
		t.dash_cd = maxf(0.0, t.dash_cd - delta)
		if t.dash_cd <= 0.0 and action_just_pressed(t.player):
			t.vel += t.facing * DASH_SPEED
			t.dash_cd = DASH_COOLDOWN
			send_event("dash", _tokens.find(t))
		t.pos += t.vel * delta
		var inner := ARENA.grow(-PLAYER_RADIUS)
		t.pos = t.pos.clamp(inner.position, inner.end)
	for i in alive.size():
		for j in range(i + 1, alive.size()):
			_collide(alive[i], alive[j])

## Choque elástico con un extra de empujón: así se saca a un rival de su foco.
func _collide(a: Token, b: Token) -> void:
	var d := b.pos - a.pos
	var dist := d.length()
	var min_dist := PLAYER_RADIUS * 2.0
	if dist >= min_dist:
		return
	var n := d / dist if dist > 0.001 else Vector2.RIGHT
	var overlap := min_dist - dist
	a.pos -= n * overlap * 0.5
	b.pos += n * overlap * 0.5
	var rel := (b.vel - a.vel).dot(n)
	if rel < 0.0:
		if _bump_cd <= 0.0:
			_bump_cd = 0.15
			send_event("bump", null)
		var impulse := -(1.0 + 0.9) * rel * 0.5 + 70.0
		a.vel -= n * impulse
		b.vel += n * impulse

## Los focos vagan con trayectorias curvas y rebotan en los bordes; se apartan un poco entre sí.
func _update_spots(delta: float) -> void:
	var inner := ARENA.grow(-_radius)
	for s in _spots:
		s.ang += sin(_elapsed * s.freq + s.phase) * 2.4 * delta
		s.vel = Vector2.from_angle(s.ang) * _speed
		s.pos += s.vel * delta
		if s.pos.x < inner.position.x:
			s.pos.x = inner.position.x
			s.ang = PI - s.ang
		elif s.pos.x > inner.end.x:
			s.pos.x = inner.end.x
			s.ang = PI - s.ang
		if s.pos.y < inner.position.y:
			s.pos.y = inner.position.y
			s.ang = -s.ang
		elif s.pos.y > inner.end.y:
			s.pos.y = inner.end.y
			s.ang = -s.ang
	for i in _spots.size():
		for j in range(i + 1, _spots.size()):
			var d := _spots[j].pos - _spots[i].pos
			var dist := d.length()
			if dist < _radius * 1.6 and dist > 0.001:
				var push := d / dist * (_radius * 1.6 - dist) * 0.5
				_spots[i].pos -= push
				_spots[j].pos += push

## Reclamar y soltar focos. Un foco libre es de quien entra primero (el más cercano si coinciden); lo
## conserva mientras siga dentro (con RELEASE_GRACE de margen) y nadie más puede quitárselo.
func _update_claims(delta: float) -> void:
	for si in _spots.size():
		var s := _spots[si]
		if s.owner_id >= 0:
			var o := _token_by_id(s.owner_id)
			if o != null and o.alive and o.pos.distance_to(s.pos) < _radius - 4.0:
				s.grace = 0.0
			else:
				s.grace += delta
				if s.grace > RELEASE_GRACE:
					if o != null:
						o.spot = -1
					send_event("unclaim", {"p": s.owner_id})
					s.owner_id = -1
					s.grace = 0.0
		if s.owner_id < 0:
			var best: Token = null
			var best_d := INF
			for t in _tokens:
				if not t.alive or t.spot >= 0:
					continue
				var d := t.pos.distance_to(s.pos)
				if d < _radius - 6.0 and d < best_d:
					best_d = d
					best = t
			if best != null:
				s.owner_id = best.player.id
				s.grace = 0.0
				best.spot = si
				send_event("claim", {"p": best.player.id})

func _lock_round() -> void:
	_phase = Phase.LOCK
	_lock_t = LOCK_TIME
	for s in _spots:
		s.vel = Vector2.ZERO
	var losers: Array[Token] = []
	for t in _tokens:
		if t.alive and t.spot < 0:
			losers.append(t)
	# Si por lo que sea nadie tiene foco, se salva el más cercano a alguno (siempre queda un superviviente).
	if losers.size() >= _alive_count():
		var keep: Token = null
		var keep_d := INF
		for t in losers:
			var d := _dist_to_nearest_spot(t)
			if d < keep_d:
				keep_d = d
				keep = t
		losers.erase(keep)
	# Los más lejos de un foco caen antes (peor puesto).
	losers.sort_custom(func(a: Token, b: Token) -> bool: return _dist_to_nearest_spot(a) > _dist_to_nearest_spot(b))
	var out_ids: Array[int] = []
	for t in losers:
		t.alive = false
		t.vel *= 0.3
		_elim_order.append(t.player.id)
		out_ids.append(t.player.id)
	DevCli.log_event("spot lock round=%d out=%s left=%d" % [_round, out_ids, _alive_count()])
	send_event("lock", {"out": out_ids, "left": _alive_count()})

func _dist_to_nearest_spot(t: Token) -> float:
	var best := INF
	for s in _spots:
		best = minf(best, t.pos.distance_to(s.pos))
	return best

func _after_lock() -> void:
	if _alive_count() <= 1:
		_phase = Phase.OVER
		_over_t = OVER_TIME
		for t in _tokens:
			if t.alive:
				_winner_id = t.player.id
		DevCli.log_event("spot win id=%d rounds=%d" % [_winner_id, _round])
		send_event("win", {"id": _winner_id})
	else:
		_start_round()

## Ranking: el superviviente primero y luego los eliminados del último al primero.
func _build_ranking() -> Array[int]:
	var ranking: Array[int] = []
	for t in _tokens:
		if t.alive:
			ranking.append(t.player.id)
	for i in range(_elim_order.size() - 1, -1, -1):
		ranking.append(_elim_order[i])
	return ranking

# --- Bots: van al foco libre (o suyo) más cercano, con algo de torpeza ---
func _bot_move(player: PlayerData) -> Vector2:
	var t := _token_of(player)
	if t == null or not t.alive or _spots.is_empty():
		return Vector2.ZERO
	t.bot_retarget -= _dt
	if t.bot_retarget <= 0.0:
		t.bot_retarget = randf_range(0.2, 0.5)
		var best := INF
		var target := ARENA.get_center()
		for si in _spots.size():
			var s := _spots[si]
			if s.owner_id >= 0 and s.owner_id != player.id:
				continue
			var d := t.pos.distance_to(s.pos)
			if d < best:
				best = d
				target = s.pos + s.vel * 0.25 + Vector2(randf_range(-14.0, 14.0), randf_range(-14.0, 14.0))
		t.bot_target = target
	var to_target := t.bot_target - t.pos
	if to_target.length() < 5.0:
		return Vector2.ZERO
	return to_target.normalized() * t.bot_skill

func _bot_action(player: PlayerData) -> int:
	var t := _token_of(player)
	if t == null or not t.alive or t.spot >= 0:
		return 0
	# Se lanza cuando el foco está lejos (o, a veces, para estorbar).
	return 1 if t.pos.distance_to(t.bot_target) > 170.0 and randf() < 0.06 else 0

# ----------------------------------------------------------------------------
# Estado hacia los clientes
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var toks := PackedFloat32Array()
	for t in _tokens:
		toks.append_array(PackedFloat32Array([t.pos.x, t.pos.y, t.vel.x, t.vel.y,
				1.0 if t.alive else 0.0, t.dash_cd, float(t.spot + 1)]))
	var spots := PackedFloat32Array()
	for s in _spots:
		spots.append_array(PackedFloat32Array([s.pos.x, s.pos.y, s.vel.x, s.vel.y, float(s.owner_id + 1)]))
	return {"ph": int(_phase), "t": _time_left, "tt": _round_total, "r": _round, "rad": _radius, "k": toks, "s": spots}

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	var st: Dictionary = state
	_phase = int(st.get("ph", _phase)) as Phase
	_time_left = float(st.get("t", _time_left))
	_round_total = float(st.get("tt", _round_total))
	_round = int(st.get("r", _round))
	_radius = float(st.get("rad", _radius))
	var toks: Variant = st.get("k")
	if toks is PackedFloat32Array and toks.size() >= _tokens.size() * FLOATS_PER_TOKEN:
		for i in _tokens.size():
			var t := _tokens[i]
			var o := i * FLOATS_PER_TOKEN
			t.net_pos = Vector2(toks[o], toks[o + 1])
			t.vel = Vector2(toks[o + 2], toks[o + 3])
			t.alive = toks[o + 4] > 0.5
			t.dash_cd = toks[o + 5]
			t.spot = int(toks[o + 6]) - 1
			if not _got_state:
				t.pos = t.net_pos
		_got_state = true
	var sp: Variant = st.get("s")
	if sp is PackedFloat32Array:
		var n: int = sp.size() / FLOATS_PER_SPOT
		while _spots.size() > n:
			_spots.pop_back()
		while _spots.size() < n:
			var ns := Spot.new()
			ns.pos = ARENA.get_center()
			ns.net_pos = ns.pos
			_spots.append(ns)
		for i in n:
			var s := _spots[i]
			var o := i * FLOATS_PER_SPOT
			s.net_pos = Vector2(sp[o], sp[o + 1])
			s.vel = Vector2(sp[o + 2], sp[o + 3])
			s.owner_id = int(sp[o + 4]) - 1

func _on_event(event_name: String, data: Variant) -> void:
	match event_name:
		"round":
			Audio.sfx(&"swoosh", -5.0)
			_banner = "RONDA %d" % int((data as Dictionary).get("r", 0))
			_banner_t = 1.2
			_flash = 0.35
			for t in _tokens:
				t.dash_flash = 0.0
		"claim":
			var t := _token_by_id(int((data as Dictionary).get("p", -1)))
			var mine := t != null and is_audible(t.player)
			Audio.sfx(&"claim", -2.0 if mine else -15.0)
			if t != null:
				for i in 8:
					_spawn_particle(t.pos, t.player.color)
		"unclaim":
			var t2 := _token_by_id(int((data as Dictionary).get("p", -1)))
			if t2 != null and is_audible(t2.player):
				Audio.sfx(&"unclaim", -4.0)
		"lock":
			var d: Dictionary = data
			Audio.sfx(&"lock", -2.0)
			_flash = 0.8
			var names: PackedStringArray = []
			for id in d.get("out", []):
				var o: Token = _token_by_id(int(id))
				if o != null:
					o.alive = false
					o.out_t = 0.0
					names.append(o.player.display_name)
					Audio.sfx(&"crash", -6.0 if is_audible(o.player) else -12.0)
					for i in 16:
						_spawn_particle(o.pos, o.player.color)
			_out_names = ", ".join(names)
			_banner = "¡SIN FOCO!"
			_banner_t = LOCK_TIME
		"win":
			_winner_id = int((data as Dictionary).get("id", -1))
			_banner = ""
		"dash":
			if typeof(data) == TYPE_INT and data >= 0 and data < _tokens.size():
				_tokens[data].dash_flash = 1.0
				Audio.sfx(&"dash", -5.0 if is_audible(_tokens[data].player) else -14.0)
		"bump":
			Audio.sfx(&"thud", -8.0)

func _spawn_particle(pos: Vector2, color: Color) -> void:
	_particles.append({"pos": pos, "vel": Vector2.from_angle(randf() * TAU) * randf_range(60.0, 260.0), "life": randf_range(0.4, 0.9), "color": color})

# ----------------------------------------------------------------------------
# Animación (todos los PC)
# ----------------------------------------------------------------------------

func _animate(delta: float) -> void:
	_time += delta
	_flash = maxf(0.0, _flash - delta * 2.0)
	_banner_t = maxf(0.0, _banner_t - delta)
	# Pitidos en los 3 últimos segundos de cada ronda.
	var sec := ceili(_time_left)
	if is_running and _phase == Phase.PLAY and sec != _last_sec and sec <= 3 and sec > 0:
		Audio.sfx(&"beep", -6.0)
	_last_sec = sec
	for t in _tokens:
		t.dash_flash = maxf(0.0, t.dash_flash - delta * 3.0)
		if not t.alive:
			t.out_t = minf(t.out_t + delta, 2.0)
	if not is_authority:
		var k := 1.0 - exp(-SMOOTHING * delta)
		var inner := ARENA.grow(-PLAYER_RADIUS)
		for t in _tokens:
			t.net_pos += t.vel * delta
			t.net_pos = t.net_pos.clamp(inner.position, inner.end)
			t.pos = t.pos.lerp(t.net_pos, k)
		for s in _spots:
			s.net_pos += s.vel * delta
			s.pos = s.pos.lerp(s.net_pos, k)
	for p in _particles:
		p.pos += p.vel * delta
		p.vel *= (1.0 - 2.5 * delta)
		p.life -= delta
	_particles = _particles.filter(func(x: Dictionary) -> bool: return x.life > 0.0)

# ----------------------------------------------------------------------------
# Dibujo
# ----------------------------------------------------------------------------

func _draw_game() -> void:
	var s := surface
	# Escenario oscuro con rejilla tenue y borde luminoso.
	s.rounded_rect(Rect2(ARENA.position + Vector2(0, 8), ARENA.size).grow(10), 34, Color(0, 0, 0, 0.35))
	s.rounded_rect(ARENA.grow(10), 34, Color("FFC81E").darkened(0.35))
	s.rounded_rect(ARENA.grow(6), 30, Color(0.04, 0.03, 0.12))
	s.rounded_rect(ARENA, 28, Color(0.07, 0.055, 0.19))
	var gx := ARENA.position.x + 40.0
	while gx < ARENA.end.x - 20.0:
		s.draw_line(Vector2(gx, ARENA.position.y + 14), Vector2(gx, ARENA.end.y - 14), Color(1, 1, 1, 0.035), 2.0)
		gx += 80.0
	var gy := ARENA.position.y + 40.0
	while gy < ARENA.end.y - 20.0:
		s.draw_line(Vector2(ARENA.position.x + 14, gy), Vector2(ARENA.end.x - 14, gy), Color(1, 1, 1, 0.035), 2.0)
		gy += 80.0
	_draw_spots()
	_draw_tokens()
	for p in _particles:
		var a := clampf(p.life / 0.9, 0.0, 1.0)
		s.draw_circle(p.pos, 5.0 * a + 1.0, Color(p.color.r, p.color.g, p.color.b, a))
	_draw_hud()
	if _flash > 0.0:
		s.draw_rect(Rect2(0, 0, 1280, 720), Color(1, 1, 1, clampf(_flash, 0.0, 1.0) * 0.35))

func _draw_spots() -> void:
	var s := surface
	var grow := 1.0
	if _phase == Phase.READY:
		grow = clampf(1.0 - _ready_t / READY_TIME, 0.0, 1.0) if is_authority else 1.0
	for sp in _spots:
		var r := _radius * (0.3 + 0.7 * grow)
		var owner_col := Color(1.0, 0.92, 0.55)
		var owned := sp.owner_id >= 0
		if owned:
			var o := _token_by_id(sp.owner_id)
			if o != null:
				owner_col = o.player.color.lightened(0.25)
		# Resplandor y charco de luz (más intenso al ocuparse).
		for k in 5:
			s.draw_circle(sp.pos, r * (1.5 - 0.12 * k), Color(owner_col.r, owner_col.g, owner_col.b, 0.045 + 0.02 * k))
		s.draw_circle(sp.pos, r, Color(1.0, 0.97, 0.8, 0.30 if not owned else 0.18))
		s.draw_circle(sp.pos, r * 0.78, Color(1.0, 0.98, 0.85, 0.20))
		var pulse := 0.5 + 0.5 * sin(_time * (7.0 if _phase == Phase.LOCK else 4.0))
		s.draw_arc(sp.pos, r, 0.0, TAU, 48, Color(owner_col.r, owner_col.g, owner_col.b, 0.75 + 0.25 * pulse), 6.0, true)
		s.draw_arc(sp.pos, r + 8.0, 0.0, TAU, 48, Color(owner_col.r, owner_col.g, owner_col.b, 0.25), 3.0, true)

func _in_any_spot(t: Token) -> bool:
	for sp in _spots:
		if t.pos.distance_to(sp.pos) < _radius:
			return true
	return false

## ¿Está el jugador dentro de un foco que tiene otro dueño?
func _inside_taken_spot(t: Token) -> bool:
	for sp in _spots:
		if sp.owner_id >= 0 and sp.owner_id != t.player.id and t.pos.distance_to(sp.pos) < _radius:
			return true
	return false

func _draw_tokens() -> void:
	var s := surface
	for t in _tokens:
		if not t.alive and t.out_t >= 1.2:
			continue
		var scale := 1.0
		var col: Color = t.player.color
		var radius := PLAYER_RADIUS
		var lit := _in_any_spot(t) or _phase == Phase.READY
		if not t.alive:
			scale = clampf(1.0 - t.out_t / 1.2, 0.0, 1.0)
			col = col.darkened(0.6)
		elif not lit and _phase == Phase.PLAY:
			col = col.darkened(0.35)     # fuera de la luz te ves apagado
		# Sombra, avatar con squash del empujón y nombre.
		s.draw_circle(t.pos + Vector2(0, 8), radius * scale, Color(0, 0, 0, 0.3))
		var sq := Vector2(1.0 + 0.2 * t.dash_flash, 1.0 - 0.2 * t.dash_flash) * scale
		s.draw_set_transform(t.pos, 0.0, sq)
		AvatarPainter.paint(s, Vector2.ZERO, radius, col, t.facing)
		if not t.alive:
			for side in [-1.0, 1.0]:
				var e: Vector2 = Vector2(side * radius * 0.33, -radius * 0.08)
				s.draw_line(e + Vector2(-5, -5), e + Vector2(5, 5), Palette.WHITE, 3.0)
				s.draw_line(e + Vector2(-5, 5), e + Vector2(5, -5), Palette.WHITE, 3.0)
		s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		if t.alive:
			# Estás dentro de un foco que ya es de otro: aviso rojo para que busques uno libre.
			if _phase == Phase.PLAY and t.spot < 0 and _inside_taken_spot(t):
				s.draw_circle(t.pos + Vector2(0, -radius - 20.0), 13.0, Palette.PURPLE_DARK)
				s.draw_circle(t.pos + Vector2(0, -radius - 20.0), 11.0, Palette.CORAL)
				s.text_centered(t.pos + Vector2(0, -radius - 20.0), "✕", 17, Palette.WHITE, 0)
			if is_local_player(t.player):
				draw_local_marker(t.pos, radius)
			s.text_centered(t.pos + Vector2(0, radius + 16.0), t.player.display_name, 18, Palette.WHITE, 5)
			if t.spot >= 0:
				s.draw_arc(t.pos, radius + 7.0, 0.0, TAU, 24, Color(1, 0.95, 0.5, 0.9), 4.0, true)
	# Ganador con corona.
	if _phase == Phase.OVER and _winner_id >= 0:
		var w := _token_by_id(_winner_id)
		if w != null:
			AvatarPainter.paint_crown(s, w.pos, PLAYER_RADIUS)

func _draw_hud() -> void:
	var s := surface
	var alive := _alive_count_visual()
	s.text_centered(Vector2(640, 36), "RONDA %d" % maxi(_round, 1), 38, Palette.WHITE, 8)
	# Barra de tiempo de la ronda: amarilla, y roja y parpadeante en los 3 últimos segundos.
	var bar := Rect2(390, 68, 500, 20)
	s.rounded_rect(bar.grow(4), 14, Color(0, 0, 0, 0.45))
	var frac := clampf(_time_left / maxf(_round_total, 0.1), 0.0, 1.0)
	if _phase != Phase.PLAY and _phase != Phase.READY:
		frac = 0.0
	var urgent := _phase == Phase.PLAY and _time_left <= 3.0
	var col := Palette.YELLOW
	if urgent:
		col = Palette.CORAL.lerp(Color.WHITE, 0.5 + 0.5 * sin(_time * 18.0) * 0.5)
	if frac > 0.0:
		s.rounded_rect(Rect2(bar.position, Vector2(maxf(bar.size.x * frac, 18.0), bar.size.y)), 10, col)
	s.text_centered(Vector2(150, 44), "VIVOS %d" % alive, 28, Palette.WHITE, 6)
	s.text_centered(Vector2(1130, 44), "FOCOS %d" % _spots.size(), 28, Palette.YELLOW, 6)
	# Tira de jugadores (los eliminados, apagados).
	var n := _tokens.size()
	var x0 := 640.0 - (n - 1) * 30.0
	for i in n:
		var t := _tokens[i]
		var c: Color = t.player.color if t.alive else t.player.color.darkened(0.7)
		AvatarPainter.paint(s, Vector2(x0 + i * 60.0, 668.0), 17.0, c)
		if not t.alive:
			var e := Vector2(x0 + i * 60.0, 668.0)
			s.draw_line(e + Vector2(-8, -8), e + Vector2(8, 8), Palette.WHITE, 3.0)
			s.draw_line(e + Vector2(-8, 8), e + Vector2(8, -8), Palette.WHITE, 3.0)
	# Avisos centrales.
	if _phase == Phase.OVER and _winner_id >= 0:
		var w := _token_by_id(_winner_id)
		s.text_centered(Vector2(640, 300), "¡%s GANA!" % (w.player.display_name if w != null else ""), 84, Palette.YELLOW, 14)
	elif _phase == Phase.LOCK:
		s.text_centered(Vector2(640, 158), "¡SIN FOCO!", 64, Palette.CORAL, 12)
		if _out_names != "":
			s.text_centered(Vector2(640, 212), "Fuera: %s" % _out_names, 32, Palette.WHITE, 7)
	elif _phase == Phase.READY:
		s.text_centered(Vector2(640, 158), "¡A POR UN FOCO!", 54, Color(1, 1, 1, 0.92), 10)
	elif _banner_t > 0.0 and _banner != "":
		s.text_centered(Vector2(640, 158), _banner, 54, Color(1, 1, 1, clampf(_banner_t / 0.4, 0.0, 1.0)), 10)

func _alive_count_visual() -> int:
	return _alive_count()
