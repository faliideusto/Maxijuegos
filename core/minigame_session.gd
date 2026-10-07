class_name MinigameSession
extends Node
## Sincroniza UN minijuego entre el host y los clientes. Es genérico: no sabe qué minijuego
## es. Lo crea el MinigameRunner en todos los PC de una partida online y adapta su
## comportamiento al modelo de ejecución del minijuego (MinigameMeta.ExecutionMode).
##
## Común (canal NetProtocol.CH_MINIGAME):
##   cliente → host  {"op":"ready"}                  el minijuego está cargado
##   host → clientes {"op":"begin","seed":int}       todos listos: semilla común y cuenta atrás
##   host → clientes {"op":"end","d":estado}         el minijuego terminó para todos
##
## HOST_AUTHORITATIVE:
##   host → clientes {"op":"snap","d":estado}  (no fiable, ~30 Hz) estado del minijuego
##   host → clientes {"op":"ev","n":nombre,"d":datos}     evento puntual
##   cliente → host  {"op":"in","m":Vector2,"c":int}  (no fiable, ~30 Hz) intención del jugador:
##                   movimiento + contador acumulado de pulsaciones. NO resultados.
##
## LOCAL_PARALLEL (sin sincronización frame a frame):
##   cliente → host  {"op":"result","s":float,"t":float}  resultado final del jugador local
##   El host completa con bots/desconectados, valida, espera a todos (con tope de tiempo),
##   construye la clasificación con Minigame.rank_results y cierra el minijuego.
##
## Seguridad: el host solo acepta mensajes de jugador del peer que es dueño de ese jugador y
## sanea los valores. En HOST_AUTHORITATIVE nada que decida resultados viene del cliente; en
## LOCAL_PARALLEL el resultado SÍ lo calcula el cliente (es inherente al modelo): se acota
## con Minigame.validate_result y un tope de tiempo. Ver docs/network.md.

## (host) Un cliente informó de que está listo.
signal client_ready(peer_id: int)

const INPUT_SEND_HZ := 30.0

var minigame: Minigame
var is_host: bool = true
## true si el minijuego es LOCAL_PARALLEL (se lee del minijuego: el runner lo configura tras crear la sesión).
var is_parallel: bool:
	get: return minigame != null and minigame.mode == MinigameMeta.ExecutionMode.LOCAL_PARALLEL
## Semilla común: la fija el host al llamar a send_begin; el cliente la recibe en "begin".
var seed_value: int = 0

## (host) peers de los que aún esperamos el "ready".
var _pending_ready: Dictionary = {}
var _active: bool = false
var _begin_seen: bool = false
var _snap_accum: float = 0.0
var _input_accum: float = 0.0
var _press_count: int = 0
var _local_player: PlayerData = null
## (host, LOCAL_PARALLEL) resultados recogidos y tiempo transcurrido.
var _results: ParallelResults = null
var _parallel_elapsed: float = 0.0
## Estadísticas (para pruebas y depuración).
var snapshots_sent: int = 0
var snapshots_applied: int = 0
var inputs_applied: int = 0
var results_accepted: int = 0
var results_dnf: int = 0

func setup(mg: Minigame) -> void:
	minigame = mg
	is_host = NetworkManager.is_host()
	mg.set_session(self)
	NetworkManager.register_channel(NetProtocol.CH_MINIGAME, _on_message)
	_local_player = Lobby.get_local_player()
	if is_host:
		NetworkManager.peer_left.connect(_on_peer_left)
		mg.ended.connect(_on_host_ended)
		# Esperamos el "ready" de cada humano remoto.
		for p in Lobby.players:
			if p.is_remote:
				_pending_ready[p.peer_id] = true
	# El modo lo fija el runner después (configure): el manejador ignora los minijuegos que no
	# son LOCAL_PARALLEL.
	mg.result_reported.connect(_on_local_result)

func _exit_tree() -> void:
	NetworkManager.unregister_channel(NetProtocol.CH_MINIGAME)
	var mode_name := "LOCAL_PARALLEL" if is_parallel else "HOST_AUTHORITATIVE"
	DevCli.log_event("mg_session mode=%s snapshots_sent=%d snapshots_applied=%d inputs_applied=%d results=%d dnf=%d" % [
			mode_name, snapshots_sent, snapshots_applied, inputs_applied, results_accepted, results_dnf])

# ----------------------------------------------------------------------------
# Arranque (lo orquesta el runner)
# ----------------------------------------------------------------------------

