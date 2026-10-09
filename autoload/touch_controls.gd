extends CanvasLayer
## Controles táctiles (autoload): solo en la versión web abierta desde un móvil o una tableta.
##
## Durante la práctica y el minijuego traduce los toques a las acciones del jugador humano
## ("p0_left", "p0_action"...), así que los minijuegos no cambian:
##   - minijuegos de un botón: tocar en cualquier sitio = botón de acción;
##   - minijuegos con movimiento (STICK_GAMES): joystick en la mitad izquierda (aparece donde se
##     toca) y botón de acción a la derecha; Pelea de Palabras añade el segundo botón (golpear).
## En ordenador (o fuera de web) no hace nada.

const STICK_RADIUS := 110.0
const KNOB_RADIUS := 46.0
const STICK_HOME := Vector2(200, 540)
const ACTION_POS := Vector2(1110, 550)
const ACTION_RADIUS := 86.0
const ACTION2_POS := Vector2(1185, 370)
const ACTION2_RADIUS := 64.0

## Minijuegos con movimiento → texto del botón de acción.
const STICK_GAMES := {
	&"coin_grab": "SPRINT",
	&"shrinking_platform": "EMBESTIR",
	&"spotlight": "EMPUJAR",
	&"obstacle_run": "SALTAR",
	&"word_fight": "PISAR",
}
## Minijuegos con segundo botón → su texto.
const ACTION2_GAMES := {
	&"word_fight": "GOLPEAR",
}

var active: bool = false

var _pad: Node2D
var _player_id: int = -1
var _use_stick: bool = false
var _action_label: String = ""
var _action2_label: String = ""
var _touches: Dictionary = {}          # índice de toque → "stick" | "action" | "action2"
var _stick_origin: Vector2 = STICK_HOME
var _stick_vector: Vector2 = Vector2.ZERO

func _ready() -> void:
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS
	active = OS.has_feature("web") and bool(JavaScriptBridge.eval("window.matchMedia('(hover: none) and (pointer: coarse)').matches", true))
	if not active:
		set_process_input(false)
		return
	InputManager.touch_mode = true
	_pad = Node2D.new()
	_pad.visible = false
	_pad.draw.connect(_draw_pad)
	add_child(_pad)
	GameManager.state_changed.connect(_on_state_changed)

func _on_state_changed(new_state: int) -> void:
	_release_all()
	var mg := GameManager.current_minigame()
	var in_game := mg != null and (new_state == GameManager.State.INTRO or new_state == GameManager.State.PLAYING)
	_player_id = _human_id() if in_game else -1
	_use_stick = in_game and STICK_GAMES.has(mg.id)
	_action_label = STICK_GAMES.get(mg.id, "") if in_game else ""
	_action2_label = ACTION2_GAMES.get(mg.id, "") if in_game else ""
	_pad.visible = _use_stick and _player_id >= 0
	# En la presentación el mando se ve más tenue para no tapar la pantalla de práctica.
	_pad.modulate.a = 0.6 if new_state == GameManager.State.INTRO else 1.0
	_pad.queue_redraw()

## Texto de los controles para la presentación del minijuego (sustituye al de teclado).
func controls_text(id: StringName) -> Array[String]:
	if not STICK_GAMES.has(id):
		return ["TOCA LA PANTALLA"]
	var lines: Array[String] = ["MOVERSE: joystick (izquierda)", "%s: botón amarillo" % STICK_GAMES[id]]
	if ACTION2_GAMES.has(id):
		lines.append("%s: botón blanco" % ACTION2_GAMES[id])
	return lines

func _human_id() -> int:
	for p in Lobby.players:
		if not p.is_bot:
			return p.id
	return -1

func _input(event: InputEvent) -> void:
	if _player_id < 0:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_down(event.index, event.position)
		else:
			_touch_up(event.index)
	elif event is InputEventScreenDrag and _touches.get(event.index, "") == "stick":
		_set_stick((event.position - _stick_origin) / STICK_RADIUS)

