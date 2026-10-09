extends Control
## Presentación del minijuego: nombre, descripción, instrucciones y controles.
## Avanza sola tras unos segundos, o cuando cualquier jugador humano pulsa su acción.

const AUTO_SECONDS := 7.0
## Margen inicial para no saltarse la pantalla sin querer con una pulsación anterior.
const SKIP_GRACE := 0.8

var _elapsed: float = 0.0
var _bar: ProgressBar
var _done: bool = false

func _ready() -> void:
	UIKit.setup_screen(self)
	var meta := GameManager.current_minigame()
	var box := UIKit.centered_vbox(self, 16)

	var counter := UIKit.label("MINIJUEGO %d DE %d" % [GameManager.current_index + 1, GameManager.playlist.size()], &"HintLabel")
	box.add_child(counter)

	var title := UIKit.label(meta.display_name.to_upper(), &"TitleLabel")
	title.add_theme_font_size_override("font_size", 72)
	title.add_theme_color_override("font_color", meta.accent_color)
	box.add_child(title)
	box.add_child(UIKit.label(meta.description, &"HeaderLabel"))
	box.add_child(UIKit.label(meta.mode_hint(), &"HintLabel"))

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(760, 0)
	var instr := UIKit.label(meta.instructions)
	if meta.instructions.length() > 230:
		instr.add_theme_font_size_override("font_size", 22)   # textos largos: letra algo menor para que quepa mejor
	instr.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card.add_child(instr)
	box.add_child(card)

	# Jugadores participantes.
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	for p in Lobby.players:
		var a := PlayerAvatar.new(64)
		a.set_player(p)
		row.add_child(a)
	box.add_child(row)

	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(500, 26)
	_bar.max_value = AUTO_SECONDS
	_bar.show_percentage = false
	box.add_child(_bar)
	box.add_child(UIKit.label("Pulsa tu botón de acción para saltar", &"HintLabel"))

	var go := UIKit.button("¡LISTO!", &"PrimaryButton", Vector2(260, 0))
	go.pressed.connect(_finish)
	box.add_child(go)

	UIKit.fit_to_screen(box)
	var i := 0
	for child in box.get_children():
		UIKit.pop_in(child as Control, 0.07 * i)
		i += 1

func _process(delta: float) -> void:
	if _done:
		return
	_elapsed += delta
	_bar.value = _elapsed
	if _elapsed >= AUTO_SECONDS:
		_finish()
		return
	if _elapsed < SKIP_GRACE:
		return
	for p in Lobby.players:
		if not p.is_bot and not p.is_remote and InputManager.is_action_just_pressed(p.id):
			_finish()
			return

func _finish() -> void:
	if _done:
		return
	_done = true
	GameManager.run_minigame()
