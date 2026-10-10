extends Minigame
## Plumas al Vuelo (modelo HOST_AUTHORITATIVE). Basado en el minijuego de las plumas de Wii Party: un prado con el
## cielo azul y plumas que caen meciéndose. Cada jugador maneja una MANO (con su color y su número) que vuela por
## toda la pantalla y, con la acción, se cierra para atrapar la pluma que tenga debajo.
##
## Plumas: rosa +1 (las normales), dorada +3 (escasas, más rápidas y con más vaivén) y marrón -3 (sucias: no hay que
## cogerlas). Los puntos no bajan de 0. Cada mano atrapa como mucho una pluma por cierre y luego tarda un momento en
## poder volver a cerrarse; si dos manos cierran a la vez sobre la misma pluma, se la lleva una al azar. Las plumas
## que llegan al suelo se pierden. Dura 30 s; gana quien más puntos suma (a igualdad, quien los consiguió antes).
##
## Controles: stick / WASD / flechas mueven la mano y la acción la cierra. Con el ratón: la mano sigue al puntero y el
## clic la cierra (el clic ya es la acción del jugador del ratón).
##
## Se adapta al nº de jugadores: caen más plumas a la vez cuantos más jugadores hay, las manos empiezan repartidas y
## el marcador de abajo reparte el ancho entre todos.
##
## Sin código de red propio: el host simula (_simulate); los clientes dibujan el estado (manos, plumas, puntos) y el
## evento `catch` (pluma atrapada). La posición del ratón llega al host por el canal de texto del minijuego
## (submit_text("m:<x>,<y>"), no fiable; en partida local, sin dueño = el jugador del ratón).

enum Kind { PINK, GOLD, BROWN }

const DURATION := 30.0
const VALUES := [1, 3, -3]                 # por Kind
const PLAY_AREA := Rect2(24, 24, 1232, 600)   # por donde se mueve la mano
const GROUND_Y := 628.0                    # las plumas que bajan de aquí se pierden
const HAND_SPEED := 720.0
const HAND_ACCEL := 14.0
const MOUSE_SPEED := 3200.0
const MOUSE_HOLD := 1.0                    # s que manda el ratón tras moverlo (si el stick no se toca)
const GRAB_RADIUS := 46.0
const GRAB_SHOW := 0.22                    # s que la mano se ve cerrada
const GRAB_COOLDOWN := 0.34
const GOLD_CHANCE := 0.1
const BROWN_CHANCE := 0.18
const MAX_GOLD := 2
const BOT_SPEED := 0.78                    # los bots mueven la mano algo más despacio que una persona
const SMOOTHING := 18.0                    # (clientes) suavizado de lo mostrado
const FLOATS_PER_HAND := 5                 # x, y, vx, vy, grab_t
const FLOATS_PER_FEATHER := 7              # id, x, y, vx, vy, rot, kind
const MOUSE_SEND_EVERY := 1.0 / 30.0

class Feather:
	var id: int = 0
	var kind: int = Kind.PINK
	var origin: Vector2              # (host) punto de partida
	var drift: float = 0.0           # (host) deriva horizontal (px/s)
	var fall: float = 60.0           # (host) velocidad de caída media (px/s)
	var amp: float = 60.0            # (host) amplitud del vaivén
	var freq: float = 1.2            # (host) rad/s del vaivén
	var phase: float = 0.0
	var t: float = 0.0               # s desde que salió
	var pos: Vector2
	var net_pos: Vector2             # (clientes) última posición recibida
	var vel: Vector2 = Vector2.ZERO
	var rot: float = 0.0
	var age: float = 0.0             # (visual) para la aparición

class Hand:
	var player: PlayerData
	var pos: Vector2
	var net_pos: Vector2
	var vel: Vector2 = Vector2.ZERO
	var grab_t: float = 0.0          # > 0 mientras se ve cerrada
	var cool: float = 0.0            # (host) s hasta poder cerrarse otra vez
	var mouse_target: Vector2
	var mouse_t: float = 0.0         # (host) s que le quedan al control por ratón
	var bot_target: int = -1         # (host) id de la pluma a la que va el bot
	var bot_retarget: float = 0.0
	var bot_delay: float = 0.0       # (host) reacción antes de cerrar

