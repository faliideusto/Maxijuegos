extends SceneTree
## Herramienta de desarrollo: captura Francotiradores tras jugar la IA unos segundos (cámara del primer jugador).
##   godot --path . --script res://tools/sniper_shot.gd -- <salida.png> [segundos] [semilla] [jugadores] [mira 0/1]
var _n: int = 0
var _mg: Node = null
var _out: String = "sniper.png"
func _process(_d: float) -> bool:
	_n += 1
	if _n == 1:
		var a := OS.get_cmdline_user_args()
		_out = a[0] if a.size() > 0 else "sniper.png"
		var secs := float(a[1]) if a.size() > 1 else 8.0
		var sd := int(a[2]) if a.size() > 2 else 4242
		var count := int(a[3]) if a.size() > 3 else 6
		var scope := a.size() > 4 and a[4] == "1"
		var lobby = root.get_node("Lobby")
		var me = lobby.add_bot()
		for i in count - 1:
			lobby.add_bot()
		var meta = load("res://minigames/sniper_town/meta.tres")
		_mg = (meta.scene as PackedScene).instantiate()
		root.add_child(_mg)
		_mg.configure(0, sd, me)
		_mg.prepare(lobby.players)
		_mg.start(lobby.players)
		var t := 0.0
		while t < secs + 3.0:
			_mg._simulate(1.0 / 60.0)
			_mg._animate(1.0 / 60.0)
			t += 1.0 / 60.0
		_mg._hint_t = 0.0
		if scope:
			_mg.is_running = false
			_mg._sp[me.id].scoped = true
			_mg._sp[me.id].alive = true
			for i in 30:
				_mg._animate(1.0 / 60.0)
	elif _n == 8:
		root.get_viewport().get_texture().get_image().save_png(_out)
		quit()
	return false
