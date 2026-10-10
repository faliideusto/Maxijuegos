extends SceneTree
## Herramienta de desarrollo: captura Impostor a Bordo tras jugar la IA unos segundos (vista del primer jugador).
##   godot --path . --script res://tools/impostor_shot.gd -- <salida.png> [segundos] [jugadores] [escena] [semilla]
## Escenas: play (por defecto), intro, task, body, splash, vote, reveal, eject, end, impostor
var _n: int = 0
var _mg: Node = null
var _out: String = "impostor.png"
func _process(_d: float) -> bool:
	_n += 1
	if _n == 1:
		var a := OS.get_cmdline_user_args()
		_out = a[0] if a.size() > 0 else "impostor.png"
		var secs := float(a[1]) if a.size() > 1 else 6.0
		var count := int(a[2]) if a.size() > 2 else 6
		var scene := a[3] if a.size() > 3 else "play"
		var seed_value := int(a[4]) if a.size() > 4 else 4242
		var lobby = root.get_node("Lobby")
		var names := ["Ana", "Luis", "Marta", "Pepe", "Sofía", "Iván", "Carla", "Nico"]
		var me = lobby.add_bot()
		for i in count - 1:
			lobby.add_bot()
		for p in lobby.players:
			p.display_name = names[p.id % names.size()]
		var meta = load("res://minigames/impostor/meta.tres")
		_mg = (meta.scene as PackedScene).instantiate()
		_mg.debug_force_impostors = [me.id] if scene == "impostor" else [lobby.players[1].id]
		root.add_child(_mg)
		_mg.set_process(false)
		_mg.configure(0, seed_value, me)
		_mg.prepare(lobby.players)
		_mg.start(lobby.players)
		var ph = _mg.Phase
		var ids: Array = []
		for p in lobby.players:
			ids.append(p.id)
		if scene == "intro":
			_step(1.2)
		else:
			_mg.debug_skip_intro()
			_step(secs)
		match scene:
			"task":
				var st: int = _mg.debug_player(me.id).tasks[0]
				_mg.debug_place(me.id, _mg.debug_station_pos(st), atan2(-float(_mg.STATIONS[st]["dir"].x), -float(_mg.STATIONS[st]["dir"].y)))
				_mg.debug_use(me.id)
				_mg.debug_task_hit(me.id, true)
				_mg._ps[me.id].task_t = 0.4
			"body", "splash", "vote", "reveal", "eject":
				var spot: Vector2 = _mg.debug_station_pos(9) + Vector2(-2.0, 0.0)
				_mg.debug_place(ids[2], spot)
				_mg.debug_place(ids[1], spot + Vector2(0.0, 1.0), 0.0)
				_mg.debug_set_cd(ids[1], 0.0)
				_mg.debug_secondary(ids[1])
				_mg.debug_place(ids[1], spot + Vector2(-3.0, 3.0), 0.0)
				_mg.debug_place(me.id, spot + Vector2(1.6, 1.8), 0.75)
				if scene != "body":
					_mg.debug_use(me.id)
					if scene != "splash":
						_until(ph.VOTE)
						_mg._ps[me.id].cursor = 1
						if scene == "vote":
							_mg.debug_cast(ids[3], ids[1])
							_mg.debug_cast(ids[4], -1)
						else:
							for id in ids:
								_mg.debug_cast(id, ids[1] if id != ids[1] else -1)
							_until(ph.REVEAL)
							_step(1.0)
							if scene == "eject":
								_until(ph.EJECT)
								_step(2.4)
			"end":
				_mg._time_left = 0.1
				_until(ph.END)
				_step(1.5)
			"impostor":
				_mg.debug_set_cd(me.id, 0.0)
				_mg.debug_place(me.id, _mg.debug_station_pos(4) + Vector2(-1.0, 1.6), 0.4)
				_mg.debug_place(ids[2], _mg.debug_station_pos(4), 0.0)
		for i in 20:
			_mg._animate(1.0 / 60.0)
	elif _n == 8:
		root.get_viewport().get_texture().get_image().save_png(_out)
		quit()
	else:
		_mg._animate(1.0 / 60.0)
	return false

func _step(secs: float) -> void:
	var t := 0.0
	while t < secs:
		_mg._simulate(1.0 / 60.0)
		_mg._animate(1.0 / 60.0)
		t += 1.0 / 60.0

func _until(phase: int) -> void:
	var guard := 0
	while _mg.debug_phase() != phase and guard < 6000:
		_mg._simulate(1.0 / 60.0)
		guard += 1
