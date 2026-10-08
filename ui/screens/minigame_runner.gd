extends Node
## Ejecuta el minijuego actual en CADA PC: lo instancia, sincroniza el arranque (con la semilla
## común), hace la cuenta atrás y muestra los avisos. Es el único punto que habla con los
## minijuegos. Soporta los dos modelos de ejecución (MinigameMeta.execution_mode):
##
##  HOST_AUTHORITATIVE  host simula y los clientes dibujan el estado (ver MinigameSession).
##  LOCAL_PARALLEL      cada PC juega la prueba por su cuenta; los resultados viajan al host.
##
## Secuencia común:  instanciar → [online: listo/begin(semilla)] → configurar → preparar →
##                   cuenta atrás → jugar → fin → (host) GameManager.report_results(ranking)
## Cliente online: nunca llama a GameManager; espera el cambio de estado del host.
## Modo local (sin red) con LOCAL_PARALLEL: los humanos juegan por turnos en este PC.

const COUNTDOWN := ["3", "2", "1", "¡YA!"]
## Segundos reales máximos que el host espera a que los clientes carguen el minijuego.
const READY_TIMEOUT := 8.0
## Segundos reales máximos que un cliente espera la señal del host.
const BEGIN_TIMEOUT := 15.0

var _meta: MinigameMeta
var _minigame: Minigame
var _session: MinigameSession
var _overlay: CanvasLayer
var _label: Label
var _wait_label: Label

func _ready() -> void:
	_meta = GameManager.current_minigame()
	_build_overlay()
	var parallel := _meta.execution_mode == MinigameMeta.ExecutionMode.LOCAL_PARALLEL
	if parallel and not NetworkManager.is_online:
		await _run_offline_parallel()
	else:
		await _run_shared()

# ----------------------------------------------------------------------------
# Ejecución común (online en ambos modelos; local en HOST_AUTHORITATIVE)
# ----------------------------------------------------------------------------

func _run_shared() -> void:
	var is_host := NetworkManager.is_host()
	_minigame = _instantiate(is_host)
	if _minigame == null:
		return
	add_child(_minigame)

	# Sincronización de arranque (solo online): todos listos → semilla común → todos empiezan.
	var seed_value := randi()
	if NetworkManager.is_online:
		_session = MinigameSession.new()
		add_child(_session)
		_session.setup(_minigame)
		if is_host:
			await _session.wait_for_clients(READY_TIMEOUT)
			_session.send_begin(seed_value)
		else:
			_session.send_ready()
			await _session.wait_for_begin(BEGIN_TIMEOUT)
			seed_value = _session.seed_value

	_minigame.configure(_meta.execution_mode, seed_value, Lobby.get_local_player())
	_minigame.prepare(Lobby.players)
	_minigame.ended.connect(_on_ended, CONNECT_ONE_SHOT)
	_minigame.result_reported.connect(_on_local_reported)
	if is_host:
		_minigame.finished.connect(_on_finished, CONNECT_ONE_SHOT)
	await _run_countdown()
	_minigame.start(Lobby.players)
	if _session:
		_session.start()

# ----------------------------------------------------------------------------
# LOCAL_PARALLEL sin red: los humanos de este PC juegan por turnos
# ----------------------------------------------------------------------------

func _run_offline_parallel() -> void:
	var seed_value := randi()
	var results := ParallelResults.new(Lobby.players)
	# Instancia auxiliar (fuera del árbol) para resultados de bots y clasificación.
	var helper := _instantiate(true)
	if helper == null:
		return
	helper.players = Lobby.players
	helper.meta = _meta
	helper.configure(_meta.execution_mode, seed_value, null)
	for p in Lobby.players:
		if InputManager.is_simulated(p.id):
			var res := helper.bot_result(p)
			results.set_result(p.id, res["score"], res["tiebreak"])
	# Un turno por humano.
	for p in Lobby.players:
		if results.has_result(p.id):
			continue
		await _play_turn(p, seed_value, results, helper)
	var dnf := results.fill_missing_as_dnf()
	DevCli.log_event("offline_parallel players=%d dnf=%d" % [Lobby.players.size(), dnf])
	var ranking := helper.rank_results(results.to_dict())
	helper.free()
	Audio.stop_music(0.6)
	Audio.sfx(&"fanfare_small")
	_show_big("¡FIN!")
	await get_tree().create_timer(1.4).timeout
	GameManager.report_results(ranking)

