extends Minigame
## Lluvia de monedas: recoge todas las monedas que puedas en 30 segundos.
## Las monedas naranjas valen 3. La acción da un sprint corto.
## Gana quien más puntos tenga (desempate: quien los consiguió antes).

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

class Coin:
	var pos: Vector2
	var value: int = 1
	var age: float = 0.0

class Token:
	var player: PlayerData
	var pos: Vector2
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

func _on_prepare() -> void:
	var n := players.size()
	for i in n:
		var t := Token.new()
		t.player = players[i]
		var angle := TAU * i / n
		t.pos = ARENA.get_center() + Vector2.from_angle(angle) * 180.0
		_tokens.append(t)
		_scores[t.player.id] = 0
		_last_gain[t.player.id] = 0.0
	# Unas monedas iniciales para arrancar con acción.
	for i in 4 + n:
		_spawn_coin()
	surface.draw_callback = _draw_game
	surface.queue_redraw()

func _on_start() -> void:
	_time_left = DURATION

func _process(delta: float) -> void:
	delta = minf(delta, 0.05)
	for pop in _popups:
		pop.age += delta
	_popups = _popups.filter(func(p: ScorePopup) -> bool: return p.age < 0.8)
	for c in _coins:
		c.age += delta
	if is_running:
		_elapsed += delta
		_time_left -= delta
		_update_players(delta)
		_update_coins(delta)
		if _time_left <= 0.0:
			_time_left = 0.0
			finish(rank_by_score(_scores, _last_gain))
	surface.queue_redraw()

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
	# Recogida.
	for t in _tokens:
		for c in _coins.duplicate():
			if t.pos.distance_to(c.pos) < PLAYER_RADIUS + COIN_RADIUS:
				_coins.erase(c)
				_scores[t.player.id] += c.value
				_last_gain[t.player.id] = _elapsed
				var pop := ScorePopup.new()
				pop.pos = c.pos
				pop.text = "+%d" % c.value
				pop.color = Palette.YELLOW if c.value == 1 else Color("FF9F43")
				_popups.append(pop)
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

func _bot_action(_player: PlayerData) -> bool:
	return randf() < 0.004   # sprint ocasional

func _token_of(player: PlayerData) -> Token:
	for t in _tokens:
		if t.player == player:
			return t
	return null

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
