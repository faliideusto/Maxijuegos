extends Control
## Marcador tras cada minijuego: muestra los puntos ganados (+N) y reordena a los
## jugadores con animación. Avanza solo, o con la acción de cualquier jugador humano.

const ROW_H := 62.0
const ROW_W := 900.0
const BAR_MAX := 360.0
const BAR_X := 330.0
const REVEAL_DELAY := 1.3     # pausa antes de repartir los puntos
const AUTO_SECONDS := 7.0     # tiempo total antes de continuar solo
const SKIP_GRACE := 1.0

var _rows: Dictionary = {}     # player_id -> Control (fila)
var _bars: Dictionary = {}     # player_id -> Panel
var _totals: Dictionary = {}   # player_id -> Label
var _board: Control
var _elapsed: float = 0.0
var _done: bool = false
var _confetti: Confetti

func _ready() -> void:
	UIKit.setup_screen(self)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_top = 24
	root.offset_bottom = -24
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var meta := GameManager.current_minigame()
	root.add_child(UIKit.label("MARCADOR", &"HeaderLabel"))
	root.add_child(UIKit.label("%s · %d de %d" % [meta.display_name, GameManager.current_index + 1, GameManager.playlist.size()], &"HintLabel"))

	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(center)
	_board = Control.new()
	_board.custom_minimum_size = Vector2(ROW_W, ROW_H * Lobby.players.size())
	center.add_child(_board)

	var next := UIKit.button("¡SIGUIENTE!" if not GameManager.is_last_minigame() else "VER RESULTADO FINAL", &"PrimaryButton", Vector2(320, 0))
	next.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	next.pressed.connect(_continue)
	root.add_child(next)

	_confetti = Confetti.new()
	add_child(_confetti)

	_build_rows()
	_play_reveal()

# Orden de filas según unas puntuaciones dadas (empates: por ranura).
func _order_by(scores: Dictionary) -> Array[int]:
	var ids: Array[int] = []
	for p in Lobby.players:
		ids.append(p.id)
	ids.sort_custom(func(a: int, b: int) -> bool:
		var sa: int = scores.get(a, 0)
		var sb: int = scores.get(b, 0)
		return sa > sb if sa != sb else a < b)
	return ids

func _new_scores() -> Dictionary:
	var d := {}
	for p in Lobby.players:
		d[p.id] = p.score
	return d

func _build_rows() -> void:
	var max_total := 1
	for p in Lobby.players:
		max_total = maxi(max_total, p.score)
	var order := _order_by(GameManager.previous_scores)
	for pos in order.size():
		var p := Lobby.get_player(order[pos])
		var row := PanelContainer.new()
		row.theme_type_variation = &"ChipPanel"
		row.size = Vector2(ROW_W, ROW_H - 8.0)
		row.position = Vector2(0, pos * ROW_H)
		var inner := Control.new()
		inner.custom_minimum_size = Vector2(ROW_W - 40.0, ROW_H - 24.0)
		row.add_child(inner)

		var avatar := PlayerAvatar.new(44)
		avatar.set_player(p)
		avatar.position = Vector2(0, -2)
		inner.add_child(avatar)

		var name_label := UIKit.label(p.label(), &"", HORIZONTAL_ALIGNMENT_LEFT)
		name_label.position = Vector2(60, 0)
		name_label.size = Vector2(250, ROW_H - 24.0)
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.clip_text = true
		inner.add_child(name_label)

		var bar := Panel.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = p.color
		sb.set_corner_radius_all(14)
		bar.add_theme_stylebox_override("panel", sb)
		bar.position = Vector2(BAR_X, 6)
		var prev: int = GameManager.previous_scores.get(p.id, 0)
		bar.size = Vector2(maxf(18.0, BAR_MAX * prev / max_total), ROW_H - 36.0)
		inner.add_child(bar)

		var total := UIKit.label(str(prev), &"HeaderLabel", HORIZONTAL_ALIGNMENT_RIGHT)
		total.position = Vector2(ROW_W - 40.0 - 170.0, -6)
		total.size = Vector2(90, ROW_H - 16.0)
		total.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		inner.add_child(total)

		var gain := UIKit.label("+%d" % GameManager.last_points.get(p.id, 0), &"HeaderLabel")
		gain.add_theme_color_override("font_color", Palette.YELLOW)
		gain.position = Vector2(ROW_W - 40.0 - 70.0, -6)
		gain.size = Vector2(70, ROW_H - 16.0)
		gain.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		gain.modulate.a = 0.0
		gain.name = "Gain"
		inner.add_child(gain)

		_board.add_child(row)
		_rows[p.id] = row
		_bars[p.id] = bar
		_totals[p.id] = total

func _play_reveal() -> void:
	# 1) Entrada escalonada de filas.
	var i := 0
	for id in _order_by(GameManager.previous_scores):
		var row: Control = _rows[id]
		row.modulate.a = 0.0
		var t := create_tween()
		t.tween_property(row, "modulate:a", 1.0, 0.25).set_delay(0.05 * i)
		i += 1
	await get_tree().create_timer(0.6).timeout
	# 2) Aparecen los "+N".
	for id in _rows:
		var gain: Label = (_rows[id] as Control).find_child("Gain", true, false)
		gain.pivot_offset = gain.size * 0.5
		gain.scale = Vector2.ONE * 2.0
		var t := create_tween().set_parallel(true)
		t.tween_property(gain, "modulate:a", 1.0, 0.2)
		t.tween_property(gain, "scale", Vector2.ONE, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	await get_tree().create_timer(REVEAL_DELAY).timeout
	# 3) Se reparten los puntos: barras crecen, números suben, filas se reordenan.
	var new_scores := _new_scores()
	var max_total := 1
	for id in new_scores:
		max_total = maxi(max_total, new_scores[id])
	var new_order := _order_by(new_scores)
	for pos in new_order.size():
		var id := new_order[pos]
		var row: Control = _rows[id]
		var bar: Panel = _bars[id]
		var total: Label = _totals[id]
		var from: int = GameManager.previous_scores.get(id, 0)
		var to: int = new_scores[id]
		var t := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		t.tween_property(row, "position:y", pos * ROW_H, 0.8)
		t.tween_property(bar, "size:x", maxf(18.0, BAR_MAX * to / max_total), 0.8)
		t.tween_method(func(v: float) -> void: total.text = str(roundi(v)), float(from), float(to), 0.8)
		if to != from:
			UIKit.punch(total, 1.4)
	# Pequeño confeti para quien ganó el minijuego.
	if not GameManager.last_ranking.is_empty():
		_confetti.burst(Vector2(Palette.VIEWPORT_SIZE.x * 0.5, Palette.VIEWPORT_SIZE.y * 0.9), 40)

func _process(delta: float) -> void:
	if _done:
		return
	_elapsed += delta
	if _elapsed >= AUTO_SECONDS:
		_continue()
		return
	if _elapsed < SKIP_GRACE:
		return
	for p in Lobby.players:
		if not p.is_bot and not p.is_remote and InputManager.is_action_just_pressed(p.id):
			_continue()
			return

func _continue() -> void:
	if _done:
		return
	_done = true
	GameManager.continue_match()