func _play_turn(p: PlayerData, seed_value: int, results: ParallelResults, helper: Minigame) -> void:
	var mg := _instantiate(true)
	if mg == null:
		return
	_minigame = mg
	add_child(mg)
	mg.configure(_meta.execution_mode, seed_value, p)
	mg.prepare(Lobby.players)
	var done := {"v": false}
	mg.result_reported.connect(func(score: float, tiebreak: float) -> void:
		if mg.validate_result(score, tiebreak):
			results.set_result(p.id, score, tiebreak)
		done["v"] = true)
	_show_big_text("TURNO DE %s" % p.label().to_upper(), 64)
	await get_tree().create_timer(1.6).timeout
	await _run_countdown()
	mg.start(Lobby.players)
	var elapsed := 0.0
	while not done["v"] and elapsed < mg.parallel_timeout():
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	Audio.stop_music(0.4)
	Audio.sfx(&"reaction_ok")
	_show_big_text("¡LISTO!", 96)
	await get_tree().create_timer(0.8).timeout
	_label.text = ""
	mg.queue_free()

# ----------------------------------------------------------------------------
# Utilidades
# ----------------------------------------------------------------------------

func _instantiate(authority: bool) -> Minigame:
	var node := _meta.scene.instantiate()
	var mg := node as Minigame
	if mg == null:
		push_error("La escena de '%s' no extiende Minigame; se omite." % _meta.display_name)
		node.queue_free()
		GameManager.report_results(_default_ranking())
		return null
	mg.meta = _meta
	mg.is_authority = authority
	return mg

func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 10
	add_child(_overlay)
	_label = UIKit.label("", &"TitleLabel")
	_label.add_theme_font_size_override("font_size", 160)
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_overlay.add_child(_label)
	# Aviso "esperando a los demás" (LOCAL_PARALLEL): sin mostrar ningún resultado ajeno.
	_wait_label = UIKit.label("", &"HeaderLabel")
	_wait_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_wait_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_wait_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_wait_label.offset_bottom = -30
	_overlay.add_child(_wait_label)

func _run_countdown() -> void:
	await get_tree().create_timer(0.3).timeout
	for step in COUNTDOWN:
		Audio.sfx(&"beep_go" if step == "¡YA!" else &"beep")
		_show_big(step)
		await get_tree().create_timer(0.65 if step != "¡YA!" else 0.45).timeout
	_label.text = ""

## (LOCAL_PARALLEL, online) El jugador local terminó: espera a los demás sin ver nada de ellos.
func _on_local_reported(_score: float, _tiebreak: float) -> void:
	if NetworkManager.is_online:
		_wait_label.text = "¡Listo! Esperando a los demás…"

## Todos los PC: aviso de fin.
func _on_ended() -> void:
	_wait_label.text = ""
	Audio.stop_music(0.6)
	Audio.sfx(&"fanfare_small")
	_show_big("¡FIN!")

## Solo host: tras el aviso, entrega el ranking (GameManager reparte puntos y avisa a los clientes).
func _on_finished(results: Array[int]) -> void:
	await get_tree().create_timer(1.4).timeout
	GameManager.report_results(results)

func _show_big(text: String) -> void:
	_show_big_text(text, 160)

func _show_big_text(text: String, font_size: int) -> void:
	_label.add_theme_font_size_override("font_size", font_size)
	_label.text = text
	_label.pivot_offset = _label.size * 0.5
	_label.scale = Vector2.ONE * 1.8
	_label.modulate.a = 1.0
	var t := create_tween().set_parallel(true)
	t.tween_property(_label, "scale", Vector2.ONE, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _default_ranking() -> Array[int]:
	var ids: Array[int] = []
	for p in Lobby.players:
		ids.append(p.id)
	return ids
