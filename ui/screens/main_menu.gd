extends Control
## Menú principal: jugar online (crear sala / unirse), modo local de pruebas, ajustes, salir.

var _main_box: VBoxContainer
var _online_card: PanelContainer
var _settings_card: PanelContainer
var _music_value: Label
var _sfx_value: Label
var _mute_btn: JuicyButton
var _fullscreen_btn: JuicyButton
var _quality_btn: JuicyButton
var _name_edit: LineEdit
var _address_edit: LineEdit
var _status: Label
var _notice: Label
var _title: Label
var _busy: bool = false

const WEB_BOTS := 3
## Paso de los botones − / + de volumen (%).
const VOLUME_STEP := 10

## (web) El código de ?sala=XXXX solo se usa la primera vez que se abre el menú.
static var _url_code_used: bool = false

func _ready() -> void:
	UIKit.setup_screen(self)
	_main_box = UIKit.centered_vbox(self, 18)

	_title = UIKit.label("MAXIJUEGOS", &"TitleLabel")
	_main_box.add_child(_title)
	_main_box.add_child(UIKit.label("¡El party game de minijuegos!", &"HeaderLabel"))
	_main_box.add_child(_spacer(16))

	var online := UIKit.button("JUGAR ONLINE")
	online.pressed.connect(_toggle_online)
	_main_box.add_child(online)

	var local := UIKit.button("MODO LOCAL (PRUEBAS)", &"SecondaryButton")
	local.pressed.connect(GameManager.go_to_lobby)
	_main_box.add_child(local)
	# En web: salas con código (WebRTC) y, en vez del modo local de pruebas, una partida contra bots.
	if OS.has_feature("web"):
		online.text = "JUGAR CON AMIGOS"
		local.text = "JUGAR CONTRA BOTS"
		local.pressed.disconnect(GameManager.go_to_lobby)
		local.pressed.connect(_play_vs_bots)

	var settings := UIKit.button("AJUSTES", &"SecondaryButton")
	settings.pressed.connect(_toggle_settings)
	_main_box.add_child(settings)

	var quit := UIKit.button("SALIR", &"DangerButton")
	quit.pressed.connect(func() -> void: get_tree().quit())
	_main_box.add_child(quit)
	# En web no tiene sentido "Salir".
	quit.visible = not OS.has_feature("web")

	# Aviso (rechazos, conexión perdida...) bajo los botones.
	_notice = UIKit.label("", &"HintLabel")
	_notice.add_theme_color_override("font_color", Palette.YELLOW)
	_main_box.add_child(_notice)

	_build_online_card()
	_build_settings_card()

	var info := UIKit.label("%d minijuegos cargados · v0.2 (fase 2)" % MinigameRegistry.get_all().size(), &"HintLabel")
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

	_notice.text = GameManager.take_notice()
	GameManager.notice.connect(_on_notice)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	_open_room_from_url()

## (web) Si la página trae ?sala=XXXX (enlace de un amigo), abre "unirse" con el código ya puesto.
func _open_room_from_url() -> void:
	if _url_code_used:
		return
	_url_code_used = true
	var code := WebRTCBackend.code_from_url()
	if code.is_empty():
		return
	_toggle_online()
	_address_edit.text = code
	_set_status("Te han invitado a la sala %s: escribe tu nombre y pulsa UNIRSE." % code)

## (web) Lobby ya preparado: tú (WASD + Espacio o clic) contra 3 bots.
func _play_vs_bots() -> void:
	if Lobby.players.is_empty():
		Lobby.add_player(PlayerData.DEVICE_KB1)
		for i in WEB_BOTS:
			Lobby.add_bot()
	GameManager.go_to_lobby()

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
	box.add_theme_constant_override("separation", 12)
	_online_card.add_child(box)
	box.add_child(UIKit.label("JUEGO ONLINE", &"HeaderLabel"))
	var web := OS.has_feature("web")
	box.add_child(UIKit.label("Crea una sala y pasa el código a tus amigos" if web
			else "Un jugador por PC · conexión por IP (Steam llegará más adelante)", &"HintLabel"))

	box.add_child(UIKit.label("Tu nombre:", &"HintLabel"))
	_name_edit = LineEdit.new()
	_name_edit.text = Lobby.profile_name
	_name_edit.max_length = Lobby.MAX_NAME_LENGTH
	box.add_child(_name_edit)

	var host := UIKit.button("CREAR SALA", &"PrimaryButton", Vector2(380, 0))
	host.pressed.connect(_on_host)
	box.add_child(host)

	box.add_child(UIKit.label("o únete a la sala de un amigo:", &"HintLabel"))
	_address_edit = LineEdit.new()
	_address_edit.text = "" if web else "127.0.0.1"
	_address_edit.placeholder_text = "Código de sala (p. ej. K7QF)" if web else "IP del anfitrión"
	box.add_child(_address_edit)
	var join := UIKit.button("UNIRSE", &"SecondaryButton", Vector2(380, 0))
	join.pressed.connect(_on_join)
	box.add_child(join)

	_status = UIKit.label("", &"HintLabel")
	box.add_child(_status)
	var back := UIKit.button("VOLVER", &"DangerButton", Vector2(380, 0))
	back.pressed.connect(_toggle_online)
	box.add_child(back)

