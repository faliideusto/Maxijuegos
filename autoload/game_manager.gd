extends Node
## Director de la partida (autoload): configuración, selección de minijuegos, flujo y puntuaciones.
## La lista de jugadores vive en Lobby; el transporte, en NetworkManager.
##
## Flujo:  MENU → LOBBY → SETUP → [ INTRO → PLAYING → SCOREBOARD ] × N → FINAL
##
## Online (host autoritativo): SOLO el host avanza el flujo. Cada cambio de estado se difunde
## a los clientes con el canal "flow" (mensaje completo e idempotente: playlist, índice,
## ranking, puntos y marcador); los clientes se limitan a reflejarlo. Las pantallas llaman
## a los mismos métodos en todos los PC: en un cliente, los métodos que avanzan la partida
## no hacen nada (el host decide).

enum State { MENU, LOBBY, SETUP, INTRO, PLAYING, SCOREBOARD, FINAL }

signal state_changed(new_state: State)
## Mensaje para el usuario (errores de red, etc.). También queda en last_notice.
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
## Número de minijuegos de la partida (lo elige el host).
var minigame_count: int = 5
var playlist: Array[MinigameMeta] = []
var current_index: int = -1
## Ranking del último minijuego (ids del 1º al último) y puntos otorgados (id → puntos).
var last_ranking: Array[int] = []
var last_points: Dictionary = {}
## Puntuaciones antes de repartir los puntos del último minijuego (para animar el marcador).
var previous_scores: Dictionary = {}
## Último aviso para el usuario; el menú lo muestra y lo limpia (take_notice).
var last_notice: String = ""

func _ready() -> void:
	NetworkManager.register_channel(NetProtocol.CH_FLOW, _on_flow_message)
	NetworkManager.disconnected.connect(_on_host_lost)
	Lobby.join_rejected.connect(_on_join_rejected)
	Lobby.joined_room.connect(_on_joined_room)

# ----------------------------------------------------------------------------
# Configuración y arranque de partida
# ----------------------------------------------------------------------------

## Cuántos minijuegos distintos admiten el número actual de jugadores.
func compatible_minigame_count() -> int:
	return MinigameRegistry.get_compatible(Lobby.players.size()).size()

## Texto con el motivo por el que no se puede empezar, o "" si se puede.
func start_blocker() -> String:
	if not NetworkManager.is_host():
		return "Esperando al anfitrión…"
	if Lobby.players.size() < MIN_PLAYERS:
		return "Hacen falta al menos %d jugadores." % MIN_PLAYERS
	if compatible_minigame_count() == 0:
		return "Ningún minijuego admite %d jugadores." % Lobby.players.size()
	return ""

func set_minigame_count(n: int) -> void:
	minigame_count = clampi(n, 1, MAX_MINIGAMES)

## (host) Genera la lista de minijuegos, reinicia puntuaciones y arranca la primera presentación.
func start_match(rng: RandomNumberGenerator = null) -> void:
	if not NetworkManager.is_host():
		return
	playlist = MinigameRegistry.pick_random(minigame_count, Lobby.players.size(), rng)
	if playlist.is_empty():
		_show_notice("No hay minijuegos disponibles para %d jugadores." % Lobby.players.size())
		return
	for p in Lobby.players:
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
# Bucle de partida (solo el host avanza; en clientes estas llamadas se ignoran)
# ----------------------------------------------------------------------------

## La presentación terminó: se juega el minijuego actual.
func run_minigame() -> void:
	if NetworkManager.is_host():
		_go(State.PLAYING)

## El minijuego terminó: el host reparte puntos según la posición y muestra el marcador.
func report_results(ranking: Array[int]) -> void:
	if not NetworkManager.is_host():
		return
	last_ranking = ranking
	last_points.clear()
	previous_scores.clear()
	for p in Lobby.players:
		previous_scores[p.id] = p.score
	for rank in ranking.size():
		var p := Lobby.get_player(ranking[rank])
		if p == null:
			continue
		var pts := MatchRules.points_for_rank(rank, Lobby.players.size())
		p.score += pts
		last_points[p.id] = pts
	_go(State.SCOREBOARD)

## Se cerró el marcador: siguiente minijuego, o pantalla final si era el último.
func continue_match() -> void:
	if not NetworkManager.is_host():
		return
	if current_index + 1 < playlist.size():
		current_index += 1
		_go(State.INTRO)
	else:
		_go(State.FINAL)

func is_last_minigame() -> bool:
	return current_index + 1 >= playlist.size()

