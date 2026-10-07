extends Node
## Ejecuta el minijuego actual: lo instancia, hace la cuenta atrás, lo arranca y
## recoge su ranking al terminar. Es el ÚNICO punto que habla con los minijuegos.

const COUNTDOWN := ["3", "2", "1", "¡YA!"]

var _minigame: Minigame
var _overlay: CanvasLayer
var _label: Label

func _ready() -> void:
	var meta := GameManager.current_minigame()
	var node := meta.scene.instantiate()
	_minigame = node as Minigame
	if _minigame == null:
		push_error("La escena de '%s' no extiende Minigame; se omite." % meta.display_name)
		node.queue_free()
		GameManager.report_results(_default_ranking())
		return
	_minigame.meta = meta
	add_child(_minigame)
	_minigame.prepare(GameManager.players)

	# Overlay de cuenta atrás / aviso de fin.
	_overlay = CanvasLayer.new()
	_overlay.layer = 10
	add_child(_overlay)
	_label = UIKit.label("", &"TitleLabel")
	_label.add_theme_font_size_override("font_size", 160)
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_overlay.add_child(_label)

	await _run_countdown()
	_minigame.finished.connect(_on_finished, CONNECT_ONE_SHOT)
	_minigame.start(GameManager.players)

func _run_countdown() -> void:
	await get_tree().create_timer(0.3).timeout
	for step in COUNTDOWN:
		_show_big(step)
		await get_tree().create_timer(0.65 if step != "¡YA!" else 0.45).timeout
	_label.text = ""

func _on_finished(results: Array[int]) -> void:
	_show_big("¡FIN!")
	await get_tree().create_timer(1.4).timeout
	GameManager.report_results(results)

func _show_big(text: String) -> void:
	_label.text = text
	_label.pivot_offset = _label.size * 0.5
	_label.scale = Vector2.ONE * 1.8
	_label.modulate.a = 1.0
	var t := create_tween().set_parallel(true)
	t.tween_property(_label, "scale", Vector2.ONE, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _default_ranking() -> Array[int]:
	var ids: Array[int] = []
	for p in GameManager.players:
		ids.append(p.id)
	return ids
