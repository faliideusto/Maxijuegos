extends Minigame
## ¡Machaca!: pulsa tu botón de acción tantas veces como puedas en 10 segundos.
## Gana quien más pulsaciones consiga (desempate: quien llegó antes a esa cifra).

const DURATION := 10.0
const ARENA := Rect2(110, 150, 1060, 470)   # zona de columnas

var _counts: Dictionary = {}       # id -> pulsaciones
var _reached_at: Dictionary = {}   # id -> instante de la última pulsación (desempate)
var _bounce: Dictionary = {}       # id -> animación de "squash" del avatar (0..1)
var _bar_h: Dictionary = {}        # id -> altura mostrada (suavizada)
var _time_left: float = DURATION
var _elapsed: float = 0.0

func _on_prepare() -> void:
	for p in players:
		_counts[p.id] = 0
		_reached_at[p.id] = 0.0
		_bounce[p.id] = 0.0
		_bar_h[p.id] = 0.0
	surface.draw_callback = _draw_game
	surface.queue_redraw()

func _on_start() -> void:
	_time_left = DURATION

func _process(delta: float) -> void:
	for p in players:
		_bounce[p.id] = maxf(0.0, _bounce[p.id] - delta * 5.0)
	if is_running:
		_elapsed += delta
		_time_left -= delta
		for p in players:
			if action_just_pressed(p):
				_counts[p.id] += 1
				_reached_at[p.id] = _elapsed
				_bounce[p.id] = 1.0
		if _time_left <= 0.0:
			_time_left = 0.0
			finish(rank_by_score(_counts, _reached_at))
	# Las barras suben suavemente hacia su valor.
	var target_max := _scale_max()
	for p in players:
		var target: float = ARENA.size.y * 0.78 * float(_counts[p.id]) / target_max
		_bar_h[p.id] = lerpf(_bar_h[p.id], target, clampf(delta * 14.0, 0.0, 1.0))
	surface.queue_redraw()

# Escala vertical: crece si alguien supera el valor base, para que siempre quepan las barras.
func _scale_max() -> float:
	var m := 40.0
	for p in players:
		m = maxf(m, _counts[p.id] * 1.15)
	return m

func _draw_game() -> void:
	var s := surface
	# Temporizador.
	s.text_centered(Vector2(640, 70), "%.1f" % _time_left, 72, Palette.YELLOW, 12)
	var col_w := ARENA.size.x / players.size()
	var base_y := ARENA.end.y - 70.0
	for i in players.size():
		var p := players[i]
		var cx := ARENA.position.x + col_w * (i + 0.5)
		var bar_w := minf(110.0, col_w * 0.62)
		var h: float = _bar_h[p.id]
		# Carril y barra.
		s.rounded_rect(Rect2(cx - bar_w * 0.5, base_y - ARENA.size.y * 0.78, bar_w, ARENA.size.y * 0.78), 20, Color(0, 0, 0, 0.18))
		if h > 2.0:
			s.rounded_rect(Rect2(cx - bar_w * 0.5, base_y - h, bar_w, h), 20, p.color)
		# Contador sobre la barra.
		s.text_centered(Vector2(cx, base_y - h - 34.0), str(_counts[p.id]), 44, Palette.WHITE, 9)
		# Avatar con rebote (se aplasta al pulsar).
		var b: float = _bounce[p.id]
		var squash := Vector2(1.0 + 0.25 * b, 1.0 - 0.25 * b)
		s.draw_set_transform(Vector2(cx, base_y + 36.0), 0.0, squash)
		AvatarPainter.paint(s, Vector2.ZERO, minf(34.0, col_w * 0.3), p.color, Vector2(0, -1))
		s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		s.text_centered(Vector2(cx, base_y + 92.0), p.display_name, 22, Palette.WHITE, 5)