var _hands: Array[Hand] = []
var _feathers: Array[Feather] = []
var _scores: Dictionary = {}          # id -> puntos
var _last_gain: Dictionary = {}       # id -> instante del último punto (desempate)
var _time_left: float = DURATION
var _elapsed: float = 0.0
var _spawn_timer: float = 0.0
var _next_feather_id: int = 1
var _rng := RandomNumberGenerator.new()      # (host) plumas
var _bot_rng := RandomNumberGenerator.new()  # (host) bots
var _got_state: bool = false
var _dt: float = 1.0 / 60.0             # (host) delta del frame simulado (lo usan los bots)
# Solo visual
var _time: float = 0.0
var _last_sec: int = 99
var _popups: Array = []               # {"pos", "text", "color", "age"}
var _sparks: Array = []               # {"pos", "vel", "color", "age"}
var _gain: Dictionary = {}            # id -> {"v": puntos, "age": s} para el +N del marcador
var _prev_grab: Dictionary = {}       # id -> grab_t del frame anterior (sonido al cerrar)
var _clouds: Array = []               # [Vector2 base, escala, velocidad]
var _flowers: Array = []              # [Vector2, color, radio]
var _mouse_send: float = 0.0
var _mouse_dirty: bool = false
var _mouse_pos: Vector2 = Vector2.ZERO
var _mouse_hidden: bool = false

# ----------------------------------------------------------------------------
# Preparación
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	var n := players.size()
	for i in n:
		var h := Hand.new()
		h.player = players[i]
		h.pos = start_pos(i, n)
		h.net_pos = h.pos
		h.mouse_target = h.pos
		_hands.append(h)
		_scores[h.player.id] = 0
		_last_gain[h.player.id] = 0.0
		_prev_grab[h.player.id] = 0.0
	_rng.seed = hash([seed_value, "feathers"])
	_bot_rng.seed = hash([seed_value, "bots"])
	# Decorado (igual en todos los PC: semilla fija).
	var deco := RandomNumberGenerator.new()
	deco.seed = 7
	for i in 6:
		_clouds.append([Vector2(deco.randf_range(0, 1280), deco.randf_range(60, 380)), deco.randf_range(0.7, 1.3),
				deco.randf_range(6.0, 16.0)])
	var flower_colors := [Color("FF7AC6"), Color("FFFFFF"), Color("E8365D"), Color("FFD23F"), Color("FFB3D9")]
	for i in 90:
		_flowers.append([Vector2(deco.randf_range(0, 1280), deco.randf_range(612, 720)),
				flower_colors[deco.randi() % flower_colors.size()], deco.randf_range(4.0, 9.0)])
	_flowers.sort_custom(func(a: Array, b: Array) -> bool: return a[0].y < b[0].y)
	surface.draw_callback = _draw_game
	ended.connect(_restore_mouse)

func _on_start() -> void:
	_time_left = DURATION
	_elapsed = 0.0
	if is_authority:
		# Unas plumas ya en el aire para arrancar con acción.
		for i in 4 + players.size():
			_spawn_feather(_rng.randf_range(60.0, 420.0))
	if not demo and _mouse_player() != null and not InputManager.is_simulated(_mouse_player().id) \
			and DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN   # la mano hace de puntero
		_mouse_hidden = true
	DevCli.log_event("feather_catch start players=%d" % players.size())

func _exit_tree() -> void:
	_restore_mouse()

func _restore_mouse() -> void:
	if _mouse_hidden:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_mouse_hidden = false

## Posición inicial de la mano del jugador i de n: repartidas a lo ancho, a media altura.
static func start_pos(i: int, n: int) -> Vector2:
	var x := PLAY_AREA.position.x + PLAY_AREA.size.x * (i + 0.5) / float(maxi(n, 1))
	return Vector2(x, 330.0 + (40.0 if i % 2 == 1 else -40.0))

## Cuántas plumas puede haber a la vez en el aire con n jugadores.
static func max_feathers(n: int) -> int:
	return 6 + 2 * n

## Marrones como mucho a la vez (como nadie las coge, sin tope acabarían llenando el cielo).
static func max_browns(n: int) -> int:
	return 2 + int(n / 3.0)

## Cada cuánto sale una pluma con n jugadores.
static func spawn_interval(n: int) -> float:
	return 1.0 / (1.0 + 0.6 * n)

# ----------------------------------------------------------------------------
# Simulación (solo host)
# ----------------------------------------------------------------------------

func _simulate(delta: float) -> void:
	_dt = delta
	_elapsed += delta
	_time_left -= delta
	_update_feathers(delta)
	_update_hands(delta)
	if _time_left <= 0.0:
		_time_left = 0.0
		DevCli.log_event("feather_catch end scores=%s" % str(_scores))
		finish(build_ranking())

