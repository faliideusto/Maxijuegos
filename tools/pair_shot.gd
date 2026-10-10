extends SceneTree
## Herramienta de desarrollo: captura Fuga en Pareja tras jugar la IA unos segundos.
##   godot --path . --script res://tools/pair_shot.gd -- <salida.png> [segundos] [jugadores] [humanos_locales]
## Con humanos_locales > 1 (modo local) se ve la pantalla partida por parejas.
var _n: int = 0
var _mg: Node = null
var _out: String = "pair.png"
func _process(_d: float) -> bool:
	_n += 1
	if _n == 1:
		var a := OS.get_cmdline_user_args()
		_out = a[0] if a.size() > 0 else "pair.png"
		var secs := float(a[1]) if a.size() > 1 else 8.0
		var count := int(a[2]) if a.size() > 2 else 4
		var humans := int(a[3]) if a.size() > 3 else 0
		var lobby = root.get_node("Lobby")
		var me = lobby.add_bot()
		for i in count - 1:
			lobby.add_bot()
		for i in humans:
			lobby.players[i].device = "kb%d" % (i + 1)
		var meta = load("res://minigames/pair_escape/meta.tres")
		_mg = (meta.scene as PackedScene).instantiate()
		_mg.meta = meta
		root.add_child(_mg)
		_mg.configure(0, 4242, null if humans > 0 else me)
		_mg.prepare(lobby.players)
		_mg.start(lobby.players)
		var t := 0.0
		while t < secs:
			_mg._simulate(1.0 / 60.0)
			_mg._animate(1.0 / 60.0)
			t += 1.0 / 60.0
		_mg._hint_t = 0.0
	elif _n == 8:
		root.get_viewport().get_texture().get_image().save_png(_out)
		quit()
	return false
