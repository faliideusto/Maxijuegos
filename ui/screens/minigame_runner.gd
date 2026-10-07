extends Node
## Ejecuta el minijuego actual en CADA PC: lo instancia, sincroniza el arranque, hace la
## cuenta atrás y muestra el aviso de fin. Es el único punto que habla con los minijuegos.
##
## Host (o partida local): simula; al terminar entrega el ranking a GameManager.
## Cliente online: solo dibuja lo que le llega y espera a que el host cambie de estado.

const COUNTDOWN := ["3", "2", "1", "¡YA!"]
## Segundos reales máximos que el host espera a que los clientes carguen el minijuego.
const READY_TIMEOUT := 8.0
## Segundos reales máximos que un cliente espera la señal del host.
const BEGIN_TIMEOUT := 15.0

var _minigame: Minigame
var _session: MinigameSession
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
	var is_host := NetworkManager.is_host()
	_minigame.meta = meta
	_minigame.is_authority = is_host
	add_child(_minigame)
	_minigame.prepare(Lobby.players)

	# Overlay de cuenta atrás / aviso de fin.
	_overlay = CanvasLayer.new()
	_overlay.layer = 10
	add_child(_overlay)
	_label = UIKit.label("", &"TitleLabel")
	_label.add_theme_font_size_override("font_size", 160)
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_overlay.add_child(_label)

	# Sincronización de arranque (solo online): todos listos → todos empiezan.
	if NetworkManager.is_online:
		_session = MinigameSession.new()
		add_child(_session)
		_session.setup(_minigame)
		if is_host:
			await _session.wait_for_clients(READY_TIMEOUT)
			_session.send_begin()
		else:
			_session.send_ready()
			await _session.wait_for_begin(BEGIN_TIMEOUT)

	_minigame.ended.connect(_on_ended, CONNECT_ONE_SHOT)
	if is_host:
		_minigame.finished.connect(_on_finished, CONNECT_ONE_SHOT)
	await _run_countdown()
	_minigame.start(Lobby.players)
	if _session:
		_session.start()

func _run_countdown() -> void:
	await get_tree().create_timer(0.3).timeout
	for step in COUNTDOWN:
		_show_big(step)
		await get_tree().create_timer(0.65 if step != "¡YA!" else 0.45).timeout
	_label.text = ""

## Todos los PC: aviso de fin.
func _on_ended() -> void:
	_show_big("¡FIN!")

## Solo host: tras el aviso, entrega el ranking (GameManager reparte puntos y avisa a los clientes).
func _on_finished(results: Array[int]) -> void:
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
	for p in Lobby.players:
		ids.append(p.id)
	return ids