func _update_feathers(delta: float) -> void:
	for f in _feathers:
		f.t += delta
		_move_feather(f)
	_feathers = _feathers.filter(func(f: Feather) -> bool:
		return f.pos.y < GROUND_Y and f.pos.x > -90.0 and f.pos.x < 1370.0)
	_spawn_timer -= delta
	if _spawn_timer <= 0.0 and _feathers.size() < max_feathers(players.size()):
		_spawn_timer = spawn_interval(players.size()) * _rng.randf_range(0.7, 1.3)
		_spawn_feather()

## Posición, velocidad e inclinación de la pluma en su instante f.t: cae a ritmo irregular y se mece de lado a lado,
## inclinándose hacia donde va (como una hoja).
func _move_feather(f: Feather) -> void:
	var w := f.freq * f.t + f.phase
	var x := f.origin.x + f.drift * f.t + f.amp * sin(w)
	var y := f.origin.y + f.fall * f.t + f.fall * 0.35 / maxf(f.freq * 2.0, 0.1) * (1.0 - cos(2.0 * w))
	var vx := f.drift + f.amp * f.freq * cos(w)
	var vy := f.fall + f.fall * 0.35 * sin(2.0 * w)
	f.pos = Vector2(x, y)
	f.vel = Vector2(vx, vy)
	f.rot = clampf(vx / 220.0, -1.1, 1.1) + (f.t * 2.4 if f.kind == Kind.BROWN else 0.0)

func _spawn_feather(at_y: float = -40.0) -> Feather:
	var f := Feather.new()
	f.id = _next_feather_id
	_next_feather_id += 1
	var golds := 0
	var browns := 0
	for o in _feathers:
		if o.kind == Kind.GOLD:
			golds += 1
		elif o.kind == Kind.BROWN:
			browns += 1
	var r := _rng.randf()
	if r < GOLD_CHANCE and golds < MAX_GOLD:
		f.kind = Kind.GOLD
	elif r < GOLD_CHANCE + BROWN_CHANCE and browns < max_browns(players.size()):
		f.kind = Kind.BROWN
	f.phase = _rng.randf_range(0.0, TAU)
	match f.kind:
		Kind.GOLD:
			f.fall = _rng.randf_range(95.0, 130.0)
			f.amp = _rng.randf_range(80.0, 130.0)
			f.freq = _rng.randf_range(1.8, 2.6)
		Kind.BROWN:
			f.fall = _rng.randf_range(70.0, 100.0)
			f.amp = _rng.randf_range(30.0, 60.0)
			f.freq = _rng.randf_range(1.0, 1.6)
		_:
			f.fall = _rng.randf_range(50.0, 80.0)
			f.amp = _rng.randf_range(40.0, 90.0)
			f.freq = _rng.randf_range(0.9, 1.6)
	if at_y < 0.0 and _rng.randf() < 0.25:
		# Entra por un lado, empujada por el viento.
		var left := _rng.randf() < 0.5
		f.origin = Vector2(-30.0 if left else 1310.0, _rng.randf_range(40.0, 300.0))
		f.drift = _rng.randf_range(70.0, 120.0) * (1.0 if left else -1.0)
	else:
		f.origin = Vector2(_rng.randf_range(80.0, 1200.0), at_y)
		f.drift = _rng.randf_range(-25.0, 25.0)
	# Que el vaivén empiece en el punto de partida.
	f.origin.x -= f.amp * sin(f.phase)
	_move_feather(f)
	f.net_pos = f.pos
	_feathers.append(f)
	return f

