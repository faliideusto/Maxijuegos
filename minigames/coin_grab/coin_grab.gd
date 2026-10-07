extends Minigame
## Lluvia de monedas: recoge todas las monedas que puedas en 30 segundos.
## Las monedas naranjas valen 3. La acción da un sprint corto.
## Gana quien más puntos tenga (desempate: quien los consiguió antes).
##
## Sin lógica de red: el host simula (_simulate) y los clientes dibujan el estado que
## reciben (_apply_state); las monedas recogidas llegan como eventos. Ver core/minigame.gd.

const DURATION := 30.0
const ARENA := Rect2(90, 130, 1100, 540)
const PLAYER_RADIUS := 24.0
const SPEED := 330.0
const SPRINT_MULT := 1.8
const SPRINT_TIME := 0.35
const SPRINT_COOLDOWN := 1.6
const COIN_RADIUS := 16.0
const COIN_LIFETIME := 9.0
const SPAWN_EVERY := 0.45
const GOLD_CHANCE := 0.14
const SMOOTHING := 18.0        # (clientes) suavizado de la posición mostrada
const FLOATS_PER_TOKEN := 8    # x, y, vx, vy, fx, fy, sprint_t, sprint_cd
const FLOATS_PER_COIN := 4     # x, y, valor, edad

class Coin:
	var pos: Vector2
	var value: int = 1
	var age: float = 0.0

class Token:
	var player: PlayerData
	var pos: Vector2            # posición mostrada
	var net_pos: Vector2        # (clientes) última posición real recibida
	var vel: Vector2 = Vector2.ZERO
	var facing: Vector2 = Vector2.DOWN
	var sprint_t: float = 0.0
	var sprint_cd: float = 0.0
	var bot_target: Vector2 = Vector2.ZERO
	var bot_retarget: float = 0.0

class ScorePopup:
	var pos: Vector2
	var text: String
	var color: Color
	var age: float = 0.0

var _tokens: Array[Token] = []
var _coins: Array[Coin] = []
var _popups: Array[ScorePopup] = []
var _scores: Dictionary = {}
var _last_gain: Dictionary = {}   # id -> instante del último punto (desempate)
var _time_left: float = DURATION
var _elapsed: float = 0.0
var _spawn_timer: float = 0.0
var _got_state: bool = false

func _on_prepare() -> void:
	var n := players.size()
	for i in n:
		var t := Token.new()
		t.player = players[i]
		var angle := TAU * i / n
		t.pos = ARENA.get_center() + Vector2.from_angle(angle) * 180.0
		t.net_pos = t.pos
		_tokens.append(t)
		_scores[t.player.id] = 0
		_last_gain[t.player.id] = 0.0
	surface.draw_callback = _draw_game

func _on_start() -> void:
	_time_left = DURATION
	# Unas monedas iniciales para arrancar con acción (solo el host las crea).
	if is_authority:
		for i in 4 + players.size():
			_spawn_coin()

# ----------------------------------------------------------------------------
# Simulación (solo host)
# ----------------------------------------------------------------------------

func _simulate(delta: float) -> void:
	_elapsed += delta
	_time_left -= delta
	_update_players(delta)
	_update_coins(delta)
	if _time_left <= 0.0:
		_time_left = 0.0
		finish(rank_by_score(_scores, _last_gain))

func _update_players(delta: float) -> void:
	for t in _tokens:
		var dir := move_input(t.player)
		if dir.length() > 0.2:
			t.facing = dir.normalized()
		t.sprint_cd = maxf(0.0, t.sprint_cd - delta)
		t.sprint_t = maxf(0.0, t.sprint_t - delta)
		if t.sprint_cd <= 0.0 and action_just_pressed(t.player):
			t.sprint_t = SPRINT_TIME
			t.sprint_cd = SPRINT_COOLDOWN
		var speed := SPEED * (SPRINT_MULT if t.sprint_t > 0.0 else 1.0)
		# Aceleración suave hacia la velocidad deseada.
		t.vel = t.vel.lerp(dir * speed, clampf(delta * 12.0, 0.0, 1.0))
		t.pos += t.vel * delta
		var inner := ARENA.grow(-PLAYER_RADIUS)
		t.pos = t.pos.clamp(inner.position, inner.end)

