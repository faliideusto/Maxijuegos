extends SceneTree
## Modo local por turnos con un jugador de teclado que nadie maneja (p. ej. un "Bot" pasado a Teclado 2 con CAMBIAR):
## su turno no debe quedarse esperando al tiempo máximo; a los pocos segundos sin pulsaciones lo juega la IA.
## Comprueba también que al cambiar un bot a teclado su nombre por defecto pasa de "Bot N" a "Jugador N".
## Ejecutar:  godot --headless --path . --script res://tests/idle_turn_test.gd

const TIMEOUT_REAL_SECONDS := 40.0

var _began: bool = false
var _t: float = 0.0
var _failures: Array[String] = []

func _process(delta: float) -> bool:
	var gm := root.get_node("GameManager")
	var lobby := root.get_node("Lobby")
	var im := root.get_node("InputManager")
	if not _began:
		_began = true
		Engine.time_scale = 3.0
		lobby.add_player(PlayerData.DEVICE_KB1)
		var b: PlayerData = lobby.add_bot()
		lobby.add_bot()
		_check(b.display_name == "Bot 2" and im.is_simulated(b.id), "el bot se crea como bot")
		lobby.cycle_device(b)
		_check(b.device == PlayerData.DEVICE_KB2 and b.display_name == "Jugador 2" and not im.is_simulated(b.id),
				"bot → teclado 2 se renombra a Jugador 2 (%s, %s)" % [b.device, b.display_name])
		lobby.cycle_device(b)
		_check(b.is_bot and b.display_name == "Bot 2", "teclado 2 → bot vuelve a Bot 2")
		lobby.cycle_device(b)
		var meta: MinigameMeta = root.get_node("MinigameRegistry").get_by_id(&"reaction_test")
		var list: Array[MinigameMeta] = [meta]
		gm.playlist = list
		gm.current_index = 0
		gm.run_minigame()
		return false
	_t += delta / Engine.time_scale
	if _t > TIMEOUT_REAL_SECONDS:
		_check(false, "los turnos sin nadie terminan antes del tiempo máximo (estado %s)" % gm.State.keys()[gm.state])
		return _finish()
	if gm.state == gm.State.SCOREBOARD:
		_check(gm.last_ranking.size() == 3, "ranking con los 3 jugadores: %s" % [gm.last_ranking])
		return _finish()
	return false

func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)
		print("  FALLO: ", what)

func _finish() -> bool:
	print("IDLE TURN TEST %s" % ("OK" if _failures.is_empty() else "FALLÓ"))
	quit(0 if _failures.is_empty() else 1)
	return true
