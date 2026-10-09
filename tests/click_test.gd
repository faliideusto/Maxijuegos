extends SceneTree
## El clic izquierdo cuenta como botón de acción (teclado 1 / online), igual que el espacio.
var _f := 0
func _process(_d: float) -> bool:
	var im = root.get_node("InputManager")
	var lobby = root.get_node("Lobby")
	if _f == 0:
		for p in lobby.players.duplicate():
			lobby.remove_player(p.id)
		lobby.add_player("kb1")
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = true
		Input.parse_input_event(ev)
	elif _f == 2:
		var id: int = lobby.players[0].id
		print("CLICK TEST ", "OK" if im.action_presses(id) > 0 or Input.is_action_pressed("p%d_action" % id) else "FALLÓ")
		quit(0)
	_f += 1
	return false
