extends Node
## Lobby (autoload): lista de jugadores (roster) y su sincronización online.
##
## Responsabilidades (y solo estas):
##   - crear/quitar jugadores (humanos locales, bots, jugadores remotos), nombre y color;
##   - modo ONLINE: el que crea la sala es el host; cada cliente aporta UN jugador;
##   - validar altas (versión, sala llena, partida en curso) y bajas (desconexiones);
##   - difundir el roster del host a los clientes.
## No conoce minijuegos ni puntuaciones (eso es GameManager) ni el transporte (NetworkManager).
##
## Decisión de diseño: si alguien se desconecta con la partida en marcha, su jugador NO se
## elimina (los minijuegos tienen estado por jugador): pasa a ser un bot marcado como
## `disconnected`. Así ninguna partida puede quedarse bloqueada por una caída.

signal roster_changed
## (cliente) El host nos aceptó en la sala.
signal joined_room
## (cliente) El host nos rechazó (versión, sala llena, partida empezada...).
signal join_rejected(reason: String)

const PROFILE_PATH := "user://profile.cfg"
const MAX_NAME_LENGTH := 14

var players: Array[PlayerData] = []
## Nombre que usará este PC al crear/unirse a una sala (se recuerda entre sesiones).
var profile_name: String = "Jugador"

func _ready() -> void:
	_load_profile()
	NetworkManager.register_channel(NetProtocol.CH_LOBBY, _on_message)
	NetworkManager.peer_left.connect(_on_peer_left)
	NetworkManager.connected_to_host.connect(_on_connected_to_host)

# ----------------------------------------------------------------------------
# Consulta
# ----------------------------------------------------------------------------

func get_player(id: int) -> PlayerData:
	for p in players:
		if p.id == id:
			return p
	return null

## Jugador humano de un peer concreto (null si no tiene o es un bot).
func player_of_peer(peer_id: int) -> PlayerData:
	for p in players:
		if p.peer_id == peer_id and not p.is_bot:
			return p
	return null

## El jugador de ESTE PC en una partida online (null en modo local).
func get_local_player() -> PlayerData:
	for p in players:
		if p.device == PlayerData.DEVICE_LOCAL:
			return p
	return null

## ¿Puede este PC editar nombre/color de ese jugador?
func can_edit(p: PlayerData) -> bool:
	if not NetworkManager.is_online:
		return true
	if NetworkManager.is_host():
		return p.is_bot or p.peer_id == NetworkManager.local_peer_id()
	return p.peer_id == NetworkManager.local_peer_id() and not p.is_bot

## ¿Puede este PC quitar/expulsar a ese jugador? (solo el host, y nunca a sí mismo)
func can_remove(p: PlayerData) -> bool:
	if not NetworkManager.is_host():
		return false
	return not NetworkManager.is_online or p.peer_id != NetworkManager.local_peer_id() or p.is_bot

## Una IP de red local para decir a los amigos a qué dirección unirse ("" si no se encuentra).
func local_ip_hint() -> String:
	for addr in IP.get_local_addresses():
		if addr.begins_with("192.168.") or addr.begins_with("10."):
			return addr
		if addr.begins_with("172."):
			var second := int(addr.split(".")[1])
			if second >= 16 and second <= 31:
				return addr
	return ""

# ----------------------------------------------------------------------------
# Sala online
# ----------------------------------------------------------------------------

## Crea una sala: este PC es el host y aporta un jugador.
func host_room() -> Error:
	clear()
	var err := NetworkManager.host_game()
	if err != OK:
		return err
	var p := _create_player(PlayerData.DEVICE_LOCAL, profile_name)
	p.peer_id = NetworkManager.local_peer_id()
	_register(p)
	return OK

## Se une a una sala. El resultado llega por NetworkManager.connected_to_host /
## connection_failed y después por joined_room / join_rejected.
func join_room(address: String) -> Error:
	clear()
	return NetworkManager.join_game(address)

func save_profile_name(new_name: String) -> void:
	profile_name = _sanitize_name(new_name, profile_name)
	var cfg := ConfigFile.new()
	cfg.set_value("profile", "name", profile_name)
	cfg.save(PROFILE_PATH)

# ----------------------------------------------------------------------------
# Edición del roster (modo local: cualquier jugador; online: según can_edit)
# ----------------------------------------------------------------------------

## Dispositivos locales que aún no usa ningún jugador (modo local).
func free_devices() -> Array[String]:
	var used: Array[String] = []
	for p in players:
		used.append(p.device)
	var free: Array[String] = []
	for d in InputManager.available_devices():
		if not used.has(d):
			free.append(d)
	return free

## (modo local) Añade un jugador con teclado/mando. Con `device` vacío usa el primer libre.
func add_player(device: String = "") -> PlayerData:
	if NetworkManager.is_online or players.size() >= PlayerData.MAX_PLAYERS:
		return null
	if device.is_empty():
		var free := free_devices()
		if free.is_empty():
			return null
		device = free[0]
	var p := _create_player(device, "")
	_register(p)
	return p

