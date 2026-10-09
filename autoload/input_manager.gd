extends Node
## Gestor de entrada (autoload). Fuente ÚNICA de "qué quiere hacer cada jugador".
##
## Tipos de jugador:
##   - local humano (kb1 / kb2 / mando en modo local; "local" online): acciones del InputMap.
##   - remoto (online): su entrada llega por red y la fija MinigameSession con set_remote_input.
##   - bot: la entrada se simula aquí (deambular + pulsar al azar).
##   - autopiloto (solo desarrollo/pruebas): un jugador local se comporta como bot.
##
## Los minijuegos NO leen dispositivos: usan Minigame.move_input()/action_presses(), que
## llegan aquí. Por eso funcionan igual con jugadores locales, remotos y bots.

const DEADZONE := 0.25
const DIRECTIONS: Array[String] = ["left", "right", "up", "down"]
## Tope de pulsaciones por frame que se aceptan de un remoto (anti-abuso).
const MAX_REMOTE_PRESSES_PER_FRAME := 6

## Solo desarrollo: los jugadores locales se controlan solos (para pruebas desatendidas).
var autopilot: bool = false

## Web en móvil/tableta: la entrada la ponen los controles táctiles (TouchControls), así que el
## toque (que el navegador también envía como clic) no se enlaza como botón de acción.
var touch_mode: bool = false

## Estado simulado de un bot.
class BotState:
	var dir: Vector2 = Vector2.ZERO
	var change_timer: float = 0.0
	var action_rate: float = 6.0   # pulsaciones por segundo (varía por bot)
	var presses: int = 0
	var presses2: int = 0          # segundo botón (golpear)

## Última entrada recibida de un jugador remoto.
class RemoteState:
	var move: Vector2 = Vector2.ZERO
	var count: int = 0       # nº acumulado de pulsaciones de acción
	var last_count: int = 0  # lo ya consumido
	var presses: int = 0     # pulsaciones en este frame
	var count2: int = 0      # nº acumulado de pulsaciones del segundo botón (golpear)
	var last_count2: int = 0
	var presses2: int = 0

var _bots: Dictionary = {}     # player_id -> BotState
var _remotes: Dictionary = {}  # player_id -> RemoteState

func _process(delta: float) -> void:
	for id in _bots:
		var bot: BotState = _bots[id]
		bot.change_timer -= delta
		if bot.change_timer <= 0.0:
			bot.change_timer = randf_range(0.3, 1.2)
			bot.dir = Vector2.ZERO if randf() < 0.15 else Vector2.from_angle(randf() * TAU)
		bot.presses = 1 if randf() < bot.action_rate * delta else 0
		bot.presses2 = 1 if randf() < 0.8 * delta else 0
	for id in _remotes:
		var r: RemoteState = _remotes[id]
		r.presses = clampi(r.count - r.last_count, 0, MAX_REMOTE_PRESSES_PER_FRAME)
		r.last_count = r.count
		r.presses2 = clampi(r.count2 - r.last_count2, 0, MAX_REMOTE_PRESSES_PER_FRAME)
		r.last_count2 = r.count2

# ----------------------------------------------------------------------------
# Registro de jugadores
# ----------------------------------------------------------------------------

func register_player(p: PlayerData) -> void:
	unregister_player(p)
	if p.is_bot or (autopilot and p.is_local_human):
		var bot := BotState.new()
		bot.action_rate = randf_range(4.0, 8.0)
		_bots[p.id] = bot
	elif p.is_remote:
		_remotes[p.id] = RemoteState.new()
	else:
		_bind_actions(p)

func unregister_player(p: PlayerData) -> void:
	_bots.erase(p.id)
	_remotes.erase(p.id)
	for suffix in DIRECTIONS + ["action", "action2"]:
		var action := _action_name(p.id, suffix)
		if InputMap.has_action(action):
			InputMap.erase_action(action)

## Dispositivos locales disponibles en modo local (2 teclados + mandos conectados).
func available_devices() -> Array[String]:
	var devices: Array[String] = [PlayerData.DEVICE_KB1, PlayerData.DEVICE_KB2]
	for joy in Input.get_connected_joypads():
		devices.append(PlayerData.DEVICE_JOY_PREFIX + str(joy))
	return devices

# ----------------------------------------------------------------------------
# Entrada remota (la fija MinigameSession en el host tras validarla)
# ----------------------------------------------------------------------------

func set_remote_input(player_id: int, move: Vector2, press_count: int, press_count2: int = 0) -> void:
	var r: RemoteState = _remotes.get(player_id)
	if r == null:
		return
	r.move = move.limit_length(1.0)
	# Los contadores son monótonos: ignorar valores antiguos (paquetes desordenados/duplicados).
	if press_count > r.count:
		r.count = press_count
	if press_count2 > r.count2:
		r.count2 = press_count2

## Descarta pulsaciones remotas pendientes (p. ej. las hechas durante la cuenta atrás).
func flush_remote_presses() -> void:
	for id in _remotes:
		var r: RemoteState = _remotes[id]
		r.last_count = r.count
		r.presses = 0
		r.last_count2 = r.count2
		r.presses2 = 0

# ----------------------------------------------------------------------------
# Lectura de entrada
# ----------------------------------------------------------------------------

## true si la entrada de ese jugador la simula el juego (bot o autopiloto de pruebas).
## Los minijuegos usan su IA propia (_bot_move/_bot_action) para estos jugadores.
func is_simulated(player_id: int) -> bool:
	return _bots.has(player_id)

