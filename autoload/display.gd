extends Node
## Pantalla (autoload): pantalla completa con F11 o desde Ajustes. En escritorio se recuerda en
## user://settings.cfg; en web el navegador solo deja entrar en pantalla completa tras pulsar algo, así que
## no se restaura al abrir la página.
##
## También la CALIDAD GRÁFICA de los minijuegos 3D, sin que cada minijuego haga nada: cada SubViewport,
## WorldEnvironment y DirectionalLight3D que aparece se ajusta al nivel actual (antialiasing, resolución
## 3D, brillo/glow y sombras). En automático (por defecto) se empieza en ALTA en escritorio y MEDIA en web,
## y si un minijuego 3D va a tirones se baja un nivel sola: en el navegador un juego lento retrasa la red
## y entrecorta el audio, que se mezcla en el mismo hilo.

const SETTINGS_PATH := "user://settings.cfg"

enum Quality { LOW, MEDIUM, HIGH }
const QUALITY_NAMES := ["BAJA", "MEDIA", "ALTA"]
const LOW_3D_SCALE := 0.6            # resolución 3D en calidad BAJA (se reescala con filtro bilineal)
const SLOW_FPS := 40.0               # por debajo de esto (media de una ventana de medida) se baja la calidad
const MEASURE_SECONDS := 3.0
const WARMUP_SECONDS := 2.0

signal fullscreen_changed(on: bool)
signal quality_changed(level: int)

var quality: int = Quality.HIGH
var auto_quality: bool = true

var _tracked: Array = []             # nodos 3D ajustados (para reaplicar al cambiar de nivel)
var _measure_t: float = 0.0
var _measure_frames: int = 0
var _warmup: float = 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().node_added.connect(_on_node_added)
	quality = Quality.MEDIUM if OS.has_feature("web") else Quality.HIGH
	if DisplayServer.get_name() == "headless":
		return
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		var q: Variant = cfg.get_value("display", "quality", "auto")
		if typeof(q) == TYPE_INT and q >= Quality.LOW and q <= Quality.HIGH:
			auto_quality = false
			quality = q
		if not OS.has_feature("web") and bool(cfg.get_value("display", "fullscreen", false)):
			set_fullscreen(true)

# ----------------------------------------------------------------------------
# Calidad gráfica
# ----------------------------------------------------------------------------

## Fija el nivel a mano (y deja de ajustarlo solo) o vuelve a automático con level = -1.
func set_quality(level: int) -> void:
	auto_quality = level < 0
	if not auto_quality:
		_change_quality(level)
	elif OS.has_feature("web"):
		_change_quality(Quality.MEDIUM)
	else:
		_change_quality(Quality.HIGH)
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("display", "quality", "auto" if auto_quality else quality)
	cfg.save(SETTINGS_PATH)

func quality_label() -> String:
	return ("AUTO · " if auto_quality else "") + QUALITY_NAMES[quality]

func _change_quality(level: int) -> void:
	level = clampi(level, Quality.LOW, Quality.HIGH)
	if level == quality:
		return
	quality = level
	for n in _tracked.duplicate():
		if is_instance_valid(n):
			_apply(n)
		else:
			_tracked.erase(n)
	quality_changed.emit(quality)

func _on_node_added(n: Node) -> void:
	if n is SubViewport or n is WorldEnvironment or n is DirectionalLight3D:
		_apply.call_deferred(n)   # diferido: después de que el minijuego acabe de configurarlo

func _apply(n: Node) -> void:
	if not is_instance_valid(n):
		return
	if not _tracked.has(n):
		_tracked.append(n)
		n.tree_exited.connect(func() -> void: _tracked.erase(n), CONNECT_ONE_SHOT)
	var high := quality == Quality.HIGH
	var low := quality == Quality.LOW
	if n is SubViewport:
		var vp := n as SubViewport
		if not vp.has_meta("q_msaa"):
			vp.set_meta("q_msaa", vp.msaa_3d)
		vp.msaa_3d = vp.get_meta("q_msaa") if high else Viewport.MSAA_DISABLED
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = LOW_3D_SCALE if low else 1.0
		if vp.world_3d != null and vp.world_3d.environment != null:
			_apply_env(vp.world_3d.environment, low)
	elif n is WorldEnvironment:
		if (n as WorldEnvironment).environment != null:
			_apply_env((n as WorldEnvironment).environment, low)
	elif n is DirectionalLight3D:
		var light := n as DirectionalLight3D
		if not light.has_meta("q_shadow"):
			light.set_meta("q_shadow", light.shadow_enabled)
		light.shadow_enabled = bool(light.get_meta("q_shadow")) and not low

func _apply_env(env: Environment, low: bool) -> void:
	if not env.has_meta("q_glow"):
		env.set_meta("q_glow", env.glow_enabled)
	env.glow_enabled = bool(env.get_meta("q_glow")) and not low

## En automático, mide los fps mientras hay un minijuego 3D en pantalla y baja la calidad si va lento.
func _process(delta: float) -> void:
	if not auto_quality or quality == Quality.LOW or Engine.time_scale != 1.0 or DisplayServer.get_name() == "headless":
		return
	var showing_3d := false
	for n in _tracked:
		if is_instance_valid(n) and n is SubViewport:
			showing_3d = true
			break
	if not showing_3d or get_tree().paused:
		_measure_t = 0.0
		_measure_frames = 0
		_warmup = WARMUP_SECONDS
		return
	if _warmup > 0.0:
		_warmup -= delta   # (al cargar un 3D se compilan sombreadores: esos tirones no cuentan)
		return
	_measure_t += delta
	_measure_frames += 1
	if _measure_t >= MEASURE_SECONDS:
		var fps := _measure_frames / _measure_t
		_measure_t = 0.0
		_measure_frames = 0
		if fps < SLOW_FPS:
			DevCli.log_event("quality_down fps=%d level=%d" % [roundi(fps), quality - 1])
			_change_quality(quality - 1)

func is_fullscreen() -> bool:
	var mode := DisplayServer.window_get_mode()
	return mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN

# ----------------------------------------------------------------------------
# Pantalla completa
# ----------------------------------------------------------------------------

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
