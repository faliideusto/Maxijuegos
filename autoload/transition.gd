extends CanvasLayer
## Transiciones entre pantallas (autoload): una "cortina" de color que barre la pantalla.

const DURATION := 0.3

var _curtain: ColorRect
var _stripe: ColorRect
var _busy: bool = false
var _queued_path: String = ""

func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_stripe = ColorRect.new()
	_stripe.color = Palette.YELLOW
	_curtain = ColorRect.new()
	_curtain.color = Palette.PURPLE_DARK
	for rect: ColorRect in [_stripe, _curtain]:
		rect.size = Palette.VIEWPORT_SIZE + Vector2(40, 0)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.visible = false
		add_child(rect)

## Cambia de escena con transición. Si ya hay una en curso, la nueva se encola (solo se
## conserva la última) y se ejecuta al terminar: el flujo de partida nunca se pierde un cambio.
func change_scene(path: String) -> void:
	if _busy:
		_queued_path = path
		return
	_busy = true
	Audio.sfx(&"swoosh", -6.0)
	var vs := get_viewport().get_visible_rect().size
	var w := vs.x
	for rect: ColorRect in [_stripe, _curtain]:
		rect.size = vs + Vector2(40, 0)
	_curtain.visible = true
	_stripe.visible = true
	_curtain.position.x = -w - 40
	_stripe.position.x = -w - 40
	# Entra (la franja amarilla va un poco por delante).
	var t_in := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	t_in.tween_property(_stripe, "position:x", 0.0, DURATION)
	t_in.tween_property(_curtain, "position:x", 0.0, DURATION).set_delay(0.06)
	await t_in.finished
	get_tree().change_scene_to_file(path)
	await get_tree().process_frame
	await get_tree().process_frame
	# Sale por la derecha.
	var t_out := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	t_out.tween_property(_curtain, "position:x", w + 40, DURATION)
	t_out.tween_property(_stripe, "position:x", w + 40, DURATION).set_delay(0.06)
	await t_out.finished
	_curtain.visible = false
	_stripe.visible = false
	_busy = false
	if not _queued_path.is_empty():
		var next := _queued_path
		_queued_path = ""
		change_scene(next)
