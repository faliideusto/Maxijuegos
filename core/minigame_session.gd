class_name MinigameSession
extends Node
## Sincroniza UN minijuego entre el host y los clientes. Es genérico: no sabe qué minijuego
## es; solo mueve snapshots (host → clientes), entrada (cliente → host) y eventos.
## Lo crea el MinigameRunner en todos los PC de una partida online.
##
## Protocolo (canal NetProtocol.CH_MINIGAME):
##   cliente → host  {"op":"ready"}                       el minijuego está cargado y preparado
##   host → clientes {"op":"begin"}                       todos listos: empezad la cuenta atrás
##   host → clientes {"op":"snap","d":estado}   (no fiable, ~30 Hz) estado del minijuego
##   host → clientes {"op":"ev","n":nombre,"d":datos}     evento puntual
##   host → clientes {"op":"end","d":estado_final}        el minijuego terminó
##   cliente → host  {"op":"in","m":Vector2,"c":int}  (no fiable, ~30 Hz) intención del jugador:
##                   movimiento + contador acumulado de pulsaciones de acción. NO resultados.
##
## Seguridad: el host solo acepta entrada del peer dueño de cada jugador, sanea los valores y
## nunca usa nada del cliente para decidir resultados o puntos.

## (host) Un cliente informó de que está listo.
signal client_ready(peer_id: int)
## (cliente) El host dio la señal de empezar.
signal begin_received

const INPUT_SEND_HZ := 30.0
## Margen de seguridad del snapshot final (por si se perdió el último no fiable).
const END_REPEAT := 1

var minigame: Minigame
var is_host: bool = true

## (host) peers de los que aún esperamos el "ready".
var _pending_ready: Dictionary = {}
var _active: bool = false
var _snap_accum: float = 0.0
var _input_accum: float = 0.0
var _press_count: int = 0
var _local_player: PlayerData = null
var _begin_seen: bool = false
## Estadísticas (para pruebas y depuración).
var snapshots_sent: int = 0
var snapshots_applied: int = 0
var inputs_applied: int = 0

func setup(mg: Minigame) -> void:
	minigame = mg
	is_host = NetworkManager.is_host()
	mg.set_session(self)
	NetworkManager.register_channel(NetProtocol.CH_MINIGAME, _on_message)
	if is_host:
		NetworkManager.peer_left.connect(_on_peer_left)
		mg.ended.connect(_on_host_ended)
		# Esperamos el "ready" de cada humano remoto.
		for p in Lobby.players:
			if p.is_remote:
				_pending_ready[p.peer_id] = true
	else:
		_local_player = Lobby.get_local_player()

func _exit_tree() -> void:
	NetworkManager.unregister_channel(NetProtocol.CH_MINIGAME)
	DevCli.log_event("mg_session snapshots_sent=%d snapshots_applied=%d inputs_applied=%d" % [
			snapshots_sent, snapshots_applied, inputs_applied])

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

## (host) Da la señal de comenzar a los clientes.
func send_begin() -> void:
	NetworkManager.broadcast(NetProtocol.CH_MINIGAME, {"op": "begin"})

## (cliente) Avisa al host de que este PC está listo.
func send_ready() -> void:
	NetworkManager.send_to_host(NetProtocol.CH_MINIGAME, {"op": "ready"})

## (cliente) Espera la señal del host (con tiempo máximo, segundos reales).
func wait_for_begin(timeout: float) -> void:
	var t0 := Time.get_ticks_msec()
	while not _begin_seen and (Time.get_ticks_msec() - t0) < timeout * 1000.0:
		await get_tree().create_timer(0.05, true, false, true).timeout
	if not _begin_seen:
		DevCli.log_event("begin_timeout")

## Empieza la sincronización de juego (host: snapshots; cliente: envío de entrada).
func start() -> void:
	_active = true
	if is_host:
		InputManager.flush_remote_presses()

# ----------------------------------------------------------------------------
# Envío periódico
# ----------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _active or not NetworkManager.is_online:
		return
	if is_host:
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

# ----------------------------------------------------------------------------
# Recepción
# ----------------------------------------------------------------------------

func _on_message(from_peer: int, payload: Variant) -> void:
	if not payload is Dictionary:
		return
	match String(payload.get("op", "")):
		"ready": _host_on_ready(from_peer)
		"in": _host_on_input(from_peer, payload)
		"begin": _client_on_begin()
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
	if not is_host or not minigame.is_running:
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

# --- cliente ---

func _client_on_begin() -> void:
	if is_host or _begin_seen:
		return
	_begin_seen = true
	begin_received.emit()

func _client_on_snapshot(payload: Dictionary) -> void:
	if is_host:
		return
	minigame.apply_state(payload.get("d"))
	snapshots_applied += 1

func _client_on_event(payload: Dictionary) -> void:
	if is_host:
		return
	minigame.deliver_event(String(payload.get("n", "")), payload.get("d"))

func _client_on_end(payload: Dictionary) -> void:
	if is_host:
		return
	_active = false
	minigame.apply_state(payload.get("d"))
	minigame.remote_end()
