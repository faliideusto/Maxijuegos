extends Minigame
## Disparos Diligentes (modelo HOST_AUTHORITATIVE). Copia del "Disparos diligentes" de Pummel Party: una caseta de
## feria con una fila de huecos y todos los jugadores delante, cada uno con su escopeta láser. De vez en cuando
## salen DIANAS a la vez en varios huecos: el primero que acierta una se la lleva, y cuanto antes dispare más puntos
## (+7 ¡EXCELENTE! antes de 0,5 s, +5 ¡BIEN! antes de 1 s, +2 ¡LENTO! después). Otras veces salen BOMBAS con la
## mecha encendida (y al rato se cambian por dianas): darle a una quita 5 puntos y deja aturdido 1,4 s. Disparar a
## un hueco vacío quita 2 (¡FALLASTE!) y encasquilla el arma un momento. Los puntos no bajan de 0.
##
## Se adapta al nº de jugadores: cada uno tiene su tramo de huecos con su color (4 con 2 jugadores, 3 hasta 5
## jugadores y 2 a partir de 6), pero se puede disparar a cualquiera. Desde la mitad de la partida algunas oleadas
## de dianas traen alguna bomba mezclada. 45 s; gana quien más puntos suma; a igualdad, quien tocó menos bombas.
##
## Controles: izquierda/derecha (mantener) mueve la mira por la fila; la acción dispara. Con el ratón, clic en un
## hueco = apuntar ahí y disparar (clic fuera de la fila = disparar donde se apunta).
##
## Sin código de red propio: el host simula (_simulate); los clientes dibujan el estado (huecos, miras, puntos,
## aturdimiento) y los eventos `shot` (resultado de cada disparo) y `end`. El clic llega al host por el canal de
## texto del minijuego (submit_text("s:<hueco>"); en partida local, sin dueño = el jugador del ratón).

enum Phase { PLAY, END }
enum Wave { GAP, BOMBS, TARGETS }
enum Result { EXCELLENT, GOOD, SLOW, BANG, MISS }

const EMPTY := 0
const TARGET := 1
const BOMB := 2

const DURATION := 45.0
const END_TIME := 2.8
const ROW_Y := 262.0                  # centro de los huecos
const ROW_W := 1060.0                 # anchura máxima de la fila
const MAX_SPACING := 96.0
const PLAYER_Y := 560.0
const AIM_SPEED := 760.0              # px/s de la mira
const SHOT_COOLDOWN := 0.22
const MISS_LOCK := 0.45               # arma encasquillada tras fallar
const STUN_TIME := 1.4                # aturdido tras darle a una bomba
const EXCELLENT_T := 0.5
const GOOD_T := 1.0
const POINTS := [7, 5, 2, -5, -2]     # por Result
const LABELS := ["¡EXCELENTE!", "¡BIEN!", "¡LENTO!", "¡BANG!", "¡FALLASTE!"]
const GAP_MIN := 0.7
const GAP_MAX := 1.5
const FIRST_GAP := 1.0
const BOMB_MIN := 0.9
const BOMB_MAX := 2.0
const TARGET_LIFE_START := 2.6
const TARGET_LIFE_END := 1.9
const MIXED_FROM := 0.4               # parte de la partida desde la que puede haber bombas entre las dianas
const NO_SLOT := -1

