class_name Minigame
extends Node
## Clase base de todos los minijuegos. Soporta DOS modelos de ejecución, que el minijuego
## declara en su meta.tres (MinigameMeta.execution_mode). El autor NO escribe código de red.
##
## ───────────────────────── HOST_AUTHORITATIVE ─────────────────────────
## Todos comparten escenario. El minijuego se instancia en todos los PC, pero solo el host
## simula (is_authority); los clientes dibujan el estado que reciben.
##   _simulate(delta)         lógica del juego. SOLO host. Lee la entrada con move_input() /
##                            action_presses() y termina con finish(ranking)
##   _serialize_state()       SOLO host: estado a mostrar (Dictionary/Array/Packed*Array)
##   _apply_state(state)      clientes: copia ese estado a las variables a dibujar
##   _on_event(name, data)    (opcional) eventos puntuales lanzados con send_event()
##   _on_player_text(player, text, final)  (opcional) texto escrito por un jugador: cada PC lo envía con
##                            submit_text() y el host lo recibe aquí ya validado de dueño (ver docs/network.md)
##
## ───────────────────────── LOCAL_PARALLEL ─────────────────────────────
## Cada jugador juega la prueba en su PC, sin ver a los demás ni sincronizar frames.
##   _play(delta)             lógica del jugador LOCAL (local_player), en cada PC. Usa `rng`
##                            (misma semilla en todos) para que la prueba procedural sea igual
##   report_result(score, tiebreak)  al terminar el jugador local. Por defecto gana la mayor
##                            puntuación (para "menor tiempo" usar score = -tiempo)
##   _bot_result(player, rng) resultado simulado de un bot/desconectado (el host lo calcula)
##   _validate_result(...)    (opcional) plausibilidad del resultado que envía un cliente
##   _rank_results(results)   (opcional) clasificación personalizada
##
## ───────────────────────── Común ──────────────────────────────────────
##   _on_prepare()            construye lo visual (antes de la cuenta atrás, en todos los PC)
##   _on_start()              empieza el juego (todos los PC)
##   _animate(delta)          animaciones/suavizado, todos los PC, cada frame
##   _bot_move / _bot_action  (opcional) IA propia de los bots
##
## El flujo (cuenta atrás, resultados, puntos, siguiente minijuego) y la red no son asunto
## del minijuego. Ver docs/network.md ("Cómo escribir un minijuego").

## (solo host) Ranking final: ids de jugador (PlayerData.id) del 1º al último.
signal finished(results: Array[int])
## (todos los PC) El minijuego terminó para todos; sirve para mostrar el aviso de fin.
signal ended
## (LOCAL_PARALLEL) El jugador local terminó y envió su resultado.
signal result_reported(score: float, tiebreak: float)

var players: Array[PlayerData] = []
## Metadatos de este minijuego (los inyecta el runner).
var meta: MinigameMeta
var is_running: bool = false
## true cuando el minijuego corre como PRÁCTICA en la pantalla de presentación: sin música propia y sin tocar nada del
## resto de la partida (el resultado no cuenta). El jugador lo juega de verdad con sus controles.
var demo: bool = false
## Modelo de ejecución (lo fija el runner a partir de meta.execution_mode).
var mode: MinigameMeta.ExecutionMode = MinigameMeta.ExecutionMode.HOST_AUTHORITATIVE
## true en el host (y en partidas locales): este PC decide los resultados. Un cliente online: false.
## (HOST_AUTHORITATIVE: además es quien simula.)
var is_authority: bool = true
## Longitud máxima del texto que se acepta de un jugador (el host recorta lo que llegue).
const MAX_TEXT_LENGTH := 32
## Frecuencia (Hz) de envío de snapshots a los clientes (HOST_AUTHORITATIVE).
var snapshot_rate: float = 30.0
## Semilla común de esta ejecución (la reparte el host) y generador determinista derivado.
## Usar `rng` para todo lo procedural: así todos los jugadores obtienen la misma prueba.
var seed_value: int = 0
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
## (LOCAL_PARALLEL) El jugador de este PC.
var local_player: PlayerData = null

## Superficie de dibujo a pantalla completa (asignar draw_callback en _on_prepare).
var surface: DrawSurface

var _finished: bool = false
var _reported: bool = false
var _session: Node = null   # MinigameSession (null en partidas locales)

# ----------------------------------------------------------------------------
# API pública (la usan el runner y la sesión)
# ----------------------------------------------------------------------------

