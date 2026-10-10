extends SceneTree
## Herramienta de desarrollo: captura Puente Personal.
##   godot --path . --script res://tools/bridge_shot.gd -- <salida.png> [choose|cross|result|end] [jugadores]
var _n: int = 0
var _mg: Node = null
var _out: String = "bridge.png"
func _process(_d: float) -> bool:
	_n += 1
	if _n == 1:
		var a := OS.get_cmdline_user_args()
		_out = a[0] if a.size() > 0 else "bridge.png"
		var what: String = a[1] if a.size() > 1 else "choose"
		var lobby = root.get_node("Lobby")
		lobby.add_player("kb1")
		for i in (int(a[2]) if a.size() > 2 else 4) - 1:
			lobby.add_bot()
		var meta = load("res://minigames/personal_bridge/meta.tres")
		_mg = (meta.scene as PackedScene).instantiate()
		root.add_child(_mg)
		_mg.configure(0, 5, null)
		_mg.prepare(lobby.players)
		_mg.start(lobby.players)
		_mg.set_process(false)
		_mg._on_player_text(null, "b:%d" % _mg._prizes.find(3), true)
		_mg._my_pick = _mg._prizes.find(3)
		var until: float = {"choose": 5.0, "cross": 8.0 + 1.5, "result": 8.0 + 2.4, "end": 999.0}.get(what, 5.0)
		var t := 0.0
		while t < until and not (what == "end" and _mg._phase == 3 and _mg._t > 0.5):
			_mg._simulate(1.0 / 60.0)
			_mg._animate(1.0 / 60.0)
			t += 1.0 / 60.0
		_mg.surface.queue_redraw()
	elif _n == 8:
		root.get_viewport().get_texture().get_image().save_png(_out)
		quit()
	return false
