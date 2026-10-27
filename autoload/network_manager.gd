extends Node
## Capa de red (autoload): TRANSPORTE genérico con anfitrión autoritativo.
##
## No conoce lobbies, minijuegos ni reglas. Ofrece:
##   - conexión: host_game / join_game / disconnect_from_game / kick
##   - mensajería por CANALES con nombre (register_channel + send_*/broadcast)
## Quien necesite red (Lobby, GameManager, MinigameSession...) registra su canal; añadir un
## minijuego nunca requiere tocar este archivo.
##
## Reglas de confianza (host autoritativo):
##   - Mensajes host → clientes: solo se aceptan si el remitente es el host (peer 1).
##   - Mensajes cliente → host: los recibe solo el host; el handler debe validar el
##     contenido y que el remitente tiene derecho a hacer lo que pide.
## Para cambiar a Steam: SteamBackend (extends NetworkBackend) + set_backend(). Los RPC y
## los canales no cambian. En web (sin ENet) el backend es WebRTCBackend: salas con código.

signal connected_to_host                 # (cliente) conexión establecida
signal connection_failed                 # (cliente) no se pudo conectar
signal disconnected                      # (cliente) se perdió al anfitrión
signal peer_joined(peer_id: int)         # un peer se conectó
signal peer_left(peer_id: int)           # un peer se fue (cierre, caída o kick)

const DEFAULT_PORT := 24680
## Total 8 jugadores: el host + 7 clientes (un jugador por PC).
const MAX_CLIENTS := 7

var backend: NetworkBackend = WebRTCBackend.new() if OS.has_feature("web") else ENetBackend.new()
var is_online: bool = false

## canal (String) -> Callable(from_peer: int, payload: Variant)
var _handlers: Dictionary = {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # la señalización no se detiene con el juego en pausa
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(func(id: int) -> void: peer_left.emit(id))

func _process(delta: float) -> void:
	if is_online:
		backend.poll(delta)

# ----------------------------------------------------------------------------
# Conexión
# ----------------------------------------------------------------------------

## Cambia el backend (ENet, Steam...). Cierra la red si estaba abierta.
func set_backend(new_backend: NetworkBackend) -> void:
	if is_online:
		disconnect_from_game()
	backend = new_backend

func host_game(port: int = DEFAULT_PORT) -> Error:
	backend.failure_reason = ""
	var peer := backend.create_host(port, MAX_CLIENTS)
	if peer == null:
		return FAILED
	multiplayer.multiplayer_peer = peer
	is_online = true
	return OK

func join_game(address: String, port: int = DEFAULT_PORT) -> Error:
	backend.failure_reason = ""
	var peer := backend.create_client(address, port)
	if peer == null:
		return FAILED
	multiplayer.multiplayer_peer = peer
	is_online = true
	return OK

func disconnect_from_game() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	backend.close()
	is_online = false

## (host) Expulsa a un peer.
func kick(peer_id: int) -> void:
	if is_online and multiplayer.is_server() and multiplayer.get_peers().has(peer_id):
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)

## (host) Lo que los demás necesitan para unirse (IP o código de sala) y cómo se llama en la UI.
func join_hint() -> String:
	return backend.get_join_hint() if is_online else ""

func join_hint_label() -> String:
	return backend.get_join_hint_label()

## true si somos el anfitrión o si no hay red (partida local).
func is_host() -> bool:
	return not is_online or multiplayer.is_server()

func local_peer_id() -> int:
	return multiplayer.get_unique_id() if is_online else 1

## (host) Peers conectados (sin contar al host).
func connected_peers() -> PackedInt32Array:
	return multiplayer.get_peers() if is_online else PackedInt32Array()

# ----------------------------------------------------------------------------
# Canales
# ----------------------------------------------------------------------------

## Registra el handler de un canal: handler(from_peer: int, payload: Variant).
func register_channel(channel: String, handler: Callable) -> void:
	_handlers[channel] = handler

func unregister_channel(channel: String) -> void:
	_handlers.erase(channel)

## (cliente → host) Envía un mensaje al anfitrión.
func send_to_host(channel: String, payload: Variant, reliable: bool = true) -> void:
	if not is_online or multiplayer.is_server():
		return
	if reliable:
		_rpc_to_host_reliable.rpc_id(1, channel, payload)
	else:
		_rpc_to_host_unreliable.rpc_id(1, channel, payload)

## (host → un cliente) Envía un mensaje a un peer concreto.
func send_to_peer(peer_id: int, channel: String, payload: Variant, reliable: bool = true) -> void:
	if not is_online or not multiplayer.is_server():
		return
	if reliable:
		_rpc_to_client_reliable.rpc_id(peer_id, channel, payload)
	else:
		_rpc_to_client_unreliable.rpc_id(peer_id, channel, payload)

## (host → todos los clientes) Difunde un mensaje. El host NO se lo envía a sí mismo.
func broadcast(channel: String, payload: Variant, reliable: bool = true) -> void:
	if not is_online or not multiplayer.is_server():
		return
	if reliable:
		_rpc_to_client_reliable.rpc(channel, payload)
	else:
		_rpc_to_client_unreliable.rpc(channel, payload)

# Cuatro RPC cubren todas las combinaciones (dirección × fiabilidad).
@rpc("any_peer", "call_remote", "reliable")
func _rpc_to_host_reliable(channel: String, payload: Variant) -> void:
	_deliver_to_host(channel, payload)

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_to_host_unreliable(channel: String, payload: Variant) -> void:
	_deliver_to_host(channel, payload)

@rpc("authority", "call_remote", "reliable")
func _rpc_to_client_reliable(channel: String, payload: Variant) -> void:
	_dispatch(1, channel, payload)

@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_to_client_unreliable(channel: String, payload: Variant) -> void:
	_dispatch(1, channel, payload)

func _deliver_to_host(channel: String, payload: Variant) -> void:
	# Un cliente no debe procesar mensajes "hacia el host" (p. ej. reenviados por otro cliente).
	if not multiplayer.is_server():
		return
	_dispatch(multiplayer.get_remote_sender_id(), channel, payload)

func _dispatch(from_peer: int, channel: String, payload: Variant) -> void:
	var handler: Callable = _handlers.get(channel, Callable())
	if handler.is_valid():
		handler.call(from_peer, payload)

# ----------------------------------------------------------------------------

func _on_peer_connected(peer_id: int) -> void:
	# Solo el host tiene conexión directa con cada peer; un cliente "ve" a los demás clientes
	# a través del host, sin conexión propia que configurar.
	if multiplayer.is_server():
		backend.configure_peer(multiplayer.multiplayer_peer, peer_id)
	peer_joined.emit(peer_id)

func _on_connected_to_server() -> void:
	backend.configure_peer(multiplayer.multiplayer_peer, 1)
	connected_to_host.emit()

func _on_connection_failed() -> void:
	disconnect_from_game()
	connection_failed.emit()

func _on_server_disconnected() -> void:
	disconnect_from_game()
	disconnected.emit()
