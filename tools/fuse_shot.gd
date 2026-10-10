extends SceneTree
## Herramienta de desarrollo: captura Mecha Corta.
##   godot --path . --script res://tools/fuse_shot.gd -- <salida.png> [segundos] [jugadores] [semilla]
var _n: int = 0
var _mg: Node = null
var _out: String = "fuse.png"
func _process(_d: float) -> bool:
	_n += 1
	if _n == 1:
		var a := OS.get_cmdline_user_args()
		_out = a[0] if a.size() > 0 else "fuse.png"
		var until: float = float(a[1]) if a.size() > 1 else 12.0
		var lobby = root.get_node("Lobby")
		for i in (int(a[2]) if a.size() > 2 else 4):
			lobby.add_bot()
		var meta = load("res://minigames/short_fuse/meta.tres")
		_mg = (meta.scene as PackedScene).instantiate()
		root.add_child(_mg)
		_mg.configure(0, int(a[3]) if a.size() > 3 else 3, lobby.players[0])
		_mg.prepare(lobby.players)
		_mg.start(lobby.players)
		_mg.set_process(false)
		var steps := 0
		while steps < 60 * 200 and _mg._clock < until and not (_mg._over and _mg._over_t > 0.6):
			_mg._simulate(1.0 / 60.0)
			_mg._animate(1.0 / 60.0)
			steps += 1
		_mg.surface.queue_redraw()
	elif _n == 8:
		root.get_viewport().get_texture().get_image().save_png(_out)
		quit()
	return false
