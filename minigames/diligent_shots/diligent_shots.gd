extends Minigame
## Disparos Diligentes (modelo HOST_AUTHORITATIVE). Basado en el "Disparos diligentes" de Pummel Party: una caseta de
## feria y todos los jugadores delante, cada uno con su escopeta láser y SUS TRES huecos (izquierda, centro y
## derecha) en la fila, con su color. Cada uno solo puede disparar a los suyos.
##
## Oleadas: en cada una salen a la vez, en los huecos de TODOS (el mismo patrón para todos, así es justo), dianas,
## bombas con la mecha encendida o una mezcla. Cuanto antes aciertes una diana, más puntos: +7 ¡EXCELENTE! (antes de
## 0,45 s), +5 ¡BIEN! (antes de 0,9 s), +2 ¡LENTO! después. Bomba: -5 ¡BANG! y aturdido 1,2 s. Hueco vacío: -2
## ¡FALLASTE!. Los puntos no bajan de 0. A veces primero salen bombas que, al rato, se cambian por dianas: es la
## trampa para quien dispara sin mirar.
##
## Cada vez más rápido: a lo largo de los 45 s las oleadas salen más seguidas y las dianas duran menos (de 2,4 s a
## 1,1 s), así que hay menos tiempo para reaccionar. Gana quien más puntos suma; a igualdad, quien tocó menos bombas.
##
## Controles: A / S o W / D (o izquierda / abajo o arriba / derecha, o el stick) apuntan AUTOMÁTICAMENTE a tu hueco
## de la izquierda / del centro / de la derecha; la acción dispara. Con el ratón: clic en uno de tus huecos = apuntar ahí y
## disparar (clic en otro sitio = disparar donde apuntas).
##
## Se adapta al nº de jugadores: cada jugador tiene su tramo de tres huecos, y el tramo se estrecha cuantos más hay.
##
## Sin código de red propio: el host simula (_simulate); los clientes dibujan el estado (huecos, a qué apunta cada
## uno, puntos, aturdimiento) y los eventos `shot` (resultado de cada disparo) y `end`. El clic llega al host por el
## canal de texto del minijuego (submit_text("s:<hueco 0-2>"); en partida local, sin dueño = el jugador del ratón).

enum Phase { PLAY, END }
enum Wave { GAP, BOMBS, TARGETS }
enum Result { EXCELLENT, GOOD, SLOW, BANG, MISS }

const EMPTY := 0
const TARGET := 1
const BOMB := 2

const PER := 3                        # huecos por jugador: izquierda, centro, derecha
const LEFT := 0
const CENTER := 1
const RIGHT := 2
const NO_SLOT := -1

const DURATION := 45.0
const END_TIME := 2.8
const ROW_Y := 262.0                  # centro de los huecos
const ROW_W := 1180.0                 # anchura de la fila
const PLAYER_Y := 560.0
const DIR_DEADZONE := 0.5
const SHOT_COOLDOWN := 0.18
const MISS_LOCK := 0.4                # arma encasquillada tras fallar
const STUN_TIME := 1.2                # aturdido tras darle a una bomba
const EXCELLENT_T := 0.45
const GOOD_T := 0.9
const POINTS := [7, 5, 2, -5, -2]     # por Result
const LABELS := ["¡EXCELENTE!", "¡BIEN!", "¡LENTO!", "¡BANG!", "¡FALLASTE!"]
# Ritmo: valor al principio → valor al final (se interpola con el avance de la partida).
const GAP_START := Vector2(1.0, 1.6)  # pausa entre oleadas (mín, máx)
const GAP_END := Vector2(0.35, 0.7)
const BOMB_START := Vector2(1.2, 2.0) # cuánto duran las bombas antes de cambiarse
const BOMB_END := Vector2(0.6, 1.2)
const LIFE_START := 2.4               # cuánto duran las dianas
const LIFE_END := 1.1
const FIRST_GAP := 1.0
const MIXED_FROM := 0.3               # avance desde el que una oleada puede mezclar dianas y bombas

