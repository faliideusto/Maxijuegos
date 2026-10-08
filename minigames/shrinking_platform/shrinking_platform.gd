extends Minigame
## Plataforma menguante: la plataforma se encoge poco a poco. Empuja a los demás
## (acción = embestida) y no te caigas. El último en pie gana.
##
## Sin lógica de red: el host simula (_simulate) y los clientes dibujan el estado que
## reciben (_apply_state) suavizando las posiciones. Ver core/minigame.gd.

const CENTER := Vector2(640, 390)
const START_RADIUS := 300.0
const GRACE_TIME := 3.0        # segundos antes de empezar a encogerse
const SHRINK_TIME := 45.0      # segundos hasta desaparecer del todo
const PLAYER_RADIUS := 26.0
const ACCEL := 1250.0
const DRAG := 3.0
const DASH_SPEED := 760.0
const DASH_COOLDOWN := 1.4
const FALL_DURATION := 0.8
const MAX_TIME := 70.0         # seguridad: si llegamos aquí se desempata por cercanía al centro
const SMOOTHING := 18.0        # (clientes) rapidez con la que la posición mostrada sigue a la real
const FLOATS_PER_TOKEN := 8    # x, y, vx, vy, fx, fy, vivo, recarga

class Token:
	var player: PlayerData
	var pos: Vector2            # posición mostrada
	var net_pos: Vector2        # (clientes) última posición real recibida
	var vel: Vector2 = Vector2.ZERO
	var facing: Vector2 = Vector2.DOWN
	var alive: bool = true
	var fall_t: float = 0.0
	var dash_cd: float = 0.0
	var dash_flash: float = 0.0
	var fall_sounded: bool = false
	var splashed: bool = false

var _tokens: Array[Token] = []
var _elim_order: Array[int] = []   # ids en orden de caída (primero = peor)
var _time: float = 0.0
var _end_timer: float = -1.0
var _got_state: bool = false
var _bump_cd: float = 0.0
var _creak_t: float = 3.0

func _on_prepare() -> void:
	var n := players.size()
	for i in n:
		var t := Token.new()
		t.player = players[i]
		var angle := TAU * i / n - PI * 0.5
		t.pos = CENTER + Vector2.from_angle(angle) * START_RADIUS * 0.6
		t.net_pos = t.pos
		t.facing = (CENTER - t.pos).normalized()
		_tokens.append(t)
	surface.draw_callback = _draw_game

func _current_radius() -> float:
	var k := clampf((_time - GRACE_TIME) / SHRINK_TIME, 0.0, 1.0)
	return START_RADIUS * (1.0 - k)

# ----------------------------------------------------------------------------
# Simulación (solo host)
# ----------------------------------------------------------------------------

func _simulate(delta: float) -> void:
	_time += delta
	_bump_cd = maxf(0.0, _bump_cd - delta)
	var radius := _current_radius()
	var alive: Array[Token] = []
	for t in _tokens:
		if t.alive:
			alive.append(t)
	# Entrada y movimiento.
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
	# Choques entre jugadores (rebote elástico con un extra de empujón).
	for i in alive.size():
		for j in range(i + 1, alive.size()):
			_collide(alive[i], alive[j])
	# Caídas: se evalúan todas a la vez para ordenar bien los empates del mismo frame.
	var fallen: Array[Token] = []
	for t in alive:
		if t.pos.distance_to(CENTER) > radius + PLAYER_RADIUS * 0.35:
			fallen.append(t)
	fallen.sort_custom(func(a: Token, b: Token) -> bool:
		return a.pos.distance_to(CENTER) > b.pos.distance_to(CENTER))  # el más lejos, peor
	for t in fallen:
		t.alive = false
		_elim_order.append(t.player.id)
		t.vel *= 0.3
	# Fin de partida: queda ≤ 1 vivo (o tiempo de seguridad), tras una breve pausa.
	var remaining := 0
	for t in _tokens:
		if t.alive:
			remaining += 1
	if _end_timer < 0.0 and (remaining <= 1 or _time >= MAX_TIME):
		_end_timer = 1.3
	if _end_timer >= 0.0:
		_end_timer -= delta
		if _end_timer < 0.0:
			finish(_build_ranking())

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
		var impulse := -(1.0 + 0.9) * rel * 0.5 + 60.0
		a.vel -= n * impulse
		b.vel += n * impulse

