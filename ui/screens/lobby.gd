extends Control
## Lobby: añadir/quitar jugadores (humanos o bots), cambiar nombre, color y dispositivo.

const COLUMNS := 4

var _grid: GridContainer
var _add_btn: JuicyButton
var _bot_btn: JuicyButton
var _next_btn: JuicyButton
var _hint: Label
var _title: Label
var _count_label: Label

func _ready() -> void:
	UIKit.setup_screen(self)
	GameManager.state = GameManager.State.LOBBY

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 40
	root.offset_right = -40
	root.offset_top = 24
	root.offset_bottom = -24
	root.add_theme_constant_override("separation", 14)
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
	_grid.add_theme_constant_override("h_separation", 16)
	_grid.add_theme_constant_override("v_separation", 16)
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
	_add_btn.pressed.connect(func() -> void: GameManager.add_player())
	bar.add_child(_add_btn)
	_bot_btn = UIKit.button("+ BOT", &"SecondaryButton", Vector2(180, 0))
	_bot_btn.pressed.connect(func() -> void: GameManager.add_bot())
	bar.add_child(_bot_btn)
	_next_btn = UIKit.button("CONTINUAR", &"PrimaryButton", Vector2(280, 0))
	_next_btn.pressed.connect(GameManager.go_to_setup)
	bar.add_child(_next_btn)

	GameManager.roster_changed.connect(_refresh)
	GameManager.notice.connect(func(t: String) -> void: _hint.text = t)

	# Partida nueva sin jugadores: arranca con el jugador 1 para que no se vea vacío.
	if GameManager.players.is_empty() and NetworkManager.is_host():
		GameManager.add_player()
	else:
		_refresh()

## Reconstruye las tarjetas de jugador y el estado de los botones.
func _refresh() -> void:
	for child in _grid.get_children():
		child.queue_free()
	var is_host := NetworkManager.is_host()
	for p in GameManager.players:
		_grid.add_child(_make_card(p, is_host))
	_count_label.text = "%d / %d jugadores · %d minijuegos disponibles" % [
			GameManager.players.size(), PlayerData.MAX_PLAYERS, GameManager.compatible_minigame_count()]
	if NetworkManager.is_online:
		_title.text = "SALA ONLINE" + (" (anfitrión)" if is_host else "")

	_add_btn.visible = is_host
	_bot_btn.visible = is_host
	_next_btn.visible = is_host
	var full := GameManager.players.size() >= PlayerData.MAX_PLAYERS
	_add_btn.disabled = full or GameManager.free_devices().is_empty()
	_bot_btn.disabled = full
	var blocker := GameManager.start_blocker()
	# En el lobby solo exigimos 2 jugadores; las otras razones se ven al continuar.
	_next_btn.disabled = GameManager.players.size() < GameManager.MIN_PLAYERS
	if not is_host:
		_hint.text = "Esperando a que el anfitrión empiece…"
	elif _next_btn.disabled:
		_hint.text = blocker
	elif _add_btn.disabled and not full:
		_hint.text = "No quedan teclados/mandos libres: conecta un mando o añade bots."
	else:
		_hint.text = "Teclado 1: WASD + Espacio · Teclado 2: Flechas + Enter · Mando: stick + A"

func _make_card(p: PlayerData, editable: bool) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(270, 0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	card.add_child(box)

	var avatar := PlayerAvatar.new(96)
	avatar.set_player(p)
	avatar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(avatar)

	var name_edit := LineEdit.new()
	name_edit.text = p.display_name
	name_edit.max_length = 14
	name_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_edit.editable = editable and not p.is_remote
	# El nombre se guarda directamente (no hace falta reconstruir las tarjetas).
	name_edit.text_changed.connect(func(t: String) -> void: p.display_name = t if not t.strip_edges().is_empty() else p.display_name)
	box.add_child(name_edit)

	# Color: ‹ ● ›
	var color_row := HBoxContainer.new()
	color_row.alignment = BoxContainer.ALIGNMENT_CENTER
	color_row.add_theme_constant_override("separation", 8)
	box.add_child(color_row)
	var prev := UIKit.button("‹", &"SecondaryButton", Vector2(56, 0))
	prev.pressed.connect(func() -> void: GameManager.cycle_color(p, -1))
	var next := UIKit.button("›", &"SecondaryButton", Vector2(56, 0))
	next.pressed.connect(func() -> void: GameManager.cycle_color(p, 1))
	var swatch := ColorRect.new()
	swatch.color = p.color
	swatch.custom_minimum_size = Vector2(60, 36)
	var swatch_style := PanelContainer.new()
	swatch_style.custom_minimum_size = Vector2(60, 36)
	swatch_style.add_child(swatch)
	color_row.add_child(prev)
	color_row.add_child(swatch_style)
	color_row.add_child(next)
	prev.visible = editable and not p.is_remote
	next.visible = prev.visible

	var device := UIKit.label(p.device_label(), &"HintLabel")
	device.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	device.custom_minimum_size = Vector2(230, 0)
	box.add_child(device)

	if editable and not p.is_remote:
		var actions := HBoxContainer.new()
		actions.alignment = BoxContainer.ALIGNMENT_CENTER
		actions.add_theme_constant_override("separation", 8)
		box.add_child(actions)
		var change := UIKit.button("MANDO/TECLADO", &"SecondaryButton", Vector2(0, 0))
		change.add_theme_font_size_override("font_size", 18)
		change.pressed.connect(func() -> void: GameManager.cycle_device(p))
		actions.add_child(change)
		var remove := UIKit.button("✕", &"DangerButton", Vector2(56, 0))
		remove.pressed.connect(func() -> void: GameManager.remove_player(p.id))
		actions.add_child(remove)
	elif editable:
		var kick := UIKit.button("✕ EXPULSAR", &"DangerButton", Vector2(0, 0))
		kick.add_theme_font_size_override("font_size", 18)
		kick.pressed.connect(func() -> void: GameManager.remove_player(p.id))
		box.add_child(kick)
	return card
