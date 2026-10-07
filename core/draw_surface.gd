class_name DrawSurface
extends Control
## Control a pantalla completa para que los minijuegos dibujen sus formas con _draw.
## Uso: surface.draw_callback = _draw_game; y surface.queue_redraw() cada frame.
## Dentro del callback se pueden usar surface.draw_*() y los helpers de texto.

var draw_callback: Callable

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _draw() -> void:
	if draw_callback.is_valid():
		draw_callback.call()

## Dibuja texto centrado en `center` con contorno oscuro (estilo de la guía).
func text_centered(center: Vector2, s: String, font_size: int, color: Color = Color.WHITE,
		outline: int = 6) -> void:
	var font := get_theme_default_font()
	var sz := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var pos := Vector2(center.x - sz.x * 0.5, center.y + font.get_ascent(font_size) - sz.y * 0.5)
	if outline > 0:
		draw_string_outline(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, outline, Palette.PURPLE_DARK)
	draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

## Dibuja un rectángulo redondeado relleno.
func rounded_rect(rect: Rect2, radius: float, color: Color) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(int(radius))
	sb.anti_aliasing = true
	draw_style_box(sb, rect)
