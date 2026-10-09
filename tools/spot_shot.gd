extends SceneTree
## Herramienta de desarrollo: captura Caza del Foco con un estado de ejemplo.
##   godot --path . --script res://tools/spot_shot.gd -- <salida.png> [lock|over]
var _n: int = 0
var _mg: Node = null
var _out: String = "spot.png"
func _process(_d: float) -> bool:
	_n += 1
	if _n == 1:
		var a := OS.get_cmdline_user_args()
		_out = a[0] if a.size() > 0 else "spot.png"
		var lobby = root.get_node("Lobby")
		for i in 6:
			lobby.add_bot()
		var meta = load("res://minigames/spotlight/meta.tres")
		_mg = (meta.scene as PackedScene).instantiate()
		root.add_child(_mg)
		_mg.configure(0, 1, lobby.players[0])
		_mg.prepare(lobby.players)
		_mg.start(lobby.players)
		for i in 60 * 3:
			_mg._simulate(1.0 / 60.0)
		if a.size() > 1 and a[1] == "lock":
			_mg._time_left = 0.0
			_mg._simulate(1.0 / 60.0)
			for i in 20:
				_mg._simulate(1.0 / 60.0)
		_mg._animate(0.5)
	elif _n == 12:
		root.get_viewport().get_texture().get_image().save_png(_out)
		quit()
	return false