func _update_hands(delta: float) -> void:
	# Orden al azar cada frame: si dos manos cierran a la vez sobre la misma pluma, gana una cualquiera.
	var order := _hands.duplicate()
	for i in range(order.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp = order[i]
		order[i] = order[j]
		order[j] = tmp
	for h: Hand in order:
		var dir := move_input(h.player)
		h.mouse_t = maxf(0.0, h.mouse_t - delta)
		if dir.length() > 0.2:
			h.mouse_t = 0.0
		if h.mouse_t > 0.0:
			var before := h.pos
			h.pos = h.pos.move_toward(h.mouse_target, MOUSE_SPEED * delta)
			h.vel = (h.pos - before) / maxf(delta, 0.001)
		else:
			h.vel = h.vel.lerp(dir * HAND_SPEED, clampf(delta * HAND_ACCEL, 0.0, 1.0))
			h.pos += h.vel * delta
		var clamped := h.pos.clamp(PLAY_AREA.position, PLAY_AREA.end)
		if clamped != h.pos:
			h.pos = clamped
		h.grab_t = maxf(0.0, h.grab_t - delta)
		h.cool = maxf(0.0, h.cool - delta)
		if action_presses(h.player) > 0:
			try_grab(h)

## (host) La mano se cierra (si puede) y atrapa la pluma más cercana que tenga debajo. Devuelve la pluma o null.
func try_grab(h: Hand) -> Feather:
	if h.cool > 0.0 or not is_running:
		return null
	h.grab_t = GRAB_SHOW
	h.cool = GRAB_COOLDOWN
	var best: Feather = null
	var best_d := GRAB_RADIUS
	for f in _feathers:
		var d := h.pos.distance_to(f.pos)
		if d <= best_d:
			best_d = d
			best = f
	if best == null:
		return null
	_feathers.erase(best)
	var before: int = _scores[h.player.id]
	_scores[h.player.id] = maxi(0, before + int(VALUES[best.kind]))
	if VALUES[best.kind] > 0:
		_last_gain[h.player.id] = _elapsed
	send_event("catch", {"x": best.pos.x, "y": best.pos.y, "k": best.kind, "p": h.player.id,
			"v": int(_scores[h.player.id]) - before})
	return best

## Más puntos primero; a igualdad, quien llegó antes a su puntuación.
func build_ranking() -> Array[int]:
	return rank_by_score(_scores, _last_gain)

## Ratón de un jugador (cualquier PC): "m:<x>,<y>" lleva su mano a ese punto.
func _on_player_text(player: PlayerData, text: String, _final: bool) -> void:
	if not text.begins_with("m:"):
		return
	var parts := text.substr(2).split(",")
	if parts.size() != 2 or not parts[0].is_valid_float() or not parts[1].is_valid_float():
		return
	if player == null:
		player = _mouse_player()
	var h := _hand_of(player)
	if h == null or InputManager.is_simulated(player.id):
		return
	var p := Vector2(parts[0].to_float(), parts[1].to_float())
	if not p.is_finite():
		return
	h.mouse_target = p.clamp(PLAY_AREA.position, PLAY_AREA.end)
	h.mouse_t = MOUSE_HOLD

# --- Bots y autopiloto: van a por la pluma que más compensa (sin marrones) y la cogen al llegar ---

func _bot_move(player: PlayerData) -> Vector2:
	var h := _hand_of(player)
	if h == null:
		return Vector2.ZERO
	h.bot_retarget -= _dt
	var target := _feather_by_id(h.bot_target)
	if target == null or h.bot_retarget <= 0.0:
		h.bot_retarget = _bot_rng.randf_range(0.25, 0.5)
		target = _bot_pick(h)
		h.bot_target = target.id if target != null else -1
		h.bot_delay = _bot_rng.randf_range(0.05, 0.22)
	if target == null:
		var idle := start_pos(_hands.find(h), _hands.size()) - h.pos   # sin plumas a la vista: a su zona
		return idle.normalized() * 0.5 if idle.length() > 40.0 else Vector2.ZERO
	var dist := h.pos.distance_to(target.pos)
	var aim := target.pos + target.vel * minf(dist / HAND_SPEED, 0.5)
	var to := aim - h.pos
	if to.length() < 8.0:
		return Vector2.ZERO
	return to.normalized() * BOT_SPEED * clampf(to.length() / 60.0, 0.35, 1.0)

func _bot_pick(h: Hand) -> Feather:
	var best: Feather = null
	var best_score := 0.0
	for f in _feathers:
		if f.kind == Kind.BROWN or f.pos.y > GROUND_Y - 40.0 or not PLAY_AREA.grow(-10.0).has_point(f.pos):
			continue
		var s := float(VALUES[f.kind]) / (h.pos.distance_to(f.pos) + 140.0)
		for o in _hands:
			if o != h and o.bot_target == f.id:
				s *= 0.35   # si otro ya va a por ella, mejor buscar otra
		if s > best_score:
			best_score = s
			best = f
	return best

func _bot_action(player: PlayerData) -> int:
	var h := _hand_of(player)
	if h == null or h.cool > 0.0:
		return 0
	var nearest: Feather = null
	var nd := GRAB_RADIUS * 0.75
	for f in _feathers:
		var d := h.pos.distance_to(f.pos)
		if d < nd:
			nd = d
			nearest = f
	if nearest == null:
		return 0
	if nearest.kind == Kind.BROWN:
		return 1 if _bot_rng.randf() < 0.002 else 0   # muy de vez en cuando se le escapa
	h.bot_delay -= _dt
	return 1 if h.bot_delay <= 0.0 else 0

func _hand_of(player: PlayerData) -> Hand:
	for h in _hands:
		if h.player == player:
			return h
	return null

func _feather_by_id(id: int) -> Feather:
	if id < 0:
		return null
	for f in _feathers:
		if f.id == id:
			return f
	return null

func hand_count() -> int:
	return _hands.size()

func hand(i: int) -> Hand:
	return _hands[i]

func feathers() -> Array[Feather]:
	return _feathers

func score_of(player: PlayerData) -> int:
	return int(_scores.get(player.id, 0))

# ----------------------------------------------------------------------------
# Estado hacia los clientes
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var scores := PackedInt32Array()
	var hands := PackedFloat32Array()
	for h in _hands:
		scores.append(_scores[h.player.id])
		hands.append_array(PackedFloat32Array([h.pos.x, h.pos.y, h.vel.x, h.vel.y, h.grab_t]))
	var fs := PackedFloat32Array()
	for f in _feathers:
		fs.append_array(PackedFloat32Array([float(f.id), f.pos.x, f.pos.y, f.vel.x, f.vel.y, f.rot, float(f.kind)]))
	return {"t": _time_left, "s": scores, "h": hands, "f": fs}

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	_time_left = float(state.get("t", _time_left))
	var scores: Variant = state.get("s")
	if scores is PackedInt32Array:
		for i in mini(scores.size(), _hands.size()):
			_scores[_hands[i].player.id] = scores[i]
	var hs: Variant = state.get("h")
	if hs is PackedFloat32Array and hs.size() >= _hands.size() * FLOATS_PER_HAND:
		for i in _hands.size():
			var h := _hands[i]
			var o := i * FLOATS_PER_HAND
			h.net_pos = Vector2(hs[o], hs[o + 1])
			h.vel = Vector2(hs[o + 2], hs[o + 3])
			h.grab_t = hs[o + 4]
			if not _got_state:
				h.pos = h.net_pos
		_got_state = true
	var fs: Variant = state.get("f")
	if fs is PackedFloat32Array:
		var old := {}
		for f in _feathers:
			old[f.id] = f
		var fresh: Array[Feather] = []
		for i in fs.size() / FLOATS_PER_FEATHER:
			var o: int = i * FLOATS_PER_FEATHER
			var id := int(fs[o])
			var f: Feather = old.get(id, null)
			if f == null:
				f = Feather.new()
				f.id = id
				f.pos = Vector2(fs[o + 1], fs[o + 2])
			f.net_pos = Vector2(fs[o + 1], fs[o + 2])
			f.vel = Vector2(fs[o + 3], fs[o + 4])
			f.rot = fs[o + 5]
			f.kind = int(fs[o + 6])
			fresh.append(f)
		_feathers = fresh

func _on_event(event_name: String, data: Variant) -> void:
	if event_name != "catch" or not data is Dictionary:
		return
	var pos := Vector2(float(data.get("x", 0.0)), float(data.get("y", 0.0)))
	var kind := int(data.get("k", Kind.PINK))
	var who := int(data.get("p", -1))
	var v := int(data.get("v", 0))
	var p: PlayerData = null
	for pl in players:
		if pl.id == who:
			p = pl
	var mine := p != null and is_audible(p)
	match kind:
		Kind.GOLD: Audio.sfx(&"hit_gold", -2.0 if mine else -14.0)
		Kind.BROWN: Audio.sfx(&"miss", -2.0 if mine else -14.0)
		_: Audio.sfx(&"coin", -3.0 if mine else -15.0)
	# Una pluma atrapada desaparece ya también en los clientes (sin esperar al siguiente estado).
	if not is_authority:
		var near: Feather = null
		var nd := 60.0
		for f in _feathers:
			if f.kind == kind and f.pos.distance_to(pos) < nd:
				nd = f.pos.distance_to(pos)
				near = f
		if near != null:
			_feathers.erase(near)
	var col: Color = p.color if p != null else Palette.WHITE
	var value: int = VALUES[kind]
	_popups.append({"pos": pos, "text": ("+%d" % value) if value > 0 else str(value),
			"color": Color("A0522D") if kind == Kind.BROWN else col, "age": 0.0})
	var spark_col := Color("FFE680") if kind == Kind.GOLD else (Color("8B5A3C") if kind == Kind.BROWN else Color("CFF6FF"))
	for i in (14 if kind == Kind.GOLD else 8):
		var a := TAU * i / (14.0 if kind == Kind.GOLD else 8.0) + randf() * 0.4
		_sparks.append({"pos": pos, "vel": Vector2.from_angle(a) * randf_range(90.0, 220.0), "color": spark_col, "age": 0.0})
	if p != null and v != 0:
		_gain[p.id] = {"v": v, "age": 0.0}

# ----------------------------------------------------------------------------
# Entrada local: ratón
# ----------------------------------------------------------------------------

## Quién maneja el ratón en este PC: online, su jugador; en local, la primera persona (teclado 1 si la hay).
func _mouse_player() -> PlayerData:
	if local_player != null:
		return local_player
	var first: PlayerData = null
	for p in players:
		if p.device == PlayerData.DEVICE_KB1 or p.device == PlayerData.DEVICE_LOCAL:
			return p
		if first == null and p.is_local_human:
			first = p
	return first

func _unhandled_input(event: InputEvent) -> void:
	if not is_running or surface == null:
		return
	if event is InputEventMouseMotion or (event is InputEventMouseButton and event.pressed):
		var me := _mouse_player()
		if me == null or InputManager.is_simulated(me.id):
			return
		_mouse_pos = surface.get_local_mouse_position()
		_mouse_dirty = true
		if event is InputEventMouseButton:
			_send_mouse()   # que la mano esté en su sitio antes de cerrarse

func _send_mouse() -> void:
	_mouse_dirty = false
	_mouse_send = MOUSE_SEND_EVERY
	submit_text("m:%d,%d" % [roundi(_mouse_pos.x), roundi(_mouse_pos.y)], false)

# ----------------------------------------------------------------------------
# Animación (todos los PC)
# ----------------------------------------------------------------------------

func _animate(delta: float) -> void:
	_time += delta
	_mouse_send = maxf(0.0, _mouse_send - delta)
	if _mouse_dirty and _mouse_send <= 0.0 and is_running:
		_send_mouse()
	# Sonido al cerrar la mano (la propia fuerte, las demás bajito).
	for h in _hands:
		if h.grab_t > _prev_grab[h.player.id] + 0.05:
			Audio.sfx(&"swish", -10.0 if is_audible(h.player) else -22.0)
		_prev_grab[h.player.id] = h.grab_t
	var sec := ceili(_time_left)
	if is_running and sec != _last_sec and sec <= 3 and sec > 0:
		Audio.sfx(&"beep", -6.0)
	_last_sec = sec
	for f in _feathers:
		f.age += delta
	for pop in _popups:
		pop["age"] = float(pop["age"]) + delta
	_popups = _popups.filter(func(p: Dictionary) -> bool: return float(p["age"]) < 0.9)
	for sp in _sparks:
		sp["age"] = float(sp["age"]) + delta
		sp["pos"] = sp["pos"] + sp["vel"] * delta
		sp["vel"] = sp["vel"] * (1.0 - minf(1.0, delta * 4.0))
	_sparks = _sparks.filter(func(s: Dictionary) -> bool: return float(s["age"]) < 0.5)
	for id in _gain:
		_gain[id]["age"] = float(_gain[id]["age"]) + delta
	if not is_authority:
		if is_running:
			_time_left = maxf(0.0, _time_left - delta)
		var k := 1.0 - exp(-SMOOTHING * delta)
		for h in _hands:
			h.grab_t = maxf(0.0, h.grab_t - delta)
			h.net_pos = (h.net_pos + h.vel * delta).clamp(PLAY_AREA.position, PLAY_AREA.end)
			h.pos = h.pos.lerp(h.net_pos, k)
		for f in _feathers:
			f.net_pos += f.vel * delta
			f.pos = f.pos.lerp(f.net_pos, k)

# ----------------------------------------------------------------------------
# Dibujo
# ----------------------------------------------------------------------------

func _draw_game() -> void:
	_draw_scenery()
	for f in _feathers:
		_draw_feather(f.pos, f.rot, f.kind, minf(f.age / 0.25, 1.0))
	for sp in _sparks:
		var k := float(sp["age"]) / 0.5
		var c: Color = sp["color"]
		c.a = 1.0 - k
		surface.draw_circle(sp["pos"], 4.0 * (1.0 - k) + 1.0, c)
	for i in _hands.size():
		_draw_hand(_hands[i], i)
	for pop in _popups:
		var k := float(pop["age"]) / 0.9
		var c: Color = pop["color"]
		c.a = 1.0 - maxf(0.0, k - 0.6) / 0.4
		surface.text_centered(pop["pos"] + Vector2(0, -24.0 - 46.0 * k), pop["text"], 38, c, 8)
	_draw_hud()

func _draw_scenery() -> void:
	var s := surface
	var top := Color("2F7BEA")
	var bottom := Color("A9DCFF")
	s.draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(1280, 0), Vector2(1280, 560), Vector2(0, 560)]),
			PackedColorArray([top, top, bottom, bottom]))
	# Nubes que pasan despacio.
	for c in _clouds:
		var base: Vector2 = c[0]
		var sc: float = c[1]
		var x := fposmod(base.x + _time * float(c[2]), 1280.0 + 300.0) - 150.0
		var p := Vector2(x, base.y)
		var white := Color(1, 1, 1, 0.92)
		s.draw_circle(p + Vector2(0, 10) * sc, 34.0 * sc, Color(0.75, 0.85, 1.0, 0.6))
		for blob in [[Vector2(-50, 8), 26.0], [Vector2(-20, -10), 34.0], [Vector2(20, -16), 38.0], [Vector2(56, 4), 28.0],
				[Vector2(0, 10), 32.0]]:
			s.draw_circle(p + blob[0] * sc, float(blob[1]) * sc, white)
	# Montañas y prado.
	var far := PackedVector2Array([Vector2(0, 520), Vector2(120, 470), Vector2(260, 500), Vector2(420, 430),
			Vector2(560, 480), Vector2(700, 455), Vector2(860, 500), Vector2(1000, 440), Vector2(1160, 490),
			Vector2(1280, 470), Vector2(1280, 580), Vector2(0, 580)])
	s.draw_colored_polygon(far, Color("6FAF7C"))
	var near := PackedVector2Array([Vector2(0, 560), Vector2(180, 530), Vector2(380, 470), Vector2(520, 520),
			Vector2(760, 500), Vector2(900, 540), Vector2(1100, 510), Vector2(1280, 545), Vector2(1280, 620),
			Vector2(0, 620)])
	s.draw_colored_polygon(near, Color("3E9B4F"))
	s.draw_rect(Rect2(0, 600, 1280, 120), Color("5CC14E"))
	s.draw_rect(Rect2(0, 596, 1280, 8), Color("7FD85F"))
	for fl in _flowers:
		var p: Vector2 = fl[0]
		var r: float = fl[2]
		s.draw_circle(p, r, fl[1])
		s.draw_circle(p, r * 0.35, Color("FFE15A"))