func _update_coins(delta: float) -> void:
	for c in _coins:
		c.age += delta
	# Recogida.
	for t in _tokens:
		for c in _coins.duplicate():
			if t.pos.distance_to(c.pos) < PLAYER_RADIUS + COIN_RADIUS:
				_coins.erase(c)
				_scores[t.player.id] += c.value
				_last_gain[t.player.id] = _elapsed
				send_event("collect", [c.pos.x, c.pos.y, c.value])
	# Caducidad y aparición.
	_coins = _coins.filter(func(c: Coin) -> bool: return c.age < COIN_LIFETIME)
	_spawn_timer -= delta
	var max_coins := 6 + players.size()
	if _spawn_timer <= 0.0 and _coins.size() < max_coins:
		_spawn_timer = SPAWN_EVERY
		_spawn_coin()

func _spawn_coin() -> void:
	var c := Coin.new()
	var inner := ARENA.grow(-40.0)
	c.pos = Vector2(randf_range(inner.position.x, inner.end.x), randf_range(inner.position.y, inner.end.y))
	c.value = 3 if randf() < GOLD_CHANCE else 1
	_coins.append(c)

# --- Bots: van a la moneda "más rentable" (valor / distancia) ---
func _bot_move(player: PlayerData) -> Vector2:
	var t := _token_of(player)
	if t == null:
		return Vector2.ZERO
	t.bot_retarget -= get_process_delta_time()
	if t.bot_retarget <= 0.0:
		t.bot_retarget = randf_range(0.25, 0.6)
		var best := -1.0
		t.bot_target = ARENA.get_center()
		for c in _coins:
			var score := float(c.value) / (t.pos.distance_to(c.pos) + 40.0)
			if score > best:
				best = score
				t.bot_target = c.pos
	var to_target := t.bot_target - t.pos
	return to_target.normalized() if to_target.length() > 6.0 else Vector2.ZERO

func _bot_action(_player: PlayerData) -> int:
	return 1 if randf() < 0.004 else 0   # sprint ocasional

func _token_of(player: PlayerData) -> Token:
	for t in _tokens:
		if t.player == player:
			return t
	return null

# ----------------------------------------------------------------------------
# Estado hacia los clientes
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var scores := PackedInt32Array()
	var toks := PackedFloat32Array()
	for t in _tokens:
		scores.append(_scores[t.player.id])
		toks.append_array(PackedFloat32Array([t.pos.x, t.pos.y, t.vel.x, t.vel.y,
				t.facing.x, t.facing.y, t.sprint_t, t.sprint_cd]))
	var coins := PackedFloat32Array()
	for c in _coins:
		coins.append_array(PackedFloat32Array([c.pos.x, c.pos.y, float(c.value), c.age]))
	return {"t": _time_left, "s": scores, "k": toks, "c": coins}

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	_time_left = float(state.get("t", _time_left))
	var scores: Variant = state.get("s")
	if scores is PackedInt32Array:
		for i in mini(scores.size(), _tokens.size()):
			_scores[_tokens[i].player.id] = scores[i]
	var toks: Variant = state.get("k")
	if toks is PackedFloat32Array and toks.size() >= _tokens.size() * FLOATS_PER_TOKEN:
		for i in _tokens.size():
			var t := _tokens[i]
			var o := i * FLOATS_PER_TOKEN
			t.net_pos = Vector2(toks[o], toks[o + 1])
			t.vel = Vector2(toks[o + 2], toks[o + 3])
			t.facing = Vector2(toks[o + 4], toks[o + 5])
			t.sprint_t = toks[o + 6]
			t.sprint_cd = toks[o + 7]
			if not _got_state:
				t.pos = t.net_pos
		_got_state = true
	var coins: Variant = state.get("c")
	if coins is PackedFloat32Array:
		_coins.clear()
		var coin_count: int = coins.size() / FLOATS_PER_COIN
		for i in coin_count:
			var o: int = i * FLOATS_PER_COIN
			var c := Coin.new()
			c.pos = Vector2(coins[o], coins[o + 1])
			c.value = int(coins[o + 2])
			c.age = coins[o + 3]
			_coins.append(c)

