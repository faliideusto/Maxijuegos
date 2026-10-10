class_name BackgroundFX
extends Control
## Fondo violeta con degradado y formas flotantes sutiles. Se añade como primer hijo
## de cada pantalla / minijuego. Todo se genera por código (sin assets).

const SHAPE_COUNT := 16

var _shapes: Array[Dictionary] = []

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	show_behind_parent = true

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var size_px := Palette.VIEWPORT_SIZE
	for i in SHAPE_COUNT:
		_shapes.append({
			"pos": Vector2(rng.randf() * size_px.x, rng.randf() * size_px.y),
			"vel": Vector2(rng.randf_range(-14.0, 14.0), rng.randf_range(-22.0, -6.0)),
			"size": rng.randf_range(24.0, 90.0),
			"rot": rng.randf() * TAU,
			"spin": rng.randf_range(-0.4, 0.4),
			"kind": rng.randi() % 3,
		})

func _real_size() -> Vector2:
	return size if size.x > 8.0 and size.y > 8.0 else Palette.VIEWPORT_SIZE

func _process(delta: float) -> void:
	var size_px := _real_size()
	for s in _shapes:
		s.pos += s.vel * delta
		s.rot += s.spin * delta
		# Reaparece por el lado opuesto al salir.
		if s.pos.y < -120.0: s.pos.y = size_px.y + 100.0
		if s.pos.x < -120.0: s.pos.x = size_px.x + 100.0
		if s.pos.x > size_px.x + 120.0: s.pos.x = -100.0
	queue_redraw()

func _draw() -> void:
	var r := Rect2(Vector2.ZERO, _real_size())
	# Degradado vertical.
	draw_polygon(PackedVector2Array([r.position, Vector2(r.end.x, 0), r.end, Vector2(0, r.end.y)]),
			PackedColorArray([Palette.BG_TOP, Palette.BG_TOP, Palette.BG_BOTTOM, Palette.BG_BOTTOM]))
	var tint := Color(1, 1, 1, 0.06)
	for s in _shapes:
		var sz: float = s.size
		match s.kind:
			0: # círculo
				draw_circle(s.pos, sz * 0.5, tint)
			1: # cuadrado redondeado girado
				draw_set_transform(s.pos, s.rot, Vector2.ONE)
				var sb := StyleBoxFlat.new()
				sb.bg_color = tint
				sb.set_corner_radius_all(int(sz * 0.25))
				draw_style_box(sb, Rect2(Vector2(-sz, -sz) * 0.5, Vector2(sz, sz)))
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			_: # triángulo
				draw_set_transform(s.pos, s.rot, Vector2.ONE)
				draw_colored_polygon(PackedVector2Array([Vector2(0, -sz * 0.55),
						Vector2(sz * 0.5, sz * 0.4), Vector2(-sz * 0.5, sz * 0.4)]), tint)
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
