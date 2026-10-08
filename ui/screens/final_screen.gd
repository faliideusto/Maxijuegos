extends Control
## Pantalla final: ganador (o ganadores si hay empate) con corona y confeti, y clasificación.

var _confetti: Confetti

func _ready() -> void:
	UIKit.setup_screen(self)
	var standings := MatchRules.standings(Lobby.players)
	# Los jugadores desconectados salen en la clasificación pero no pueden ganar.
	var contenders: Array[PlayerData] = []
	for p in standings:
		if not p.disconnected:
			contenders.append(p)
	if contenders.is_empty():
		contenders = standings
	var top_score: int = contenders[0].score if not contenders.is_empty() else 0
	var winners: Array[PlayerData] = []
	for p in contenders:
		if p.score == top_score:
			winners.append(p)

	var box := UIKit.centered_vbox(self, 6)
	var title := UIKit.label("¡GANADOR!" if winners.size() == 1 else "¡EMPATE!", &"TitleLabel")
	title.add_theme_font_size_override("font_size", 72)
	box.add_child(title)

	# Avatares grandes con corona.
	var crown_row := HBoxContainer.new()
	crown_row.alignment = BoxContainer.ALIGNMENT_CENTER
	crown_row.add_theme_constant_override("separation", 24)
	var avatar_size := 120.0 if winners.size() <= 2 else 84.0
	for p in winners:
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 0)
		var gap := Control.new()  # hueco para la corona
		gap.custom_minimum_size = Vector2(0, 14)
		col.add_child(gap)
		var a := PlayerAvatar.new(avatar_size)
		a.set_player(p)
		a.crown = true
		a.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		col.add_child(a)
		col.add_child(UIKit.label(p.label(), &"HeaderLabel"))
		crown_row.add_child(col)
		get_tree().create_timer(0.6).timeout.connect(a.bounce)
		get_tree().create_timer(0.6).timeout.connect(func() -> void: Audio.sfx(&"pop", -3.0, 0.8))
	box.add_child(crown_row)

	# Clasificación: una columna hasta 4 jugadores, dos columnas si hay más.
	var card := PanelContainer.new()
	var grid := GridContainer.new()
	grid.columns = 1 if standings.size() <= 4 else 2
	grid.add_theme_constant_override("h_separation", 40)
	grid.add_theme_constant_override("v_separation", 2)
	card.add_child(grid)
	# Se rellena por columnas (1-4 a la izquierda, 5-8 a la derecha).
	var rows_per_col := ceili(standings.size() / float(grid.columns))
	for r in rows_per_col:
		for c in grid.columns:
			var idx := c * rows_per_col + r
			if idx < standings.size():
				grid.add_child(_standing_row(idx, standings[idx]))
			else:
				grid.add_child(Control.new())
	box.add_child(card)

	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 16)
	box.add_child(bar)
	var menu := UIKit.button("MENÚ", &"DangerButton", Vector2(180, 0))
	menu.pressed.connect(GameManager.go_to_menu)
	bar.add_child(menu)
	# Solo el host decide qué pasa después; los clientes esperan (o salen con MENÚ).
	if NetworkManager.is_host():
		var lobby := UIKit.button("VOLVER AL LOBBY", &"SecondaryButton", Vector2(0, 0))
		lobby.pressed.connect(GameManager.go_to_lobby)
		bar.add_child(lobby)
		var again := UIKit.button("REVANCHA", &"PrimaryButton", Vector2(220, 0))
		again.pressed.connect(GameManager.rematch)
		bar.add_child(again)
	else:
		bar.add_child(UIKit.label("Esperando al anfitrión…", &"HintLabel"))

	_confetti = Confetti.new()
	add_child(_confetti)
	_confetti.rain(6.0, 90.0)
	_confetti.burst(Vector2(Palette.VIEWPORT_SIZE.x * 0.5, Palette.VIEWPORT_SIZE.y * 0.5), 80)
	Audio.sfx(&"confetti")

	var i := 0
	for child in box.get_children():
		UIKit.pop_in(child as Control, 0.08 * i)
		i += 1

func _standing_row(index: int, p: PlayerData) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var pos := UIKit.label("%d." % (index + 1), &"", HORIZONTAL_ALIGNMENT_RIGHT)
	pos.custom_minimum_size = Vector2(40, 0)
	row.add_child(pos)
	var av := PlayerAvatar.new(34)
	av.set_player(p)
	row.add_child(av)
	var name_label := UIKit.label(p.label(), &"", HORIZONTAL_ALIGNMENT_LEFT)
	name_label.custom_minimum_size = Vector2(190, 0)
	row.add_child(name_label)
	var pts := UIKit.label("%d pts" % p.score, &"", HORIZONTAL_ALIGNMENT_RIGHT)
	pts.custom_minimum_size = Vector2(90, 0)
	row.add_child(pts)
	return row
