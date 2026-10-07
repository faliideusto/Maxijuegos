class_name JuicyButton
extends Button
## Botón con "jugo": rebote al pasar el ratón, al pulsar y al soltar.
## El aspecto (colores/formas) viene del tema global: usar theme_type_variation
## = "PrimaryButton" / "SecondaryButton" / "DangerButton".

const HOVER_SCALE := 1.06
const PRESS_SCALE := 0.94

var _tween: Tween

func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	pivot_offset = size * 0.5
	resized.connect(func() -> void: pivot_offset = size * 0.5)
	mouse_entered.connect(func() -> void: _animate(HOVER_SCALE, 0.12))
	mouse_exited.connect(func() -> void: _animate(1.0, 0.12))
	focus_entered.connect(func() -> void: _animate(HOVER_SCALE, 0.12))
	focus_exited.connect(func() -> void: _animate(1.0, 0.12))
	button_down.connect(func() -> void: _animate(PRESS_SCALE, 0.06))
	button_up.connect(_on_button_up)

func _on_button_up() -> void:
	var target := HOVER_SCALE if (is_hovered() or has_focus()) else 1.0
	_animate(target, 0.35, Tween.TRANS_ELASTIC)

func _animate(target: float, duration: float, trans: Tween.TransitionType = Tween.TRANS_BACK) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween().set_trans(trans).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "scale", Vector2.ONE * target, duration)
