extends Node
## Audio (autoload): todo el sonido del juego, sintetizado por código (sin assets de terceros).
##
##   Audio.sfx(&"ui_click")            efecto (catálogo: SfxCatalog; también acepta un AudioStream)
##   Audio.play_music(&"menu")         música con fundido cruzado (pistas: MusicCatalog); &"" = silencio
##   Audio.stop_music()                fundido a silencio
##
## Automático (no hace falta tocar cada pantalla):
##   - Todos los botones (BaseButton) suenan al pasar el ratón y al pulsar ("ui_back" los de tipo peligro).
##   - Música por estado de la partida: menú/lobby/ajustes → "menu"; marcador → "scoreboard"; final →
##     fanfarria + "final". Cada minijuego pone la suya en Minigame.start() (campo `music` de su meta.tres).
##   - Entrar/salir jugadores del lobby, presentación del minijuego y transiciones de pantalla tienen sonido.
##
## Las pistas se generan en un hilo al arrancar (unos 12 s en total; el menú, en ~1 s) y suenan en cuanto
## están listas. En web, sin hilos, se cargan ya generadas de res://audio/music/ (tools/bake_music.sh).
## F10 silencia/activa todo el sonido; los volúmenes se guardan en user://settings.cfg.
## En modo headless (pruebas) no se genera ni se reproduce nada.

const SFX_POOL_SIZE := 14
const SETTINGS_PATH := "user://settings.cfg"
const MUSIC_BUS := &"Music"
const SFX_BUS := &"SFX"
## Pistas ya generadas para la versión web (tools/bake_music.sh).
const BAKED_MUSIC_DIR := "res://audio/music"

## Volumen (dB) de música y efectos; 0 = el del catálogo. Se guardan en user://settings.cfg.
var music_db: float = 0.0
var sfx_db: float = 0.0
var muted: bool = false
var enabled: bool = false

var _sfx_players: Array[AudioStreamPlayer] = []
var _sfx_next: int = 0
var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _music_active: AudioStreamPlayer
var _current: StringName = &""
var _tracks: Dictionary = {}          # id → AudioStream (WAV generado u OGG en web)
var _mutex := Mutex.new()
var _thread: Thread
var _stop_thread: bool = false
var _ready_ids: Array[StringName] = []
var _roster_count: int = 0
var _hover_t: float = 0.0
var _toast: Label
var _fades: Dictionary = {}           # AudioStreamPlayer → Tween (un fundido a la vez por reproductor)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	enabled = DisplayServer.get_name() != "headless"
	if not enabled:
		return
	_load_settings()
	_build_buses()
	for i in SFX_POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = SFX_BUS
		add_child(p)
		_sfx_players.append(p)
	_music_a = _make_music_player()
	_music_b = _make_music_player()
	_music_active = _music_a
	_apply_volumes()
	get_tree().node_added.connect(_on_node_added)
	GameManager.state_changed.connect(_on_state_changed)
	Lobby.roster_changed.connect(_on_roster_changed)
	_roster_count = Lobby.players.size()
	_build_toast()
	# La exportación web no tiene hilos: allí las pistas se cargan ya generadas cuando se piden.
	if not OS.has_feature("web"):
		_thread = Thread.new()
		_thread.start(_generate_music)
	# La pantalla inicial es el menú.
	play_music(&"menu", 0.0)

func _exit_tree() -> void:
	_stop_thread = true
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()

# ----------------------------------------------------------------------------
# API
# ----------------------------------------------------------------------------

