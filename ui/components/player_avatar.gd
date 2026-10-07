class_name PlayerAvatar
extends Control
## Avatar de jugador para la UI (círculo de color con ojos). Ver AvatarPainter.

@export var color: Color = Palette.PLAYER_COLORS[0]:
	set(value):
		color = value
		queue_redraw()
@export var crown: bool = false:
	set(value):
		crown = value
		queue_redraw()

var look: Vector2 = Vector2.ZERO

func _init(p_size: float = 72.0) -> void:
	custom_minimum_size = Vector2(p_size, p_size)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	pivot_offset = size * 0.5
	resized.connect(func() -> void: pivot_offset = size * 0.5)

## Aplica el color del jugador.
func set_player(p: PlayerData) -> void:
	color = p.color

## Salto con squash & stretch (para celebrar o llamar la atención).
func bounce() -> void:
	var t := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(self, "scale", Vector2(1.25, 0.8), 0.08)
	t.tween_property(self, "scale", Vector2(0.9, 1.15), 0.12)
	t.tween_property(self, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_ELASTIC)

func _draw() -> void:
	var radius := minf(size.x, size.y) * 0.5 - 4.0
	var center := size * 0.5 - Vector2(0, 2)
	AvatarPainter.paint(self, center, radius, color, look)
	if crown:
		AvatarPainter.paint_crown(self, center, radius)
