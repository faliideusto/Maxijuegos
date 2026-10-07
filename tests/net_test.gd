extends SceneTree
## Prueba de red (ENet en local): lanzar DOS procesos.
##   godot --headless --path . --script res://tests/net_test.gd -- host
##   godot --headless --path . --script res://tests/net_test.gd -- client
## El cliente se une, el host lo ve en su lista y el cliente recibe la lista completa.
## Cada proceso imprime "NET OK" y sale con 0, o falla (1) tras 20 s.

var _role: String = "host"
var _gm: Node
var _t: float = 0.0
var _began: bool = false
var _linger: float = -1.0

func _process(delta: float) -> bool:
	if not _began:
		_began = true
		var a := OS.get_cmdline_user_args()
		_role = a[0] if a.size() > 0 else "host"
		_gm = root.get_node("GameManager")
		if _role == "host":
			print("host: crear sala → ", error_string(_gm.host_online()))
			_gm.add_player()
		else:
			print("cliente: unirse → ", error_string(_gm.join_online("127.0.0.1")))
		return false
	_t += delta
	if _t > 20.0:
		print("NET FALLÓ (timeout) rol=", _role, " jugadores=", _gm.players.size())
		quit(1)
		return true
	var ok: bool = _gm.players.size() >= 2
	if ok and _linger < 0.0:
		print("%s: lista con %d jugadores: %s" % [_role, _gm.players.size(), _gm.players.map(func(p: PlayerData) -> String: return "%s(%s)" % [p.display_name, p.device])])
		_linger = 1.5   # margen para que el otro extremo también reciba su lista
	if _linger >= 0.0:
		_linger -= delta
		if _linger < 0.0:
			print("NET OK (%s)" % _role)
			quit(0)
			return true
	return false