## Pluma: un óvalo alargado con el cañón en medio, inclinado según su vaivén. `pop` 0→1 al aparecer.
func _draw_feather(center: Vector2, rot: float, kind: int, pop: float = 1.0) -> void:
	var s := surface
	var length := 60.0 if kind == Kind.GOLD else 54.0
	var width := 15.0
	var vane: Color
	var edge: Color
	match kind:
		Kind.GOLD:
			vane = Color("FFD23F")
			edge = Color("FFF3B0")
			var glow := 0.5 + 0.5 * sin(_time * 8.0 + center.x * 0.05)
			s.draw_circle(center, 34.0 * pop, Color(1.0, 0.92, 0.4, 0.18 + 0.12 * glow))
		Kind.BROWN:
			vane = Color("7A4A2A")
			edge = Color("A0704A")
		_:
			vane = Color("FF8FB8")
			edge = Color("FFD0E2")
	s.draw_set_transform(center, rot + PI * 0.5 - 0.35, Vector2(pop, pop))
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	var steps := 10
	for i in steps + 1:
		var t := float(i) / steps
		var y := -length * 0.5 + length * t
		var w := width * pow(sin(PI * clampf(t * 0.92 + 0.04, 0.0, 1.0)), 0.7)
		left.append(Vector2(-w * 1.05, y))
		right.append(Vector2(w * 0.85, y))
	right.reverse()
	var poly := left + right
	s.draw_colored_polygon(poly, vane)
	# Brillo en un lado y barbas (rayitas).
	var shine := PackedVector2Array()
	for i in range(2, steps - 1):
		shine.append(Vector2(left[i].x * 0.55, left[i].y))
	for i in range(steps - 2, 1, -1):
		shine.append(Vector2(-1.5, left[i].y))
	if shine.size() >= 3:
		s.draw_colored_polygon(shine, edge)
	for i in range(2, steps - 1, 2):
		var y: float = left[i].y
		s.draw_line(Vector2(0, y + 3), Vector2(left[i].x * 0.9, y - 3), vane.darkened(0.15), 1.5)
	s.draw_line(Vector2(0, -length * 0.5), Vector2(0, length * 0.5 + 8.0), vane.darkened(0.35), 2.5)
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if kind == Kind.GOLD:
		var tw := 0.5 + 0.5 * sin(_time * 11.0 + center.y * 0.1)
		s.draw_circle(center + Vector2(14, -16), 3.0 * tw * pop, Color(1, 1, 1, 0.9))

