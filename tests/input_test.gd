extends SceneTree
## Prueba de entrada: comprueba que los jugadores locales (kb1, kb2, "local" online) leen el
## teclado a través del InputMap, y que la entrada remota/bot funciona sin dispositivo.
## Ejecutar:  godot --headless --path . --script res://tests/input_test.gd

var _failures: Array[String] = []
var _step: int = 0
var _im: Node
var _p_kb1 := PlayerData.new()
var _p_kb2 := PlayerData.new()
var _p_local := PlayerData.new()
var _p_remote := PlayerData.new()

func _process(_delta: float) -> bool:
	_im = root.get_node("InputManager")
	match _step:
		0:
			_p_kb1.id = 0
			_p_kb1.device = PlayerData.DEVICE_KB1
			_p_kb2.id = 1
			_p_kb2.device = PlayerData.DEVICE_KB2
			_p_local.id = 2
			_p_local.device = PlayerData.DEVICE_LOCAL
			_p_remote.id = 3
			_p_remote.device = PlayerData.DEVICE_REMOTE
			for p in [_p_kb1, _p_kb2, _p_local, _p_remote]:
				_im.register_player(p)
			_press(KEY_D, true)       # kb1: derecha
			_press(KEY_UP, true)      # kb2: arriba
			# El jugador "local" acepta WASD y flechas a la vez: D + flecha arriba = diagonal.
			_press(KEY_SPACE, true)   # kb1 acción y local acción
			_im.set_remote_input(3, Vector2(0.5, -2.0), 3)   # remoto: mover + 3 pulsaciones
		1:
			_check(_im.get_vector(0).is_equal_approx(Vector2.RIGHT), "kb1: D = derecha (%s)" % _im.get_vector(0))
			_check(_im.get_vector(1).is_equal_approx(Vector2.UP), "kb2: flecha arriba = arriba (%s)" % _im.get_vector(1))
			_check(_im.get_vector(2).is_equal_approx(Vector2(1, -1).normalized()), "local: D + flecha arriba = diagonal (%s)" % _im.get_vector(2))
			_check(_im.action_presses(0) == 1, "kb1: Espacio = 1 pulsación")
			_check(_im.action_presses(1) == 0, "kb2: Espacio NO activa al teclado 2")
			_check(_im.action_presses(2) == 1, "local: Espacio = 1 pulsación")
			_check(_im.get_vector(3).length() <= 1.0001 and _im.get_vector(3).x > 0.0, "remoto: vector saneado a longitud <= 1 (%s)" % _im.get_vector(3))
			_check(_im.action_presses(3) == 3, "remoto: 3 pulsaciones acumuladas (%d)" % _im.action_presses(3))
			_release_all()
		2:
			_check(_im.get_vector(0) == Vector2.ZERO, "kb1: sin teclas = sin movimiento")
			_check(_im.action_presses(3) == 0, "remoto: las pulsaciones no se repiten en el frame siguiente")
			# Contador antiguo / duplicado: no debe generar pulsaciones nuevas.
			_im.set_remote_input(3, Vector2.ZERO, 2)
		3:
			_check(_im.action_presses(3) == 0, "remoto: un contador menor se ignora")
			_im.set_remote_input(3, Vector2.ZERO, 5)
		4:
			_check(_im.action_presses(3) == 2, "remoto: contador 3→5 = 2 pulsaciones (%d)" % _im.action_presses(3))
			# Abuso: salto enorme del contador. Se limita por frame.
			_im.set_remote_input(3, Vector2.ZERO, 5 + 100000)
		5:
			_check(_im.action_presses(3) <= _im.MAX_REMOTE_PRESSES_PER_FRAME, "remoto: tope de pulsaciones por frame (%d)" % _im.action_presses(3))
		6:
			print("")
			if _failures.is_empty():
				print("INPUT TEST OK")
				quit(0)
			else:
				print("INPUT TEST FALLÓ")
				quit(1)
			return true
	_step += 1
	return false

func _press(key: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = key
	ev.pressed = pressed
	Input.parse_input_event(ev)

func _release_all() -> void:
	for k in [KEY_D, KEY_UP, KEY_SPACE]:
		_press(k, false)

func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		_failures.append(what)
		print("  ✗ " + what)