var _phase: Phase = Phase.PLAY
var _t_left: float = DURATION
var _end_t: float = 0.0
var _wave: Wave = Wave.GAP
var _wave_t: float = FIRST_GAP        # s que le quedan a la oleada actual
var _kind: PackedByteArray = []       # EMPTY / TARGET / BOMB por hueco
var _born: PackedFloat32Array = []    # (host) instante (tiempo de partida) en que salió lo que hay en cada hueco
var _aim: Dictionary = {}             # id -> x de la mira
var _scores: Dictionary = {}          # id -> puntos
var _bombs_hit: Dictionary = {}       # id -> bombas tocadas (desempate)
var _stun: Dictionary = {}            # id -> s de aturdimiento que quedan
var _cool: Dictionary = {}            # id -> s hasta poder disparar otra vez (host)
var _clock: float = 0.0               # tiempo de partida transcurrido (host)
# Bots / autopiloto (host)
var _bot_rng := RandomNumberGenerator.new()
var _bot_slot: Dictionary = {}        # id -> hueco al que va
var _bot_ready: Dictionary = {}       # id -> instante desde el que reacciona en esta oleada
var _bot_reckless: Dictionary = {}    # id -> true si en esta oleada de bombas "se le escapa el dedo"
# Solo visual
var _time: float = 0.0
var _aim_draw: Dictionary = {}        # id -> x de la mira suavizada
var _prev_kind: PackedByteArray = []
var _slot_pop: PackedFloat32Array = []  # animación de aparición (0 → 1)
var _slot_fx: PackedFloat32Array = []   # destello al acertar/explotar (1 → 0)
var _slot_fx_kind: PackedByteArray = []
var _flash: Dictionary = {}           # id -> fogonazo del disparo (1 → 0)
var _popups: Array = []   # {"pos", "text", "color", "age", "big"}
var _gain: Dictionary = {}            # id -> {"v": puntos, "age": s} para el +N del marcador
var _last_sec: int = 99

# ----------------------------------------------------------------------------
# Preparación
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	var n := slot_count()
	_kind.resize(n)
	_kind.fill(EMPTY)
	_born.resize(n)
	_prev_kind.resize(n)
	_prev_kind.fill(EMPTY)
	_slot_pop.resize(n)
	_slot_fx.resize(n)
	_slot_fx_kind.resize(n)
	for i in players.size():
		var p := players[i]
		var x := player_x(i)
		_aim[p.id] = x
		_aim_draw[p.id] = x
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
	DevCli.log_event("diligent_shots start players=%d slots=%d" % [players.size(), slot_count()])

## Huecos por jugador: 4 con 2 jugadores, 3 hasta 5 y 2 a partir de 6.
static func slots_per_player(n_players: int) -> int:
	if n_players <= 2:
		return 4
	if n_players <= 5:
		return 3
	return 2

func slot_count() -> int:
	return slots_per_player(players.size()) * players.size()

func spacing() -> float:
	return minf(MAX_SPACING, ROW_W / float(maxi(slot_count(), 1)))

func slot_radius() -> float:
	return minf(34.0, spacing() * 0.42)

func slot_x(i: int) -> float:
	return 640.0 + (float(i) - float(slot_count() - 1) * 0.5) * spacing()

## Dueño (por color) del hueco i: índice de jugador.
func slot_owner(i: int) -> int:
	return clampi(i / slots_per_player(players.size()), 0, players.size() - 1)

## x del jugador i: en el centro de su tramo de huecos.
func player_x(i: int) -> float:
	var per := slots_per_player(players.size())
	return (slot_x(i * per) + slot_x(i * per + per - 1)) * 0.5

func row_left() -> float:
	return slot_x(0) - spacing() * 0.5

func row_right() -> float:
	return slot_x(slot_count() - 1) + spacing() * 0.5

## Hueco bajo una x (dentro de su diana), o NO_SLOT si cae entre dos.
func slot_at(x: float) -> int:
	var i := roundi((x - 640.0) / spacing() + float(slot_count() - 1) * 0.5)
	if i < 0 or i >= slot_count():
		return NO_SLOT
	if absf(x - slot_x(i)) > slot_radius():
		return NO_SLOT
	return i