## Mano del jugador: abierta (palma y cinco dedos) o cerrada en puño, con su color y su número.
func _draw_hand(h: Hand, index: int) -> void:
	var s := surface
	var col := h.player.color
	var closed := h.grab_t > 0.0
	var c := h.pos
	var outline := col.darkened(0.35)
	var fill := Color("FFFFFF")
	s.draw_circle(c + Vector2(4, 8), 26.0, Color(0, 0, 0, 0.12))
	if closed:
		s.draw_circle(c, 22.0, outline)
		s.draw_circle(c, 19.0, fill)
		for k in 4:
			var fp := c + Vector2(-13.0 + k * 8.7, -14.0)
			s.draw_circle(fp, 6.5, outline)
			s.draw_circle(fp, 4.5, fill)
		s.draw_circle(c + Vector2(-19, 2), 6.5, outline)
		s.draw_circle(c + Vector2(-19, 2), 4.5, fill)
	else:
		# Dedos: cápsulas que salen de la palma.
		var fingers := [[Vector2(-13, -16), Vector2(-17, -40)], [Vector2(-4, -18), Vector2(-5, -46)],
				[Vector2(5, -18), Vector2(7, -44)], [Vector2(13, -14), Vector2(19, -35)], [Vector2(-16, 4), Vector2(-34, -10)]]
		for f in fingers:
			s.draw_line(c + f[0], c + f[1], outline, 13.0)
			s.draw_circle(c + f[1], 6.5, outline)
		s.draw_circle(c, 21.0, outline)
		for f in fingers:
			s.draw_line(c + f[0], c + f[1], fill, 8.5)
			s.draw_circle(c + f[1], 4.25, fill)
		s.draw_circle(c, 18.0, fill)
	# Número del jugador en la palma.
	s.draw_circle(c + Vector2(3, 6), 11.0, col)
	s.text_centered(c + Vector2(3, 6), str(index + 1), 16, Palette.WHITE, 4)
	if is_local_player(h.player) and players.size() > 1:
		draw_local_marker(c + Vector2(0, -26), 22.0)