var _phase: Phase = Phase.PLAY
var _t_left: float = DURATION
var _end_t: float = 0.0
var _wave: Wave = Wave.GAP
var _wave_t: float = FIRST_GAP        # s que le quedan a la oleada actual
var _kind: PackedByteArray = []       # EMPTY / TARGET / BOMB por hueco (jugador i → huecos i*3 .. i*3+2)
var _born: float = 0.0                # (host) instante en que salió la oleada actual
var _aim: Dictionary = {}             # id -> hueco propio al que apunta (LEFT / CENTER / RIGHT)
var _scores: Dictionary = {}          # id -> puntos
var _bombs_hit: Dictionary = {}       # id -> bombas tocadas (desempate)
var _stun: Dictionary = {}            # id -> s de aturdimiento que quedan
var _cool: Dictionary = {}            # id -> s hasta poder disparar otra vez (host)
var _clock: float = 0.0               # tiempo de partida transcurrido (host)
# Bots / autopiloto (host)
var _bot_rng := RandomNumberGenerator.new()
var _bot_slot: Dictionary = {}        # id -> hueco propio (0-2) al que va
var _bot_ready: Dictionary = {}       # id -> instante desde el que reacciona
var _bot_reckless: Dictionary = {}    # id -> true si en esta oleada de bombas "se le escapa el dedo"
# Solo visual
var _time: float = 0.0
var _aim_draw: Dictionary = {}        # id -> x de la mira suavizada
var _prev_kind: PackedByteArray = []
var _slot_pop: PackedFloat32Array = []  # animación de aparición (0 → 1)
var _slot_fx: PackedFloat32Array = []   # destello al acertar/explotar (1 → 0)
var _slot_fx_kind: PackedByteArray = []
var _flash: Dictionary = {}           # id -> fogonazo del disparo (1 → 0)
var _popups: Array = []               # {"pos", "text", "color", "age", "big"}
var _gain: Dictionary = {}            # id -> {"v": puntos, "age": s} para el +N del marcador
var _last_sec: int = 99

# ----------------------------------------------------------------------------
# Preparación
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	var n := slot_count()
	_kind.resize(n)
	_kind.fill(EMPTY)
	_prev_kind.resize(n)
	_prev_kind.fill(EMPTY)
	_slot_pop.resize(n)
	_slot_fx.resize(n)
	_slot_fx_kind.resize(n)
	for i in players.size():
		var p := players[i]
		_aim[p.id] = CENTER
		_aim_draw[p.id] = slot_x(i * PER + CENTER)
		_scores[p.id] = 0
		_bombs_hit[p.id] = 0
		_stun[p.id] = 0.0
		_cool[p.id] = 0.0
		_flash[p.id] = 0.0
		_bot_slot[p.id] = NO_SLOT
		_bot_ready[p.id] = 0.0
		_bot_reckless[p.id] = false
	_bot_rng.seed = hash([seed_value, "bots"])
	surface.draw_callback = _draw_game

func _on_start() -> void:
	_phase = Phase.PLAY
	_t_left = DURATION
	_clock = 0.0
	_wave = Wave.GAP
	_wave_t = FIRST_GAP
	DevCli.log_event("diligent_shots start players=%d" % players.size())

func slot_count() -> int:
	return PER * players.size()

## Anchura del tramo de cada jugador.
func group_w() -> float:
	return ROW_W / float(maxi(players.size(), 1))

## Distancia entre los tres huecos de un jugador.
func spacing() -> float:
	return minf(96.0, group_w() / 3.3)

func slot_radius() -> float:
	return minf(34.0, spacing() * 0.42)

## x del jugador i: centro de su tramo.
func player_x(i: int) -> float:
	return 640.0 + (float(i) - float(players.size() - 1) * 0.5) * group_w()

## x del hueco global s (jugador s / 3, posición s % 3).
func slot_x(s: int) -> float:
	return player_x(s / PER) + float(s % PER - 1) * spacing()

## Dueño del hueco s: índice de jugador.
func slot_owner(s: int) -> int:
	return clampi(s / PER, 0, players.size() - 1)

func player_index(p: PlayerData) -> int:
	return players.find(p)

## Hueco propio (0-2) bajo un punto de la pantalla para el jugador i, o NO_SLOT.
func own_slot_at(i: int, pos: Vector2) -> int:
	if absf(pos.y - ROW_Y) > slot_radius() + 30.0:
		return NO_SLOT
	for k in PER:
		if absf(pos.x - slot_x(i * PER + k)) <= slot_radius() + 6.0:
			return k
	return NO_SLOT

## Hueco al que apunta una dirección: izquierda, arriba o abajo (centro) o derecha. NO_SLOT si no se pulsa nada claro.
static func slot_from_dir(v: Vector2) -> int:
	if v.length() < DIR_DEADZONE:
		return NO_SLOT
	if absf(v.x) >= absf(v.y):
		return LEFT if v.x < 0.0 else RIGHT
	return CENTER

