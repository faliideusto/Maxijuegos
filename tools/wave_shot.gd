extends SceneTree
## Herramienta de desarrollo: captura Onda Neón a una distancia dada.
##   godot --path . --script res://tools/wave_shot.gd -- <distancia> <salida.png>
var _n: int = 0
var _mg: Node = null
var _out: String = "wave.png"
func _process(_d: float) -> bool:
	_n += 1
	if _n == 1:
		var a := OS.get_cmdline_user_args()
		var dist := float(a[0]) if a.size() > 0 else 300.0
		_out = a[1] if a.size() > 1 else "wave.png"
		var meta = load("res://minigames/wave_dash/meta.tres")
		_mg = (meta.scene as PackedScene).instantiate()
		root.add_child(_mg)
		var p := PlayerData.new()
		p.color_index = 2
		_mg.configure(1, 1, p)
		var ps: Array[PlayerData] = [p]
		_mg.prepare(ps)
		_mg.start(ps)
		var s = _mg._s
		while s.alive and s.x < dist:
			_mg._step_state(s, _mg.STEP, _mg._bot_wants_up(s))
		_mg._time = dist / 11.0
	elif _n == 8:
		root.get_viewport().get_texture().get_image().save_png(_out)
		quit()
	return false
