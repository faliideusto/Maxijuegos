class_name ENetBackend
extends NetworkBackend
## Backend ENet: conexión directa por IP y puerto (pruebas locales / LAN).

## Detección de caídas: si un peer no responde en este tiempo (ms) se da por desconectado.
## (Por defecto ENet tarda hasta ~30 s, demasiado para un party game.)
const TIMEOUT_LIMIT := 32
const TIMEOUT_MIN_MS := 3000
const TIMEOUT_MAX_MS := 6000

func get_backend_name() -> String:
	return "LAN / IP"

func create_host(port: int, max_clients: int) -> MultiplayerPeer:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, max_clients)
	if err != OK:
		push_error("ENetBackend: no se pudo crear el servidor (%s)" % error_string(err))
		return null
	return peer

func create_client(address: String, port: int) -> MultiplayerPeer:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		push_error("ENetBackend: no se pudo crear el cliente (%s)" % error_string(err))
		return null
	return peer

func configure_peer(multiplayer_peer: MultiplayerPeer, peer_id: int) -> void:
	var enet := multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var packet_peer := enet.get_peer(peer_id)
	if packet_peer != null:
		packet_peer.set_timeout(TIMEOUT_LIMIT, TIMEOUT_MIN_MS, TIMEOUT_MAX_MS)