func _build_ranking() -> Array[int]:
	var ranking: Array[int] = []
	var survivors: Array[Token] = []
	for t in _tokens:
		if t.alive:
			survivors.append(t)
	# Supervivientes (si el tiempo de seguridad saltó): el más cercano al centro, mejor.
	survivors.sort_custom(func(a: Token, b: Token) -> bool:
		return a.pos.distance_to(CENTER) < b.pos.distance_to(CENTER))
	for t in survivors:
		ranking.append(t.player.id)
	var fell_last_first := _elim_order.duplicate()
	fell_last_first.reverse()
	for id in fell_last_first:
		ranking.append(id)
	return ranking

# --- Bots: vuelven al centro y, si están seguros, embisten al rival más cercano ---
func _bot_move(player: PlayerData) -> Vector2:
	var t := _token_of(player)
	if t == null or not t.alive:
		return Vector2.ZERO
	var to_center := CENTER - t.pos
	var radius := _current_radius()
	var safe := radius * 0.55
	var dir := Vector2.ZERO
	if to_center.length() > safe:
		dir = to_center.normalized()
	else:
		var target := _nearest_enemy(t)
		if target != null:
			dir = (target.pos - t.pos).normalized() * 0.7
	# Un poco de ruido para que no sean perfectos.
	return (dir + Vector2.from_angle(randf() * TAU) * 0.25).limit_length(1.0)

func _bot_action(player: PlayerData) -> int:
	var t := _token_of(player)
	if t == null or not t.alive or t.dash_cd > 0.0:
		return 0
	var target := _nearest_enemy(t)
	if target == null:
		return 0
	# Embiste si el rival está cerca y el bot no está al borde.
	var near := t.pos.distance_to(target.pos) < 150.0
	var inside := t.pos.distance_to(CENTER) < _current_radius() * 0.6
	return 1 if (near and inside and randf() < 0.08) else 0

func _token_of(player: PlayerData) -> Token:
	for t in _tokens:
		if t.player == player:
			return t
	return null

func _nearest_enemy(me: Token) -> Token:
	var best: Token = null
	var best_d := INF
	for t in _tokens:
		if t == me or not t.alive:
			continue
		var d := me.pos.distance_to(t.pos)
		if d < best_d:
			best_d = d
			best = t
	return best

# ----------------------------------------------------------------------------
# Estado hacia los clientes
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var data := PackedFloat32Array()
	for t in _tokens:
		data.append_array(PackedFloat32Array([t.pos.x, t.pos.y, t.vel.x, t.vel.y,
				t.facing.x, t.facing.y, 1.0 if t.alive else 0.0, t.dash_cd]))
	return {"t": _time, "k": data}

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	_time = float(state.get("t", _time))
	var data: Variant = state.get("k")
	if not data is PackedFloat32Array or data.size() < _tokens.size() * FLOATS_PER_TOKEN:
		return
	for i in _tokens.size():
		var t := _tokens[i]
		var o := i * FLOATS_PER_TOKEN
		t.net_pos = Vector2(data[o], data[o + 1])
		t.vel = Vector2(data[o + 2], data[o + 3])
		t.facing = Vector2(data[o + 4], data[o + 5])
		t.alive = data[o + 6] > 0.5
		t.dash_cd = data[o + 7]
		if not _got_state:
			t.pos = t.net_pos
	_got_state = true

func _on_event(event_name: String, data: Variant) -> void:
	if event_name == "dash" and typeof(data) == TYPE_INT and data >= 0 and data < _tokens.size():
		_tokens[data].dash_flash = 1.0
		Audio.sfx(&"dash", -4.0 if is_audible(_tokens[data].player) else -13.0)
	elif event_name == "bump":
		Audio.sfx(&"thud", -5.0)

# ----------------------------------------------------------------------------
# Animación (todos los PC)
# ----------------------------------------------------------------------------

