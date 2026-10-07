extends Control
## Configuración de la partida: cuántos minijuegos se jugarán.

const PRESETS: Array[int] = [3, 5, 10]

var _count_label: Label
var _info: Label
var _preset_buttons: Dictionary = {}  # int -> Button
var _start_btn: JuicyButton

func _ready() -> void:
	UIKit.setup_screen(self)
	var box := UIKit.centered_vbox(self, 18)

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
	var i := 0
	for child in box.get_children():
		UIKit.pop_in(child as Control, 0.06 * i)
		i += 1

func _change(delta: int) -> void:
	_set_count(GameManager.minigame_count + delta)

func _set_count(n: int) -> void:
	GameManager.set_minigame_count(n)
	_refresh()
	UIKit.punch(_count_label)

func _refresh() -> void:
	var count := GameManager.minigame_count
	_count_label.text = str(count)
	var available := GameManager.compatible_minigame_count()
	var players := GameManager.player_count()
	if count > available and available > 0:
		_info.text = "Hay %d minijuegos para %d jugadores: algunos se repetirán." % [available, players]
	else:
		_info.text = "Minijuegos distintos para %d jugadores: %d" % [players, available]
	var blocker := GameManager.start_blocker()
	_start_btn.disabled = not blocker.is_empty()
	if not blocker.is_empty():
		_info.text = blocker
	for n in _preset_buttons:
		(_preset_buttons[n] as Button).theme_type_variation = &"PrimaryButton" if n == count else &"SecondaryButton"
