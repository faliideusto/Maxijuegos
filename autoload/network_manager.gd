extends Node
## Capa de red (autoload) con anfitrión autoritativo.
##
## El resto del juego solo conoce esta API y sus señales; nunca toca ENet ni Steam.
## Para cambiar a Steam: crear SteamBackend (extends NetworkBackend) y asignarlo con
## set_backend(). Los RPC de abajo viajan por el MultiplayerAPI de Godot, así que
## funcionan igual con cualquier MultiplayerPeer.
##
## Alcance de esta fase: conectar, detectar jugadores y sincronizar el lobby.
## La sincronización dentro de los minijuegos queda para la fase 2.

signal connected_to_host                 # (cliente) conexión establecida
signal connection_failed                 # (cliente) no se pudo conectar
signal disconnected                      # (cliente) se perdió al anfitrión
signal peer_joined(peer_id: int)         # (todos) un peer se conectó
signal peer_left(peer_id: int)           # (todos) un peer se fue
## (host) un cliente pide unirse con su perfil.
signal join_requested(peer_id: int, player_name: String, color_index: int)
## (cliente) el host envía la lista completa de jugadores.
signal roster_received(players: Array)

const DEFAULT_PORT := 24680
## Total 8 jugadores: el host + 7 clientes.
const MAX_CLIENTS := 7

var backend: NetworkBackend = ENetBackend.new()
var is_online: bool = false

func _ready() -> void:
	multiplayer.connected_to_server.connect(func() -> void: connected_to_host.emit())
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_connected.connect(func(id: int) -> void: peer_joined.emit(id))
	multiplayer.peer_disconnected.connect(func(id: int) -> void: peer_left.emit(id))

## Cambia el backend (ENet, Steam...). Solo con la red cerrada.
func set_backend(new_backend: NetworkBackend) -> void:
	if is_online:
		disconnect_from_game()
	backend = new_backend

func host_game(port: int = DEFAULT_PORT) -> Error:
	var peer := backend.create_host(port, MAX_CLIENTS)
	if peer == null:
		return FAILED
	multiplayer.multiplayer_peer = peer
	is_online = true
	return OK

func join_game(address: String, port: int = DEFAULT_PORT) -> Error:
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
	is_online = false

## true si somos el anfitrión o si no hay red (partida local).
func is_host() -> bool:
	return not is_online or multiplayer.is_server()

func local_peer_id() -> int:
	return multiplayer.get_unique_id() if is_online else 1

# ----------------------------------------------------------------------------
# Mensajes de lobby (RPC)
# ----------------------------------------------------------------------------

## (cliente → host) Pide unirse con un jugador.
func send_join_request(player_name: String, color_index: int) -> void:
	_rpc_join_request.rpc_id(1, player_name, color_index)

## (host → todos) Envía la lista completa de jugadores.
func broadcast_roster(players: Array) -> void:
	if is_online and multiplayer.is_server():
		_rpc_roster.rpc(players)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_join_request(player_name: String, color_index: int) -> void:
	if not multiplayer.is_server():
		return
	join_requested.emit(multiplayer.get_remote_sender_id(), player_name, color_index)

@rpc("authority", "call_remote", "reliable")
func _rpc_roster(players: Array) -> void:
	roster_received.emit(players)

# ----------------------------------------------------------------------------

func _on_connection_failed() -> void:
	disconnect_from_game()
	connection_failed.emit()

func _on_server_disconnected() -> void:
	disconnect_from_game()
	disconnected.emit()
