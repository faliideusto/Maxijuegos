class_name Minigame
extends Node
## Clase base de todos los minijuegos.
##
## Contrato:
##   1. El runner instancia la escena y llama a prepare(players) → se construye lo visual.
##   2. Tras la cuenta atrás se llama a start(players) → empieza el juego.
##   3. El minijuego llama a finish(ranking) UNA vez, con los ids de jugador del mejor al peor.
##
## Los minijuegos no conocen el flujo de la partida ni la red: solo leen la entrada con
## move_input()/action_just_pressed() y emiten `finished`.

## Ranking final: ids de jugador (PlayerData.id) del 1º al último.
signal finished(results: Array[int])

var players: Array[PlayerData] = []
## Metadatos de este minijuego (los inyecta el runner).
var meta: MinigameMeta
var is_running: bool = false

## Superficie de dibujo a pantalla completa (asignar draw_callback en _on_prepare).
var surface: DrawSurface

var _finished: bool = false

# ----------------------------------------------------------------------------
# API pública (la usa el runner)
# ----------------------------------------------------------------------------

func prepare(p_players: Array[PlayerData]) -> void:
	players = p_players
	add_child(BackgroundFX.new())
	surface = DrawSurface.new()
	add_child(surface)
	_on_prepare()

func start(p_players: Array[PlayerData]) -> void:
	players = p_players
	_finished = false
	is_running = true
	_on_start()

# ----------------------------------------------------------------------------
# Métodos virtuales (sobrescribir en cada minijuego)
# ----------------------------------------------------------------------------

## Construye escena/estado inicial. Se ejecuta ANTES de la cuenta atrás.
func _on_prepare() -> void:
	pass

## Comienza el juego. Se ejecuta tras la cuenta atrás.
func _on_start() -> void:
	pass

## Movimiento de un bot. Por defecto, deambula al azar; sobrescribir para IA propia.
func _bot_move(player: PlayerData) -> Vector2:
	return InputManager.get_vector(player.id)

## Pulsación de acción de un bot. Por defecto, pulsa al azar (ver InputManager).
func _bot_action(player: PlayerData) -> bool:
	return InputManager.is_action_just_pressed(player.id)

# ----------------------------------------------------------------------------
# Utilidades para los minijuegos
# ----------------------------------------------------------------------------

## Vector de movimiento del jugador (humano o bot), longitud <= 1.
func move_input(player: PlayerData) -> Vector2:
	if player.is_bot:
		return _bot_move(player).limit_length(1.0)
	return InputManager.get_vector(player.id)

## true el frame en que el jugador pulsa su botón de acción.
func action_just_pressed(player: PlayerData) -> bool:
	if player.is_bot:
		return _bot_action(player)
	return InputManager.is_action_just_pressed(player.id)

## Termina el minijuego. `ranking` = ids del mejor al peor. Los jugadores que falten
## se añaden al final, así que nunca se pierde a nadie. Solo cuenta la primera llamada.
func finish(ranking: Array[int]) -> void:
	if _finished:
		return
	_finished = true
	is_running = false
	var complete: Array[int] = []
	for id in ranking:
		if not complete.has(id) and _has_player(id):
			complete.append(id)
	for p in players:
		if not complete.has(p.id):
			complete.append(p.id)
	finished.emit(complete)

## Ordena ids por puntuación descendente. `tiebreak` (opcional): id → valor, menor = mejor.
func rank_by_score(scores: Dictionary, tiebreak: Dictionary = {}) -> Array[int]:
	var ids: Array[int] = []
	for p in players:
		ids.append(p.id)
	ids.sort_custom(func(a: int, b: int) -> bool:
		var sa: float = scores.get(a, 0)
		var sb: float = scores.get(b, 0)
		if not is_equal_approx(sa, sb):
			return sa > sb
		var ta: float = tiebreak.get(a, 0.0)
		var tb: float = tiebreak.get(b, 0.0)
		if not is_equal_approx(ta, tb):
			return ta < tb
		return a < b)
	return ids

func _has_player(id: int) -> bool:
	for p in players:
		if p.id == id:
			return true
	return false