## Fija modo, semilla y jugador local. El runner lo llama antes de prepare().
func configure(p_mode: MinigameMeta.ExecutionMode, p_seed: int, p_local_player: PlayerData) -> void:
	mode = p_mode
	seed_value = p_seed
	rng.seed = p_seed
	local_player = p_local_player

func prepare(p_players: Array[PlayerData]) -> void:
	players = p_players
	add_child(BackgroundFX.new())
	surface = DrawSurface.new()
	add_child(surface)
	_on_prepare()

func start(p_players: Array[PlayerData]) -> void:
	players = p_players
	_finished = false
	_reported = false
	is_running = true
	if meta != null and not demo:
		Audio.play_music(meta.music)   # cada minijuego declara su pista en meta.tres
	_on_start()

func set_session(session: Node) -> void:
	_session = session

func serialize_state() -> Variant:
	return _serialize_state()

func apply_state(state: Variant) -> void:
	_apply_state(state)

func deliver_event(event_name: String, data: Variant) -> void:
	_on_event(event_name, data)

## (cliente) El host avisó de que el minijuego terminó para todos.
func remote_end() -> void:
	if is_running or not _finished:
		is_running = false
		_finished = true
		ended.emit()

## Resultado simulado de un bot (determinista a partir de la semilla común).
func bot_result(player: PlayerData) -> Dictionary:
	var r := RandomNumberGenerator.new()
	r.seed = hash([seed_value, player.id])
	var res := _bot_result(player, r)
	return {"score": float(res.get("score", 0.0)), "tiebreak": float(res.get("tiebreak", 0.0))}

## ¿Es plausible el resultado enviado por un cliente? (anti-trampas básico, lo evalúa el host)
func validate_result(score: float, tiebreak: float) -> bool:
	return is_finite(score) and is_finite(tiebreak) and _validate_result(score, tiebreak)

## Clasificación (ids del 1º al último) a partir de los resultados {id: {"score","tiebreak"}}.
func rank_results(results: Dictionary) -> Array[int]:
	return _rank_results(results)

## Segundos tras los cuales el host da por no terminado a quien no envió resultado.
func parallel_timeout() -> float:
	if meta != null and meta.max_duration > 0.0:
		return meta.max_duration
	var approx := meta.approx_duration if meta != null else 30.0
	return approx * 2.0 + 15.0

func _process(delta: float) -> void:
	delta = minf(delta, 0.05)
	if is_running:
		if mode == MinigameMeta.ExecutionMode.HOST_AUTHORITATIVE:
			if is_authority:
				_simulate(delta)
		elif not _reported:
			_play(delta)
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

## HOST_AUTHORITATIVE, solo host.
func _simulate(_delta: float) -> void:
	pass

## LOCAL_PARALLEL, en cada PC, mientras el jugador local no haya terminado.
func _play(_delta: float) -> void:
	pass

func _animate(_delta: float) -> void:
	pass

func _serialize_state() -> Variant:
	return null

func _apply_state(_state: Variant) -> void:
	pass

func _on_event(_event_name: String, _data: Variant) -> void:
	pass

## HOST_AUTHORITATIVE, solo host (o partida local): un jugador envió texto. `final` = false mientras escribe
## (borrador en vivo), true al confirmar. `player` es el dueño del peer; en partida local (varios humanos en
## un PC) es null y el minijuego decide a quién corresponde.
func _on_player_text(_player: PlayerData, _text: String, _final: bool) -> void:
	pass

## Movimiento de un bot. Por defecto, deambula al azar; sobrescribir para IA propia.
func _bot_move(player: PlayerData) -> Vector2:
	return InputManager.get_vector(player.id)

## Pulsaciones de acción de un bot este frame. Por defecto, al azar (ver InputManager).
func _bot_action(player: PlayerData) -> int:
	return InputManager.action_presses(player.id)

## LOCAL_PARALLEL: resultado simulado de un bot. `r` es un generador propio de ese bot.
## Devolver {"score": float, "tiebreak": float}. Por defecto, al azar.
func _bot_result(_player: PlayerData, r: RandomNumberGenerator) -> Dictionary:
	return {"score": r.randf(), "tiebreak": 0.0}

## LOCAL_PARALLEL: filtro de plausibilidad de un resultado recibido de un cliente.
func _validate_result(_score: float, _tiebreak: float) -> bool:
	return true

## LOCAL_PARALLEL: orden por defecto = mayor puntuación primero; desempate por menor `tiebreak`.
func _rank_results(results: Dictionary) -> Array[int]:
	var scores := {}
	var ties := {}
	for id in results:
		scores[id] = results[id].get("score", ParallelResults.DNF_SCORE)
		ties[id] = results[id].get("tiebreak", 0.0)
	return rank_by_score(scores, ties)

