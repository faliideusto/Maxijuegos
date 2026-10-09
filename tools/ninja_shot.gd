extends SceneTree
## Herramienta de desarrollo: captura Ninja Trepador tras jugar la IA unos segundos (con la trayectoria de puntos).
##   godot --path . --script res://tools/ninja_shot.gd -- <salida.png> [segundos]
var _n: int = 0
var _mg: Node = null
var _out: String = "ninja.png"
func _process(_d: float) -> bool:
	_n += 1
	if _n == 1:
		var a := OS.get_cmdline_user_args()
		_out = a[0] if a.size() > 0 else "ninja.png"
		var secs := float(a[1]) if a.size() > 1 else 10.0
		var lobby = root.get_node("Lobby")
		var me = lobby.add_bot()
		lobby.add_bot()
		var meta = load("res://minigames/ninja_climb/meta.tres")
		_mg = (meta.scene as PackedScene).instantiate()
		root.add_child(_mg)
		_mg.configure(1, 4242, me)
		_mg.prepare(lobby.players)
		_mg.start(lobby.players)
		var t := 0.0
		while t < secs and _mg.debug_state()["mode"] == 0 or t < secs and _mg.debug_state()["mode"] == 1:
			_mg._play(1.0 / 60.0)
			_mg._animate(1.0 / 60.0)
			t += 1.0 / 60.0
		# Se detiene en un momento de apuntado para que se vean los puntos.
		var guard := 0
		while _mg.debug_state()["mode"] != 0 and guard < 600:
			_mg._play(1.0 / 60.0)
			_mg._animate(1.0 / 60.0)
			guard += 1
		_mg._hint_t = 0.0
	elif _n == 6:
		root.get_viewport().get_texture().get_image().save_png(_out)
		quit()
	return false
