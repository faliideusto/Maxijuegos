extends SceneTree
## Herramienta de desarrollo: captura Puntería a mitad de partida (la juega la IA hasta el segundo indicado).
##   godot --path . --script res://tools/aim_shot.gd -- <salida.png> [segundos]
var _n: int = 0
var _mg: Node = null
var _out: String = "aim.png"
func _process(_d: float) -> bool:
	_n += 1
	if _n == 1:
		var a := OS.get_cmdline_user_args()
		_out = a[0] if a.size() > 0 else "aim.png"
		var secs := float(a[1]) if a.size() > 1 else 14.0
		var lobby = root.get_node("Lobby")
		var me = lobby.add_bot()
		lobby.add_bot()
		var meta = load("res://minigames/target_range/meta.tres")
		_mg = (meta.scene as PackedScene).instantiate()
		root.add_child(_mg)
		_mg.configure(1, 4242, me)
		_mg.prepare(lobby.players)
		_mg.start(lobby.players)
		_mg.debug_ai_skill = 0.7
		while _mg.debug_state()["time"] < secs:
			_mg.debug_advance(1.0 / 60.0)
			_mg._animate(1.0 / 60.0)
	elif _n == 6:
		root.get_viewport().get_texture().get_image().save_png(_out)
		quit()
	return false