## Resultado de acertar en una diana que lleva `age` s fuera.
static func result_for_age(age: float) -> Result:
	if age < EXCELLENT_T:
		return Result.EXCELLENT
	if age < GOOD_T:
		return Result.GOOD
	return Result.SLOW

## Avance de la partida (0 al empezar, 1 al acabar): marca el ritmo.
func progress() -> float:
	return clampf(1.0 - _t_left / DURATION, 0.0, 1.0)

## Cuánto dura una oleada de dianas ahora mismo.
func target_life() -> float:
	return lerpf(LIFE_START, LIFE_END, progress())

# ----------------------------------------------------------------------------
# Simulación (solo host)
# ----------------------------------------------------------------------------

func _simulate(delta: float) -> void:
	if _phase == Phase.END:
		for p in players:
			action_presses(p)
		_end_t += delta
		if _end_t >= END_TIME:
			finish(build_ranking())
		return
	_clock += delta
	_t_left -= delta
	if _t_left <= 0.0:
		_t_left = 0.0
		_phase = Phase.END
		_end_t = 0.0
		_kind.fill(EMPTY)
		send_event("end")
		return
	_update_wave(delta)
	for p in players:
		_cool[p.id] = maxf(0.0, float(_cool[p.id]) - delta)
		var stunned := float(_stun[p.id]) > 0.0
		_stun[p.id] = maxf(0.0, float(_stun[p.id]) - delta)
		var k := slot_from_dir(move_input(p))
		var presses := action_presses(p)
		if stunned:
			continue
		if k != NO_SLOT:
			_aim[p.id] = k
		if presses > 0:
			_fire(p)

func _update_wave(delta: float) -> void:
	_wave_t -= delta
	match _wave:
		Wave.GAP:
			if _wave_t <= 0.0:
				_next_wave()
		Wave.BOMBS:
			if _wave_t <= 0.0:
				_spawn(_pattern(false))
		Wave.TARGETS:
			if _wave_t <= 0.0 or not _kind.has(TARGET):
				_kind.fill(EMPTY)
				_wave = Wave.GAP
				var g := GAP_START.lerp(GAP_END, progress())
				_wave_t = rng.randf_range(g.x, g.y)

## Nueva oleada: a veces primero bombas (que luego se cambian por dianas), a veces dianas directamente.
func _next_wave() -> void:
	if rng.randf() < lerpf(0.3, 0.45, progress()):
		var b := BOMB_START.lerp(BOMB_END, progress())
		_wave = Wave.BOMBS
		_wave_t = rng.randf_range(b.x, b.y)
		var pat := PackedByteArray([EMPTY, EMPTY, EMPTY])
		for k in PER:
			pat[k] = BOMB if rng.randf() < 0.75 else EMPTY
		if not pat.has(BOMB):
			pat[rng.randi_range(0, PER - 1)] = BOMB
		_apply_pattern(pat)
		for p in players:
			_bot_slot[p.id] = NO_SLOT
			_bot_reckless[p.id] = _bot_rng.randf() < 0.1
			_bot_ready[p.id] = _clock + _bot_rng.randf_range(0.25, 0.6)
	else:
		_spawn(_pattern(progress() >= MIXED_FROM and rng.randf() < 0.4))

