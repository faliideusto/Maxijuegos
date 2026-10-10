extends SceneTree
## Prueba de humo: comprueba el registro y simula partidas completas con bots.
## Ejecutar:  godot --headless --path . --script res://tests/smoke_test.gd -- [jugadores] [minijuegos]
## Sale con código 0 si todo va bien, 1 si algo falla.

const TIME_SCALE := 12.0
const TIMEOUT_REAL_SECONDS := 90.0

var _gm: Node
var _registry: Node
var _lobby: Node
var _expected_games: int = 3
var _expected_players: int = 4
var _visited: Dictionary = {}     # nombre de estado -> veces
var _awarded: int = 0
var _failures: Array[String] = []
var _started_at: int = 0
var _finished: bool = false
var _began: bool = false

func _start() -> void:
	_gm = root.get_node("GameManager")
	_registry = root.get_node("MinigameRegistry")
	_lobby = root.get_node("Lobby")
	var args := OS.get_cmdline_user_args()
	if args.size() > 0: _expected_players = int(args[0])
	if args.size() > 1: _expected_games = int(args[1])

	_test_registry()

	Engine.time_scale = TIME_SCALE
	for i in _expected_players:
		_lobby.add_bot()
	_gm.set_minigame_count(_expected_games)
	_check(_gm.start_blocker() == "", "start_blocker vacío con %d bots (%s)" % [_expected_players, _gm.start_blocker()])
	_gm.state_changed.connect(_on_state_changed)
	_started_at = Time.get_ticks_msec()
	_gm.start_match()

func _test_registry() -> void:
	var all: Array = _registry.get_all()
	_check(all.size() >= 3, "el registro descubre al menos 3 minijuegos (hay %d)" % all.size())
	for m: MinigameMeta in all:
		print("  minijuego: %s [%s] %d-%d jugadores" % [m.display_name, m.id, m.min_players, m.max_players])
	# Selección: sin repetir mientras haya disponibles y sin dos iguales seguidos.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var pick: Array = _registry.pick_random(all.size(), 4, rng)
	var ids := {}
	for m: MinigameMeta in pick:
		ids[m.id] = true
	_check(pick.size() == all.size() and ids.size() == all.size(), "pick_random sin repeticiones")
	var many: Array = _registry.pick_random(10, 4, rng)
	_check(many.size() == 10, "pick_random devuelve 10 aunque haya menos distintos")
	for i in range(1, many.size()):
		_check(many[i] != many[i - 1], "sin repetidos consecutivos (pos %d)" % i)
	_check(_registry.pick_random(3, 99, rng).is_empty(), "sin minijuegos para 99 jugadores")
	# Puntos.
	_check(MatchRules.points_for_rank(0, 4) == 4 and MatchRules.points_for_rank(3, 4) == 1, "tabla de puntos")

func _on_state_changed(new_state: int) -> void:
	var name_: String = _gm.State.keys()[new_state]
	_visited[name_] = _visited.get(name_, 0) + 1
	if name_ == "SCOREBOARD":
		for v in _gm.last_points.values():
			_awarded += int(v)
	print("  [%5.1fs] estado → %s" % [(Time.get_ticks_msec() - _started_at) / 1000.0, name_])

func _process(_delta: float) -> bool:
	if not _began:
		_began = true
		_start()
		return false
	if _finished:
		return true
	if (Time.get_ticks_msec() - _started_at) / 1000.0 > TIMEOUT_REAL_SECONDS:
		_check(false, "timeout: la partida no terminó (estado %s)" % _gm.State.keys()[_gm.state])
		return _conclude()
	if _gm.state == _gm.State.FINAL:
		# Esperar un frame para que la pantalla final se construya sin errores.
		_finished = true
		_verify_match()
		return _conclude()
	return false

func _verify_match() -> void:
	var n := _expected_players
	var g := _expected_games
	_check(_visited.get("INTRO", 0) == g, "%d presentaciones (hubo %d)" % [g, _visited.get("INTRO", 0)])
	_check(_visited.get("PLAYING", 0) == g, "%d minijuegos jugados (hubo %d)" % [g, _visited.get("PLAYING", 0)])
	_check(_visited.get("SCOREBOARD", 0) == g, "%d marcadores (hubo %d)" % [g, _visited.get("SCOREBOARD", 0)])
	var total := 0
	for p: PlayerData in _lobby.players:
		total += p.score
	var per_game := 0
	for r in n:
		per_game += MatchRules.points_for_rank(r, n)
	# Con puestos compartidos (parejas, empates) o puntos por bandos el total de un minijuego puede no ser el de la tabla:
	# se comprueba contra lo repartido en cada marcador, y que haya al menos los puntos mínimos (1 por jugador y minijuego).
	_check(total == _awarded and total >= n * g, "puntos totales %d == repartidos %d (tabla sin empates: %d)" % [total, _awarded, per_game * g])

func _conclude() -> bool:
	print("")
	if _failures.is_empty():
		print("SMOKE TEST OK (%d jugadores, %d minijuegos)" % [_expected_players, _expected_games])
		quit(0)
	else:
		print("SMOKE TEST FALLÓ:")
		for f in _failures:
			print("  ✗ " + f)
		quit(1)
	return true

func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ✓ " + what)
	else:
		_failures.append(what)
		print("  ✗ " + what)
