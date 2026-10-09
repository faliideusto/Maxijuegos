extends SceneTree
## Herramienta de desarrollo: captura Tronco de Dagas con algunas dagas ya clavadas.
##   godot --path . --script res://tools/knife_shot.gd -- <salida.png> [clang|over]
var _n: int = 0
var _mg: Node = null
var _out: String = "knife.png"
func _process(_d: float) -> bool:
	_n += 1
	if _n == 1:
		var a := OS.get_cmdline_user_args()
		_out = a[0] if a.size() > 0 else "knife.png"
		var lobby = root.get_node("Lobby")
		for i in 6:
			lobby.add_bot()
		var meta = load("res://minigames/knife_log/meta.tres")
		_mg = (meta.scene as PackedScene).instantiate()
		root.add_child(_mg)
		_mg.configure(0, 1, lobby.players[0])
		_mg.prepare(lobby.players)
		_mg.start(lobby.players)
		var steps := 0
		while _mg._count < 7 and steps < 60 * 120:
			_mg._simulate(1.0 / 60.0)
			_mg._animate(1.0 / 60.0)
			steps += 1
		if a.size() > 1 and a[1] == "clang":
			while _mg._elim_order.is_empty() and steps < 60 * 300:
				_mg._simulate(1.0 / 60.0)
				_mg._animate(1.0 / 60.0)
				steps += 1
			for i in 14:
				_mg._simulate(1.0 / 60.0)
				_mg._animate(1.0 / 60.0)
	elif _n == 8:
		root.get_viewport().get_texture().get_image().save_png(_out)
		quit()
	return false