## (host) Otra partida con los mismos jugadores (los desconectados se descartan).
func rematch() -> void:
	if not NetworkManager.is_host():
		return
	Lobby.prune_disconnected()
	if Lobby.players.size() < MIN_PLAYERS:
		_show_notice("Quedan menos de %d jugadores." % MIN_PLAYERS)
		go_to_lobby()
		return
	start_match()

# ----------------------------------------------------------------------------
# Navegación
# ----------------------------------------------------------------------------

## Sale al menú: cierra la red (si la hay) y vacía el roster.
func go_to_menu() -> void:
	NetworkManager.disconnect_from_game()
	Lobby.clear()
	_enter(State.MENU)

func go_to_lobby() -> void:
	if not NetworkManager.is_host():
		return
	Lobby.prune_disconnected()
	_go(State.LOBBY)

func go_to_setup() -> void:
	if NetworkManager.is_host():
		_go(State.SETUP)

## Devuelve y limpia el último aviso (para mostrarlo al cargar el menú).
func take_notice() -> String:
	var text := last_notice
	last_notice = ""
	return text

## (host) Cambia de estado, lo difunde a los clientes y cambia de pantalla.
func _go(new_state: State) -> void:
	# SETUP es solo del host: los clientes siguen viendo el lobby.
	if NetworkManager.is_online and new_state != State.SETUP:
		NetworkManager.broadcast(NetProtocol.CH_FLOW, _flow_payload(new_state))
	_enter(new_state)

func _enter(new_state: State) -> void:
	state = new_state
	DevCli.log_event("state=%s index=%d" % [State.keys()[new_state], current_index])
	state_changed.emit(new_state)
	Transition.change_scene(SCREENS[new_state])

func _show_notice(text: String) -> void:
	last_notice = text
	notice.emit(text)

# ----------------------------------------------------------------------------
# Sincronización de flujo (cliente)
# ----------------------------------------------------------------------------

func _flow_payload(s: State) -> Dictionary:
	var ids: Array = []
	for m in playlist:
		ids.append(String(m.id))
	var scores := {}
	for p in Lobby.players:
		scores[p.id] = p.score
	return {"op": "state", "s": int(s), "playlist": ids, "i": current_index,
			"rank": last_ranking, "pts": last_points, "prev": previous_scores, "scores": scores}

## Mensaje del host con el estado completo de la partida. Un cliente solo refleja.
func _on_flow_message(_from_peer: int, payload: Variant) -> void:
	if NetworkManager.is_host() or not payload is Dictionary or payload.get("op") != "state":
		return
	var new_state := int(payload.get("s", -1))
	if new_state < 0 or new_state >= State.size():
		return
	# Playlist: ids → metadatos locales. Si falta alguno, este cliente no puede jugar.
	var new_playlist: Array[MinigameMeta] = []
	for id in payload.get("playlist", []):
		var meta := MinigameRegistry.get_by_id(StringName(str(id)))
		if meta == null:
			_leave_with_notice("Te faltan minijuegos que tiene el anfitrión (versión distinta).")
			return
		new_playlist.append(meta)
	playlist = new_playlist
	current_index = clampi(int(payload.get("i", -1)), -1, playlist.size() - 1)
	last_ranking = _to_int_array(payload.get("rank", []))
	last_points = _to_int_dict(payload.get("pts", {}))
	previous_scores = _to_int_dict(payload.get("prev", {}))
	var scores := _to_int_dict(payload.get("scores", {}))
	for p in Lobby.players:
		p.score = int(scores.get(p.id, p.score))
	_enter(new_state as State)

## El host nos rechazó: cerramos la conexión y seguimos en el menú con el motivo.
func _on_join_rejected(reason: String) -> void:
	_show_notice(reason)
	NetworkManager.disconnect_from_game()
	Lobby.clear()
	DevCli.log_event("join_rejected: %s" % reason)

func _on_joined_room() -> void:
	# El host nos aceptó: pasamos al lobby de la sala.
	_enter(State.LOBBY)

## (cliente) Se cerró la conexión con el host.
func _on_host_lost() -> void:
	_leave_with_notice("Se perdió la conexión con el anfitrión.")

func _leave_with_notice(text: String) -> void:
	_show_notice(text)
	NetworkManager.disconnect_from_game()
	Lobby.clear()
	DevCli.log_event("host_lost: %s" % text)
	_enter(State.MENU)

func _to_int_array(value: Variant) -> Array[int]:
	var result: Array[int] = []
	if value is Array:
		for v in value:
			result.append(int(v))
	return result

func _to_int_dict(value: Variant) -> Dictionary:
	var result := {}
	if value is Dictionary:
		for k in value:
			result[int(k)] = int(value[k])
	return result
