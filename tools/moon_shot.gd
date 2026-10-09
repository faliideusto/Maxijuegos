extends SceneTree
## Herramienta de desarrollo: captura Salto Lunar tras jugar la IA unos segundos.
##   godot --path . --script res://tools/moon_shot.gd -- <salida.png> [segundos]
var _n: int = 0
var _mg: Node = null
var _out: String = "moon.png"
func _process(_d: float) -> bool:
	_n += 1
	if _n == 1:
		var a := OS.get_cmdline_user_args()
		_out = a[0] if a.size() > 0 else "moon.png"
		var secs := float(a[1]) if a.size() > 1 else 6.0
		var lobby = root.get_node("Lobby")
		var me = lobby.add_bot()
		lobby.add_bot()
		var meta = load("res://minigames/moon_hop/meta.tres")
		_mg = (meta.scene as PackedScene).instantiate()
		root.add_child(_mg)
		_mg.configure(1, 1234, me)
		_mg.prepare(lobby.players)
		_mg.start(lobby.players)
		var t := 0.0
		while t < secs:
			_mg._play(1.0 / 60.0)
			_mg._animate(1.0 / 60.0)
			t += 1.0 / 60.0
	elif _n == 6:
		root.get_viewport().get_texture().get_image().save_png(_out)
		quit()
	return false
