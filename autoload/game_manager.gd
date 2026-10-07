extends Node
## Director de la partida (autoload). Mantiene la lista de jugadores, la configuración,
## la selección aleatoria de minijuegos, el flujo y las puntuaciones.
##
## Flujo:  MENU → LOBBY → SETUP → [ INTRO → PLAYING → SCOREBOARD ] × N → FINAL
## Las pantallas solo llaman a los métodos públicos de aquí; la lógica vive en este archivo.

enum State { MENU, LOBBY, SETUP, INTRO, PLAYING, SCOREBOARD, FINAL }

signal roster_changed
signal state_changed(new_state: State)
## Mensaje para mostrar al usuario (errores de red, etc.).
signal notice(text: String)

const SCREENS := {
	State.MENU: "res://ui/screens/main_menu.tscn",
	State.LOBBY: "res://ui/screens/lobby.tscn",
	State.SETUP: "res://ui/screens/match_setup.tscn",
	State.INTRO: "res://ui/screens/minigame_intro.tscn",
	State.PLAYING: "res://ui/screens/minigame_runner.tscn",
	State.SCOREBOARD: "res://ui/screens/scoreboard.tscn",
	State.FINAL: "res://ui/screens/final_screen.tscn",
}

const MIN_PLAYERS := 2
const MAX_MINIGAMES := 20

var state: State = State.MENU
var players: Array[PlayerData] = []
## Número de minijuegos de la partida (lo elige el host).
var minigame_count: int = 5
var playlist: Array[MinigameMeta] = []
var current_index: int = -1
## Ranking del último minijuego (ids del 1º al último) y puntos otorgados (id → puntos).
var last_ranking: Array[int] = []
var last_points: Dictionary = {}
## Puntuaciones antes de repartir los puntos del último minijuego (para animar el marcador).
var previous_scores: Dictionary = {}

func _ready() -> void:
	NetworkManager.join_requested.connect(_on_join_requested)
	NetworkManager.roster_received.connect(_on_roster_received)
	NetworkManager.peer_joined.connect(_on_peer_joined)
	NetworkManager.peer_left.connect(_on_peer_left)
	NetworkManager.connected_to_host.connect(_on_connected_to_host)
	NetworkManager.disconnected.connect(_on_host_lost)

# ----------------------------------------------------------------------------
# Jugadores
# ----------------------------------------------------------------------------

func get_player(id: int) -> PlayerData:
	for p in players:
		if p.id == id:
			return p
	return null

## Dispositivos humanos que aún no usa ningún jugador.
func free_devices() -> Array[String]:
	var used: Array[String] = []
	for p in players:
		used.append(p.device)
	var free: Array[String] = []
	for d in InputManager.available_devices():
		if not used.has(d):
			free.append(d)
	return free

## Añade un jugador local. Con `device` vacío usa el primer dispositivo libre.
## Devuelve null si no se puede (partida llena o sin dispositivos libres).
func add_player(device: String = "") -> PlayerData:
	if not NetworkManager.is_host() or players.size() >= PlayerData.MAX_PLAYERS:
		return null
	if device.is_empty():
		var free := free_devices()
		if free.is_empty():
			return null
		device = free[0]
	var p := _create_player(device, "")
	p.peer_id = NetworkManager.local_peer_id()
	_register(p)
	return p

func add_bot() -> PlayerData:
	return add_player(PlayerData.DEVICE_BOT)

func remove_player(id: int) -> void:
	var p := get_player(id)
	if p == null or not NetworkManager.is_host():
		return
	InputManager.unregister_player(p)
	players.erase(p)
	_roster_updated()

## Pasa el jugador al siguiente dispositivo humano libre (o bot si no hay).
func cycle_device(p: PlayerData) -> void:
	var options := free_devices()
	options.append(PlayerData.DEVICE_BOT)
	var idx := options.find(p.device)
	# Si el actual es humano, ya está "usado": se busca el siguiente tras él en la lista de libres.
	p.device = options[(idx + 1) % options.size()] if idx >= 0 else options[0]
	InputManager.register_player(p)
	_roster_updated()

## Cambia el color al siguiente que no use otro jugador.
func cycle_color(p: PlayerData, step: int = 1) -> void:
	var n := Palette.PLAYER_COLORS.size()
	var idx := p.color_index
	for i in n:
		idx = posmod(idx + step, n)
		if not _color_in_use(idx, p):
			p.color_index = idx
			break
	_roster_updated()

func clear_players() -> void:
	for p in players:
		InputManager.unregister_player(p)
	players.clear()
	_roster_updated()

func _create_player(device: String, p_name: String) -> PlayerData:
	var p := PlayerData.new()
	p.id = _first_free_slot()
	p.device = device
	p.color_index = _first_free_color(p.id)
	if p_name.is_empty():
		p_name = ("Bot %d" if p.is_bot else "Jugador %d") % (p.id + 1)
	p.display_name = p_name
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

# ----------------------------------------------------------------------------
# Configuración y arranque de partida
# ----------------------------------------------------------------------------

func player_count() -> int:
	return players.size()

## Cuántos minijuegos distintos admiten el número actual de jugadores.
func compatible_minigame_count() -> int:
	return MinigameRegistry.get_compatible(players.size()).size()

