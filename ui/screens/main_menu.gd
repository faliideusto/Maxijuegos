extends Control
## Menú principal: jugar en local, crear/unirse a sala online, salir.

var _main_box: VBoxContainer
var _online_card: PanelContainer
var _address_edit: LineEdit
var _status: Label
var _title: Label

func _ready() -> void:
	UIKit.setup_screen(self)
	_main_box = UIKit.centered_vbox(self, 18)

	_title = UIKit.label("MAXIJUEGOS", &"TitleLabel")
	_main_box.add_child(_title)
	_main_box.add_child(UIKit.label("¡El party game de minijuegos!", &"HeaderLabel"))
	_main_box.add_child(_spacer(24))

	var play := UIKit.button("JUGAR EN LOCAL")
	play.pressed.connect(GameManager.go_to_lobby)
	_main_box.add_child(play)

	var online := UIKit.button("ONLINE", &"SecondaryButton")
	online.pressed.connect(_toggle_online)
	_main_box.add_child(online)

	var quit := UIKit.button("SALIR", &"DangerButton")
	quit.pressed.connect(func() -> void: get_tree().quit())
	_main_box.add_child(quit)
	# En web no tiene sentido "Salir".
	quit.visible = not OS.has_feature("web")

	_build_online_card()

	var info := UIKit.label("%d minijuegos cargados · v0.1 (fase 1)" % MinigameRegistry.get_all().size(), &"HintLabel")
	info.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	info.grow_horizontal = Control.GROW_DIRECTION_BOTH
	info.grow_vertical = Control.GROW_DIRECTION_BEGIN
	info.offset_bottom = -12
	add_child(info)

	# Animaciones de entrada.
	var i := 0
	for child in _main_box.get_children():
		if child is Control:
			UIKit.pop_in(child, 0.07 * i)
			i += 1
	_wobble_title()

	GameManager.notice.connect(_on_notice)
	NetworkManager.connection_failed.connect(func() -> void: _set_status("No se pudo conectar."))

func _wobble_title() -> void:
	await get_tree().process_frame
	_title.pivot_offset = _title.size * 0.5
	var t := create_tween().set_loops().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(_title, "rotation_degrees", 2.0, 1.4)
	t.tween_property(_title, "rotation_degrees", -2.0, 1.4)

func _build_online_card() -> void:
	_online_card = PanelContainer.new()
	_online_card.visible = false
	_online_card.set_anchors_preset(Control.PRESET_CENTER)
	_online_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_online_card.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_online_card)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	_online_card.add_child(box)
	box.add_child(UIKit.label("JUEGO ONLINE", &"HeaderLabel"))
	box.add_child(UIKit.label("Prueba LAN / IP (Steam llegará más adelante)", &"HintLabel"))

	var host := UIKit.button("CREAR SALA", &"PrimaryButton", Vector2(380, 0))
	host.pressed.connect(_on_host)
	box.add_child(host)

	box.add_child(UIKit.label("o únete a una sala:", &"HintLabel"))
	_address_edit = LineEdit.new()
	_address_edit.text = "127.0.0.1"
	_address_edit.placeholder_text = "IP del anfitrión"
	box.add_child(_address_edit)
	var join := UIKit.button("UNIRSE", &"SecondaryButton", Vector2(380, 0))
	join.pressed.connect(_on_join)
	box.add_child(join)

	_status = UIKit.label("", &"HintLabel")
	box.add_child(_status)
	var back := UIKit.button("VOLVER", &"DangerButton", Vector2(380, 0))
	back.pressed.connect(_toggle_online)
	box.add_child(back)

func _toggle_online() -> void:
	_online_card.visible = not _online_card.visible
	_main_box.get_parent().visible = not _online_card.visible
	if _online_card.visible:
		_status.text = ""
		UIKit.pop_in(_online_card)

func _on_host() -> void:
	if GameManager.host_online() != OK:
		_set_status("No se pudo crear la sala (¿puerto ocupado?).")
		return
	GameManager.go_to_lobby()

func _on_join() -> void:
	var address := _address_edit.text.strip_edges()
	if address.is_empty():
		_set_status("Escribe una IP.")
		return
	_set_status("Conectando…")
	if GameManager.join_online(address) != OK:
		_set_status("Dirección no válida.")

func _on_notice(text: String) -> void:
	_set_status(text)

func _set_status(text: String) -> void:
	if _status:
		_status.text = text

func _spacer(height: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c