## (host / modo local) Añade un bot: relleno o pruebas con pocos PCs.
func add_bot() -> PlayerData:
	if not NetworkManager.is_host() or players.size() >= PlayerData.MAX_PLAYERS:
		return null
	var p := _create_player(PlayerData.DEVICE_BOT, "")
	p.peer_id = NetworkManager.local_peer_id()
	_register(p)
	return p

## (host / modo local) Quita un jugador. Online, a un humano remoto se le expulsa.
func remove_player(id: int) -> void:
	var p := get_player(id)
	if p == null or not can_remove(p):
		return
	if p.is_remote:
		NetworkManager.kick(p.peer_id)   # peer_left hará el resto
		return
	InputManager.unregister_player(p)
	players.erase(p)
	_roster_updated()

## (modo local) Pasa el jugador al siguiente dispositivo libre (o bot).
func cycle_device(p: PlayerData) -> void:
	if NetworkManager.is_online:
		return
	var options := free_devices()
	options.append(PlayerData.DEVICE_BOT)
	var idx := options.find(p.device)
	p.device = options[(idx + 1) % options.size()] if idx >= 0 else options[0]
	InputManager.register_player(p)
	_roster_updated()

## Cambia el color al siguiente libre. Un cliente lo pide al host.
func cycle_color(p: PlayerData, step: int = 1) -> void:
	if not can_edit(p):
		return
	if NetworkManager.is_host():
		_apply_cycle_color(p, step)
		_roster_updated()
	else:
		NetworkManager.send_to_host(NetProtocol.CH_LOBBY, {"op": "profile", "cycle": step})

## Cambia el nombre. Un cliente lo pide al host.
func set_player_name(p: PlayerData, text: String) -> void:
	if not can_edit(p):
		return
	if NetworkManager.is_host():
		p.display_name = _sanitize_name(text, p.display_name)
		_roster_updated()
	else:
		NetworkManager.send_to_host(NetProtocol.CH_LOBBY, {"op": "profile", "name": text})

func clear() -> void:
	for p in players:
		InputManager.unregister_player(p)
	players.clear()
	roster_changed.emit()

## Elimina a los desconectados (ya sustituidos por bots) antes de una nueva partida/lobby.
func prune_disconnected() -> void:
	var keep: Array[PlayerData] = []
	for p in players:
		if p.disconnected:
			InputManager.unregister_player(p)
		else:
			keep.append(p)
	if keep.size() != players.size():
		players = keep
		_roster_updated()

# ----------------------------------------------------------------------------
# Internos: creación de jugadores
# ----------------------------------------------------------------------------

func _create_player(device: String, p_name: String) -> PlayerData:
	var p := PlayerData.new()
	p.id = _first_free_slot()
	p.device = device
	p.color_index = _first_free_color(p.id)
	if p_name.is_empty():
		p_name = ("Bot %d" if p.is_bot else "Jugador %d") % (p.id + 1)
	p.display_name = _sanitize_name(p_name, "Jugador %d" % (p.id + 1))
	return p

func _register(p: PlayerData) -> void:
	players.append(p)
	players.sort_custom(func(a: PlayerData, b: PlayerData) -> bool: return a.id < b.id)
	InputManager.register_player(p)
	_roster_updated()

func _first_free_slot() -> int:
	for i in PlayerData.MAX_PLAYERS:
		if get_player(i) == null:
			return i
	return PlayerData.MAX_PLAYERS - 1

func _first_free_color(preferred: int) -> int:
	var n := Palette.PLAYER_COLORS.size()
	for i in n:
		var idx := (preferred + i) % n
		if not _color_in_use(idx, null):
			return idx
	return preferred % n

func _color_in_use(idx: int, ignore: PlayerData) -> bool:
	for p in players:
		if p != ignore and p.color_index == idx:
			return true
	return false

func _apply_cycle_color(p: PlayerData, step: int) -> void:
	var n := Palette.PLAYER_COLORS.size()
	var idx := p.color_index
	for i in n:
		idx = posmod(idx + (1 if step >= 0 else -1), n)
		if not _color_in_use(idx, p):
			p.color_index = idx
			return

## Limpia un nombre recibido (puede venir de un cliente no fiable).
func _sanitize_name(text: String, fallback: String) -> String:
	var clean := text.strip_edges().strip_escapes().left(MAX_NAME_LENGTH).strip_edges()
	return clean if not clean.is_empty() else fallback

func _load_profile() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PROFILE_PATH) == OK:
		profile_name = _sanitize_name(String(cfg.get_value("profile", "name", profile_name)), profile_name)

# ----------------------------------------------------------------------------
# Internos: sincronización
# ----------------------------------------------------------------------------

func _roster_updated() -> void:
	roster_changed.emit()
	if NetworkManager.is_online and NetworkManager.is_host():
		var data: Array = []
		for p in players:
			data.append(p.to_dict())
		NetworkManager.broadcast(NetProtocol.CH_LOBBY, {"op": "roster", "players": data})

func _on_connected_to_host() -> void:
	NetworkManager.send_to_host(NetProtocol.CH_LOBBY,
			{"op": "join", "v": NetProtocol.VERSION, "name": profile_name})