## (host) Espera a que todos los clientes estén listos, con tiempo máximo (segundos reales).
## Los que no respondan a tiempo no bloquean la partida.
func wait_for_clients(timeout: float) -> void:
	var t0 := Time.get_ticks_msec()
	while not _pending_ready.is_empty() and (Time.get_ticks_msec() - t0) < timeout * 1000.0:
		await get_tree().create_timer(0.05, true, false, true).timeout
	if not _pending_ready.is_empty():
		push_warning("MinigameSession: clientes sin responder, se empieza igualmente: %s" % [_pending_ready.keys()])
		DevCli.log_event("ready_timeout peers=%s" % [_pending_ready.keys()])

## (host) Da la señal de comenzar a los clientes, con la semilla común.
func send_begin(p_seed: int) -> void:
	seed_value = p_seed
	NetworkManager.broadcast(NetProtocol.CH_MINIGAME, {"op": "begin", "seed": p_seed})

## (cliente) Avisa al host de que este PC está listo.
func send_ready() -> void:
	NetworkManager.send_to_host(NetProtocol.CH_MINIGAME, {"op": "ready"})

## (cliente) Espera la señal del host (con tiempo máximo, segundos reales). Tras ella,
## seed_value contiene la semilla común.
func wait_for_begin(timeout: float) -> void:
	var t0 := Time.get_ticks_msec()
	var last_ready := t0
	while not _begin_seen and (Time.get_ticks_msec() - t0) < timeout * 1000.0:
		await get_tree().create_timer(0.05, true, false, true).timeout
		# El host puede cargar la escena más tarde que nosotros y perder el primer "ready":
		# se reenvía cada 0.5 s hasta recibir "begin" (el host lo trata de forma idempotente).
		if Time.get_ticks_msec() - last_ready >= 500:
			last_ready = Time.get_ticks_msec()
			send_ready()
	if not _begin_seen:
		DevCli.log_event("begin_timeout")

## Empieza la sincronización de juego (se llama justo después de minigame.start()).
func start() -> void:
	_active = true
	if is_host and not is_parallel:
		InputManager.flush_remote_presses()
	if is_host and is_parallel:
		_begin_parallel_collection()

# ----------------------------------------------------------------------------
# Bucle
# ----------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _active or not NetworkManager.is_online:
		return
	if is_parallel:
		if is_host:
			_parallel_host_tick(delta)
	elif is_host:
		_snap_accum += delta
		var interval := 1.0 / maxf(minigame.snapshot_rate, 1.0)
		if _snap_accum >= interval:
			_snap_accum = fmod(_snap_accum, interval)
			NetworkManager.broadcast(NetProtocol.CH_MINIGAME,
					{"op": "snap", "d": minigame.serialize_state()}, false)
			snapshots_sent += 1
	elif _local_player != null:
		# Se envía la intención del jugador: movimiento y pulsaciones acumuladas.
		var presses := InputManager.action_presses(_local_player.id)
		_press_count += presses
		_input_accum += delta
		if presses > 0 or _input_accum >= 1.0 / INPUT_SEND_HZ:
			_input_accum = 0.0
			NetworkManager.send_to_host(NetProtocol.CH_MINIGAME,
					{"op": "in", "m": InputManager.get_vector(_local_player.id), "c": _press_count}, false)

## (host, desde Minigame.send_event) Reenvía un evento a los clientes.
func send_event(event_name: String, data: Variant) -> void:
	NetworkManager.broadcast(NetProtocol.CH_MINIGAME, {"op": "ev", "n": event_name, "d": data})

func _on_host_ended() -> void:
	_active = false
	# Estado final fiable: los clientes ven exactamente el resultado del host.
	NetworkManager.broadcast(NetProtocol.CH_MINIGAME, {"op": "end", "d": minigame.serialize_state()})

func _on_peer_left(peer_id: int) -> void:
	_pending_ready.erase(peer_id)
	# LOCAL_PARALLEL: el jugador ya es un bot (lo hizo Lobby): su resultado se simula.
	if is_parallel and _results != null:
		for p in minigame.players:
			if p.is_bot and not _results.has_result(p.id):
				_accept_result(p.id, minigame.bot_result(p))

# ----------------------------------------------------------------------------
# LOCAL_PARALLEL: recogida de resultados (host)
# ----------------------------------------------------------------------------

func _begin_parallel_collection() -> void:
	DevCli.log_event("begin_parallel_collection")
	_results = ParallelResults.new(minigame.players)
	_parallel_elapsed = 0.0
	# Bots, autopiloto y desconectados: el host calcula su resultado.
	for p in minigame.players:
		if InputManager.is_simulated(p.id):
			_accept_result(p.id, minigame.bot_result(p))

