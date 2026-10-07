class_name Confetti
extends Node2D
## Confeti generado por código (sin texturas). Añadir a la escena y llamar a rain() o burst().

const GRAVITY := 520.0

var _pieces: Array = []  # de Dictionary (sin tipar: filter() devuelve Array genérico)
var _rain_time_left: float = 0.0
var _rain_rate: float = 80.0   # piezas por segundo
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.randomize()

## Lluvia continua desde arriba durante `duration` segundos.
func rain(duration: float, rate: float = 80.0) -> void:
	_rain_time_left = duration
	_rain_rate = rate

## Explosión de piezas desde un punto.
func burst(origin: Vector2, count: int = 60) -> void:
	for i in count:
		var angle := _rng.randf_range(-PI, 0.0)
		var speed := _rng.randf_range(250.0, 700.0)
		_add_piece(origin, Vector2.from_angle(angle) * speed)

func _add_piece(pos: Vector2, vel: Vector2) -> void:
	var colors: Array[Color] = Palette.PLAYER_COLORS.duplicate()
	colors.append(Palette.YELLOW)
	colors.append(Palette.WHITE)
	_pieces.append({
		"pos": pos, "vel": vel,
		"rot": _rng.randf() * TAU, "spin": _rng.randf_range(-8.0, 8.0),
		"size": Vector2(_rng.randf_range(8.0, 16.0), _rng.randf_range(5.0, 9.0)),
		"color": colors[_rng.randi() % colors.size()],
		"sway": _rng.randf() * TAU,
	})

func _process(delta: float) -> void:
	if _rain_time_left > 0.0:
		_rain_time_left -= delta
		var n := int(_rain_rate * delta) + (1 if _rng.randf() < fmod(_rain_rate * delta, 1.0) else 0)
		for i in n:
			_add_piece(Vector2(_rng.randf() * Palette.VIEWPORT_SIZE.x, -20.0),
					Vector2(_rng.randf_range(-60.0, 60.0), _rng.randf_range(40.0, 200.0)))
	for p in _pieces:
		p.vel.y += GRAVITY * delta
		p.vel.x += sin(p.sway + Time.get_ticks_msec() * 0.004) * 30.0 * delta
		p.vel *= 1.0 - minf(delta * 0.8, 1.0)
		p.pos += p.vel * delta
		p.rot += p.spin * delta
	_pieces = _pieces.filter(func(p: Dictionary) -> bool: return p.pos.y < Palette.VIEWPORT_SIZE.y + 40.0)
	queue_redraw()

func _draw() -> void:
	for p in _pieces:
		draw_set_transform(p.pos, p.rot, Vector2.ONE)
		draw_rect(Rect2(-p.size * 0.5, p.size), p.color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
