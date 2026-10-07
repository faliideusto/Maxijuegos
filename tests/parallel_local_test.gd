extends SceneTree
## Prueba del modelo LOCAL_PARALLEL en modo local (sin red): un humano (teclado 1) y un bot.
## El humano "juega" Reflejos pulsando Espacio de verdad (a través del InputMap) ~250 ms
## después de que la pantalla se ponga verde. Comprueba que su resultado se acepta (no queda
## como "no terminado") y que se llega al marcador.
## Ejecutar:  godot --headless --path . --script res://tests/parallel_local_test.gd -- --log

const TIMEOUT_REAL_SECONDS := 90.0

var _began: bool = false
var _t: float = 0.0
var _last_go_ms: int = -1
var _pressed_for_go: bool = false
var _release_at: float = -1.0

func _process(delta: float) -> bool:
	var gm := root.get_node("GameManager")
	var lobby := root.get_node("Lobby")
	var registry := root.get_node("MinigameRegistry")
	if not _began:
		_began = true
		Engine.time_scale = 3.0
		lobby.add_player(PlayerData.DEVICE_KB1)
		lobby.add_bot()
		var meta: MinigameMeta = registry.get_by_id(&"reaction_test")
		var list: Array[MinigameMeta] = [meta]
		gm.playlist = list
		gm.current_index = 0
		gm.run_minigame()
		return false
	_t += delta / Engine.time_scale
	if _t > TIMEOUT_REAL_SECONDS:
		print("PARALLEL LOCAL TEST FALLÓ: timeout (estado %s)" % gm.State.keys()[gm.state])
		quit(1)
		return true
	if gm.state == gm.State.SCOREBOARD:
		var ok: bool = gm.last_ranking.size() == 2
		print("  ranking final: ", gm.last_ranking)
		print("PARALLEL LOCAL TEST %s" % ("OK" if ok else "FALLÓ"))
		quit(0 if ok else 1)
		return true
	# Pulsa Espacio unos 250 ms después de que aparezca el verde; suelta la tecla poco después.
	var scene := current_scene
	var mg: Variant = scene.get("_minigame") if scene != null else null
	if mg != null and mg.get("_phase") == 1:   # Phase.GO
		var go_ms: int = mg.get("_go_ms")
		if go_ms != _last_go_ms:
			_last_go_ms = go_ms
			_pressed_for_go = false
		if not _pressed_for_go and Time.get_ticks_msec() - go_ms >= 250:
			_pressed_for_go = true
			_key(true)
			_release_at = _t + 0.05
	if _release_at > 0.0 and _t >= _release_at:
		_release_at = -1.0
		_key(false)
	return false

func _key(pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_SPACE
	ev.pressed = pressed
	Input.parse_input_event(ev)
