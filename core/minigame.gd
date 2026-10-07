class_name Minigame
extends Node
## Clase base de todos los minijuegos.
##
## MODELO (host autoritativo): el minijuego se instancia en TODOS los PC, pero solo el host
## simula (is_authority). Los clientes únicamente dibujan el estado que reciben.
## El autor de un minijuego NO escribe código de red: implementa estos métodos.
##
##   _on_prepare()            construye lo visual (antes de la cuenta atrás, en todos los PC)
##   _on_start()              empieza el juego (todos los PC; inicializar variables)
##   _simulate(delta)         lógica del juego. SOLO host. Lee la entrada con move_input() /
##                            action_presses() y termina con finish(ranking)
##   _animate(delta)          animaciones/suavizado. Todos los PC, cada frame
##   _serialize_state()       SOLO host: devuelve el estado a mostrar (Dictionary/Array/
##                            Packed*Array con tipos simples; unos ~30 envíos por segundo)
##   _apply_state(state)      clientes: recibe ese estado y lo copia a las variables a dibujar
##   _on_event(name, data)    (opcional) eventos puntuales: el host los lanza con send_event()
##                            y se ejecutan en todos los PC (sonidos, partículas, "+1"...)
##   _bot_move / _bot_action  (opcional) IA propia de los bots
##
## Contrato de resultados: finish(ranking) con los ids de jugador del 1º al último, UNA vez
## (solo host). El flujo de la partida, los puntos y la red no son asunto del minijuego.
## Ver docs/network.md ("Cómo escribir un minijuego").

## (solo host) Ranking final: ids de jugador (PlayerData.id) del 1º al último.
signal finished(results: Array[int])
## (todos los PC) El juego terminó; sirve para mostrar el aviso de fin.
signal ended

var players: Array[PlayerData] = []
## Metadatos de este minijuego (los inyecta el runner).
var meta: MinigameMeta
var is_running: bool = false
## true en el host (y en partidas locales): este PC simula. false en un cliente online.
var is_authority: bool = true
## Frecuencia (Hz) de envío de snapshots a los clientes.
var snapshot_rate: float = 30.0

## Superficie de dibujo a pantalla completa (asignar draw_callback en _on_prepare).
var surface: DrawSurface

var _finished: bool = false
var _session: Node = null   # MinigameSession (null en partidas locales)

# ----------------------------------------------------------------------------
# API pública (la usan el runner y la sesión)
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

func set_session(session: Node) -> void:
	_session = session

func serialize_state() -> Variant:
	return _serialize_state()

func apply_state(state: Variant) -> void:
	_apply_state(state)

func deliver_event(event_name: String, data: Variant) -> void:
	_on_event(event_name, data)

## (cliente) El host avisó de que el juego terminó.
func remote_end() -> void:
	if is_running or not _finished:
		is_running = false
		_finished = true
		ended.emit()

func _process(delta: float) -> void:
	delta = minf(delta, 0.05)
	if is_authority and is_running:
		_simulate(delta)
	_animate(delta)
	if surface:
		surface.queue_redraw()

# ----------------------------------------------------------------------------
# Métodos virtuales (sobrescribir en cada minijuego)
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	pass

func _on_start() -> void:
	pass

func _simulate(_delta: float) -> void:
	pass

func _animate(_delta: float) -> void:
	pass

func _serialize_state() -> Variant:
	return null

func _apply_state(_state: Variant) -> void:
	pass

func _on_event(_event_name: String, _data: Variant) -> void:
	pass

## Movimiento de un bot. Por defecto, deambula al azar; sobrescribir para IA propia.
func _bot_move(player: PlayerData) -> Vector2:
	return InputManager.get_vector(player.id)

## Pulsaciones de acción de un bot este frame. Por defecto, al azar (ver InputManager).
func _bot_action(player: PlayerData) -> int:
	return InputManager.action_presses(player.id)

# ----------------------------------------------------------------------------
# Utilidades para los minijuegos
# ----------------------------------------------------------------------------

## Vector de movimiento del jugador (humano local, remoto o bot), longitud <= 1.
func move_input(player: PlayerData) -> Vector2:
	if player.is_bot:
		return _bot_move(player).limit_length(1.0)
	return InputManager.get_vector(player.id)

## Nº de pulsaciones de acción del jugador en este frame.
func action_presses(player: PlayerData) -> int:
	if player.is_bot:
		return _bot_action(player)
	return InputManager.action_presses(player.id)

## true el frame en que el jugador pulsa su botón de acción.
func action_just_pressed(player: PlayerData) -> bool:
	return action_presses(player) > 0

## (host) Lanza un evento puntual: se ejecuta _on_event aquí y en todos los clientes.
func send_event(event_name: String, data: Variant = null) -> void:
	_on_event(event_name, data)
	if _session != null and is_authority:
		_session.send_event(event_name, data)

## true si el jugador es el de ESTE PC en una partida online (para marcarlo en pantalla).
func is_local_player(player: PlayerData) -> bool:
	return player.device == PlayerData.DEVICE_LOCAL

## Marca "tú" sobre el jugador local (triángulo sobre su avatar).
func draw_local_marker(center: Vector2, radius: float) -> void:
	if surface == null:
		return
	var tip := center + Vector2(0, -radius - 10.0)
	surface.draw_colored_polygon(PackedVector2Array([tip, tip + Vector2(-9, -14), tip + Vector2(9, -14)]),
			Palette.WHITE)

## Termina el minijuego (solo host). `ranking` = ids del mejor al peor. Los jugadores que
## falten se añaden al final, así que nunca se pierde a nadie. Solo cuenta la primera llamada.
func finish(ranking: Array[int]) -> void:
	if _finished or not is_authority:
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
	ended.emit()
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
