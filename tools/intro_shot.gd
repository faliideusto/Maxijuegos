extends SceneTree
## Herramienta de desarrollo: captura la presentación de un minijuego con 2 personas en este PC (+1 bot).
##   godot --path . --script res://tools/intro_shot.gd -- <id_minijuego> <salida.png> [segundos]
var _n: int = 0
var _out: String = "intro.png"
var _wait: float = 3.0
var _t: float = 0.0
func _process(d: float) -> bool:
	_n += 1
	if _n == 1:
		var a := OS.get_cmdline_user_args()
		var id := StringName(a[0] if a.size() > 0 else "moon_hop")
		_out = a[1] if a.size() > 1 else "intro.png"
		_wait = float(a[2]) if a.size() > 2 else 3.0
		var lobby = root.get_node("Lobby")
		var h1 = lobby.add_player("kb1")
		var h2 = lobby.add_player("kb2")
		h1.display_name = "Ana"
		h2.display_name = "Luis"
		lobby.add_bot()
		var gm = root.get_node("GameManager")
		var meta: MinigameMeta = root.get_node("MinigameRegistry").get_by_id(id)
		var one: Array[MinigameMeta] = [meta]
		gm.playlist = one
		gm.current_index = 0
		gm._go(gm.State.INTRO)
	else:
		_t += d
		if _t >= _wait:
			root.get_viewport().get_texture().get_image().save_png(_out)
			quit()
	return false