## Reproduce un efecto. `sfx_name` es el nombre del catálogo (o directamente un AudioStream).
func sfx(sfx_name: Variant, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if not enabled or muted:
		return
	var stream: AudioStream = null
	if sfx_name is AudioStream:
		stream = sfx_name
	else:
		stream = SfxCatalog.get_sfx(StringName(sfx_name))
		if stream == null:
			push_warning("Audio: no existe el efecto '%s'" % sfx_name)
			return
	var p := _sfx_players[_sfx_next]
	_sfx_next = (_sfx_next + 1) % _sfx_players.size()
	p.stream = stream
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()

## Cambia de pista con fundido. Si la pista aún se está generando, empieza en cuanto esté lista.
func play_music(id: StringName, fade: float = 0.8) -> void:
	if not enabled:
		return
	if id == _current and _music_active.playing:
		return
	_current = id
	if id == &"":
		_fade_out(_music_active, fade)
		return
	if OS.has_feature("web") and not _tracks.has(id):
		_tracks[id] = _load_baked(id)
	_mutex.lock()
	var stream: AudioStream = _tracks.get(id)
	_mutex.unlock()
	if stream == null:
		_fade_out(_music_active, fade)   # empezará cuando la pista esté lista (_process)
		return
	_start_track(id, stream, fade)

func stop_music(fade: float = 0.8) -> void:
	play_music(&"", fade)

func toggle_mute() -> void:
	set_muted(not muted)
	_show_toast("Sonido: NO" if muted else "Sonido: SÍ")

func set_muted(value: bool) -> void:
	muted = value
	if not enabled:
		return
	AudioServer.set_bus_mute(AudioServer.get_bus_index(MUSIC_BUS), muted)
	AudioServer.set_bus_mute(AudioServer.get_bus_index(SFX_BUS), muted)
	if muted:
		for p in _sfx_players:
			p.stop()
	_save_settings()

## Volumen de música y efectos en % (0-100) para la pantalla de ajustes; 100 = el del catálogo.
func get_music_percent() -> int:
	return _db_to_percent(music_db)

func get_sfx_percent() -> int:
	return _db_to_percent(sfx_db)

func set_music_percent(percent: int) -> void:
	music_db = _percent_to_db(percent)
	_apply_and_save()

func set_sfx_percent(percent: int) -> void:
	sfx_db = _percent_to_db(percent)
	_apply_and_save()

func _apply_and_save() -> void:
	if not enabled:
		return
	_apply_volumes()
	_save_settings()

static func _percent_to_db(percent: int) -> float:
	return linear_to_db(clampi(percent, 0, 100) / 100.0) if percent > 0 else -80.0

static func _db_to_percent(db: float) -> int:
	return clampi(roundi(db_to_linear(db) * 100.0), 0, 100) if db > -79.0 else 0

# ----------------------------------------------------------------------------
# Música
# ----------------------------------------------------------------------------

## (hilo) Renderiza todas las pistas en el orden del catálogo.
func _generate_music() -> void:
	for id in MusicCatalog.ORDER:
		if _stop_thread:
			return
		var samples := SynthMusic.render(MusicCatalog.SPECS[id])
		var stream := SynthMusic.to_stream(samples)
		_mutex.lock()
		_tracks[id] = stream
		_ready_ids.append(id)
		_mutex.unlock()

## (web) Pista generada de antemano, en bucle. null si falta (sin música, como antes).
func _load_baked(id: StringName) -> AudioStream:
	var path := "%s/%s.ogg" % [BAKED_MUSIC_DIR, id]
	if not ResourceLoader.exists(path):
		push_warning("Audio: falta la pista %s (ejecuta tools/bake_music.sh)" % path)
		return null
	var stream := load(path) as AudioStreamOggVorbis
	if stream != null:
		stream.loop = true
	return stream

func _process(delta: float) -> void:
	if not enabled:
		return
	_hover_t = maxf(0.0, _hover_t - delta)
	# ¿Se ha terminado de generar la pista que se estaba esperando?
	_mutex.lock()
	var ids := _ready_ids.duplicate()
	_ready_ids.clear()
	_mutex.unlock()
	for id in ids:
		DevCli.log_event("audio track_ready=%s" % id)
		if id == _current and not _music_active.playing:
			_mutex.lock()
			var stream: AudioStream = _tracks[id]
			_mutex.unlock()
			_start_track(id, stream, 1.2)

func _make_music_player() -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = MUSIC_BUS
	p.volume_db = -60.0
	add_child(p)
	return p

func _start_track(id: StringName, stream: AudioStream, fade: float) -> void:
	DevCli.log_event("audio music=%s" % id)
	var old := _music_active
	var next := _music_b if old == _music_a else _music_a
	_kill_fade(next)
	next.stream = stream
	next.volume_db = -60.0 if fade > 0.0 else float(MusicCatalog.VOLUME_DB.get(id, -15.0))
	next.play()
	_music_active = next
	if fade > 0.0:
		var t := create_tween()
		t.tween_property(next, "volume_db", float(MusicCatalog.VOLUME_DB.get(id, -15.0)), fade)
		_fades[next] = t
		_fade_out(old, fade)
	else:
		old.stop()

func _fade_out(player: AudioStreamPlayer, fade: float) -> void:
	if not player.playing:
		return
	if fade <= 0.0:
		player.stop()
		return
	_kill_fade(player)
	var t := create_tween()
	t.tween_property(player, "volume_db", -60.0, fade)
	t.tween_callback(func() -> void:
		if player != _music_active or _current == &"":
			player.stop())
	_fades[player] = t

func _kill_fade(player: AudioStreamPlayer) -> void:
	if _fades.has(player):
		(_fades[player] as Tween).kill()
		_fades.erase(player)

# ----------------------------------------------------------------------------
# Enlaces automáticos
# ----------------------------------------------------------------------------

func _on_node_added(node: Node) -> void:
	if node is BaseButton and not node.has_meta(&"audio_hooked"):
		node.set_meta(&"audio_hooked", true)
		var b := node as BaseButton
		b.pressed.connect(func() -> void:
			sfx(&"ui_back" if b.theme_type_variation == &"DangerButton" else &"ui_click"))
		b.mouse_entered.connect(func() -> void:
			if not b.disabled and _hover_t <= 0.0:
				_hover_t = 0.05
				sfx(&"ui_hover"))

func _on_state_changed(new_state: int) -> void:
	match new_state:
		GameManager.State.MENU, GameManager.State.LOBBY, GameManager.State.SETUP:
			play_music(&"menu")
		GameManager.State.INTRO:
			sfx(&"stinger")
		GameManager.State.PLAYING:
			stop_music(0.4)           # silencio para la cuenta atrás; el minijuego pone la suya al empezar
		GameManager.State.SCOREBOARD:
			play_music(&"scoreboard", 0.5)
		GameManager.State.FINAL:
			sfx(&"fanfare_big")
			play_music(&"final", 1.5)

func _on_roster_changed() -> void:
	var n := Lobby.players.size()
	if GameManager.state == GameManager.State.LOBBY:
		if n > _roster_count:
			sfx(&"join")
		elif n < _roster_count:
			sfx(&"leave")
	_roster_count = n

func _unhandled_key_input(event: InputEvent) -> void:
	if enabled and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F10:
		toggle_mute()
		get_viewport().set_input_as_handled()

# ----------------------------------------------------------------------------
# Buses, ajustes y aviso en pantalla
# ----------------------------------------------------------------------------

func _build_buses() -> void:
	for bus_name in [MUSIC_BUS, SFX_BUS]:
		if AudioServer.get_bus_index(bus_name) < 0:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, &"Master")
	AudioServer.set_bus_mute(AudioServer.get_bus_index(MUSIC_BUS), muted)
	AudioServer.set_bus_mute(AudioServer.get_bus_index(SFX_BUS), muted)

func _apply_volumes() -> void:
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(MUSIC_BUS), music_db)
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(SFX_BUS), sfx_db - 3.0)

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		music_db = float(cfg.get_value("audio", "music_db", 0.0))
		sfx_db = float(cfg.get_value("audio", "sfx_db", 0.0))
		muted = bool(cfg.get_value("audio", "muted", false))

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("audio", "music_db", music_db)
	cfg.set_value("audio", "sfx_db", sfx_db)
	cfg.set_value("audio", "muted", muted)
	cfg.save(SETTINGS_PATH)

func _build_toast() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 120
	add_child(layer)
	_toast = Label.new()
	_toast.add_theme_font_size_override("font_size", 28)
	_toast.add_theme_color_override("font_color", Palette.WHITE)
	_toast.add_theme_color_override("font_outline_color", Palette.PURPLE_DARK)
	_toast.add_theme_constant_override("outline_size", 8)
	_toast.position = Vector2(24, 18)
	_toast.modulate.a = 0.0
	layer.add_child(_toast)

func _show_toast(text: String) -> void:
	_toast.text = text
	_toast.modulate.a = 1.0
	var t := create_tween()
	t.tween_interval(1.2)
	t.tween_property(_toast, "modulate:a", 0.0, 0.4)