## Texto con el motivo por el que no se puede empezar, o "" si se puede.
func start_blocker() -> String:
	if not NetworkManager.is_host():
		return "Esperando al anfitrión…"
	if players.size() < MIN_PLAYERS:
		return "Hacen falta al menos %d jugadores." % MIN_PLAYERS
	for p in players:
		if p.is_remote:
			return "Online: los minijuegos en red llegan en la fase 2."
	if compatible_minigame_count() == 0:
		return "Ningún minijuego admite %d jugadores." % players.size()
	return ""

func set_minigame_count(n: int) -> void:
	minigame_count = clampi(n, 1, MAX_MINIGAMES)

## Genera la lista de minijuegos, reinicia puntuaciones y arranca la primera presentación.
func start_match(rng: RandomNumberGenerator = null) -> void:
	playlist = MinigameRegistry.pick_random(minigame_count, players.size(), rng)
	if playlist.is_empty():
		notice.emit("No hay minijuegos disponibles para %d jugadores." % players.size())
		return
	for p in players:
		p.score = 0
	previous_scores.clear()
	last_points.clear()
	last_ranking.clear()
	current_index = 0
	_go(State.INTRO)

func current_minigame() -> MinigameMeta:
	if current_index < 0 or current_index >= playlist.size():
		return null
	return playlist[current_index]

# ----------------------------------------------------------------------------
# Bucle de partida
# ----------------------------------------------------------------------------

## La presentación terminó: se juega el minijuego actual.
func run_minigame() -> void:
	_go(State.PLAYING)

## El minijuego terminó: reparte puntos según la posición y muestra el marcador.
func report_results(ranking: Array[int]) -> void:
	last_ranking = ranking
	last_points.clear()
	previous_scores.clear()
	for p in players:
		previous_scores[p.id] = p.score
	for rank in ranking.size():
		var p := get_player(ranking[rank])
		if p == null:
			continue
		var pts := MatchRules.points_for_rank(rank, players.size())
		p.score += pts
		last_points[p.id] = pts
	_go(State.SCOREBOARD)

## Se cerró el marcador: siguiente minijuego, o pantalla final si era el último.
func continue_match() -> void:
	if current_index + 1 < playlist.size():
		current_index += 1
		_go(State.INTRO)
	else:
		_go(State.FINAL)

## Número de minijuegos ya jugados (para mostrar "2 / 5").
func is_last_minigame() -> bool:
	return current_index + 1 >= playlist.size()

func rematch() -> void:
	start_match()

# ----------------------------------------------------------------------------
# Navegación
# ----------------------------------------------------------------------------

func go_to_menu() -> void:
	NetworkManager.disconnect_from_game()
	clear_players()
	_go(State.MENU)

func go_to_lobby() -> void:
	_go(State.LOBBY)

func go_to_setup() -> void:
	_go(State.SETUP)

func _go(new_state: State) -> void:
	state = new_state
	state_changed.emit(new_state)
	Transition.change_scene(SCREENS[new_state])

# ----------------------------------------------------------------------------
# Red (solo lobby en esta fase)
# ----------------------------------------------------------------------------

## Crea una sala online: este PC es el anfitrión.
func host_online() -> Error:
	clear_players()
	var err := NetworkManager.host_game()
	return err

## Se une a una sala online. El resultado llega por NetworkManager.connected_to_host
## / connection_failed.
func join_online(address: String) -> Error:
	clear_players()
	return NetworkManager.join_game(address)

func _roster_updated() -> void:
	roster_changed.emit()
	if NetworkManager.is_online and NetworkManager.is_host():
		_broadcast_roster()

func _broadcast_roster() -> void:
	var data: Array = []
	for p in players:
		data.append(p.to_dict())
	NetworkManager.broadcast_roster(data)

func _on_peer_joined(_peer_id: int) -> void:
	# El nuevo peer recibe la lista actual; su jugador se añade al llegar su petición.
	if NetworkManager.is_host():
		_broadcast_roster()

func _on_peer_left(peer_id: int) -> void:
	if not NetworkManager.is_host():
		return
	var leaving: Array[PlayerData] = []
	for p in players:
		if p.peer_id == peer_id and p.is_remote:
			leaving.append(p)
	for p in leaving:
		players.erase(p)
	if not leaving.is_empty():
		_roster_updated()

func _on_connected_to_host() -> void:
	NetworkManager.send_join_request("Jugador", 0)

func _on_join_requested(peer_id: int, player_name: String, color_index: int) -> void:
	if players.size() >= PlayerData.MAX_PLAYERS:
		return
	var p := _create_player(PlayerData.DEVICE_REMOTE, player_name)
	p.peer_id = peer_id
	if not _color_in_use(color_index, null):
		p.color_index = color_index
	_register(p)

func _on_roster_received(data: Array) -> void:
	# (cliente) Sustituye la lista local por la del anfitrión.
	for p in players:
		InputManager.unregister_player(p)
	players.clear()
	for d in data:
		var p := PlayerData.from_dict(d)
		# El cliente no controla a nadie en esta fase: todos son "online" (salvo bots).
		if not p.is_bot:
			p.device = PlayerData.DEVICE_REMOTE
		players.append(p)
	roster_changed.emit()
	# Primera lista recibida: ir al lobby.
	if state == State.MENU:
		go_to_lobby()

func _on_host_lost() -> void:
	clear_players()
	notice.emit("Se perdió la conexión con el anfitrión.")
	if state != State.MENU:
		_go(State.MENU)
