extends Node
## Pantalla (autoload): pantalla completa con F11 o desde Ajustes. En escritorio se recuerda en
## user://settings.cfg; en web el navegador solo deja entrar en pantalla completa tras pulsar algo, así que
## no se restaura al abrir la página.

const SETTINGS_PATH := "user://settings.cfg"

signal fullscreen_changed(on: bool)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if DisplayServer.get_name() == "headless" or OS.has_feature("web"):
		return
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK and bool(cfg.get_value("display", "fullscreen", false)):
		set_fullscreen(true)

func is_fullscreen() -> bool:
	var mode := DisplayServer.window_get_mode()
	return mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN

func set_fullscreen(on: bool) -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED)
	if not OS.has_feature("web"):
		var cfg := ConfigFile.new()
		cfg.load(SETTINGS_PATH)
		cfg.set_value("display", "fullscreen", on)
		cfg.save(SETTINGS_PATH)
	fullscreen_changed.emit(on)

func toggle_fullscreen() -> void:
	set_fullscreen(not is_fullscreen())

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F11:
		toggle_fullscreen()
		get_viewport().set_input_as_handled()
