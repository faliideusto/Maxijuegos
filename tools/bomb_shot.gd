extends SceneTree
## Herramienta de desarrollo: captura Bomba de Palabras con un estado de ejemplo.
##   godot --path . --script res://tools/bomb_shot.gd -- <salida.png> [boom]
var _n: int = 0
var _mg: Node = null
var _out: String = "bomb.png"
func _process(_d: float) -> bool:
	_n += 1
	if _n == 1:
		var a := OS.get_cmdline_user_args()
		_out = a[0] if a.size() > 0 else "bomb.png"
		var meta = load("res://minigames/bomb_party/meta.tres")
		_mg = (meta.scene as PackedScene).instantiate()
		root.add_child(_mg)
		var plist: Array[PlayerData] = []
		for i in 6:
			var p := PlayerData.new()
			p.id = i
			p.display_name = ["Ana", "Luis", "Marta", "Pedro", "Sofía", "Raúl"][i]
			p.color_index = i
			plist.append(p)
		_mg.configure(0, 1, plist[0])
		_mg.prepare(plist)
		_mg.start(plist)
		_mg._turn = 2
		_mg._cur_id = 2
		_mg._syl = "cas"
		_mg._draft = "ESCAS"
		_mg._feed = [[0, "CASA"], [1, "CASCO"], [2, "ESCASO"], [3, "CASTILLO"]]
		_mg._counts = {0: 2, 1: 1, 2: 1, 3: 1, 4: 0, 5: 0}
		if a.size() > 1 and a[1] == "boom":
			_mg._explode()
			_mg._boom_age = 0.9
	elif _n == 14:
		if _mg._boom:
			_mg._flash = 0.0
		root.get_viewport().get_texture().get_image().save_png(_out)
		quit()
	return false
