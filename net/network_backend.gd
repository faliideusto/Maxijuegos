class_name NetworkBackend
extends RefCounted
## Backend de red abstracto. Su ÚNICA responsabilidad es fabricar el MultiplayerPeer
## que usará el MultiplayerAPI de Godot (host autoritativo = peer 1).
##
## Implementaciones:
##   - ENetBackend  (escritorio): IP + puerto, para pruebas LAN/local.
##   - WebRTCBackend (web): salas con código; señalización por PeerJS y conexión directa WebRTC.
##   - SteamBackend (futuro, GodotSteam): lobbies de Steam, devolviendo un
##     SteamMultiplayerPeer. Como el resto del juego solo habla con NetworkManager
##     (canales) y los RPC de Godot, los minijuegos no cambian.

## La pista para unirse (IP, código de sala...) cambió; p. ej. el código se sorteó de nuevo.
signal hint_changed

## (cliente) Motivo del último fallo al unirse, para mostrarlo ("" = genérico).
var failure_reason: String = ""

## Nombre para mostrar en la UI ("LAN / IP", "Steam"...).
func get_backend_name() -> String:
	return "Base"

## Crea el peer del anfitrión. Devuelve null si falla.
func create_host(_port: int, _max_clients: int) -> MultiplayerPeer:
	push_error("NetworkBackend.create_host no implementado")
	return null

## Crea el peer de un cliente. `address` es una IP/host (ENet) o un id de lobby (Steam).
func create_client(_address: String, _port: int) -> MultiplayerPeer:
	push_error("NetworkBackend.create_client no implementado")
	return null

## Ajustes por conexión (timeouts, etc.) que se aplican cuando un peer se conecta.
## Opcional: la implementación por defecto no hace nada.
func configure_peer(_multiplayer_peer: MultiplayerPeer, _peer_id: int) -> void:
	pass

## (host) Lo que los demás necesitan para unirse (IP, código de sala...). "" si no hay nada que mostrar.
func get_join_hint() -> String:
	return ""

## Cómo se llama esa pista en la UI ("IP para unirse", "Código de sala"...).
func get_join_hint_label() -> String:
	return ""

## Se llama cada frame mientras hay red (señalización, timeouts...). Opcional.
func poll(_delta: float) -> void:
	pass

## Se llama al cerrar la red: libera lo que el backend tenga abierto. Opcional.
func close() -> void:
	pass