func _animate(delta: float) -> void:
	# Crujidos de la plataforma mientras mengua.
	if is_running and _time > GRACE_TIME:
		_creak_t -= delta
		if _creak_t <= 0.0:
			_creak_t = 3.5
			Audio.sfx(&"plat_crack", -10.0)
	for t in _tokens:
		if not t.alive:
			if not t.fall_sounded:
				t.fall_sounded = true
				Audio.sfx(&"plat_fall", -3.0 if is_audible(t.player) else -9.0)
			t.fall_t = minf(t.fall_t + delta, FALL_DURATION)
			if t.fall_t >= FALL_DURATION and not t.splashed:
				t.splashed = true
				Audio.sfx(&"splash", -6.0 if is_audible(t.player) else -14.0)
		t.dash_flash = maxf(0.0, t.dash_flash - delta * 3.0)
	if not is_authority:
		# Cliente: el tiempo avanza entre snapshots y la posición sigue suavemente a la real.
		if is_running:
			_time += delta
		var k := 1.0 - exp(-SMOOTHING * delta)
		for t in _tokens:
			t.net_pos += t.vel * delta   # extrapolación corta entre snapshots
			t.pos = t.pos.lerp(t.net_pos, k)

# ----------------------------------------------------------------------------
# Dibujo
# ----------------------------------------------------------------------------

func _draw_game() -> void:
	var s := surface
	var radius := _current_radius()
	# Plataforma: sombra, borde (grosor) y cara; se tiñe de coral cuando queda poco.
	var danger := clampf(1.0 - radius / START_RADIUS, 0.0, 1.0)
	var face := Palette.CARD_LIGHT.lerp(Palette.CORAL, danger * 0.6)
	if radius > 1.0:
		s.draw_circle(CENTER + Vector2(0, 26), radius, Color(0, 0, 0, 0.25))
		s.draw_circle(CENTER + Vector2(0, 18), radius, face.darkened(0.35))
		s.draw_circle(CENTER, radius, face)
		s.draw_arc(CENTER, radius * 0.66, 0.0, TAU, 64, face.darkened(0.08), 6.0, true)
		s.draw_arc(CENTER, radius * 0.33, 0.0, TAU, 48, face.darkened(0.08), 6.0, true)
	# Jugadores: primero los caídos (debajo), luego los vivos.
	for t in _tokens:
		if not t.alive:
			_draw_token(t)
	for t in _tokens:
		if t.alive:
			_draw_token(t)
	_draw_hud()

func _draw_token(t: Token) -> void:
	var s := surface
	var scale_f := 1.0
	var offset := Vector2.ZERO
	if not t.alive:
		var k := t.fall_t / FALL_DURATION
		scale_f = maxf(0.0, 1.0 - k)
		offset = Vector2(0, k * 90.0)
		if scale_f <= 0.01:
			return
	# Estela de la embestida.
	if t.dash_flash > 0.0:
		s.draw_circle(t.pos - t.facing * 22.0, PLAYER_RADIUS * (0.9 + t.dash_flash * 0.2), Color(1, 1, 1, 0.25 * t.dash_flash))
	s.draw_set_transform(t.pos + offset, 0.0, Vector2(scale_f, scale_f))
	AvatarPainter.paint(s, Vector2.ZERO, PLAYER_RADIUS, t.player.color, t.facing)
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if t.alive and is_local_player(t.player):
		draw_local_marker(t.pos, PLAYER_RADIUS)

func _draw_hud() -> void:
	var s := surface
	# Fila de avatares arriba: los eliminados se atenúan con una cruz.
	var n := _tokens.size()
	var x0 := 640.0 - (n - 1) * 30.0
	for i in n:
		var t := _tokens[i]
		var c := Vector2(x0 + i * 60.0, 54.0)
		if t.alive:
			AvatarPainter.paint(s, c, 22.0, t.player.color)
		else:
			s.draw_circle(c, 22.0, Color(0, 0, 0, 0.3))
			s.draw_line(c + Vector2(-12, -12), c + Vector2(12, 12), Palette.CORAL, 5.0, true)
			s.draw_line(c + Vector2(12, -12), c + Vector2(-12, 12), Palette.CORAL, 5.0, true)
	# Indicador de recarga de embestida bajo el jugador local (o bajo todos los humanos en local).
	for t in _tokens:
		if t.alive and not t.player.is_bot and not t.player.is_remote:
			var ready := 1.0 - t.dash_cd / DASH_COOLDOWN
			var w := 44.0
			var p := t.pos + Vector2(-w * 0.5, PLAYER_RADIUS + 12.0)
			s.draw_rect(Rect2(p, Vector2(w, 6)), Color(0, 0, 0, 0.3))
			s.draw_rect(Rect2(p, Vector2(w * ready, 6)), Palette.YELLOW if ready >= 1.0 else Color(1, 1, 1, 0.6))
