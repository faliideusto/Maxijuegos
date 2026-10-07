extends SceneTree
## Herramienta de desarrollo: abre una pantalla del juego y guarda una captura PNG.
## Uso (con ventana, NO headless):
##   godot --path . --script res://tools/screenshot.gd -- <escenario> <segundos> <salida.png> [jugadores]
## Escenarios: menu, lobby, setup, intro, scoreboard, final, mg:<id_minijuego>

var _scenario: String = "menu"
var _wait: float = 1.0
var _out: String = "screenshot.png"
var _players: int = 4
var _t: float = 0.0
var _began: bool = false

func _process(delta: float) -> bool:
	if not _began:
		_began = true
		var a := OS.get_cmdline_user_args()
		if a.size() > 0: _scenario = a[0]
		if a.size() > 1: _wait = float(a[1])
		if a.size() > 2: _out = a[2]
		if a.size() > 3: _players = int(a[3])
		_setup()
		return false
	_t += delta
	if _t >= _wait:
		var img := root.get_viewport().get_texture().get_image()
		img.save_png(_out)
		print("captura guardada: ", _out)
		quit()
		return true
	return false

func _setup() -> void:
	var gm := root.get_node("GameManager")
	var reg := root.get_node("MinigameRegistry")
	if _scenario == "menu":
		root.get_node("GameManager").go_to_menu()
		return
	for i in _players:
		gm.add_bot()
	# Nombres/puntuaciones de ejemplo para que los marcadores se vean reales.
	var names := ["Ana", "Luis", "Marta", "Pepe", "Sofía", "Iván", "Carla", "Nico"]
	for p: PlayerData in gm.players:
		p.display_name = names[p.id % names.size()]
	match _scenario:
		"lobby":
			gm.go_to_lobby()
		"setup":
			gm.go_to_setup()
		"intro", "scoreboard", "final":
			gm.playlist = reg.pick_random(5, _players)
			gm.current_index = 1
			if _scenario == "intro":
				gm._go(gm.State.INTRO)
			elif _scenario == "scoreboard":
				for p: PlayerData in gm.players:
					p.score = (p.id * 3 + 2) % 9
				var ids: Array[int] = []
				for p: PlayerData in gm.players:
					ids.append(p.id)
				ids.reverse()
				gm.report_results(ids)
			else:
				for p: PlayerData in gm.players:
					p.score = (p.id * 7 + 3) % 17
				gm._go(gm.State.FINAL)
		_:
			if _scenario.begins_with("mg:"):
				var meta: MinigameMeta = reg.get_by_id(StringName(_scenario.substr(3)))
				var single: Array[MinigameMeta] = [meta]
				gm.playlist = single
				gm.current_index = 0
				gm.run_minigame()
