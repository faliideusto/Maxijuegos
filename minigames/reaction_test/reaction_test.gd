extends Minigame
## Reflejos (modelo LOCAL_PARALLEL): 5 rondas. Espera a que la pantalla se ponga verde y
## pulsa tu botón de acción lo más rápido posible. Pulsar antes de tiempo suma una penalización.
## Gana quien acumule MENOS tiempo.
##
## Cada jugador juega en su PC sin ver a los demás. Las esperas salen de `rng`, que tiene la
## misma semilla en todos los PC: todos juegan exactamente la misma prueba. Al terminar se
## llama a report_result() y el host construye la clasificación. No hay nada de red aquí.

const ROUNDS := 5
const FALSE_START_PENALTY := 0.5   # segundos
const MAX_REACTION := 2.0          # segundos; si no pulsas, cuenta esto
const FEEDBACK_TIME := 1.1
const MIN_PLAUSIBLE := 0.08        # por ronda: más rápido que esto no es humano
const MAX_PLAUSIBLE_TOTAL := 120.0

enum Phase { WAIT, GO, FEEDBACK, DONE }

var _delays: Array[float] = []
var _round: int = 0
var _phase: Phase = Phase.WAIT
var _wait_t: float = 0.0
var _go_ms: int = 0
var _fb_t: float = 0.0
var _fb_text: String = ""
var _fb_color: Color = Palette.WHITE
var _repeat_round: bool = false
var _total: float = 0.0
var _times: Array[float] = []      # reacción de cada ronda ya jugada
var _bot_reaction: float = 0.3

func _on_prepare() -> void:
	# Procedural y determinista: misma secuencia de esperas en todos los PC.
	for i in ROUNDS:
		_delays.append(rng.randf_range(1.2, 3.2))
	surface.draw_callback = _draw_game

func _on_start() -> void:
	_round = 0
	_total = 0.0
	_times.clear()
	_begin_round()

func _begin_round() -> void:
	_phase = Phase.WAIT
	_wait_t = 0.0

func _pressed() -> bool:
	return local_player != null and action_presses(local_player) > 0

# --- Lógica del jugador local (en cada PC) ---
func _play(delta: float) -> void:
	match _phase:
		Phase.WAIT:
			_wait_t += delta
			if _pressed():
				_total += FALSE_START_PENALTY
				Audio.sfx(&"error")
				_repeat_round = true
				_start_feedback("¡Demasiado pronto! +%.1f s" % FALSE_START_PENALTY, Palette.CORAL)
			elif _wait_t >= _delays[_round]:
				_phase = Phase.GO
				Audio.sfx(&"beep_go")
				DevCli.log_event("reaction GO round=%d" % _round)
				_go_ms = Time.get_ticks_msec()
				_bot_reaction = randf_range(0.2, 0.45)
		Phase.GO:
			var since := (Time.get_ticks_msec() - _go_ms) / 1000.0
			if _pressed():
				_register(since)
			elif since >= MAX_REACTION:
				_register(MAX_REACTION)
		Phase.FEEDBACK:
			_fb_t += delta
			if _fb_t >= FEEDBACK_TIME:
				if _repeat_round:
					_repeat_round = false
					_begin_round()
				elif _round + 1 >= ROUNDS:
					_phase = Phase.DONE
					report_result(-_total)   # menos tiempo = mejor = mayor puntuación
				else:
					_round += 1
					_begin_round()

func _register(reaction: float) -> void:
	_total += reaction
	_times.append(reaction)
	Audio.sfx(&"reaction_ok")
	_start_feedback("%d ms" % roundi(reaction * 1000.0), Palette.MINT)

func _start_feedback(text: String, color: Color) -> void:
	DevCli.log_event("reaction round=%d %s" % [_round, text])
	_phase = Phase.FEEDBACK
	_fb_t = 0.0
	_fb_text = text
	_fb_color = color

# --- IA de bots/autopiloto: nunca se adelantan; reaccionan tras un tiempo humano ---
func _bot_action(_player: PlayerData) -> int:
	if _phase == Phase.GO and (Time.get_ticks_msec() - _go_ms) / 1000.0 >= _bot_reaction:
		return 1
	return 0

# --- Resultado simulado de un bot (lo calcula el host con la semilla común) ---
func _bot_result(_player: PlayerData, r: RandomNumberGenerator) -> Dictionary:
	var total := 0.0
	for i in ROUNDS:
		total += r.randf_range(0.22, 0.55)
	return {"score": -total, "tiebreak": 0.0}

# --- El host comprueba que el resultado de un cliente es humanamente posible ---
func _validate_result(score: float, _tiebreak: float) -> bool:
	var total := -score
	return total >= ROUNDS * MIN_PLAUSIBLE and total <= MAX_PLAUSIBLE_TOTAL

# ----------------------------------------------------------------------------
# Dibujo (solo lo del jugador local: no se muestra nada de los demás)
# ----------------------------------------------------------------------------

func _draw_game() -> void:
	var s := surface
	var panel := Rect2(250, 150, 780, 330)
	var color := Palette.PURPLE_DARK
	var text := ""
	match _phase:
		Phase.WAIT:
			color = Palette.CORAL
			text = "ESPERA…"
		Phase.GO:
			color = Palette.MINT
			text = "¡YA!"
		Phase.FEEDBACK:
			color = _fb_color.darkened(0.25)
			text = _fb_text
		Phase.DONE:
			color = Palette.CARD
			text = "%.2f s" % _total
	s.rounded_rect(Rect2(panel.position + Vector2(0, 10), panel.size), 48, Color(0, 0, 0, 0.25))
	s.rounded_rect(panel, 48, color)
	s.text_centered(panel.get_center(), text, 110 if _phase != Phase.FEEDBACK else 80, Palette.WHITE, 12)
	# Cabecera: ronda y tiempo acumulado.
	s.text_centered(Vector2(640, 70), "RONDA %d / %d" % [mini(_round + 1, ROUNDS), ROUNDS], 56, Palette.YELLOW, 10)
	s.text_centered(Vector2(640, 540), "Tiempo: %.2f s" % _total, 40, Palette.WHITE, 8)
	# Puntos de progreso.
	for i in ROUNDS:
		var c := Vector2(640 + (i - (ROUNDS - 1) * 0.5) * 50.0, 600)
		var done := i < _times.size()
		s.draw_circle(c, 15.0, Palette.WHITE if done else Color(1, 1, 1, 0.25))
	# Tu avatar.
	if local_player != null:
		AvatarPainter.paint(s, Vector2(150, 360), 54.0, local_player.color, Vector2.RIGHT)
		s.text_centered(Vector2(150, 440), local_player.label(), 24, Palette.WHITE, 6)
