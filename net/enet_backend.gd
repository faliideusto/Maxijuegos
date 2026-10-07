class_name ENetBackend
extends NetworkBackend
## Backend ENet: conexión directa por IP y puerto (pruebas locales / LAN).

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
