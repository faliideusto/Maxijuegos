extends Node
## Herramientas de desarrollo (autoload): permite lanzar varias instancias del juego y
## automatizar partidas desde la línea de comandos. No afecta al juego normal: sin argumentos
## no hace nada.
##
## Argumentos (tras "--"):
##   --host                 crea una sala online al arrancar (este PC es el host)
##   --local                partida SIN red: un humano (teclado 1: WASD + Espacio) + --bots=N, empieza sola
##   --join=IP              se une a la sala de esa IP al arrancar
##   --name=Nombre          nombre del jugador de este PC
##   --bots=N               (host) añade N bots al lobby
##   --players=N            (host) empieza la partida sola cuando haya N jugadores (humanos + bots)
##   --games=N              (host) nº de minijuegos de la partida automática
##   --only=<id>            (host) fuerza ese minijuego en todas las rondas (p. ej. reaction_test)
##   --autopilot            los jugadores locales de este PC se controlan solos (pruebas desatendidas)
##   --timescale=X          acelera el juego (solo para pruebas)
##   --log                  escribe eventos "[EVT] ..." por stdout (los leen los tests)
##   --quit-at-end          cierra el juego al llegar a la pantalla final
##   --shot=ruta.png:seg    guarda una captura de la ventana pasados `seg` segundos
##
## Varias instancias a mano: tools/dev_multi.ps1 (ventanas) o tests/online_test.sh (headless).

const AUTO_START_STABLE_SECONDS := 2.5

var log_events: bool = false
var _args: Dictionary = {}
var _auto_players: int = 0
var _stable_since: float = -1.0
var _auto_started: bool = false
var _quit_at_end: bool = false

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	if _args.is_empty():
		return
	log_events = _args.has("log")
	_quit_at_end = _args.has("quit-at-end")
	if DisplayServer.get_name() == "headless":
		Engine.max_fps = 60   # varias instancias headless no deben acaparar la CPU
	if _args.has("timescale"):
		Engine.time_scale = float(_args["timescale"])
	if _args.has("only"):
		GameManager.forced_minigame_id = str(_args["only"])
	if _args.has("autopilot"):
		InputManager.autopilot = true
	if _args.has("name"):
		Lobby.profile_name = str(_args["name"])
	if _args.has("shot"):
		# --shot=ruta.png:segundos → guarda una captura de la ventana pasado ese tiempo.
		var parts := str(_args["shot"]).rsplit(":", true, 1)
		var path := parts[0]
		var secs := float(parts[1]) if parts.size() > 1 else 10.0
		get_tree().create_timer(secs, true, false, true).timeout.connect(func() -> void:
			get_viewport().get_texture().get_image().save_png(path)
			log_event("screenshot saved %s" % path))
	GameManager.state_changed.connect(_on_state_changed)
	Lobby.roster_changed.connect(func() -> void:
		log_event("roster n=%d humans=%d" % [Lobby.players.size(), _human_count()]))
	if _args.has("host") or _args.has("join") or _args.has("local"):
		_bootstrap.call_deferred()

func log_event(text: String) -> void:
	if log_events:
		print("[EVT] ", text)

func _bootstrap() -> void:
	await get_tree().process_frame
	if _args.has("host"):
		var err := Lobby.host_room()
		log_event("host_room err=%s" % error_string(err))
		if err != OK:
			get_tree().quit(1)
			return
		GameManager.go_to_lobby()
		for i in int(_args.get("bots", "0")):
			Lobby.add_bot()
		_auto_players = int(_args.get("players", "0"))
		GameManager.set_minigame_count(int(_args.get("games", str(GameManager.minigame_count))))
	elif _args.has("local"):
		# Partida SIN red: un humano en el teclado 1 (WASD + Espacio) y N bots.
		var human := Lobby.add_player(PlayerData.DEVICE_KB1)
		if human != null:
			human.display_name = Lobby.profile_name
		GameManager.go_to_lobby()
		var bots := int(_args.get("bots", "3"))
		for i in bots:
			Lobby.add_bot()
		_auto_players = 1 + bots
		GameManager.set_minigame_count(int(_args.get("games", str(GameManager.minigame_count))))
		log_event("local human + %d bots" % bots)
	else:
		var err := Lobby.join_room(str(_args["join"]))
		log_event("join_room err=%s" % error_string(err))

func _process(delta: float) -> void:
	# Arranque automático del host: cuando haya suficientes jugadores de forma estable.
	if _auto_players <= 0 or _auto_started or GameManager.state != GameManager.State.LOBBY:
		return
	if Lobby.players.size() >= _auto_players:
		if _stable_since < 0.0:
			_stable_since = 0.0
		_stable_since += delta
		if _stable_since >= AUTO_START_STABLE_SECONDS:
			_auto_started = true
			log_event("auto_start players=%d games=%d" % [Lobby.players.size(), GameManager.minigame_count])
			GameManager.start_match()
	else:
		_stable_since = -1.0

func _on_state_changed(new_state: int) -> void:
	if new_state == GameManager.State.FINAL:
		var scores: Array = []
		for p in Lobby.players:
			scores.append("%d:%d" % [p.id, p.score])
		log_event("final scores=%s" % ",".join(scores))
		if _quit_at_end:
			# El host cierra primero (tras dar margen a que los clientes reciban el estado final):
			# así no se ve a los clientes "marchándose" de una sala que sigue abierta.
			var wait := 2.5 if NetworkManager.is_host() else 7.0
			get_tree().create_timer(wait, true, false, true).timeout.connect(func() -> void: get_tree().quit(0))
	elif new_state == GameManager.State.SCOREBOARD:
		var parts: Array = []
		for p in Lobby.players:
			parts.append("%d:%d" % [p.id, p.score])
		log_event("scoreboard scores=%s ranking=%s" % [",".join(parts), GameManager.last_ranking])

func _human_count() -> int:
	var n := 0
	for p in Lobby.players:
		if not p.is_bot:
			n += 1
	return n