func _on_message(from_peer: int, payload: Variant) -> void:
	if not payload is Dictionary:
		return
	match String(payload.get("op", "")):
		"join": _host_handle_join(from_peer, payload)
		"profile": _host_handle_profile(from_peer, payload)
		"roster": _client_handle_roster(payload)
		"joined":
			if not NetworkManager.is_host():
				joined_room.emit()
		"rejected":
			if not NetworkManager.is_host():
				join_rejected.emit(String(payload.get("reason", "Rechazado por el anfitrión.")))

# --- host ---

func _host_handle_join(peer_id: int, payload: Dictionary) -> void:
	if not NetworkManager.is_online or not NetworkManager.is_host():
		return
	if player_of_peer(peer_id) != null:
		return   # petición duplicada
	var reason := ""
	if int(payload.get("v", 0)) != NetProtocol.VERSION:
		reason = "Versión del juego distinta a la del anfitrión."
	elif GameManager.state != GameManager.State.LOBBY and GameManager.state != GameManager.State.SETUP:
		reason = "La partida ya ha empezado."
	elif players.size() >= PlayerData.MAX_PLAYERS:
		reason = "La sala está llena (8 jugadores)."
	if not reason.is_empty():
		NetworkManager.send_to_peer(peer_id, NetProtocol.CH_LOBBY, {"op": "rejected", "reason": reason})
		_kick_later(peer_id)
		return
	var p := _create_player(PlayerData.DEVICE_REMOTE, str(payload.get("name", "")))
	p.peer_id = peer_id
	_register(p)
	NetworkManager.send_to_peer(peer_id, NetProtocol.CH_LOBBY, {"op": "joined"})

func _host_handle_profile(peer_id: int, payload: Dictionary) -> void:
	if not NetworkManager.is_online or not NetworkManager.is_host():
		return
	var p := player_of_peer(peer_id)   # un cliente solo puede tocar SU jugador
	if p == null:
		return
	if payload.has("name"):
		p.display_name = _sanitize_name(str(payload["name"]), p.display_name)
	if payload.has("cycle"):
		_apply_cycle_color(p, int(payload["cycle"]))
	_roster_updated()

func _kick_later(peer_id: int) -> void:
	# Margen para que el mensaje de rechazo llegue antes de cortar la conexión.
	await get_tree().create_timer(0.4).timeout
	NetworkManager.kick(peer_id)

func _on_peer_left(peer_id: int) -> void:
	if not NetworkManager.is_online or not NetworkManager.is_host():
		return
	var leaving: Array[PlayerData] = []
	for p in players:
		if p.peer_id == peer_id and not p.is_bot:
			leaving.append(p)
	if leaving.is_empty():
		return
	var in_lobby := GameManager.state in [GameManager.State.MENU, GameManager.State.LOBBY, GameManager.State.SETUP]
	for p in leaving:
		if in_lobby:
			InputManager.unregister_player(p)
			players.erase(p)
			DevCli.log_event("peer_left removed id=%d" % p.id)
		else:
			# Partida en marcha: lo sustituye un bot (nada se bloquea).
			p.device = PlayerData.DEVICE_BOT
			p.disconnected = true
			p.peer_id = NetworkManager.local_peer_id()
			InputManager.register_player(p)
			DevCli.log_event("replaced_by_bot id=%d" % p.id)
	_roster_updated()

# --- cliente ---

func _client_handle_roster(payload: Dictionary) -> void:
	if NetworkManager.is_host():
		return
	var list: Variant = payload.get("players", [])
	if not list is Array:
		return
	var my_peer := NetworkManager.local_peer_id()
	var seen: Dictionary = {}
	for d in list:
		if not d is Dictionary:
			continue
		var id := int(d.get("id", -1))
		if id < 0 or id >= PlayerData.MAX_PLAYERS:
			continue
		# Se actualizan los objetos en el sitio: los minijuegos guardan referencias a ellos.
		var p := get_player(id)
		var is_new := p == null
		if is_new:
			p = PlayerData.new()
			p.id = id
			players.append(p)
		var old_device := p.device
		p.display_name = String(d.get("name", ""))
		p.color_index = clampi(int(d.get("color", 0)), 0, Palette.PLAYER_COLORS.size() - 1)
		p.peer_id = int(d.get("peer", 1))
		p.score = int(d.get("score", 0))
		p.disconnected = bool(d.get("dc", false))
		# El dispositivo se interpreta desde la perspectiva de ESTE PC.
		if String(d.get("device", "")) == PlayerData.DEVICE_BOT:
			p.device = PlayerData.DEVICE_BOT
		elif p.peer_id == my_peer:
			p.device = PlayerData.DEVICE_LOCAL
		else:
			p.device = PlayerData.DEVICE_REMOTE
		if is_new or p.device != old_device:
			InputManager.register_player(p)
		seen[id] = true
	var keep: Array[PlayerData] = []
	for p in players:
		if seen.has(p.id):
			keep.append(p)
		else:
			InputManager.unregister_player(p)
	players = keep
	players.sort_custom(func(a: PlayerData, b: PlayerData) -> bool: return a.id < b.id)
	roster_changed.emit()