func _draw_hud() -> void:
	var s := surface
	# Reloj arriba en el centro.
	var clock := Vector2(640, 52)
	s.draw_circle(clock + Vector2(0, 4), 38.0, Color(0, 0, 0, 0.2))
	s.draw_circle(clock, 38.0, Palette.PURPLE_DARK)
	s.draw_arc(clock, 32.0, -PI * 0.5, -PI * 0.5 + TAU * clampf(_time_left / DURATION, 0.0, 1.0), 48, Palette.YELLOW, 6.0)
	s.text_centered(clock, "%d" % ceili(_time_left), 34, Palette.WHITE, 6)
	# Marcador abajo: una píldora por jugador, repartidas a lo ancho.
	var n := _hands.size()
	var slot := 1240.0 / float(maxi(n, 1))
	var w := minf(220.0, slot - 12.0)
	for i in n:
		var p := _hands[i].player
		var cx := 20.0 + slot * (i + 0.5)
		var r := Rect2(cx - w * 0.5, 648.0, w, 56.0)
		s.rounded_rect(Rect2(r.position + Vector2(0, 5), r.size), 28, Color(0, 0, 0, 0.25))
		s.rounded_rect(r, 28, p.color.darkened(0.2))
		s.rounded_rect(r.grow(-5), 23, Color("FFFFFF"))
		var avatar_r := minf(19.0, w * 0.13)
		AvatarPainter.paint(s, Vector2(r.position.x + 10.0 + avatar_r, r.get_center().y), avatar_r, p.color)
		var bump := 0.0
		if _gain.has(p.id):
			var age := float(_gain[p.id]["age"])
			bump = maxf(0.0, 1.0 - age / 0.3)
		var num_pos := Vector2(r.position.x + w * 0.62, r.get_center().y - 6.0 * bump)
		s.text_centered(num_pos, str(_scores[p.id]), int(36 + 8 * bump), p.color.darkened(0.25), 0)
		if _gain.has(p.id) and float(_gain[p.id]["age"]) < 0.9:
			var gv := int(_gain[p.id]["v"])
			var ga := float(_gain[p.id]["age"])
			var gc := Palette.MINT if gv > 0 else Palette.CORAL
			gc.a = 1.0 - maxf(0.0, ga - 0.5) / 0.4
			s.text_centered(Vector2(r.end.x - 14.0, r.position.y - 14.0 - 16.0 * ga), ("+%d" % gv) if gv > 0 else str(gv),
					26, gc, 6)