func get_vector(player_id: int) -> Vector2:
	if _bots.has(player_id):
		return (_bots[player_id] as BotState).dir
	if _remotes.has(player_id):
		return (_remotes[player_id] as RemoteState).move
	if not InputMap.has_action(_action_name(player_id, "left")):
		return Vector2.ZERO
	return Input.get_vector(_action_name(player_id, "left"), _action_name(player_id, "right"),
			_action_name(player_id, "up"), _action_name(player_id, "down"))

## Nº de pulsaciones de acción de este frame.
func action_presses(player_id: int) -> int:
	if _bots.has(player_id):
		return (_bots[player_id] as BotState).presses
	if _remotes.has(player_id):
		return (_remotes[player_id] as RemoteState).presses
	var action := _action_name(player_id, "action")
	return 1 if (InputMap.has_action(action) and Input.is_action_just_pressed(action)) else 0

## Nº de pulsaciones del SEGUNDO botón (golpear) de este frame.
func action2_presses(player_id: int) -> int:
	if _bots.has(player_id):
		return (_bots[player_id] as BotState).presses2
	if _remotes.has(player_id):
		return (_remotes[player_id] as RemoteState).presses2
	var action := _action_name(player_id, "action2")
	return 1 if (InputMap.has_action(action) and Input.is_action_just_pressed(action)) else 0

func is_action_just_pressed(player_id: int) -> bool:
	return action_presses(player_id) > 0

func is_action_pressed(player_id: int) -> bool:
	if _bots.has(player_id) or _remotes.has(player_id):
		return action_presses(player_id) > 0
	var action := _action_name(player_id, "action")
	return InputMap.has_action(action) and Input.is_action_pressed(action)

# ----------------------------------------------------------------------------
# Internos
# ----------------------------------------------------------------------------

func _action_name(player_id: int, suffix: String) -> String:
	return "p%d_%s" % [player_id, suffix]

func _bind_actions(p: PlayerData) -> void:
	for suffix in DIRECTIONS + ["action", "action2"]:
		var action := _action_name(p.id, suffix)
		InputMap.add_action(action, DEADZONE)
		for ev in _events_for(p.device, suffix):
			InputMap.action_add_event(action, ev)

func _events_for(device: String, suffix: String) -> Array[InputEvent]:
	var events: Array[InputEvent] = []
	match device:
		PlayerData.DEVICE_KB1:
			var keys := {"left": KEY_A, "right": KEY_D, "up": KEY_W, "down": KEY_S, "action": KEY_SPACE, "action2": KEY_E}
			events.append(_key(keys[suffix]))
			if suffix == "action" and not touch_mode:
				events.append(_click())
			elif suffix == "action2" and not touch_mode:
				events.append(_click(MOUSE_BUTTON_RIGHT))
		PlayerData.DEVICE_KB2:
			var keys := {"left": KEY_LEFT, "right": KEY_RIGHT, "up": KEY_UP, "down": KEY_DOWN, "action": KEY_ENTER, "action2": KEY_KP_0}
			events.append(_key(keys[suffix]))
			if suffix == "action":
				events.append(_key(KEY_KP_ENTER))
			elif suffix == "action2":
				events.append(_key(KEY_PERIOD))
		PlayerData.DEVICE_LOCAL:
			# Online (un jugador por PC): WASD o flechas + Espacio/Enter, o cualquier mando.
			var wasd := {"left": KEY_A, "right": KEY_D, "up": KEY_W, "down": KEY_S}
			var arrows := {"left": KEY_LEFT, "right": KEY_RIGHT, "up": KEY_UP, "down": KEY_DOWN}
			if suffix == "action":
				events.append(_key(KEY_SPACE))
				events.append(_key(KEY_ENTER))
				events.append(_key(KEY_KP_ENTER))
				events.append(_click())
			elif suffix == "action2":
				events.append(_key(KEY_E))
				events.append(_key(KEY_KP_0))
				events.append(_click(MOUSE_BUTTON_RIGHT))
			else:
				events.append(_key(wasd[suffix]))
				events.append(_key(arrows[suffix]))
			events.append_array(_joy_events(-1, suffix))
		_:
			if device.begins_with(PlayerData.DEVICE_JOY_PREFIX):
				var joy := int(device.substr(PlayerData.DEVICE_JOY_PREFIX.length()))
				events.append_array(_joy_events(joy, suffix))
	return events

## Clic izquierdo = botón de acción (jugador que usa el ratón: online o teclado 1).
func _click(button: MouseButton = MOUSE_BUTTON_LEFT) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	return ev

func _key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.device = -1   # cualquier dispositivo de teclado
	return ev

## Eventos de mando. joy = -1 → cualquier mando.
func _joy_events(joy: int, suffix: String) -> Array[InputEvent]:
	var events: Array[InputEvent] = []
	if suffix == "action" or suffix == "action2":
		var buttons: Array = [JOY_BUTTON_A, JOY_BUTTON_B] if suffix == "action" else [JOY_BUTTON_X, JOY_BUTTON_Y]
		for button in buttons:
			var b := InputEventJoypadButton.new()
			b.device = joy
			b.button_index = button
			events.append(b)
		return events
	# Stick izquierdo + cruceta.
	var axis := JOY_AXIS_LEFT_X if suffix in ["left", "right"] else JOY_AXIS_LEFT_Y
	var sign_value := -1.0 if suffix in ["left", "up"] else 1.0
	var m := InputEventJoypadMotion.new()
	m.device = joy
	m.axis = axis
	m.axis_value = sign_value
	events.append(m)
	var dpad := {"left": JOY_BUTTON_DPAD_LEFT, "right": JOY_BUTTON_DPAD_RIGHT,
			"up": JOY_BUTTON_DPAD_UP, "down": JOY_BUTTON_DPAD_DOWN}
	var d := InputEventJoypadButton.new()
	d.device = joy
	d.button_index = dpad[suffix]
	events.append(d)
	return events