## Ajustes: volumen de música y efectos, silencio (F10), pantalla completa (F11) y calidad gráfica.
func _build_settings_card() -> void:
	_settings_card = PanelContainer.new()
	_settings_card.visible = false
	_settings_card.set_anchors_preset(Control.PRESET_CENTER)
	_settings_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_settings_card.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_settings_card)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	_settings_card.add_child(box)
	box.add_child(UIKit.label("AJUSTES", &"HeaderLabel"))
	_music_value = _volume_row(box, "Música", Audio.get_music_percent, Audio.set_music_percent)
	_sfx_value = _volume_row(box, "Efectos", Audio.get_sfx_percent, Audio.set_sfx_percent)
	_mute_btn = UIKit.button("", &"SecondaryButton", Vector2(420, 0))
	_mute_btn.pressed.connect(func() -> void:
		Audio.set_muted(not Audio.muted)
		_refresh_settings())
	box.add_child(_mute_btn)
	_fullscreen_btn = UIKit.button("", &"SecondaryButton", Vector2(420, 0))
	_fullscreen_btn.pressed.connect(Display.toggle_fullscreen)
	box.add_child(_fullscreen_btn)
	Display.fullscreen_changed.connect(func(_on: bool) -> void: _refresh_settings())
	# Gráficos: AUTO → ALTA → MEDIA → BAJA → AUTO (si los juegos 3D van a tirones, BAJA).
	_quality_btn = UIKit.button("", &"SecondaryButton", Vector2(420, 0))
	_quality_btn.pressed.connect(func() -> void:
		if Display.auto_quality:
			Display.set_quality(Display.Quality.HIGH)
		elif Display.quality == Display.Quality.LOW:
			Display.set_quality(-1)
		else:
			Display.set_quality(Display.quality - 1)
		_refresh_settings())
	box.add_child(_quality_btn)
	box.add_child(UIKit.label("Atajos: F10 silencia · F11 pantalla completa", &"HintLabel"))
	var back := UIKit.button("VOLVER", &"DangerButton", Vector2(420, 0))
	back.pressed.connect(_toggle_settings)
	box.add_child(back)

## Fila "Nombre  −  80 %  +". Devuelve la etiqueta del valor.
func _volume_row(box: VBoxContainer, title: String, getter: Callable, setter: Callable) -> Label:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)
	var name_label := UIKit.label(title, &"", HORIZONTAL_ALIGNMENT_LEFT)
	name_label.custom_minimum_size = Vector2(140, 0)
	row.add_child(name_label)
	var value := UIKit.label("")
	value.custom_minimum_size = Vector2(110, 0)
	for delta in [-VOLUME_STEP, VOLUME_STEP]:
		var b := UIKit.button("−" if delta < 0 else "+", &"SecondaryButton", Vector2(72, 0))
		b.pressed.connect(func() -> void:
			setter.call(clampi(getter.call() + delta, 0, 100))
			_refresh_settings())
		row.add_child(b)
		if delta < 0:
			row.add_child(value)
	return value

func _refresh_settings() -> void:
	if _settings_card == null:
		return
	_music_value.text = "%d %%" % Audio.get_music_percent()
	_sfx_value.text = "%d %%" % Audio.get_sfx_percent()
	_mute_btn.text = "SONIDO: %s" % ("NO" if Audio.muted else "SÍ")
	_fullscreen_btn.text = "PANTALLA COMPLETA: %s" % ("SÍ" if Display.is_fullscreen() else "NO")
	_quality_btn.text = "GRÁFICOS: %s" % ("AUTO" if Display.auto_quality else Display.QUALITY_NAMES[Display.quality])

func _toggle_settings() -> void:
	_settings_card.visible = not _settings_card.visible
	_main_box.get_parent().visible = not _settings_card.visible
	if _settings_card.visible:
		_refresh_settings()
		UIKit.pop_in(_settings_card)

func _toggle_online() -> void:
	_online_card.visible = not _online_card.visible
	_main_box.get_parent().visible = not _online_card.visible
	_busy = false
	if _online_card.visible:
		_status.text = _notice.text
		UIKit.pop_in(_online_card)

func _on_host() -> void:
	Lobby.save_profile_name(_name_edit.text)
	if Lobby.host_room() != OK:
		_set_status("No se pudo crear la sala." if OS.has_feature("web") else "No se pudo crear la sala (¿puerto ocupado?).")
		return
	GameManager.go_to_lobby()

func _on_join() -> void:
	if _busy:
		return
	var address := _address_edit.text.strip_edges()
	if address.is_empty():
		_set_status("Escribe el código de la sala." if OS.has_feature("web") else "Escribe una IP.")
		return
	Lobby.save_profile_name(_name_edit.text)
	_set_status("Conectando…")
	_busy = true
	if Lobby.join_room(address) != OK:
		_set_status("Ese código no es válido (son 4 letras o números)." if OS.has_feature("web") else "Dirección no válida.")
		_busy = false

func _on_connection_failed() -> void:
	_busy = false
	var reason := NetworkManager.backend.failure_reason
	_set_status(reason if not reason.is_empty() else "No se pudo conectar.")

func _on_notice(text: String) -> void:
	_busy = false
	_set_status(text)

func _set_status(text: String) -> void:
	if _status:
		_status.text = text
	if _notice:
		_notice.text = text

func _spacer(height: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c
