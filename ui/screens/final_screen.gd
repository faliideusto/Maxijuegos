extends Control
## Pantalla final: ganador (o ganadores si hay empate) con corona y confeti, y clasificación.

var _confetti: Confetti

func _ready() -> void:
	UIKit.setup_screen(self)
	var standings := MatchRules.standings(GameManager.players)
	var top_score: int = standings[0].score if not standings.is_empty() else 0
	var winners: Array[PlayerData] = []
	for p in standings:
		if p.score == top_score:
			winners.append(p)

	var box := UIKit.centered_vbox(self, 12)
	box.add_child(UIKit.label("¡GANADOR!" if winners.size() == 1 else "¡EMPATE!", &"TitleLabel"))

	# Avatares grandes con corona.
	var crown_row := HBoxContainer.new()
	crown_row.alignment = BoxContainer.ALIGNMENT_CENTER
	crown_row.add_theme_constant_override("separation", 24)
	for p in winners:
		var col := VBoxContainer.new()
		col.alignment = BoxContainer.ALIGNMENT_CENTER
		var a := PlayerAvatar.new(150)
		a.set_player(p)
		a.crown = true
		a.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		col.add_child(Control.new())  # hueco para la corona
		(col.get_child(0) as Control).custom_minimum_size = Vector2(0, 40)
		col.add_child(a)
		col.add_child(UIKit.label(p.display_name, &"HeaderLabel"))
		crown_row.add_child(col)
		get_tree().create_timer(0.5).timeout.connect(a.bounce)
	box.add_child(crown_row)

	# Clasificación compacta.
	var card := PanelContainer.new()
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 4)
	card.add_child(list)
	for i in standings.size():
		var p := standings[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		var pos := UIKit.label("%d." % (i + 1), &"", HORIZONTAL_ALIGNMENT_RIGHT)
		pos.custom_minimum_size = Vector2(44, 0)
		row.add_child(pos)
		var av := PlayerAvatar.new(36)
		av.set_player(p)
		row.add_child(av)
		var name_label := UIKit.label(p.display_name, &"", HORIZONTAL_ALIGNMENT_LEFT)
		name_label.custom_minimum_size = Vector2(260, 0)
		row.add_child(name_label)
		var pts := UIKit.label("%d pts" % p.score, &"", HORIZONTAL_ALIGNMENT_RIGHT)
		pts.custom_minimum_size = Vector2(120, 0)
		row.add_child(pts)
		list.add_child(row)
	box.add_child(card)

	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 16)
	box.add_child(bar)
	var menu := UIKit.button("MENÚ", &"DangerButton", Vector2(200, 0))
	menu.pressed.connect(GameManager.go_to_menu)
	bar.add_child(menu)
	var lobby := UIKit.button("CAMBIAR JUGADORES", &"SecondaryButton", Vector2(0, 0))
	lobby.pressed.connect(GameManager.go_to_lobby)
	bar.add_child(lobby)
	var again := UIKit.button("REVANCHA", &"PrimaryButton", Vector2(240, 0))
	again.pressed.connect(GameManager.rematch)
	bar.add_child(again)

	_confetti = Confetti.new()
	add_child(_confetti)
	_confetti.rain(6.0, 90.0)
	_confetti.burst(Vector2(Palette.VIEWPORT_SIZE.x * 0.5, Palette.VIEWPORT_SIZE.y * 0.5), 80)

	var i := 0
	for child in box.get_children():
		UIKit.pop_in(child as Control, 0.08 * i)
		i += 1
