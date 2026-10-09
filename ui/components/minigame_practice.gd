class_name MinigamePractice
extends PanelContainer
## Práctica jugable en miniatura (pantalla de presentación de cada minijuego): el propio minijuego corre dentro de un
## recuadro pequeño y el jugador lo prueba de verdad con SUS controles (la práctica no cuenta para nada); al acabar se
## reinicia sola. Así se entiende cómo se juega sin vídeos ni textos largos, y nunca queda desfasado del juego real.
##
## Quién juega en el recuadro (ver MinigamePractice.plan): siempre un solo recuadro.
##   - Minijuegos COMPARTIDOS (HOST_AUTHORITATIVE): juegan a la vez todas las personas de este PC (modo local: todas las de
##     ese ordenador; online: la de este PC) y el resto del reparto, como bots con su nombre y color.
##   - Minijuegos de "cada uno en su pantalla" (LOCAL_PARALLEL): solo tu pantalla de práctica, sin las de los demás.
## Detalles: el minijuego se ejecuta con su pantalla lógica de siempre (1280x720) dentro de un SubViewport reducido, y el
## SubViewportContainer le reenvía el ratón y el teclado (clic, escribir...). Sin música propia (sigue la del menú) y,
## en las pruebas sin ventana (headless), no se crea nada.

const RESTART_DELAY := 1.3
const MAX_SECONDS := 80.0
const BASE_VIEW := Vector2i(576, 324)

## Para las pruebas automáticas: crear la práctica también en headless.
static var force_in_headless: bool = false

var _meta: MinigameMeta
var _local: PlayerData = null          # jugador de este recuadro (LOCAL_PARALLEL); null en los compartidos
var _view: Vector2i = BASE_VIEW
var _container: SubViewportContainer
var _vp: SubViewport
var _mg: Minigame = null
var _roster: Array[PlayerData] = []
var _extra_bots: Array[PlayerData] = []
var _elapsed: float = 0.0
var _restart_in: float = -1.0
var _badge: Label

## Los recuadros que hay que mostrar: lista de {"local": PlayerData o null, "size": Vector2i}. Siempre UNO solo: en los
## minijuegos de "cada uno en su pantalla" es tu pantalla de práctica (la de la primera persona de este PC) y en los
## compartidos, el recuadro común donde juegan a la vez todas las personas de este PC.
static func plan(meta: MinigameMeta) -> Array:
	if meta.execution_mode == MinigameMeta.ExecutionMode.LOCAL_PARALLEL:
		var me: PlayerData = Lobby.get_local_player()
		if me == null:
			for p in Lobby.players:
				if p.is_local_human:
					me = p
					break
		if me == null:
			me = Lobby.players[0]
		return [{"local": me, "size": BASE_VIEW}]
	return [{"local": null, "size": BASE_VIEW}]

func setup(meta: MinigameMeta, local: PlayerData, view: Vector2i) -> void:
	_meta = meta
	_local = local
	_view = view

func _ready() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.35)
	sb.set_corner_radius_all(18)
	sb.set_content_margin_all(5)
	sb.border_color = _meta.accent_color
	sb.set_border_width_all(4)
	add_theme_stylebox_override("panel", sb)
	clip_contents = true
	if DisplayServer.get_name() == "headless" and not force_in_headless:
		custom_minimum_size = Vector2(_view)
		return
	_container = SubViewportContainer.new()
	_container.stretch = true
	_container.custom_minimum_size = Vector2(_view)
	_container.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_container)
	_vp = SubViewport.new()
	_vp.size = _view
	_vp.size_2d_override = Vector2i(1280, 720)           # el minijuego ve su pantalla de siempre
	_vp.size_2d_override_stretch = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.handle_input_locally = true
	_vp.gui_embed_subwindows = false
	_container.add_child(_vp)
	# Etiqueta "PRÁCTICA" (y el nombre de quien juega, si hay varios recuadros).
	_badge = Label.new()
	_badge.add_theme_font_size_override("font_size", 16)
	_badge.add_theme_color_override("font_color", Palette.WHITE)
	_badge.add_theme_color_override("font_outline_color", Palette.PURPLE_DARK)
	_badge.add_theme_constant_override("outline_size", 5)
	_badge.text = "PRÁCTICA"
	_badge.position = Vector2(12, float(_view.y) - 30.0)      # abajo a la izquierda: arriba suelen estar los marcadores del juego
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_container.add_child(_badge)           # dentro del contenedor del visor: se coloca donde se le dice, encima del juego
	# La primera partida se prepara tras mostrar la pantalla (la carga de algunos minijuegos tarda un instante).
	await get_tree().process_frame
	if is_instance_valid(self):
		_start_practice()

func _exit_tree() -> void:
	_cleanup()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

# ----------------------------------------------------------------------------

## Reparto de la práctica: los de este PC con sus controles reales; los remotos, como bots con su nombre y color.
func _build_roster() -> Array[PlayerData]:
	var out: Array[PlayerData] = []
	for p in Lobby.players:
		if p.is_remote:
			var b := PlayerData.new()
			b.id = 100 + p.id
			b.display_name = p.display_name
			b.color_index = p.color_index
			b.device = PlayerData.DEVICE_BOT
			InputManager.register_player(b)
			_extra_bots.append(b)
			out.append(b)
		else:
			out.append(p)
	return out

func _start_practice() -> void:
	_cleanup_minigame()
	if _roster.is_empty():
		_roster = _build_roster()
	var node := _meta.scene.instantiate()
	_mg = node as Minigame
	if _mg == null:
		node.queue_free()
		return
	_mg.meta = _meta
	_mg.is_authority = true
	_mg.demo = true
	_vp.add_child(_mg)
	var parallel := _meta.execution_mode == MinigameMeta.ExecutionMode.LOCAL_PARALLEL
	var local: PlayerData = null
	if parallel:
		local = _local
	else:
		local = Lobby.get_local_player()           # online: la persona de este PC
	_mg.configure(_meta.execution_mode, randi(), local)
	_mg.prepare(_roster)
	_mg.start(_roster)
	_mg.ended.connect(_schedule_restart, CONNECT_ONE_SHOT)
	_mg.result_reported.connect(func(_s: float, _t: float) -> void: _schedule_restart(), CONNECT_ONE_SHOT)
	_elapsed = 0.0
	_restart_in = -1.0

func _schedule_restart() -> void:
	if _restart_in < 0.0:
		_restart_in = RESTART_DELAY

func _process(delta: float) -> void:
	if _mg == null:
		return
	_elapsed += delta
	if _restart_in >= 0.0:
		_restart_in -= delta
		if _restart_in < 0.0:
			_start_practice()
	elif _elapsed > MAX_SECONDS:
		_start_practice()

func _cleanup_minigame() -> void:
	if _mg != null and is_instance_valid(_mg):
		_mg.queue_free()
	_mg = null
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _cleanup() -> void:
	_cleanup_minigame()
	for b in _extra_bots:
		InputManager.unregister_player(b)
	_extra_bots.clear()

## (pruebas) El minijuego que corre ahora.
func debug_minigame() -> Minigame:
	return _mg
