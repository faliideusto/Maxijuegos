extends SceneTree
## Herramienta de desarrollo: deja correr el juego REAL (los argumentos de DevCli van tras "--") y guarda una captura
## a los N segundos. Sirve para ver el aspecto en distintas proporciones de ventana (--resolution 1500x720).
##   godot --path . --resolution 1500x720 --script res://tools/flow_shot.gd -- <salida.png> <segundos> --local --bots=3 --games=1 --only=coin_grab
var _t: float = 0.0
var _out: String = "flow.png"
var _wait: float = 8.0
func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	_out = a[0] if a.size() > 0 else "flow.png"
	_wait = float(a[1]) if a.size() > 1 else 8.0
func _process(delta: float) -> bool:
	_t += delta
	if _t >= _wait:
		root.get_viewport().get_texture().get_image().save_png(_out)
		var cs := current_scene
		if cs != null:
			for c in cs.get_children():
				if c is Control:
					print("  hijo Control: ", c.get_class(), " pos=", (c as Control).global_position, " size=", (c as Control).size, " anchors=", (c as Control).anchor_left)
		print("captura guardada: ", _out, " tamaño ", root.get_viewport().get_visible_rect().size)
		quit()
		return true
	return false
