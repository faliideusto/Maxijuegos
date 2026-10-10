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
var _human_labels: Array[Label] = []

func _ready() -> void:
	UIKit.setup_screen(self)
	if DisplayServer.get_name() == "headless" or InputManager.autopilot:
		_auto = AUTO_SECONDS_TESTS
	var meta := GameManager.current_minigame()
	# Disposición como en los party games de consola: panel de información a la izquierda, la práctica grande a la
	# derecha con su cartel, y abajo la fila de jugadores con su "¡TODO LISTO!".
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	var top := HBoxContainer.new()
	top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top.add_theme_constant_override("separation", 0)
	root.add_child(top)
	# --- Panel izquierdo (claro) ---
	var side := PanelContainer.new()
	side.custom_minimum_size = Vector2(340, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.97, 0.96, 1.0)
	sb.set_content_margin_all(22)
	side.add_theme_stylebox_override("panel", sb)
	top.add_child(side)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 8)
	side.add_child(info)
	var dark := Color(0.13, 0.08, 0.28)
	info.add_child(_text("MINIJUEGO %d DE %d" % [GameManager.current_index + 1, GameManager.playlist.size()], 16, dark.lightened(0.45)))
	info.add_child(_text(meta.display_name, 34, dark, true))
	info.add_child(_text(meta.description, 22, meta.accent_color.darkened(0.25), true))
	info.add_child(_text(meta.short_text if meta.short_text != "" else meta.instructions, 20, dark.lightened(0.2), true))
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	info.add_child(spacer)
	info.add_child(_pill("Controles", Color(0.8, 0.8, 0.84), dark))
	for line in _controls(meta.id):
		info.add_child(_pill(line, dark, Color.WHITE))
	# --- Práctica a la derecha, con el cartel ---
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	right.add_theme_constant_override("separation", 14)
	top.add_child(right)
	var banner := PanelContainer.new()
	banner.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var bsb := StyleBoxFlat.new()
	bsb.bg_color = Color(0.12, 0.12, 0.16)
	bsb.set_corner_radius_all(28)
	bsb.set_content_margin_all(10)
	bsb.content_margin_left = 40
	bsb.content_margin_right = 40
	bsb.border_color = Color(0.5, 0.5, 0.58)
	bsb.set_border_width_all(4)
	banner.add_theme_stylebox_override("panel", bsb)
	banner.add_child(_text("¡HORA DE PRACTICAR!", 38, Color.WHITE))
	right.add_child(banner)
	for spec in MinigamePractice.plan(meta):
		var practice := MinigamePractice.new()
		practice.setup(meta, spec["local"], spec["size"])
		practice.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		right.add_child(practice)
	# --- Fila de jugadores ---
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", 0)
	strip.custom_minimum_size = Vector2(0, 96)
	root.add_child(strip)
	for p in Lobby.players:
		var tile := PanelContainer.new()
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var tsb := StyleBoxFlat.new()
		tsb.bg_color = p.color.darkened(0.1)
		tsb.set_content_margin_all(8)
		tile.add_theme_stylebox_override("panel", tsb)
		var h := HBoxContainer.new()
		h.alignment = BoxContainer.ALIGNMENT_CENTER
		h.add_theme_constant_override("separation", 10)
		tile.add_child(h)
		var a := PlayerAvatar.new(56)
		a.set_player(p)
		h.add_child(a)
		var v := VBoxContainer.new()
		v.alignment = BoxContainer.ALIGNMENT_CENTER
		var st := _text("¡TODO LISTO!" if p.is_bot else "PRACTICANDO…", 20, Color.WHITE)
		v.add_child(st)
		v.add_child(_text(p.display_name, 15, Color(1, 1, 1, 0.85)))
		h.add_child(v)
		strip.add_child(tile)
		if not p.is_bot:
			_human_labels.append(st)
	# Barra de tiempo y botón sobre la franja, esquina inferior derecha del panel de práctica.
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(380, 12)
	_bar.max_value = _auto
	_bar.show_percentage = false
	_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	right.add_child(_bar)
	var tip := "Empezad con ¡LISTO! (o ESC)" if NetworkManager.is_host() else "Empieza cuando lo decida el anfitrión"
	var tl := _text(tip, 16, Color(1, 1, 1, 0.8))
	tl.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	right.add_child(tl)
	var go := UIKit.button("¡LISTO!", &"PrimaryButton", Vector2(240, 0))
	go.focus_mode = Control.FOCUS_NONE        # el espacio/enter son botones de juego: no deben activar este botón
	go.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	go.pressed.connect(_finish)
	right.add_child(go)

func _text(s: String, size: int, color: Color, wrap: bool = false) -> Label:
	var l := Label.new()
	l.text = s
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(290, 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if size != 38 else HORIZONTAL_ALIGNMENT_CENTER
	return l

func _pill(s: String, bg: Color, fg: Color) -> Control:
	var pc := PanelContainer.new()
	var sbx := StyleBoxFlat.new()
	sbx.bg_color = bg
	sbx.set_corner_radius_all(20)
	sbx.content_margin_left = 16
	sbx.content_margin_right = 16
	sbx.content_margin_top = 6
	sbx.content_margin_bottom = 6
	pc.add_theme_stylebox_override("panel", sbx)
	pc.add_child(_text(s, 20, fg))
	return pc

## Controles de cada minijuego (texto de la píldora).
func _controls(id: StringName) -> Array[String]:
	if TouchControls.active:
		return TouchControls.controls_text(id)
	match id:
		&"coin_grab", &"shrinking_platform", &"spotlight":
			return ["MOVERSE: flechas / WASD / palanca"]
		&"bomb_party":
			return ["ESCRIBIR: teclado, Enter envía"]
		&"word_fight":
			return ["MOVERSE: WASD o flechas", "PULSAR LETRA: ESPACIO o CLIC", "GOLPEAR: E o CLIC DERECHO"]
		&"obstacle_run", &"uphill_rush":
			return ["MOVERSE: WASD o flechas", "SALTAR: ESPACIO o CLIC"]
		&"target_range":
			return ["APUNTAR: ratón o WASD / flechas", "DISPARAR: clic o espacio"]
	return ["ESPACIO o CLIC"]

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
	for l in _human_labels:
		l.text = "¡TODO LISTO!"
	GameManager.run_minigame()