## Puntos y resultado de acertar en una diana que lleva `age` s fuera.
static func result_for_age(age: float) -> Result:
	if age < EXCELLENT_T:
		return Result.EXCELLENT
	if age < GOOD_T:
		return Result.GOOD
	return Result.SLOW

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
	# Mira y disparos. El orden de quién dispara primero en un mismo frame se sortea (nadie tiene ventaja fija).
	var shooters: Array[PlayerData] = []
	for p in players:
		_cool[p.id] = maxf(0.0, float(_cool[p.id]) - delta)
		var stunned := float(_stun[p.id]) > 0.0
		_stun[p.id] = maxf(0.0, float(_stun[p.id]) - delta)
		var v := move_input(p)
		var presses := action_presses(p)
		if stunned:
			continue
		if absf(v.x) > 0.2:
			_aim[p.id] = clampf(float(_aim[p.id]) + v.x * AIM_SPEED * delta, row_left(), row_right())
		if presses > 0:
			shooters.append(p)
	for i in range(shooters.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := shooters[i]
		shooters[i] = shooters[j]
		shooters[j] = tmp
	for p in shooters:
		_fire(p)

func _update_wave(delta: float) -> void:
	_wave_t -= delta
	match _wave:
		Wave.GAP:
			if _wave_t <= 0.0:
				_next_wave()
		Wave.BOMBS:
			if _wave_t <= 0.0:
				_spawn_targets()
		Wave.TARGETS:
			if _wave_t <= 0.0 or not _kind.has(TARGET):
				_kind.fill(EMPTY)
				_wave = Wave.GAP
				_wave_t = rng.randf_range(GAP_MIN, GAP_MAX)

## Nueva oleada: a veces primero bombas (que luego se cambian por dianas), a veces dianas directamente.
func _next_wave() -> void:
	var progress := 1.0 - _t_left / DURATION
	if rng.randf() < lerpf(0.4, 0.55, progress):
		_wave = Wave.BOMBS
		_wave_t = rng.randf_range(BOMB_MIN, BOMB_MAX)
		_fill_random(BOMB, rng.randi_range(maxi(2, ceili(slot_count() * 0.5)), slot_count()))
		for p in players:
			_bot_slot[p.id] = NO_SLOT
			_bot_reckless[p.id] = _bot_rng.randf() < 0.1
			_bot_ready[p.id] = _clock + _bot_rng.randf_range(0.25, 0.7)
	else:
		_spawn_targets()

func _spawn_targets() -> void:
	var progress := 1.0 - _t_left / DURATION
	_wave = Wave.TARGETS
	_wave_t = lerpf(TARGET_LIFE_START, TARGET_LIFE_END, progress)
	_kind.fill(EMPTY)
	var n := slot_count()
	_fill_random(TARGET, rng.randi_range(maxi(2, ceili(n * 0.35)), n))
	# Desde la mitad de la partida, algunas oleadas traen alguna bomba entre las dianas.
	if progress >= MIXED_FROM and n >= 6 and rng.randf() < 0.45:
		var empties: Array[int] = []
		for i in n:
			if _kind[i] == EMPTY:
				empties.append(i)
		if empties.is_empty():
			# Fila llena de dianas: una de ellas pasa a ser bomba.
			_kind[rng.randi_range(0, n - 1)] = BOMB
		else:
			for k in mini(empties.size(), rng.randi_range(1, maxi(1, n / 8))):
				var pick := rng.randi_range(0, empties.size() - 1)
				_kind[empties[pick]] = BOMB
				empties.remove_at(pick)
	for p in players:
		_bot_slot[p.id] = NO_SLOT
		_bot_reckless[p.id] = false
		_bot_ready[p.id] = _clock + _bot_rng.randf_range(0.28, 0.85)

## Pone `count` huecos al azar (distintos) con `what`.
func _fill_random(what: int, count: int) -> void:
	_kind.fill(EMPTY)
	var idx: Array[int] = []
	for i in slot_count():
		idx.append(i)
	for i in range(idx.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := idx[i]
		idx[i] = idx[j]
		idx[j] = tmp
	for k in mini(count, idx.size()):
		_kind[idx[k]] = what
		_born[idx[k]] = _clock

## Disparo de un jugador donde apunta. Devuelve el resultado (Result), o -1 si ahora no puede disparar.
func _fire(p: PlayerData) -> int:
	if float(_cool[p.id]) > 0.0 or float(_stun[p.id]) > 0.0 or _phase != Phase.PLAY:
		return -1
	var s := slot_at(float(_aim[p.id]))
	var res: Result = Result.MISS
	if s != NO_SLOT and _kind[s] == TARGET:
		res = result_for_age(_clock - _born[s])
		_kind[s] = EMPTY
	elif s != NO_SLOT and _kind[s] == BOMB:
		res = Result.BANG
		_kind[s] = EMPTY
		_stun[p.id] = STUN_TIME
		_bombs_hit[p.id] = int(_bombs_hit[p.id]) + 1
	var pts: int = POINTS[res]
	var before: int = _scores[p.id]
	_scores[p.id] = maxi(0, before + pts)
	_cool[p.id] = MISS_LOCK if res == Result.MISS else SHOT_COOLDOWN
	DevCli.log_event("diligent_shots shot id=%d slot=%d res=%d score=%d" % [p.id, s, int(res), _scores[p.id]])
	send_event("shot", {"p": p.id, "s": s, "r": int(res), "v": int(_scores[p.id]) - before, "x": float(_aim[p.id])})
	return int(res)

## Clic de un jugador (cualquier PC): "s:<hueco>" apunta a ese hueco y dispara; "s:-1" dispara donde apunta.
func _on_player_text(player: PlayerData, text: String, _final: bool) -> void:
	if _phase != Phase.PLAY or not text.begins_with("s:") or not text.substr(2).is_valid_int():
		return
	if player == null:
		player = _mouse_player()
	if player == null or InputManager.is_simulated(player.id) or float(_stun[player.id]) > 0.0:
		return
	var s := text.substr(2).to_int()
	if s >= slot_count():
		return
	if s >= 0:
		_aim[player.id] = slot_x(s)
	_fire(player)

## Más puntos primero; a igualdad, menos bombas tocadas.
func build_ranking() -> Array[int]:
	var tb := {}
	for p in players:
		tb[p.id] = float(_bombs_hit[p.id])
	return rank_by_score(_scores, tb)

# --- Bots y autopiloto: van a la diana libre más cercana y disparan al tenerla en la mira ---

func _bot_move(player: PlayerData) -> Vector2:
	var s := _bot_choose(player)
	if s == NO_SLOT:
		return Vector2.ZERO
	var dx := slot_x(s) - float(_aim[player.id])
	return Vector2(clampf(dx / 28.0, -1.0, 1.0), 0.0)

func _bot_action(player: PlayerData) -> int:
	var s: int = _bot_slot.get(player.id, NO_SLOT)
	if s == NO_SLOT or float(_cool[player.id]) > 0.0 or _clock < float(_bot_ready[player.id]):
		return 0
	if absf(slot_x(s) - float(_aim[player.id])) < slot_radius() * 0.55:
		return 1
	return 0

## Hueco al que va el bot ahora mismo (NO_SLOT = esperar).
func _bot_choose(player: PlayerData) -> int:
	if _clock < float(_bot_ready[player.id]) or float(_stun[player.id]) > 0.0:
		_bot_slot[player.id] = NO_SLOT
		return NO_SLOT
	var want := TARGET
	if _wave == Wave.BOMBS:
		if not _bot_reckless[player.id]:
			_bot_slot[player.id] = NO_SLOT
			return NO_SLOT
		want = BOMB            # "se le escapa el dedo"
	var cur: int = _bot_slot[player.id]
	if cur != NO_SLOT and _kind[cur] == want:
		return cur
	var best := NO_SLOT
	var best_d := INF
	var ax: float = _aim[player.id]
	for i in slot_count():
		if _kind[i] != want:
			continue
		var d := absf(slot_x(i) - ax) + _bot_rng.randf() * spacing() * 1.5
		if d < best_d:
			best_d = d
			best = i
	_bot_slot[player.id] = best
	return best

# ----------------------------------------------------------------------------
# Estado hacia los clientes
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var aims := PackedFloat32Array()
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
		if a is PackedFloat32Array and i < a.size():
			_aim[id] = a[i]
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
			var s := int(data.get("s", NO_SLOT))
			var res := int(data.get("r", Result.MISS))
			var v := int(data.get("v", 0))
			var x := float(data.get("x", _aim.get(who.id, 640.0)))
			_flash[who.id] = 1.0
			_aim[who.id] = x
			_aim_draw[who.id] = x
			if s >= 0 and s < _kind.size() and res != Result.MISS:
				_kind[s] = EMPTY
				_prev_kind[s] = EMPTY
				_slot_fx[s] = 1.0
				_slot_fx_kind[s] = BOMB if res == Result.BANG else TARGET
			if res == Result.BANG:
				_stun[who.id] = STUN_TIME
			_scores[who.id] = maxi(0, int(_scores.get(who.id, 0)) + v)
			var label: String = ("%+d " % v if v != 0 else "") + String(LABELS[res])
			var col := Palette.YELLOW if res == Result.EXCELLENT else (Palette.MINT if res == Result.GOOD else Palette.WHITE)
			if res == Result.BANG or res == Result.MISS:
				col = Palette.CORAL
			_popups.append({"pos": Vector2(x, ROW_Y - 58.0), "text": label, "color": col, "age": 0.0,
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
		var m := surface.get_local_mouse_position()
		var s := NO_SLOT
		if absf(m.y - ROW_Y) < 90.0:
			s = slot_at(m.x)
		submit_text("s:%d" % s)

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
	for p in players:
		_aim_draw[p.id] = lerpf(float(_aim_draw[p.id]), float(_aim[p.id]), minf(1.0, delta * 22.0))
		_flash[p.id] = maxf(0.0, float(_flash[p.id]) - delta * 6.0)
		if _gain.has(p.id):
			_gain[p.id]["age"] = float(_gain[p.id]["age"]) + delta
	var bombs_out := false
	var targets_out := false
	for i in _kind.size():
		if _kind[i] != _prev_kind[i]:
			if _kind[i] != EMPTY:
				_slot_pop[i] = 0.0
				if _kind[i] == BOMB:
					bombs_out = true
				else:
					targets_out = true
			_prev_kind[i] = _kind[i]
		_slot_pop[i] = minf(1.0, _slot_pop[i] + delta * 7.0)
		_slot_fx[i] = maxf(0.0, _slot_fx[i] - delta * 2.5)
	if is_running and _phase == Phase.PLAY:
		if bombs_out:
			Audio.sfx(&"release", -6.0)
		elif targets_out:
			Audio.sfx(&"flip_up", -4.0)
	for pop in _popups:
		pop["age"] = float(pop["age"]) + delta
	_popups = _popups.filter(func(pop: Dictionary) -> bool: return float(pop["age"]) < 1.1)
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
	for i in slot_count():
		_draw_slot(i)
	for i in players.size():
		_draw_laser(i)
	for i in players.size():
		_draw_player(i)
	_draw_popups()
	_draw_hud()

## Caseta de feria: fondo de tablones, toldo y mostrador.
func _draw_booth() -> void:
	var s := surface
	var left := row_left() - 40.0
	var right := row_right() + 40.0
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
	# Bandas de color de cada jugador detrás de su tramo de huecos.
	var per := slots_per_player(players.size())
	for i in players.size():
		var x0 := slot_x(i * per) - spacing() * 0.48
		var x1 := slot_x(i * per + per - 1) + spacing() * 0.48
		s.rounded_rect(Rect2(x0, ROW_Y - slot_radius() - 14.0, x1 - x0, slot_radius() * 2.0 + 28.0), 14, Color(players[i].color, 0.22))
	# Mostrador.
	s.draw_rect(Rect2(left - 24, bottom, right - left + 48, 26), Color("C98F55"))
	s.draw_rect(Rect2(left - 24, bottom + 26, right - left + 48, 10), Color("6E4227"))

func _draw_slot(i: int) -> void:
	var s := surface
	var c := Vector2(slot_x(i), ROW_Y)
	var r := slot_radius()
	var owner_col := players[slot_owner(i)].color
	# Aro del hueco (color del tramo).
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

func _gun_tip(i: int) -> Vector2:
	var p := players[i]
	var base := Vector2(player_x(i), PLAYER_Y)
	var dir := (Vector2(float(_aim_draw[p.id]), ROW_Y) - base).normalized()
	return base + dir * (_avatar_r() + 26.0)

func _avatar_r() -> float:
	return 36.0 if players.size() <= 5 else 30.0

func _draw_laser(i: int) -> void:
	var s := surface
	var p := players[i]
	if float(_stun[p.id]) > 0.0 or _phase != Phase.PLAY:
		return
	var target := Vector2(float(_aim_draw[p.id]), ROW_Y)
	var tip := _gun_tip(i)
	s.draw_line(tip, target, Color(p.color, 0.55), 3.0, true)
	s.draw_line(tip, target, Color(1, 1, 1, 0.35), 1.0, true)
	var on := slot_at(target.x) != NO_SLOT
	var rr := 13.0 if on else 10.0
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
	var winner := _phase == Phase.END and build_ranking_visual()[0] == p.id
	if winner:
		s.draw_circle(c, r + 14.0, Color(Palette.YELLOW, 0.4 + 0.15 * sin(_time * 6.0)))
	var aim_pt := Vector2(float(_aim_draw[p.id]), ROW_Y)
	var dir := (aim_pt - c).normalized()
	if stunned:
		# Tumbado y con estrellas dando vueltas.
		s.draw_set_transform(c + Vector2(0, 10), 1.35, Vector2(1.0, 0.9))
		AvatarPainter.paint(s, Vector2.ZERO, r, p.color, Vector2.ZERO)
		s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		for k in 3:
			var a := _time * 5.0 + TAU * k / 3.0
			var st := c + Vector2(cos(a) * r * 0.9, -r - 6.0 + sin(a) * 8.0)
			_star(st, 8.0, Palette.YELLOW)
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
	var box := Rect2(c.x - 54.0, c.y + r + 18.0, 108.0, 38.0)
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
			s.text_centered(Vector2(c.x + 46.0, box.position.y - 6.0 - age * 22.0), "%+d" % v, 22, Color(col, 1.0 - age), 5)

func _star(c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for k in 10:
		var rad := r if k % 2 == 0 else r * 0.45
		pts.append(c + Vector2.from_angle(-PI * 0.5 + TAU * k / 10.0) * rad)
	surface.draw_colored_polygon(pts, col)

## Ranking para dibujar (igual que el del host; los clientes lo calculan con los puntos que reciben).
func build_ranking_visual() -> Array[int]:
	return build_ranking()

func _draw_popups() -> void:
	for pop in _popups:
		var age: float = pop["age"]
		var a := clampf(1.0 - (age - 0.6) / 0.5, 0.0, 1.0)
		var big: bool = pop["big"]
		var size := 30 if big else 22
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
	var hint := "¡Dispara a las dianas antes que nadie!"
	if _kind.has(BOMB) and not _kind.has(TARGET):
		hint = "¡BOMBAS! No dispares…"
	elif _kind.has(BOMB):
		hint = "¡Ojo, hay bombas entre las dianas!"
	var me := _hud_player()
	if me != null and float(_stun[me.id]) > 0.0:
		hint = "¡Aturdido!"
	s.text_centered(Vector2(640, 52), hint, 30, Palette.CORAL if hint.begins_with("¡BOMBAS") or hint == "¡Aturdido!" else Palette.WHITE, 7)

## Jugador al que se le habla en el texto de ayuda: el de este PC (online) o ninguno (varios en un PC).
func _hud_player() -> PlayerData:
	if local_player != null:
		return local_player
	for p in players:
		if p.device == PlayerData.DEVICE_LOCAL:
			return p
	return null
