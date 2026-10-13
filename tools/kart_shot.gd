extends SceneTree
## Herramienta de desarrollo: captura Karts Arcoíris tras correr la IA unos segundos.
##   godot --path . --script res://tools/kart_shot.gd -- <salida.png> [segundos] [semilla] [personas en este PC (0-4)]
## Con personas > 0 se ve la pantalla partida (las conduce el autopiloto).
var _n: int = 0
var _mg: Node = null
var _out: String = "kart.png"
func _process(_d: float) -> bool:
	_n += 1
	if _n == 1:
		var a := OS.get_cmdline_user_args()
		_out = a[0] if a.size() > 0 else "kart.png"
		var secs := float(a[1]) if a.size() > 1 else 8.0
		var sd := int(a[2]) if a.size() > 2 else 4242
		var humans := int(a[3]) if a.size() > 3 else 0
		var lobby = root.get_node("Lobby")
		root.get_node("InputManager").autopilot = true
		var devices := ["kb1", "kb2", "joy:0", "joy:1"]
		var me = null
		for i in humans:
			var p = lobby.add_player(devices[i])
			if me == null:
				me = p
		while lobby.players.size() < 8:
			var b = lobby.add_bot()
			if me == null:
				me = b
		var meta = load("res://minigames/rainbow_kart/meta.tres")
		_mg = (meta.scene as PackedScene).instantiate()
		root.add_child(_mg)
		_mg.configure(0, sd, null if humans > 0 else me)
		_mg.prepare(lobby.players)
		_mg.start(lobby.players)
		var t := 0.0
		while t < secs:
			_mg._simulate(1.0 / 60.0)
			_mg._animate(1.0 / 60.0)
			t += 1.0 / 60.0
		_mg._hint_t = 0.0
	elif _n < 8:
		_mg._simulate(1.0 / 60.0)
	elif _n == 8:
		root.get_viewport().get_texture().get_image().save_png(_out)
		quit()
	return false
