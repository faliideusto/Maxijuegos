extends Control
## Lobby. Dos modos con la misma pantalla:
##   - Online: un jugador por PC; cada uno edita el suyo; el host puede añadir bots y expulsar.
##   - Local (pruebas / mismo PC): se añaden jugadores con teclado/mando y bots.
## La lógica de jugadores vive en Lobby; aquí solo se muestra y se piden cambios.

const COLUMNS := 4

var _grid: GridContainer
var _add_btn: JuicyButton
var _bot_btn: JuicyButton
var _next_btn: JuicyButton
var _share_btn: JuicyButton
var _hint: Label
var _title: Label
var _count_label: Label

func _ready() -> void:
	UIKit.setup_screen(self)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 24
	root.offset_right = -24
	root.offset_top = 14
	root.offset_bottom = -14
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	_title = UIKit.label("JUGADORES", &"HeaderLabel")
	root.add_child(_title)
	_count_label = UIKit.label("", &"HintLabel")
	root.add_child(_count_label)

	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(center)
	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", 14)
	_grid.add_theme_constant_override("v_separation", 14)
	center.add_child(_grid)

	_hint = UIKit.label("", &"HintLabel")
	root.add_child(_hint)

	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 16)
	root.add_child(bar)

	var back := UIKit.button("ATRÁS", &"DangerButton", Vector2(200, 0))
	back.pressed.connect(GameManager.go_to_menu)
	bar.add_child(back)
	_add_btn = UIKit.button("+ JUGADOR", &"SecondaryButton", Vector2(230, 0))
	_add_btn.pressed.connect(func() -> void: Lobby.add_player())
	bar.add_child(_add_btn)
	_bot_btn = UIKit.button("+ BOT", &"SecondaryButton", Vector2(180, 0))
	_bot_btn.pressed.connect(func() -> void: Lobby.add_bot())
	bar.add_child(_bot_btn)
	# (web, host) Copia el enlace que mete a tus amigos directamente en la sala.
	_share_btn = UIKit.button("COPIAR ENLACE", &"SecondaryButton", Vector2(260, 0))
	_share_btn.pressed.connect(_copy_link)
	bar.add_child(_share_btn)
	_next_btn = UIKit.button("CONTINUAR", &"PrimaryButton", Vector2(280, 0))
	_next_btn.pressed.connect(GameManager.go_to_setup)
	bar.add_child(_next_btn)

	Lobby.roster_changed.connect(_refresh)
	NetworkManager.backend.hint_changed.connect(_refresh)

	# Modo local sin jugadores: arranca con el jugador 1 para que no se vea vacío.
	if not NetworkManager.is_online and Lobby.players.is_empty():
		Lobby.add_player()
	else:
		_refresh()

## Reconstruye las tarjetas de jugador y el estado de los botones.
func _refresh() -> void:
	for child in _grid.get_children():
		child.queue_free()
	var is_host := NetworkManager.is_host()
	var online := NetworkManager.is_online
	for p in Lobby.players:
		_grid.add_child(_make_card(p))

	if online:
		var hint := NetworkManager.join_hint()
		var code := hint if NetworkManager.backend is WebRTCBackend else ""
		_title.text = "SALA ONLINE · CÓDIGO %s" % code if not code.is_empty() else "SALA ONLINE"
		# El código ya va en el título; la IP (escritorio) se muestra aquí.
		var where := " · %s: %s" % [NetworkManager.join_hint_label(), hint] if (is_host and not hint.is_empty() and code.is_empty()) else ""
		_count_label.text = "%d / %d jugadores%s" % [Lobby.players.size(), PlayerData.MAX_PLAYERS, where]
	else:
		_title.text = "JUGADORES (LOCAL)"
		_count_label.text = "%d / %d jugadores · %d minijuegos disponibles" % [
				Lobby.players.size(), PlayerData.MAX_PLAYERS, GameManager.compatible_minigame_count()]

	var full := Lobby.players.size() >= PlayerData.MAX_PLAYERS
	# Un jugador por PC online: "+ JUGADOR" solo existe en modo local.
	_add_btn.visible = is_host and not online
	_share_btn.visible = is_host and online and OS.has_feature("web") and not NetworkManager.join_hint().is_empty()
	_bot_btn.visible = is_host
	_next_btn.visible = is_host
	_add_btn.disabled = full or Lobby.free_devices().is_empty()
	_bot_btn.disabled = full
	_next_btn.disabled = Lobby.players.size() < GameManager.MIN_PLAYERS

	if not is_host:
		_hint.text = "Esperando a que el anfitrión empiece…"
	elif _next_btn.disabled:
		_hint.text = GameManager.start_blocker()
	elif online:
		_hint.text = "Controles: WASD o flechas + Espacio/Enter, o mando (stick + A)."
	elif _add_btn.disabled and not full:
		_hint.text = "No quedan teclados/mandos libres: conecta un mando o añade bots."
	else:
		_hint.text = "Teclado 1: WASD + Espacio · Teclado 2: Flechas + Enter · Mando: stick + A"

