extends Node
## Gestor de entrada multijugador local (autoload).
##
## Crea en el InputMap acciones por jugador ("p0_left", "p0_right", "p0_up", "p0_down",
## "p0_action") ligadas a su dispositivo: teclado 1, teclado 2 o un mando. Los bots no
## usan el InputMap: su "entrada" la simula este nodo (deambular + pulsar al azar).
##
## Los minijuegos NO usan esto directamente: leen vía Minigame.move_input() /
## action_just_pressed(). Así, más adelante, los jugadores remotos pueden alimentarse
## desde la red cambiando solo este archivo.

const DEADZONE := 0.25
const DIRECTIONS: Array[String] = ["left", "right", "up", "down"]

## Estado simulado de un bot.
class BotState:
	var dir: Vector2 = Vector2.ZERO
	var change_timer: float = 0.0
	var action_rate: float = 6.0   # pulsaciones por segundo (varía por bot)
	var action_just: bool = false

var _bots: Dictionary = {}  # player_id -> BotState

func _process(delta: float) -> void:
	for id in _bots:
		var bot: BotState = _bots[id]
		bot.change_timer -= delta
		if bot.change_timer <= 0.0:
			bot.change_timer = randf_range(0.3, 1.2)
			bot.dir = Vector2.ZERO if randf() < 0.15 else Vector2.from_angle(randf() * TAU)
		bot.action_just = randf() < bot.action_rate * delta

# ----------------------------------------------------------------------------
# Registro de jugadores
# ----------------------------------------------------------------------------

func register_player(p: PlayerData) -> void:
	unregister_player(p)
	if p.is_bot:
		var bot := BotState.new()
		bot.action_rate = randf_range(4.0, 8.0)
		_bots[p.id] = bot
	elif not p.is_remote:
		_bind_actions(p)

func unregister_player(p: PlayerData) -> void:
	_bots.erase(p.id)
	for dir in DIRECTIONS + ["action"]:
		var action := _action_name(p.id, dir)
		if InputMap.has_action(action):
			InputMap.erase_action(action)

## Dispositivos humanos disponibles ahora mismo (2 teclados + mandos conectados).
func available_devices() -> Array[String]:
	var devices: Array[String] = [PlayerData.DEVICE_KB1, PlayerData.DEVICE_KB2]
	for joy in Input.get_connected_joypads():
		devices.append(PlayerData.DEVICE_JOY_PREFIX + str(joy))
	return devices

# ----------------------------------------------------------------------------
# Lectura de entrada
# ----------------------------------------------------------------------------

func get_vector(player_id: int) -> Vector2:
	if _bots.has(player_id):
		return (_bots[player_id] as BotState).dir
	if not InputMap.has_action(_action_name(player_id, "left")):
		return Vector2.ZERO
	return Input.get_vector(_action_name(player_id, "left"), _action_name(player_id, "right"),
			_action_name(player_id, "up"), _action_name(player_id, "down"))

func is_action_pressed(player_id: int) -> bool:
	if _bots.has(player_id):
		return (_bots[player_id] as BotState).action_just
	var action := _action_name(player_id, "action")
	return InputMap.has_action(action) and Input.is_action_pressed(action)

func is_action_just_pressed(player_id: int) -> bool:
	if _bots.has(player_id):
		return (_bots[player_id] as BotState).action_just
	var action := _action_name(player_id, "action")
	return InputMap.has_action(action) and Input.is_action_just_pressed(action)

# ----------------------------------------------------------------------------
# Internos
# ----------------------------------------------------------------------------

func _action_name(player_id: int, suffix: String) -> String:
	return "p%d_%s" % [player_id, suffix]

func _bind_actions(p: PlayerData) -> void:
	for suffix in DIRECTIONS + ["action"]:
		var action := _action_name(p.id, suffix)
		InputMap.add_action(action, DEADZONE)
		for ev in _events_for(p.device, suffix):
			InputMap.action_add_event(action, ev)

func _events_for(device: String, suffix: String) -> Array[InputEvent]:
	var events: Array[InputEvent] = []
	match device:
		PlayerData.DEVICE_KB1:
			var keys := {"left": KEY_A, "right": KEY_D, "up": KEY_W, "down": KEY_S, "action": KEY_SPACE}
			events.append(_key(keys[suffix]))
		PlayerData.DEVICE_KB2:
			var keys := {"left": KEY_LEFT, "right": KEY_RIGHT, "up": KEY_UP, "down": KEY_DOWN, "action": KEY_ENTER}
			events.append(_key(keys[suffix]))
			if suffix == "action":
				events.append(_key(KEY_KP_ENTER))
		_:
			if device.begins_with(PlayerData.DEVICE_JOY_PREFIX):
				var joy := int(device.substr(PlayerData.DEVICE_JOY_PREFIX.length()))
				events.append_array(_joy_events(joy, suffix))
	return events

func _key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	return ev

func _joy_events(joy: int, suffix: String) -> Array[InputEvent]:
	var events: Array[InputEvent] = []
	if suffix == "action":
		for button in [JOY_BUTTON_A, JOY_BUTTON_X]:
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