func _accept_result(player_id: int, result: Dictionary) -> void:
	if _results != null and _results.set_result(player_id, float(result.get("score", 0.0)), float(result.get("tiebreak", 0.0))):
		results_accepted += 1

func _parallel_host_tick(delta: float) -> void:
	if _results == null:
		return
	_parallel_elapsed += delta
	if _results.is_complete() or _parallel_elapsed >= minigame.parallel_timeout():
		results_dnf = _results.fill_missing_as_dnf()
		if results_dnf > 0:
			DevCli.log_event("parallel_timeout dnf=%d" % results_dnf)
		_active = false
		minigame.finish(minigame.rank_results(_results.to_dict()))

## El jugador local terminó (en cualquier PC): el host lo anota; un cliente lo envía.
func _on_local_result(score: float, tiebreak: float) -> void:
	if not is_parallel:
		return
	if is_host:
		var me := _local_player
		if me != null:
			_submit_validated(me.id, score, tiebreak)
	elif NetworkManager.is_online:
		NetworkManager.send_to_host(NetProtocol.CH_MINIGAME, {"op": "result", "s": score, "t": tiebreak})

func _submit_validated(player_id: int, score: float, tiebreak: float) -> void:
	DevCli.log_event("submit id=%d score=%s has_results=%s" % [player_id, score, _results != null])
	if _results == null:
		return
	if not minigame.validate_result(score, tiebreak):
		DevCli.log_event("result_rejected id=%d score=%s" % [player_id, score])
		return
	_accept_result(player_id, {"score": score, "tiebreak": tiebreak})

# ----------------------------------------------------------------------------
# Recepción
# ----------------------------------------------------------------------------

func _on_message(from_peer: int, payload: Variant) -> void:
	if not payload is Dictionary:
		return
	match String(payload.get("op", "")):
		"ready": _host_on_ready(from_peer)
		"in": _host_on_input(from_peer, payload)
		"result": _host_on_result(from_peer, payload)
		"begin": _client_on_begin(payload)
		"snap": _client_on_snapshot(payload)
		"ev": _client_on_event(payload)
		"end": _client_on_end(payload)

# --- host ---

func _host_on_ready(peer_id: int) -> void:
	if not is_host:
		return
	if _pending_ready.erase(peer_id):
		client_ready.emit(peer_id)

func _host_on_input(peer_id: int, payload: Dictionary) -> void:
	if not is_host or is_parallel or not minigame.is_running:
		return
	# Solo se acepta entrada del dueño del jugador (no se puede mover a otros).
	var player := Lobby.player_of_peer(peer_id)
	if player == null or not player.is_remote:
		return
	var move: Variant = payload.get("m", Vector2.ZERO)
	var count: Variant = payload.get("c", 0)
	if typeof(move) != TYPE_VECTOR2 or typeof(count) != TYPE_INT:
		return
	var v: Vector2 = move
	if not (is_finite(v.x) and is_finite(v.y)):
		return
	InputManager.set_remote_input(player.id, v, maxi(int(count), 0))
	inputs_applied += 1

func _host_on_result(peer_id: int, payload: Dictionary) -> void:
	if not is_host or not is_parallel or _results == null:
		return
	# El resultado solo vale para el jugador del que el peer es dueño.
	var player := Lobby.player_of_peer(peer_id)
	if player == null or not player.is_remote:
		return
	var score: Variant = payload.get("s")
	var tiebreak: Variant = payload.get("t", 0.0)
	if (typeof(score) != TYPE_FLOAT and typeof(score) != TYPE_INT) \
			or (typeof(tiebreak) != TYPE_FLOAT and typeof(tiebreak) != TYPE_INT):
		return
	_submit_validated(player.id, float(score), float(tiebreak))

# --- cliente ---

func _client_on_begin(payload: Dictionary) -> void:
	if is_host or _begin_seen:
		return
	seed_value = int(payload.get("seed", 0))
	_begin_seen = true

func _client_on_snapshot(payload: Dictionary) -> void:
	if is_host or is_parallel:
		return
	minigame.apply_state(payload.get("d"))
	snapshots_applied += 1

func _client_on_event(payload: Dictionary) -> void:
	if is_host or is_parallel:
		return
	minigame.deliver_event(String(payload.get("n", "")), payload.get("d"))

func _client_on_end(payload: Dictionary) -> void:
	if is_host:
		return
	_active = false
	if not is_parallel:
		minigame.apply_state(payload.get("d"))
	minigame.remote_end()
