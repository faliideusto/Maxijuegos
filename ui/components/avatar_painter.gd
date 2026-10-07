class_name AvatarPainter
extends RefCounted
## Dibuja el avatar de un jugador (círculo de color con ojos) en cualquier CanvasItem.
## Lo comparten la UI (PlayerAvatar) y los minijuegos, para que el jugador se vea igual en todas partes.

## `look` = dirección hacia la que miran los ojos (normalizada o cero).
static func paint(ci: CanvasItem, center: Vector2, radius: float, color: Color,
		look: Vector2 = Vector2.ZERO) -> void:
	# Sombra dura inferior + borde blanco + cuerpo.
	ci.draw_circle(center + Vector2(0, radius * 0.14), radius, Palette.PURPLE_DARK)
	ci.draw_circle(center, radius, Palette.WHITE)
	ci.draw_circle(center, radius * 0.88, color)
	# Brillo.
	ci.draw_circle(center + Vector2(-0.35, -0.4) * radius, radius * 0.2, Color(1, 1, 1, 0.35))
	# Ojos.
	var eye_r := radius * 0.25
	for side in [-1.0, 1.0]:
		var eye := center + Vector2(side * radius * 0.33, -radius * 0.08) + look * radius * 0.08
		ci.draw_circle(eye, eye_r, Palette.WHITE)
		ci.draw_circle(eye + look * eye_r * 0.4, eye_r * 0.52, Palette.PURPLE_DARK)

## Corona sobre un avatar (para el ganador).
static func paint_crown(ci: CanvasItem, center: Vector2, radius: float) -> void:
	var base := center.y - radius * 0.82   # apoyada sobre la cabeza
	var w := radius * 0.72
	var h := radius * 0.62
	var cx := center.x
	var pts := PackedVector2Array([
		Vector2(cx - w, base), Vector2(cx - w, base - h * 0.95),
		Vector2(cx - w * 0.45, base - h * 0.45), Vector2(cx, base - h * 1.1),
		Vector2(cx + w * 0.45, base - h * 0.45), Vector2(cx + w, base - h * 0.95),
		Vector2(cx + w, base)])
	ci.draw_colored_polygon(pts, Palette.YELLOW)
	var outline := pts.duplicate()
	outline.append(pts[0])
	ci.draw_polyline(outline, Palette.YELLOW_DARK, 4.0, true)
	# Perlas en las puntas.
	for tip in [pts[1], pts[3], pts[5]]:
		ci.draw_circle(tip, radius * 0.1, Palette.WHITE)
