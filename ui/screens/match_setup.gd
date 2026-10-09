extends Control
## Configuración de la partida: cuántos minijuegos se jugarán (al azar) o cuáles, eligiéndolos a mano.

const PRESETS: Array[int] = [3, 5, 10]
const PICK_COLUMNS := 4

var _count_label: Label
var _info: Label
var _preset_buttons: Dictionary = {}  # int -> Button
var _start_btn: JuicyButton
var _pick_buttons: Dictionary = {}    # id (StringName) -> Button

func _ready() -> void:
	UIKit.setup_screen(self)
	var box := UIKit.centered_vbox(self, 12)

	box.add_child(UIKit.label("¿CUÁNTOS MINIJUEGOS?", &"HeaderLabel"))

	# Selector principal:  [−]  5  [+]
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 24)
	box.add_child(row)
	var minus := UIKit.button("−", &"SecondaryButton", Vector2(90, 0))
	minus.pressed.connect(func() -> void: _change(-1))
	row.add_child(minus)
	_count_label = UIKit.label("", &"TitleLabel")
	_count_label.custom_minimum_size = Vector2(200, 0)
	row.add_child(_count_label)
	var plus := UIKit.button("+", &"SecondaryButton", Vector2(90, 0))
	plus.pressed.connect(func() -> void: _change(1))
	row.add_child(plus)

	# Atajos 3 / 5 / 10.
	var presets := HBoxContainer.new()
	presets.alignment = BoxContainer.ALIGNMENT_CENTER
	presets.add_theme_constant_override("separation", 14)
	box.add_child(presets)
	for n in PRESETS:
		var b := UIKit.button(str(n), &"SecondaryButton", Vector2(110, 0))
		b.pressed.connect(func() -> void: _set_count(n))
		presets.add_child(b)
		_preset_buttons[n] = b

	# Selector de minijuegos: tocar uno lo añade a la partida (en ese orden); tocarlo otra vez lo quita.
	box.add_child(UIKit.label("O ELIGE CUÁLES JUGAR, EN EL ORDEN QUE QUIERAS", &"HintLabel"))
	var grid := GridContainer.new()
	grid.columns = PICK_COLUMNS
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(grid)
	var compatible := MinigameRegistry.get_compatible(Lobby.players.size())
	var still_valid: Array[StringName] = []
	for meta in compatible:
		var pick := UIKit.button(meta.display_name, &"SmallButton", Vector2(270, 50))
		pick.pressed.connect(func() -> void: _toggle_pick(meta.id))
		grid.add_child(pick)
		_pick_buttons[meta.id] = pick
	for id in GameManager.chosen_ids:
		if _pick_buttons.has(id):
			still_valid.append(id)
	GameManager.chosen_ids = still_valid

	_info = UIKit.label("", &"HintLabel")
	box.add_child(_info)

	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 16)
	box.add_child(bar)
	var back := UIKit.button("ATRÁS", &"DangerButton", Vector2(200, 0))
	back.pressed.connect(GameManager.go_to_lobby)
	bar.add_child(back)
	_start_btn = UIKit.button("¡EMPEZAR!", &"PrimaryButton", Vector2(320, 0))
	_start_btn.pressed.connect(func() -> void: GameManager.start_match())
	bar.add_child(_start_btn)

	_refresh()
	UIKit.fit_to_screen(box)
	var i := 0
	for child in box.get_children():
		UIKit.pop_in(child as Control, 0.06 * i)
		i += 1

func _change(delta: int) -> void:
	_set_count(GameManager.minigame_count + delta)

func _toggle_pick(id: StringName) -> void:
	if GameManager.chosen_ids.has(id):
		GameManager.chosen_ids.erase(id)
	else:
		GameManager.chosen_ids.append(id)
	_refresh()
	UIKit.punch(_count_label)

## Cambiar el número vuelve a la partida al azar.
func _set_count(n: int) -> void:
	GameManager.chosen_ids.clear()
	GameManager.set_minigame_count(n)
	_refresh()
	UIKit.punch(_count_label)

func _refresh() -> void:
	var chosen := GameManager.chosen_ids
	var count := GameManager.minigame_count if chosen.is_empty() else chosen.size()
	_count_label.text = str(count)
	for id in _pick_buttons:
		var pick: Button = _pick_buttons[id]
		var order := chosen.find(id)
		var meta := MinigameRegistry.get_by_id(id)
		pick.text = meta.display_name if order < 0 else "%d · %s" % [order + 1, meta.display_name]
		pick.self_modulate = Color.WHITE if order < 0 else Palette.YELLOW
	var available := GameManager.compatible_minigame_count()
	var players := Lobby.players.size()
	if not chosen.is_empty():
		_info.text = "Jugaréis los %d elegidos, en ese orden. Cambia el número para volver al azar." % chosen.size()
	elif count > available and available > 0:
		_info.text = "Hay %d minijuegos para %d jugadores: algunos se repetirán." % [available, players]
	else:
		_info.text = "Minijuegos distintos para %d jugadores: %d" % [players, available]
	var blocker := GameManager.start_blocker()
	_start_btn.disabled = not blocker.is_empty()
	if not blocker.is_empty():
		_info.text = blocker
	for n in _preset_buttons:
		(_preset_buttons[n] as Button).theme_type_variation = &"PrimaryButton" if (n == count and chosen.is_empty()) else &"SecondaryButton"
