extends SceneTree
## Herramienta de desarrollo: captura Crono a Ciegas.
##   godot --path . --script res://tools/timer_shot.gd -- <salida.png> [announce|run|hidden|reveal] [jugadores]
var _n: int = 0
var _mg: Node = null
var _out: String = "timer.png"
func _process(_d: float) -> bool:
	_n += 1
	if _n == 1:
		var a := OS.get_cmdline_user_args()
		_out = a[0] if a.size() > 0 else "timer.png"
		var what: String = a[1] if a.size() > 1 else "run"
		var lobby = root.get_node("Lobby")
		for i in (int(a[2]) if a.size() > 2 else 6):
			lobby.add_bot()
		var meta = load("res://minigames/blind_timer/meta.tres")
		_mg = (meta.scene as PackedScene).instantiate()
		root.add_child(_mg)
		_mg.configure(0, 3, lobby.players[0])
		_mg.prepare(lobby.players)
		_mg.start(lobby.players)
		_mg.set_process(false)
		var until: float = 2.4
		if what == "hidden":
			until = _mg._target - 0.3
		var steps := 0
		while steps < 60 * 60:
			if what == "announce":
				if _mg._announce_t <= 1.3:
					break
			elif what == "reveal":
				if _mg.revealed_count() >= lobby.players.size():
					break
			elif _mg._elapsed >= until:
				break
			_mg._simulate(1.0 / 60.0)
			_mg._animate(1.0 / 60.0)
			steps += 1
		_mg.surface.queue_redraw()
	elif _n == 8:
		root.get_viewport().get_texture().get_image().save_png(_out)
		quit()
	return false
