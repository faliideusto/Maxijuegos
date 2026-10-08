extends SceneTree
## Herramienta de desarrollo: captura Columpio de Lengua a una distancia dada (la rana la lleva el bot).
##   godot --path . --script res://tools/tongue_shot.gd -- <distancia> <salida.png>
var _n: int = 0
var _mg: Node = null
var _out: String = "tongue.png"
func _process(_d: float) -> bool:
	_n += 1
	if _n == 1:
		var a := OS.get_cmdline_user_args()
		var dist := float(a[0]) if a.size() > 0 else 100.0
		_out = a[1] if a.size() > 1 else "tongue.png"
		var meta = load("res://minigames/tongue_swing/meta.tres")
		_mg = (meta.scene as PackedScene).instantiate()
		root.add_child(_mg)
		var p := PlayerData.new()
		p.color_index = 3
		_mg.configure(1, 1, p)
		var ps: Array[PlayerData] = [p]
		_mg.prepare(ps)
		_mg.start(ps)
		var s = _mg._s
		var steps := 0
		while s.alive and s.pos.x < dist and steps < 20000:
			_mg._phys(s, _mg.STEP, _mg._bot_wants_hold(s))
			if s.broke >= 0:
				_mg._broken[s.broke] = true
			steps += 1
		_mg._prev_pos = s.pos
		_mg._cam = s.pos.x - _mg.CAM_LEAD
		_mg._time = steps * _mg.STEP
		_mg._touched = true
		_mg.is_running = false
	elif _n == 6:
		root.get_viewport().get_texture().get_image().save_png(_out)
		quit()
	return false
