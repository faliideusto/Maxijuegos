extends Control
## Presentación del minijuego: nombre, descripción corta y una PRÁCTICA jugable en miniatura (ver MinigamePractice) donde
## se prueba el juego con los propios controles. Como el botón de acción se usa para jugar, esta pantalla ya no se salta
## con él: avanza con el botón "¡LISTO!" (clic), con ESC, o sola pasado un tiempo. Online solo avanza el host; los demás
## ven la misma pantalla y siguen probando hasta que empiece.

const AUTO_SECONDS := 25.0
## En pruebas automáticas (sin ventana o con autopiloto) no hay nadie practicando: avanza enseguida.
const AUTO_SECONDS_TESTS := 7.0
## Margen inicial para no saltarse la pantalla sin querer con una pulsación anterior.
const SKIP_GRACE := 0.8

var _elapsed: float = 0.0
var _bar: ProgressBar
var _done: bool = false
var _auto: float = AUTO_SECONDS

func _ready() -> void:
	UIKit.setup_screen(self)
	if DisplayServer.get_name() == "headless" or InputManager.autopilot:
		_auto = AUTO_SECONDS_TESTS
	var meta := GameManager.current_minigame()
	var box := UIKit.centered_vbox(self, 12)
	box.add_child(UIKit.label("MINIJUEGO %d DE %d" % [GameManager.current_index + 1, GameManager.playlist.size()], &"HintLabel"))
	var title := UIKit.label(meta.display_name.to_upper(), &"TitleLabel")
	title.add_theme_font_size_override("font_size", 60)
	title.add_theme_color_override("font_color", meta.accent_color)
	box.add_child(title)
	box.add_child(UIKit.label(meta.description, &"HeaderLabel"))
	# La práctica: un solo recuadro (en los de "cada uno en su pantalla", la tuya).
	var frames := HBoxContainer.new()
	frames.alignment = BoxContainer.ALIGNMENT_CENTER
	frames.add_theme_constant_override("separation", 14)
	for spec in MinigamePractice.plan(meta):
		var practice := MinigamePractice.new()
		practice.setup(meta, spec["local"], spec["size"])
		frames.add_child(practice)
	box.add_child(frames)
	# El texto corto de cómo se juega (pequeño).
	var short := UIKit.label(meta.short_text if meta.short_text != "" else meta.description, &"HintLabel")
	short.add_theme_font_size_override("font_size", 22)
	short.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	short.custom_minimum_size = Vector2(820, 0)
	box.add_child(short)
	# Jugadores participantes.
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	for p in Lobby.players:
		var a := PlayerAvatar.new(40)
		a.set_player(p)
		row.add_child(a)
	box.add_child(row)
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(500, 20)
	_bar.max_value = _auto
	_bar.show_percentage = false
	box.add_child(_bar)
	var tip := "Pruébalo aquí. Empezad con ¡LISTO! (o ESC)" if NetworkManager.is_host() else "Pruébalo aquí: empieza cuando lo decida el anfitrión"
	box.add_child(UIKit.label(tip, &"HintLabel"))
	var go := UIKit.button("¡LISTO!", &"PrimaryButton", Vector2(260, 0))
	go.focus_mode = Control.FOCUS_NONE        # el espacio/enter son botones de juego: no deben activar este botón
	go.pressed.connect(_finish)
	box.add_child(go)
	UIKit.fit_to_screen(box)

func _process(delta: float) -> void:
	if _done:
		return
	_elapsed += delta
	_bar.value = _elapsed
	if _elapsed >= _auto:
		_finish()
		return
	if _elapsed < SKIP_GRACE:
		return
	if Input.is_physical_key_pressed(KEY_ESCAPE):
		_finish()

func _finish() -> void:
	if _done:
		return
	_done = true
	GameManager.run_minigame()