func _on_event(event_name: String, data: Variant) -> void:
	if event_name == "collect" and data is Array and data.size() >= 3:
		var pop := ScorePopup.new()
		pop.pos = Vector2(float(data[0]), float(data[1]))
		var value := int(data[2])
		pop.text = "+%d" % value
		pop.color = Palette.YELLOW if value == 1 else Color("FF9F43")
		_popups.append(pop)

# ----------------------------------------------------------------------------
# Animación (todos los PC)
# ----------------------------------------------------------------------------

func _animate(delta: float) -> void:
	for pop in _popups:
		pop.age += delta
	_popups = _popups.filter(func(p: ScorePopup) -> bool: return p.age < 0.8)
	if not is_authority:
		for c in _coins:
			c.age += delta
		var k := 1.0 - exp(-SMOOTHING * delta)
		for t in _tokens:
			t.net_pos += t.vel * delta   # extrapolación corta entre snapshots
			t.net_pos = t.net_pos.clamp(ARENA.grow(-PLAYER_RADIUS).position, ARENA.grow(-PLAYER_RADIUS).end)
			t.pos = t.pos.lerp(t.net_pos, k)

# ----------------------------------------------------------------------------
# Dibujo
# ----------------------------------------------------------------------------

func _draw_game() -> void:
	var s := surface
	# Suelo de la arena.
	s.rounded_rect(Rect2(ARENA.position + Vector2(0, 8), ARENA.size).grow(8), 36, Color(0, 0, 0, 0.25))
	s.rounded_rect(ARENA.grow(8), 36, Palette.PURPLE_DARK)
	s.rounded_rect(ARENA, 30, Palette.CARD_LIGHT.darkened(0.04))
	# Monedas.
	for c in _coins:
		var pop := minf(c.age / 0.2, 1.0)
		var remaining := COIN_LIFETIME - c.age
		if remaining < 2.0 and int(remaining * 6.0) % 2 == 0:
			continue   # parpadeo antes de desaparecer
		var color := Palette.YELLOW if c.value == 1 else Color("FF9F43")
		var r := COIN_RADIUS * (1.0 if c.value == 1 else 1.3) * pop
		var bob := sin(c.age * 5.0) * 3.0
		var center := c.pos + Vector2(0, bob)
		s.draw_circle(center + Vector2(0, 5), r, Color(0, 0, 0, 0.2))
		s.draw_circle(center, r, color.darkened(0.25))
		s.draw_circle(center, r * 0.82, color)
		s.draw_circle(center + Vector2(-r * 0.25, -r * 0.3), r * 0.22, Color(1, 1, 1, 0.6))
	# Jugadores.
	for t in _tokens:
		var squash := 1.0 + (0.12 if t.sprint_t > 0.0 else 0.0)
		s.draw_set_transform(t.pos, 0.0, Vector2(squash, 2.0 - squash))
		AvatarPainter.paint(s, Vector2.ZERO, PLAYER_RADIUS, t.player.color, t.facing)
		s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		if is_local_player(t.player):
			draw_local_marker(t.pos, PLAYER_RADIUS)
	# Textos flotantes "+N".
	for pop in _popups:
		var k := pop.age / 0.8
		s.text_centered(pop.pos + Vector2(0, -20.0 - 40.0 * k), pop.text, 32, pop.color.lerp(Color.WHITE, 0.2), 8)
	_draw_hud()

func _draw_hud() -> void:
	var s := surface
	s.text_centered(Vector2(640, 62), "%.0f" % ceilf(_time_left), 64, Palette.YELLOW, 12)
	# Puntuaciones repartidas a ambos lados del reloj (mitad izquierda, mitad derecha).
	var n := _tokens.size()
	var left_n := ceili(n / 2.0)
	var right_n := n - left_n
	for i in n:
		var t := _tokens[i]
		var x: float
		if i < left_n:
			x = 110.0 + i * 120.0
		else:
			x = 1120.0 - (right_n - 1 - (i - left_n)) * 120.0
		var c := Vector2(x, 56.0)
		AvatarPainter.paint(s, c, 24.0, t.player.color)
		s.text_centered(c + Vector2(48, 0), str(_scores[t.player.id]), 40, Palette.WHITE, 8)