# ----------------------------------------------------------------------------
# Utilidades para los minijuegos
# ----------------------------------------------------------------------------

## Vector de movimiento del jugador (humano local, remoto o bot), longitud <= 1.
func move_input(player: PlayerData) -> Vector2:
	if InputManager.is_simulated(player.id):
		return _bot_move(player).limit_length(1.0)
	return InputManager.get_vector(player.id)

## Nº de pulsaciones de acción del jugador en este frame.
func action_presses(player: PlayerData) -> int:
	if InputManager.is_simulated(player.id):
		return _bot_action(player)
	return InputManager.action_presses(player.id)

## true el frame en que el jugador pulsa su botón de acción.
func action_just_pressed(player: PlayerData) -> bool:
	return action_presses(player) > 0

## true mientras el jugador mantiene pulsado su botón de acción.
func action_held(player: PlayerData) -> bool:
	if InputManager.is_simulated(player.id):
		return _bot_action_held(player)
	return InputManager.is_action_pressed(player.id)

## (HOST_AUTHORITATIVE) Nº de pulsaciones del SEGUNDO botón (golpear) del jugador en este frame.
func action2_presses(player: PlayerData) -> int:
	if InputManager.is_simulated(player.id):
		return _bot_action2(player)
	return InputManager.action2_presses(player.id)

## Segundo botón de un bot/autopiloto. Por defecto, el azar de InputManager.
func _bot_action2(player: PlayerData) -> int:
	return InputManager.action2_presses(player.id)

## Botón de acción mantenido por un bot/autopiloto. Por defecto, deriva de _bot_action.
func _bot_action_held(player: PlayerData) -> bool:
	return _bot_action(player) > 0

## (HOST_AUTHORITATIVE, cualquier PC) El jugador de este PC envía texto al minijuego. En el host (o en
## partida local) se entrega directamente; en un cliente viaja al host por el canal genérico del minijuego.
func submit_text(text: String, final: bool = true) -> void:
	if mode != MinigameMeta.ExecutionMode.HOST_AUTHORITATIVE:
		return
	if is_authority:
		deliver_player_text(local_player, text, final)
	elif _session != null:
		_session.send_text(text, final)

## (host) Recibe texto de un jugador (ya comprobado el dueño): recorta y lo pasa a _on_player_text.
func deliver_player_text(player: PlayerData, text: String, final: bool) -> void:
	if not is_running or not is_authority:
		return
	_on_player_text(player, text.strip_edges().substr(0, MAX_TEXT_LENGTH), final)

## (HOST_AUTHORITATIVE, host) Lanza un evento puntual: se ejecuta _on_event aquí y en todos los
## clientes.
func send_event(event_name: String, data: Variant = null) -> void:
	_on_event(event_name, data)
	if _session != null and is_authority:
		_session.send_event(event_name, data)

## (LOCAL_PARALLEL) El jugador local terminó. Solo cuenta la primera llamada. El runner/la
## sesión se encargan de hacérselo llegar al host.
func report_result(score: float, tiebreak: float = 0.0) -> void:
	if _reported or mode != MinigameMeta.ExecutionMode.LOCAL_PARALLEL:
		return
	_reported = true
	DevCli.log_event("report_result score=%s" % score)
	result_reported.emit(score, tiebreak)

## true si el jugador es el de ESTE PC (para marcarlo en pantalla).
func is_local_player(player: PlayerData) -> bool:
	return player == local_player or player.device == PlayerData.DEVICE_LOCAL

## ¿Debe oírse el sonido de este jugador en este PC? Online: solo el jugador de este PC. Partida local:
## cualquier humano (los bots y el autopiloto no meten ruido).
func is_audible(player: PlayerData) -> bool:
	if NetworkManager.is_online:
		return is_local_player(player) and not InputManager.is_simulated(player.id)
	return not player.is_bot and not InputManager.is_simulated(player.id)

## Marca "tú" sobre el jugador local (triángulo sobre su avatar).
func draw_local_marker(center: Vector2, radius: float) -> void:
	if surface == null:
		return
	var tip := center + Vector2(0, -radius - 10.0)
	surface.draw_colored_polygon(PackedVector2Array([tip, tip + Vector2(-9, -14), tip + Vector2(9, -14)]),
			Palette.WHITE)

## Termina el minijuego para todos (solo host / partida local). `ranking` = ids del mejor al
## peor. Los jugadores que falten se añaden al final. Solo cuenta la primera llamada.
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