func _copy_link() -> void:
	DisplayServer.clipboard_set(WebRTCBackend.share_link(NetworkManager.join_hint()))
	_hint.text = "Enlace copiado: pásaselo a tus amigos y entrarán directos a la sala."

## Tarjeta compacta de jugador: avatar + nombre/color arriba, dispositivo y acciones abajo.
func _make_card(p: PlayerData) -> Control:
	var can_edit := Lobby.can_edit(p)
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(280, 0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	card.add_child(box)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	box.add_child(top)
	var avatar := PlayerAvatar.new(76)
	avatar.set_player(p)
	top.add_child(avatar)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(right)

	var name_edit := LineEdit.new()
	name_edit.text = p.display_name
	name_edit.max_length = Lobby.MAX_NAME_LENGTH
	name_edit.custom_minimum_size = Vector2(150, 0)
	name_edit.add_theme_font_size_override("font_size", 22)
	name_edit.editable = can_edit
	# Los nombres de los demás no se editan, pero se tienen que leer igual de bien que el tuyo.
	name_edit.add_theme_color_override("font_uneditable_color", name_edit.get_theme_color("font_color"))
	# El cambio se confirma al pulsar Enter o salir del campo (online viaja al host).
	name_edit.text_submitted.connect(func(t: String) -> void: Lobby.set_player_name(p, t))
	name_edit.focus_exited.connect(func() -> void:
		if name_edit.text != p.display_name:
			Lobby.set_player_name(p, name_edit.text))
	right.add_child(name_edit)

	# Color:  ‹ [■] ›
	var color_row := HBoxContainer.new()
	color_row.add_theme_constant_override("separation", 6)
	right.add_child(color_row)
	var prev := UIKit.button("‹", &"SmallButton", Vector2(40, 0))
	prev.pressed.connect(func() -> void: Lobby.cycle_color(p, -1))
	var swatch := Panel.new()
	var sw_style := StyleBoxFlat.new()
	sw_style.bg_color = p.color
	sw_style.set_corner_radius_all(12)
	sw_style.set_border_width_all(3)
	sw_style.border_color = Palette.WHITE
	swatch.add_theme_stylebox_override("panel", sw_style)
	swatch.custom_minimum_size = Vector2(46, 30)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var next := UIKit.button("›", &"SmallButton", Vector2(40, 0))
	next.pressed.connect(func() -> void: Lobby.cycle_color(p, 1))
	color_row.add_child(prev)
	color_row.add_child(swatch)
	color_row.add_child(next)
	prev.visible = can_edit
	next.visible = can_edit

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 8)
	box.add_child(bottom)
	var device := UIKit.label(p.device_label(), &"HintLabel", HORIZONTAL_ALIGNMENT_LEFT)
	device.add_theme_font_size_override("font_size", 16)
	device.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	device.custom_minimum_size = Vector2(80, 0)
	device.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(device)
	if not NetworkManager.is_online and can_edit:
		var change := UIKit.button("CAMBIAR", &"SmallButton", Vector2(0, 0))
		change.tooltip_text = "Cambiar de teclado/mando"
		change.add_theme_font_size_override("font_size", 16)
		change.pressed.connect(func() -> void: Lobby.cycle_device(p))
		bottom.add_child(change)
	if Lobby.can_remove(p):
		var remove := UIKit.button("✕", &"SmallDangerButton", Vector2(40, 0))
		remove.tooltip_text = "Quitar / expulsar"
		remove.pressed.connect(func() -> void: Lobby.remove_player(p.id))
		bottom.add_child(remove)
	return card