func _touch_down(index: int, pos: Vector2) -> void:
	var kind := "action"
	if _use_stick:
		if pos.x < Palette.VIEWPORT_SIZE.x * 0.5:
			if _touches.values().has("stick"):
				return
			kind = "stick"
			_stick_origin = pos.clamp(Vector2(STICK_RADIUS, STICK_RADIUS), Palette.VIEWPORT_SIZE - Vector2(STICK_RADIUS, STICK_RADIUS))
			_set_stick(Vector2.ZERO)
		elif not _action2_label.is_empty() and pos.distance_to(ACTION2_POS) <= ACTION2_RADIUS + 24.0:
			kind = "action2"
	_touches[index] = kind
	if kind != "stick":
		# Soltar y pulsar: cada dedo nuevo cuenta como una pulsación aunque haya otro apoyado.
		var action := _action(kind)
		Input.action_release(action)
		Input.action_press(action)
	_pad.queue_redraw()

func _touch_up(index: int) -> void:
	if not _touches.has(index):
		return
	var kind: String = _touches[index]
	_touches.erase(index)
	if kind == "stick":
		_stick_origin = STICK_HOME
		_set_stick(Vector2.ZERO)
	elif not _touches.values().has(kind):
		Input.action_release(_action(kind))
	_pad.queue_redraw()

func _set_stick(v: Vector2) -> void:
	_stick_vector = v.limit_length(1.0)
	_apply_axis("left", -_stick_vector.x)
	_apply_axis("right", _stick_vector.x)
	_apply_axis("up", -_stick_vector.y)
	_apply_axis("down", _stick_vector.y)
	_pad.queue_redraw()

func _apply_axis(suffix: String, strength: float) -> void:
	var action := _action(suffix)
	if not InputMap.has_action(action):
		return
	if strength > 0.0:
		Input.action_press(action, strength)
	else:
		Input.action_release(action)

func _release_all() -> void:
	if _player_id >= 0:
		for suffix in InputManager.DIRECTIONS + ["action", "action2"]:
			var action := _action(suffix)
			if InputMap.has_action(action):
				Input.action_release(action)
	_touches.clear()
	_stick_origin = STICK_HOME
	_stick_vector = Vector2.ZERO

func _action(suffix: String) -> String:
	return "p%d_%s" % [_player_id, suffix]

func _draw_pad() -> void:
	var held := _touches.values()
	# Joystick: base y pomo.
	_pad.draw_circle(_stick_origin, STICK_RADIUS, Color(0, 0, 0, 0.28))
	_pad.draw_arc(_stick_origin, STICK_RADIUS, 0.0, TAU, 64, Color(1, 1, 1, 0.55), 4.0, true)
	_pad.draw_circle(_stick_origin + _stick_vector * (STICK_RADIUS - KNOB_RADIUS * 0.5), KNOB_RADIUS, Color(1, 1, 1, 0.85 if held.has("stick") else 0.6))
	_draw_button(ACTION_POS, ACTION_RADIUS, _action_label, Palette.YELLOW, held.has("action"))
	if not _action2_label.is_empty():
		_draw_button(ACTION2_POS, ACTION2_RADIUS, _action2_label, Palette.WHITE, held.has("action2"))

func _draw_button(center: Vector2, radius: float, text: String, color: Color, pressed: bool) -> void:
	_pad.draw_circle(center, radius, Color(color, 0.9 if pressed else 0.6))
	_pad.draw_arc(center, radius, 0.0, TAU, 64, Color(1, 1, 1, 0.8), 4.0, true)
	var font := get_tree().root.get_theme_default_font()
	var size := 22
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, size).x
	_pad.draw_string_outline(font, center + Vector2(-width * 0.5, size * 0.35), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 6, Palette.PURPLE_DARK)
	_pad.draw_string(font, center + Vector2(-width * 0.5, size * 0.35), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Palette.WHITE)