## Patrón de una oleada de dianas para los tres huecos: al menos una diana; con `mixed`, una bomba en otro hueco.
func _pattern(mixed: bool) -> PackedByteArray:
	var pat := PackedByteArray([EMPTY, EMPTY, EMPTY])
	var n := rng.randi_range(1, 2 if mixed else PER)
	var order: Array[int] = [LEFT, CENTER, RIGHT]
	for i in range(order.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := order[i]
		order[i] = order[j]
		order[j] = tmp
	for k in n:
		pat[order[k]] = TARGET
	if mixed:
		pat[order[n]] = BOMB
	return pat

func _spawn(pat: PackedByteArray) -> void:
	_wave = Wave.TARGETS
	_wave_t = target_life()
	_apply_pattern(pat)
	for p in players:
		_bot_slot[p.id] = NO_SLOT
		_bot_reckless[p.id] = false
		_bot_ready[p.id] = _clock + _bot_rng.randf_range(0.22, 0.75)

## El mismo patrón en los tres huecos de cada jugador.
func _apply_pattern(pat: PackedByteArray) -> void:
	for i in players.size():
		for k in PER:
			_kind[i * PER + k] = pat[k]
	_born = _clock

## Disparo de un jugador a su hueco apuntado. Devuelve el resultado (Result), o -1 si ahora no puede disparar.
func _fire(p: PlayerData) -> int:
	if float(_cool[p.id]) > 0.0 or float(_stun[p.id]) > 0.0 or _phase != Phase.PLAY:
		return -1
	var i := player_index(p)
	var k: int = _aim[p.id]
	var s := i * PER + k
	var res: Result = Result.MISS
	if _kind[s] == TARGET:
		res = result_for_age(_clock - _born)
		_kind[s] = EMPTY
	elif _kind[s] == BOMB:
		res = Result.BANG
		_kind[s] = EMPTY
		_stun[p.id] = STUN_TIME
		_bombs_hit[p.id] = int(_bombs_hit[p.id]) + 1
	var pts: int = POINTS[res]
	var before: int = _scores[p.id]
	_scores[p.id] = maxi(0, before + pts)
	_cool[p.id] = MISS_LOCK if res == Result.MISS else SHOT_COOLDOWN
	DevCli.log_event("diligent_shots shot id=%d slot=%d res=%d score=%d" % [p.id, k, int(res), _scores[p.id]])
	send_event("shot", {"p": p.id, "k": k, "r": int(res), "v": int(_scores[p.id]) - before})
	return int(res)

## Clic de un jugador (cualquier PC): "s:<0-2>" apunta a ese hueco propio y dispara; "s:-1" dispara donde apunta.
func _on_player_text(player: PlayerData, text: String, _final: bool) -> void:
	if _phase != Phase.PLAY or not text.begins_with("s:") or not text.substr(2).is_valid_int():
		return
	if player == null:
		player = _mouse_player()
	if player == null or InputManager.is_simulated(player.id) or float(_stun[player.id]) > 0.0:
		return
	var k := text.substr(2).to_int()
	if k >= PER or k < NO_SLOT:
		return
	if k >= 0:
		_aim[player.id] = k
	_fire(player)

## Más puntos primero; a igualdad, menos bombas tocadas.
func build_ranking() -> Array[int]:
	var tb := {}
	for p in players:
		tb[p.id] = float(_bombs_hit[p.id])
	return rank_by_score(_scores, tb)

# --- Bots y autopiloto: tras su tiempo de reacción apuntan a una de sus dianas y disparan ---

func _bot_move(player: PlayerData) -> Vector2:
	match _bot_choose(player):
		LEFT: return Vector2.LEFT
		CENTER: return Vector2.DOWN
		RIGHT: return Vector2.RIGHT
	return Vector2.ZERO

func _bot_action(player: PlayerData) -> int:
	var k: int = _bot_slot.get(player.id, NO_SLOT)
	if k == NO_SLOT or float(_cool[player.id]) > 0.0 or _clock < float(_bot_ready[player.id]):
		return 0
	# Ya apunta a su hueco: dispara y se toma un momento antes del siguiente.
	if int(_aim[player.id]) == k:
		_bot_ready[player.id] = _clock + _bot_rng.randf_range(0.08, 0.2)
		return 1
	return 0

## Hueco propio al que va el bot ahora mismo (NO_SLOT = esperar).
func _bot_choose(player: PlayerData) -> int:
	if _clock < float(_bot_ready[player.id]) or float(_stun[player.id]) > 0.0:
		return NO_SLOT
	var want := TARGET
	if _wave == Wave.BOMBS:
		if not _bot_reckless[player.id]:
			_bot_slot[player.id] = NO_SLOT
			return NO_SLOT
		want = BOMB            # "se le escapa el dedo"
	var i := player_index(player)
	var cur: int = _bot_slot[player.id]
	if cur != NO_SLOT and _kind[i * PER + cur] == want:
		return cur
	var options: Array[int] = []
	for k in PER:
		if _kind[i * PER + k] == want:
			options.append(k)
	var pick := NO_SLOT
	if not options.is_empty():
		pick = options[_bot_rng.randi_range(0, options.size() - 1)]
	_bot_slot[player.id] = pick
	return pick

# ----------------------------------------------------------------------------
# Estado hacia los clientes
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var aims := PackedByteArray()
	var sc := PackedInt32Array()
	var stn := PackedFloat32Array()
	for p in players:
		aims.append(_aim[p.id])
		sc.append(_scores[p.id])
		stn.append(_stun[p.id])
	return {"ph": int(_phase), "tl": _t_left, "k": _kind, "a": aims, "sc": sc, "st": stn, "et": _end_t}

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	var d: Dictionary = state
	_phase = int(d.get("ph", _phase)) as Phase
	_t_left = float(d.get("tl", _t_left))
	_end_t = float(d.get("et", _end_t))
	var k: Variant = d.get("k")
	if k is PackedByteArray and k.size() == _kind.size():
		_kind = k
	var a: Variant = d.get("a")
	var sc: Variant = d.get("sc")
	var st: Variant = d.get("st")
	for i in players.size():
		var id := players[i].id
		if a is PackedByteArray and i < a.size():
			_aim[id] = clampi(a[i], 0, PER - 1)
		if sc is PackedInt32Array and i < sc.size():
			_scores[id] = sc[i]
		if st is PackedFloat32Array and i < st.size():
			_stun[id] = st[i]

func _on_event(event_name: String, data: Variant) -> void:
	match event_name:
		"shot":
			if not data is Dictionary:
				return
			var who := _player_by_id(int(data.get("p", -1)))
			if who == null:
				return
			var i := player_index(who)
			var k := clampi(int(data.get("k", CENTER)), 0, PER - 1)
			var res := int(data.get("r", Result.MISS))
			var v := int(data.get("v", 0))
			var s := i * PER + k
			var x := slot_x(s)
			_flash[who.id] = 1.0
			_aim[who.id] = k
			if res != Result.MISS:
				_kind[s] = EMPTY
				_prev_kind[s] = EMPTY
				_slot_fx[s] = 1.0
				_slot_fx_kind[s] = BOMB if res == Result.BANG else TARGET
			if res == Result.BANG:
				_stun[who.id] = STUN_TIME
			if not is_authority:
				_scores[who.id] = maxi(0, int(_scores.get(who.id, 0)) + v)
			var label: String = ("%+d " % v if v != 0 else "") + String(LABELS[res])
			var col := Palette.YELLOW if res == Result.EXCELLENT else (Palette.MINT if res == Result.GOOD else Palette.WHITE)
			if res == Result.BANG or res == Result.MISS:
				col = Palette.CORAL
			_popups.append({"pos": Vector2(x, ROW_Y - 54.0), "text": label, "color": col, "age": 0.0,
					"big": res == Result.EXCELLENT or res == Result.BANG})
			_gain[who.id] = {"v": v, "age": 0.0}
			var loud := is_audible(who)
			var vol := 0.0 if loud else -9.0
			Audio.sfx(&"shot", vol - 4.0)
			match res:
				Result.EXCELLENT: Audio.sfx(&"hit_gold", vol - 2.0)
				Result.GOOD, Result.SLOW: Audio.sfx(&"hit", vol - 2.0)
				Result.BANG: Audio.sfx(&"crash", vol - 1.0)
				_:
					if loud:
						Audio.sfx(&"miss", -4.0)
		"end":
			_phase = Phase.END
			_end_t = 0.0
			_kind.fill(EMPTY)
			Audio.sfx(&"stinger", -4.0)

func _player_by_id(id: int) -> PlayerData:
	for p in players:
		if p.id == id:
			return p
	return null

# ----------------------------------------------------------------------------
# Entrada local: ratón
# ----------------------------------------------------------------------------

## Quién maneja el ratón en este PC: online, su jugador; en local, la primera persona (teclado 1 si la hay).
func _mouse_player() -> PlayerData:
	if local_player != null:
		return local_player
	var first: PlayerData = null
	for p in players:
		if p.device == PlayerData.DEVICE_KB1 or p.device == PlayerData.DEVICE_LOCAL:
			return p
		if first == null and p.is_local_human:
			first = p
	return first

func _unhandled_input(event: InputEvent) -> void:
	if not is_running or _phase != Phase.PLAY or surface == null:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var me := _mouse_player()
		if me == null or InputManager.is_simulated(me.id):
			return
		submit_text("s:%d" % own_slot_at(player_index(me), surface.get_local_mouse_position()))

# ----------------------------------------------------------------------------
# Animación (todos los PC)
# ----------------------------------------------------------------------------

func _animate(delta: float) -> void:
	_time += delta
	if not is_authority and is_running:
		if _phase == Phase.PLAY:
			_t_left = maxf(0.0, _t_left - delta)
		else:
			_end_t += delta
		for p in players:
			_stun[p.id] = maxf(0.0, float(_stun[p.id]) - delta)
	for i in players.size():
		var p := players[i]
		var tx := slot_x(i * PER + int(_aim[p.id]))
		_aim_draw[p.id] = lerpf(float(_aim_draw[p.id]), tx, minf(1.0, delta * 30.0))
		_flash[p.id] = maxf(0.0, float(_flash[p.id]) - delta * 6.0)
		if _gain.has(p.id):
			_gain[p.id]["age"] = float(_gain[p.id]["age"]) + delta
	var bombs_out := false
	var targets_out := false
	for s in _kind.size():
		if _kind[s] != _prev_kind[s]:
			if _kind[s] != EMPTY:
				_slot_pop[s] = 0.0
				if _kind[s] == BOMB:
					bombs_out = true
				else:
					targets_out = true
			_prev_kind[s] = _kind[s]
		_slot_pop[s] = minf(1.0, _slot_pop[s] + delta * 8.0)
		_slot_fx[s] = maxf(0.0, _slot_fx[s] - delta * 2.5)
	if is_running and _phase == Phase.PLAY:
		if targets_out:
			Audio.sfx(&"flip_up", -4.0)
		elif bombs_out:
			Audio.sfx(&"release", -6.0)
	for pop in _popups:
		pop["age"] = float(pop["age"]) + delta
	_popups = _popups.filter(func(pop: Dictionary) -> bool: return float(pop["age"]) < 1.0)
	if is_running and _phase == Phase.PLAY:
		var sec := ceili(_t_left)
		if sec != _last_sec and sec <= 5 and sec >= 1:
			Audio.sfx(&"score_tick", -3.0)
		_last_sec = sec

# ----------------------------------------------------------------------------
# Dibujo
# ----------------------------------------------------------------------------

func _draw_game() -> void:
	_draw_booth()
	for s in slot_count():
		_draw_slot(s)
	for i in players.size():
		_draw_laser(i)
	for i in players.size():
		_draw_player(i)
	_draw_popups()
	_draw_hud()

## Caseta de feria: fondo de tablones, toldo y mostrador.
func _draw_booth() -> void:
	var s := surface
	var left := 640.0 - ROW_W * 0.5 - 20.0
	var right := 640.0 + ROW_W * 0.5 + 20.0
	var top := ROW_Y - 120.0
	var bottom := ROW_Y + 78.0
	s.draw_rect(Rect2(left + 8, top + 12, right - left, bottom - top), Color(0, 0, 0, 0.25))
	s.draw_rect(Rect2(left, top, right - left, bottom - top), Color("7A4A2B"))
	var plank := 46.0
	var x := left
	var k := 0
	while x < right:
		var w := minf(plank, right - x)
		s.draw_rect(Rect2(x, top, w, bottom - top), Color("8C5A35") if k % 2 == 0 else Color("6E4227"))
		s.draw_line(Vector2(x, top), Vector2(x, bottom), Color(0, 0, 0, 0.25), 2.0)
		x += plank
		k += 1
	# Toldo a rayas.
	var stripes := 14
	var sw := (right - left + 40.0) / float(stripes)
	for i in stripes:
		var x0 := left - 20.0 + sw * i
		var col := Palette.CORAL if i % 2 == 0 else Palette.WHITE
		s.draw_colored_polygon(PackedVector2Array([Vector2(x0, top - 46), Vector2(x0 + sw, top - 46),
				Vector2(x0 + sw, top - 6), Vector2(x0 + sw * 0.5, top + 8), Vector2(x0, top - 6)]), col)
	s.draw_rect(Rect2(left - 20, top - 58, right - left + 40, 14), Palette.CORAL_DARK)
	# Banda de color de cada jugador detrás de sus tres huecos.
	for i in players.size():
		var x0 := slot_x(i * PER) - spacing() * 0.5
		var x1 := slot_x(i * PER + PER - 1) + spacing() * 0.5
		s.rounded_rect(Rect2(x0, ROW_Y - slot_radius() - 14.0, x1 - x0, slot_radius() * 2.0 + 28.0), 14, Color(players[i].color, 0.25))
	# Mostrador.
	s.draw_rect(Rect2(left - 24, bottom, right - left + 48, 26), Color("C98F55"))
	s.draw_rect(Rect2(left - 24, bottom + 26, right - left + 48, 10), Color("6E4227"))

func _draw_slot(i: int) -> void:
	var s := surface
	var c := Vector2(slot_x(i), ROW_Y)
	var r := slot_radius()
	var owner_col := players[slot_owner(i)].color
	# Aro del hueco (color de su dueño).
	s.draw_circle(c, r + 3.0, Color(0, 0, 0, 0.35))
	s.draw_arc(c, r, 0.0, TAU, 40, owner_col, 4.0, true)
	var pop := _slot_pop[i]
	var scale := minf(1.0, pop * 1.25) * (1.0 + 0.18 * sin(pop * PI))
	match _kind[i]:
		TARGET:
			var rr := r * 0.92 * scale
			s.draw_circle(c, rr, Palette.WHITE)
			s.draw_circle(c, rr * 0.78, Palette.CORAL)
			s.draw_circle(c, rr * 0.56, Palette.WHITE)
			s.draw_circle(c, rr * 0.34, Palette.CORAL)
			s.draw_circle(c, rr * 0.13, Palette.WHITE)
		BOMB:
			var rr := r * 0.78 * scale
			var wob := Vector2(sin(_time * 21.0 + i) * 1.5, 0)
			s.draw_circle(c + wob + Vector2(0, 4), rr, Color("1D1633"))
			s.draw_circle(c + wob + Vector2(-rr * 0.32, -rr * 0.1), rr * 0.22, Color(1, 1, 1, 0.25))
			var neck := c + wob + Vector2(rr * 0.45, -rr * 0.75)
			s.draw_rect(Rect2(neck - Vector2(6, 5), Vector2(12, 9)), Color("4B4166"))
			var tip := neck + Vector2(9, -12)
			s.draw_line(neck, tip, Color("D8C7A0"), 3.0, true)
			# Chispas de la mecha.
			for k in 6:
				var a := _time * 13.0 + k * 1.7 + i
				var ln := 5.0 + 9.0 * fposmod(_time * 4.0 + k * 0.37, 1.0)
				s.draw_line(tip, tip + Vector2.from_angle(a) * ln, Palette.YELLOW if k % 2 == 0 else Color("FF8A3D"), 2.0, true)
			s.draw_circle(tip, 4.0 + sin(_time * 30.0) * 1.2, Color("FFF2A8"))
	# Destello al acertar (dorado) o explotar (naranja).
	var fx := _slot_fx[i]
	if fx > 0.0:
		var col := Color("FF7A2E") if _slot_fx_kind[i] == BOMB else Palette.YELLOW
		var big := r * (1.0 + (1.0 - fx) * (1.6 if _slot_fx_kind[i] == BOMB else 0.9))
		s.draw_circle(c, big, Color(col, fx * 0.45))
		for k in 8:
			var d := Vector2.from_angle(TAU * k / 8.0 + i)
			s.draw_line(c + d * big * 0.6, c + d * big * 1.1, Color(col, fx), 3.0, true)

func _avatar_r() -> float:
	return 36.0 if players.size() <= 5 else 28.0

func _draw_laser(i: int) -> void:
	var s := surface
	var p := players[i]
	if float(_stun[p.id]) > 0.0 or _phase != Phase.PLAY:
		return
	var base := Vector2(player_x(i), PLAYER_Y)
	var target := Vector2(float(_aim_draw[p.id]), ROW_Y)
	var tip := base + (target - base).normalized() * (_avatar_r() + 26.0)
	s.draw_line(tip, target, Color(p.color, 0.55), 3.0, true)
	s.draw_line(tip, target, Color(1, 1, 1, 0.35), 1.0, true)
	var rr := slot_radius() * 0.45 + 4.0
	s.draw_arc(target, rr, 0.0, TAU, 24, p.color, 3.0, true)
	s.draw_line(target + Vector2(-rr - 5, 0), target + Vector2(-rr + 4, 0), p.color, 2.0)
	s.draw_line(target + Vector2(rr - 4, 0), target + Vector2(rr + 5, 0), p.color, 2.0)
	s.draw_circle(target, 3.0, Palette.WHITE)

func _draw_player(i: int) -> void:
	var s := surface
	var p := players[i]
	var c := Vector2(player_x(i), PLAYER_Y)
	var r := _avatar_r()
	var stunned := float(_stun[p.id]) > 0.0
	var winner := _phase == Phase.END and build_ranking()[0] == p.id
	if winner:
		s.draw_circle(c, r + 14.0, Color(Palette.YELLOW, 0.4 + 0.15 * sin(_time * 6.0)))
	var dir := (Vector2(float(_aim_draw[p.id]), ROW_Y) - c).normalized()
	if stunned:
		# Tumbado y con estrellas dando vueltas.
		s.draw_set_transform(c + Vector2(0, 10), 1.35, Vector2(1.0, 0.9))
		AvatarPainter.paint(s, Vector2.ZERO, r, p.color, Vector2.ZERO)
		s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		for k in 3:
			var a := _time * 5.0 + TAU * k / 3.0
			_star(c + Vector2(cos(a) * r * 0.9, -r - 6.0 + sin(a) * 8.0), 8.0, Palette.YELLOW)
	else:
		# Escopeta: un cañón que sale del avatar hacia la mira.
		var flash: float = _flash[p.id]
		var gun0 := c + dir * (r * 0.5)
		var gun1 := c + dir * (r + 26.0 - flash * 6.0)
		s.draw_line(gun0, gun1, Palette.PURPLE_DARK, 13.0, true)
		s.draw_line(gun0, gun1, Color("5B4E7A"), 8.0, true)
		if flash > 0.0:
			s.draw_circle(gun1 + dir * 6.0, 10.0 + 10.0 * flash, Color(Palette.YELLOW, flash))
		AvatarPainter.paint(s, c, r, p.color, dir)
	if winner:
		AvatarPainter.paint_crown(s, c, r)
	elif is_local_player(p) and NetworkManager.is_online:
		draw_local_marker(c, r)
	# Marcador bajo el jugador.
	var bw := minf(108.0, group_w() - 12.0)
	var box := Rect2(c.x - bw * 0.5, c.y + r + 18.0, bw, 38.0)
	s.rounded_rect(Rect2(box.position + Vector2(0, 4), box.size), 12, Palette.PURPLE_DARK)
	s.rounded_rect(box, 12, Color(p.color.darkened(0.35), 0.95))
	s.text_centered(box.get_center(), str(_scores[p.id]), 26, Palette.WHITE, 6)
	s.text_centered(Vector2(c.x, box.end.y + 16.0), p.label(), 18, Palette.WHITE, 5)
	if _gain.has(p.id):
		var g: Dictionary = _gain[p.id]
		var age: float = g["age"]
		if age < 1.0:
			var v: int = g["v"]
			var col := Palette.MINT if v > 0 else Palette.CORAL
			s.text_centered(Vector2(c.x + bw * 0.42, box.position.y - 6.0 - age * 22.0), "%+d" % v, 22, Color(col, 1.0 - age), 5)

func _star(c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for k in 10:
		var rad := r if k % 2 == 0 else r * 0.45
		pts.append(c + Vector2.from_angle(-PI * 0.5 + TAU * k / 10.0) * rad)
	surface.draw_colored_polygon(pts, col)

func _draw_popups() -> void:
	for pop in _popups:
		var age: float = pop["age"]
		var a := clampf(1.0 - (age - 0.5) / 0.5, 0.0, 1.0)
		var big: bool = pop["big"]
		var size := 20 if big else 16
		if players.size() <= 5:
			size = 26 if big else 20
		var scale := 1.0 + 0.4 * maxf(0.0, 1.0 - age * 6.0)
		var at: Vector2 = pop["pos"] + Vector2(0, -age * 30.0)
		surface.draw_set_transform(at, 0.0, Vector2.ONE * scale)
		var col: Color = pop["color"]
		surface.text_centered(Vector2.ZERO, String(pop["text"]), size, Color(col, a), 6)
		surface.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_hud() -> void:
	var s := surface
	# Tiempo (arriba a la derecha).
	var tc := Vector2(1200, 48)
	s.draw_circle(tc, 32, Palette.PURPLE_DARK)
	s.draw_arc(tc, 28, -PI * 0.5, -PI * 0.5 + TAU * clampf(_t_left / DURATION, 0.0, 1.0), 48,
			Palette.CORAL if _t_left <= 5.0 else Palette.MINT, 5.0, true)
	s.text_centered(tc, str(ceili(_t_left)), 26, Palette.WHITE, 0)
	if _phase == Phase.END:
		var order := build_ranking()
		var w: PlayerData = null
		if not order.is_empty():
			w = _player_by_id(order[0])
		if w != null:
			s.text_centered(Vector2(640, 52), "¡%s GANA!" % w.display_name.to_upper(), 44, Palette.YELLOW, 10)
		return
	var hint := "A / W o S / D apuntan · acción dispara"
	var warn := false
	if _kind.has(BOMB) and not _kind.has(TARGET):
		hint = "¡BOMBAS! No dispares…"
		warn = true
	elif _kind.has(BOMB):
		hint = "¡Ojo, hay bombas entre las dianas!"
	var me := _hud_player()
	if me != null and float(_stun[me.id]) > 0.0:
		hint = "¡Aturdido!"
		warn = true
	elif progress() > 0.66 and not warn and not _kind.has(BOMB):
		hint = "¡Más rápido!"
	s.text_centered(Vector2(640, 52), hint, 30, Palette.CORAL if warn else Palette.WHITE, 7)

## Jugador al que se le habla en el texto de ayuda: el de este PC (online) o ninguno (varios en un PC).
func _hud_player() -> PlayerData:
	if local_player != null:
		return local_player
	for p in players:
		if p.device == PlayerData.DEVICE_LOCAL:
			return p
	return null
