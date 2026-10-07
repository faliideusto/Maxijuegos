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
	var top := center.y - radius * 1.05
	var w := radius * 0.9
	var h := radius * 0.75
	var pts := PackedVector2Array([
		Vector2(center.x - w, top), Vector2(center.x - w * 0.5, top - h * 0.55),
		Vector2(center.x, top - h * 0.1), Vector2(center.x + w * 0.5, top - h * 0.55),
		Vector2(center.x + w, top)])
	ci.draw_colored_polygon(pts, Palette.YELLOW)
	ci.draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[4], pts[0]]),
			Palette.YELLOW_DARK, 3.0, true)
