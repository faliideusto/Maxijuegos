extends Minigame
## Puente Personal (modelo HOST_AUTHORITATIVE): todos empiezan en una plataforma central rodeada de torres, cada
## una con su puente y un premio (+1, +2 o el dorado +3). Hay unos segundos para elegir puente EN SECRETO: con el
## RATÓN (clic en el puente o en su torre) o apuntando con la dirección (WASD / flechas / stick). Se puede cambiar
## de idea hasta que se acaba el tiempo. Entonces todos cruzan a la vez: si en un puente hay más de un jugador, se
## viene abajo y se quedan sin nada; quien cruza solo se lleva el premio de su torre. ¿Egoísta o no?
##
## Se adapta al nº de jugadores: hay jugadores + 1 puentes (mínimo 3), repartidos en círculo. 3 rondas; el oro
## cambia de sitio en cada una. Gana quien más puntos suma; a igualdad, quien menos veces se cayó.
##
## Secreto: durante la elección nadie ve el puente de nadie (solo el suyo y, a todos, quién ya ha elegido). Las
## elecciones no viajan a los clientes hasta el destape. El clic de un cliente llega al host por el canal de texto
## del minijuego (submit_text("b:<n>")); la dirección, por la entrada normal. Sin código de red propio.

enum Phase { CHOOSE, CROSS, RESULT, END }

const CENTER := Vector2(640, 372)
const RING := Vector2(478, 232)       # semiejes de la elipse en la que están las torres
const HUB_R := 104.0                  # radio de la plataforma central
const TOWER_R := 50.0
const BRIDGE_W := 34.0
const ROUNDS := 3
const CHOOSE_TIME := 8.0
const CROSS_TIME := 2.2
const BREAK_AT := 0.5                 # parte del cruce en la que cede un puente compartido
const RESULT_TIME := 1.6
const END_TIME := 2.6
const DIR_DEADZONE := 0.55
const NO_PICK := -1
const GOLD := 3

var _phase: Phase = Phase.CHOOSE
var _round: int = 0
var _t: float = 0.0                   # tiempo dentro de la fase
var _prizes: PackedByteArray = []     # premio de cada puente en esta ronda
var _picks: Dictionary = {}           # id -> puente elegido (host; en clientes solo tras el destape)
var _chosen: Dictionary = {}          # id -> bool: ya eligió (lo ven todos)
var _scores: Dictionary = {}          # id -> puntos
var _falls: Dictionary = {}           # id -> veces que se cayó
var _broken: PackedByteArray = []     # 1 si el puente se rompió en esta ronda
var _dir_pick: Dictionary = {}        # id -> último puente señalado con la dirección (para no pisar un clic)
var _bot_plan: Dictionary = {}        # id -> {"at": s, "b": puente}
# Solo visual / local
var _my_pick: int = NO_PICK           # elección del jugador del ratón en ESTE PC (los clientes no saben la del resto)
var _my_dir_pick: int = NO_PICK
var _hover: int = NO_PICK
var _time: float = 0.0
var _pop: Dictionary = {}             # id -> rebote al elegir (1 → 0)
var _last_sec: int = 0

# ----------------------------------------------------------------------------
# Preparación
# ----------------------------------------------------------------------------

func _on_prepare() -> void:
	for p in players:
		_scores[p.id] = 0
		_falls[p.id] = 0
		_pop[p.id] = 0.0
	_broken.resize(bridge_count())
	_new_round_prizes(0)
	surface.draw_callback = _draw_game

func _on_start() -> void:
	_start_round(0)
	DevCli.log_event("personal_bridge start bridges=%d" % bridge_count())

## Puentes según los jugadores: uno más que jugadores (mínimo 3, máximo 9).
func bridge_count() -> int:
	return clampi(players.size() + 1, 3, 9)

## Premios de una ronda: un oro (+3), un +2 si hay 4 puentes o más, el resto +1. El orden sale de la semilla común.
static func prizes_for(count: int, r: RandomNumberGenerator) -> PackedByteArray:
	var list: Array[int] = [GOLD]
	if count >= 4:
		list.append(2)
	while list.size() < count:
		list.append(1)
	for i in range(list.size() - 1, 0, -1):
		var j := r.randi_range(0, i)
		var tmp := list[i]
		list[i] = list[j]
		list[j] = tmp
	return PackedByteArray(list)

func _new_round_prizes(_r: int) -> void:
	_prizes = prizes_for(bridge_count(), rng)

func _start_round(r: int) -> void:
	_round = r
	_phase = Phase.CHOOSE
	_t = 0.0
	_last_sec = 0
	if r > 0:
		_new_round_prizes(r)
	_broken.fill(0)
	_my_pick = NO_PICK
	_my_dir_pick = NO_PICK
	for p in players:
		_picks[p.id] = NO_PICK
		_chosen[p.id] = false
		_dir_pick[p.id] = NO_PICK
		# Bots: eligen en un momento al azar. El oro tienta (más cuanto menos jugadores).
		var b := _bot_choice()
		_bot_plan[p.id] = {"at": rng.randf_range(1.2, CHOOSE_TIME - 1.0), "b": b}

func _bot_choice() -> int:
	var gold := Array(_prizes).find(GOLD)
	var roll := rng.randf()
	if roll < 0.3 + 0.25 / float(players.size()):
		return gold
	var silver := Array(_prizes).find(2)
	if silver >= 0 and roll < 0.55:
		return silver
	return rng.randi_range(0, bridge_count() - 1)

# ----------------------------------------------------------------------------
# Simulación (solo host)
# ----------------------------------------------------------------------------

func _simulate(delta: float) -> void:
	_t += delta
	match _phase:
		Phase.CHOOSE:
			for p in players:
				action_presses(p)            # se consumen (el clic también es "acción" y aquí no hace nada)
				if InputManager.is_simulated(p.id):
					var plan: Dictionary = _bot_plan[p.id]
					if _t >= float(plan.at) and _picks[p.id] != plan.b:
						_set_pick(p, int(plan.b))
				else:
					var b := _bridge_from_dir(move_input(p))
					if b != NO_PICK and b != _dir_pick[p.id]:
						_dir_pick[p.id] = b
						_set_pick(p, b)
			if _t >= CHOOSE_TIME:
				_resolve()
		Phase.CROSS:
			if _t >= CROSS_TIME:
				_phase = Phase.RESULT
				_t = 0.0
		Phase.RESULT:
			if _t >= RESULT_TIME:
				if _round + 1 < ROUNDS:
					_start_round(_round + 1)
					send_event("round", {"r": _round, "pz": _prizes})
				else:
					_phase = Phase.END
					_t = 0.0
					send_event("end")
		Phase.END:
			if _t >= END_TIME:
				finish(build_ranking())

## Clic de un jugador (cualquier PC): "b:<puente>". En partida local llega sin dueño → el jugador del ratón.
func _on_player_text(player: PlayerData, text: String, _final: bool) -> void:
	if _phase != Phase.CHOOSE or not text.begins_with("b:"):
		return
	if player == null:
		player = _mouse_player()
	if player == null or InputManager.is_simulated(player.id):
		return
	var b := text.substr(2).to_int()
	if b < 0 or b >= bridge_count() or not text.substr(2).is_valid_int():
		return
	_set_pick(player, b)

func _set_pick(p: PlayerData, b: int) -> void:
	if _picks[p.id] == b:
		return
	var first: bool = not _chosen[p.id]
	_picks[p.id] = b
	_chosen[p.id] = true
	send_event("pick", {"p": p.id, "f": first})

## Fin del tiempo de elegir: se destapan las elecciones, se rompen los puentes compartidos y se reparten premios.
func _resolve() -> void:
	var count := {}
	for p in players:
		var b: int = _picks[p.id]
		if b != NO_PICK:
			count[b] = int(count.get(b, 0)) + 1
	_broken.fill(0)
	for b in count:
		if count[b] > 1:
			_broken[b] = 1
	for p in players:
		var b: int = _picks[p.id]
		if b == NO_PICK:
			continue
		if _broken[b] == 1:
			_falls[p.id] += 1
		else:
			_scores[p.id] += _prizes[b]
	_phase = Phase.CROSS
	_t = 0.0
	var picks := PackedInt32Array()
	for p in players:
		picks.append(_picks[p.id])
	DevCli.log_event("personal_bridge round=%d picks=%s broken=%s" % [_round, picks, _broken])
	send_event("reveal", {"pk": picks, "br": _broken, "sc": _score_array()})

func _score_array() -> PackedInt32Array:
	var a := PackedInt32Array()
	for p in players:
		a.append(_scores[p.id])
	return a

## Más puntos primero; a igualdad, menos caídas.
func build_ranking() -> Array[int]:
	var fl := {}
	for p in players:
		fl[p.id] = float(_falls[p.id])
	return rank_by_score(_scores, fl)

func _bot_action(_player: PlayerData) -> int:
	return 0

# ----------------------------------------------------------------------------
# Entrada local: ratón y dirección
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
	if not is_running or _phase != Phase.CHOOSE or surface == null:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var me := _mouse_player()
		if me == null or InputManager.is_simulated(me.id):
			return
		var b := bridge_at(surface.get_local_mouse_position())
		if b != NO_PICK:
			_my_pick = b
			submit_text("b:%d" % b)

## (todos los PC) Lo que ve el jugador de este PC de su propia elección con la dirección, sin esperar al host.
func _local_dir_update() -> void:
	var me := _mouse_player()
	if me == null or InputManager.is_simulated(me.id):
		return
	var b := _bridge_from_dir(InputManager.get_vector(me.id))
	if b != NO_PICK and b != _my_dir_pick:
		_my_dir_pick = b
		_my_pick = b

func _bridge_from_dir(v: Vector2) -> int:
	if v.length() < DIR_DEADZONE:
		return NO_PICK
	var best := NO_PICK
	var best_dot := -2.0
	for b in bridge_count():
		var d := v.normalized().dot((tower_pos(b) - CENTER).normalized())
		if d > best_dot:
			best_dot = d
			best = b
	return best

## Puente bajo un punto de la pantalla (su torre o el propio puente), o NO_PICK.
func bridge_at(pos: Vector2) -> int:
	for b in bridge_count():
		var tp := tower_pos(b)
		if pos.distance_to(tp) <= TOWER_R + 8.0:
			return b
		var a := bridge_start(b)
		var e := bridge_end(b)
		var q := Geometry2D.get_closest_point_to_segment(pos, a, e)
		if pos.distance_to(q) <= BRIDGE_W * 0.5 + 10.0:
			return b
	return NO_PICK

# ----------------------------------------------------------------------------
# Estado hacia los clientes
# ----------------------------------------------------------------------------

func _serialize_state() -> Variant:
	var ch := PackedByteArray()
	for p in players:
		ch.append(1 if _chosen[p.id] else 0)
	var d := {"ph": int(_phase), "t": _t, "r": _round, "pz": _prizes, "ch": ch, "sc": _score_array()}
	if _phase != Phase.CHOOSE:
		var pk := PackedInt32Array()
		for p in players:
			pk.append(_picks[p.id])
		d["pk"] = pk
		d["br"] = _broken
	return d

func _apply_state(state: Variant) -> void:
	if not state is Dictionary:
		return
	var d: Dictionary = state
	var ph := int(d.get("ph", _phase)) as Phase
	var r := int(d.get("r", _round))
	if r != _round or (ph == Phase.CHOOSE and _phase != Phase.CHOOSE):
		_client_new_round(r)
	_phase = ph
	var t := float(d.get("t", _t))
	if absf(t - _t) > 0.12:
		_t = t
	var pz: Variant = d.get("pz")
	if pz is PackedByteArray and pz.size() == bridge_count():
		_prizes = pz
	var ch: Variant = d.get("ch")
	if ch is PackedByteArray:
		for i in mini(ch.size(), players.size()):
			_chosen[players[i].id] = ch[i] != 0
	_apply_scores(d.get("sc"))
	_apply_picks(d.get("pk"), d.get("br"))

func _client_new_round(r: int) -> void:
	_round = r
	_t = 0.0
	_my_pick = NO_PICK
	_my_dir_pick = NO_PICK
	_broken.fill(0)
	for p in players:
		_picks[p.id] = NO_PICK
		_chosen[p.id] = false

func _apply_scores(sc: Variant) -> void:
	if sc is PackedInt32Array:
		for i in mini(sc.size(), players.size()):
			_scores[players[i].id] = sc[i]

func _apply_picks(pk: Variant, br: Variant) -> void:
	if pk is PackedInt32Array:
		for i in mini(pk.size(), players.size()):
			_picks[players[i].id] = pk[i]
	if br is PackedByteArray and br.size() == _broken.size():
		_broken = br

func _on_event(event_name: String, data: Variant) -> void:
	match event_name:
		"pick":
			var who := _player_by_id(int(data.get("p", -1))) if data is Dictionary else null
			if who == null:
				return
			_chosen[who.id] = true
			if bool(data.get("f", false)):
				_pop[who.id] = 1.0
				Audio.sfx(&"claim" if is_audible(who) else &"ui_hover", -4.0 if is_audible(who) else -9.0)
			elif is_audible(who):
				Audio.sfx(&"ui_click", -6.0)
		"reveal":
			if not data is Dictionary:
				return
			if not is_authority:
				_phase = Phase.CROSS
				_t = 0.0
				_apply_picks(data.get("pk"), data.get("br"))
				_apply_scores(data.get("sc"))
			Audio.sfx(&"stinger", -4.0)
		"round":
			if not is_authority and data is Dictionary:
				_client_new_round(int(data.get("r", _round + 1)))
				_phase = Phase.CHOOSE
				var pz: Variant = data.get("pz")
				if pz is PackedByteArray and pz.size() == bridge_count():
					_prizes = pz
			Audio.sfx(&"swoosh", -6.0)
		"end":
			if not is_authority:
				_phase = Phase.END
				_t = 0.0
			Audio.sfx(&"fanfare_small", -4.0)

func _player_by_id(id: int) -> PlayerData:
	for p in players:
		if p.id == id:
			return p
	return null

# ----------------------------------------------------------------------------
# Animación (todos los PC)
# ----------------------------------------------------------------------------

var _sfx_broke: bool = false
var _sfx_prize: bool = false

func _animate(delta: float) -> void:
	_time += delta
	for p in players:
		_pop[p.id] = maxf(0.0, float(_pop[p.id]) - delta * 3.5)
	if not is_running:
		return
	if not is_authority:
		_t += delta
	if surface != null:
		_hover = bridge_at(surface.get_local_mouse_position()) if _phase == Phase.CHOOSE else NO_PICK
	match _phase:
		Phase.CHOOSE:
			_sfx_broke = false
			_sfx_prize = false
			_local_dir_update()
			var sec := ceili(CHOOSE_TIME - _t)
			if sec != _last_sec and sec <= 3 and sec > 0:
				Audio.sfx(&"beep", -7.0)
			_last_sec = sec
		Phase.CROSS:
			if not _sfx_broke and _t >= CROSS_TIME * BREAK_AT and _broken.has(1):
				_sfx_broke = true
				Audio.sfx(&"plat_crack", -3.0)
				Audio.sfx(&"plat_fall", -5.0)
			if not _sfx_prize and _t >= CROSS_TIME * 0.85:
				_sfx_prize = true
				if _anyone_scored():
					Audio.sfx(&"coin_gold", -5.0)

func _anyone_scored() -> bool:
	for p in players:
		var b: int = _picks[p.id]
		if b != NO_PICK and _broken[b] == 0:
			return true
	return false

# ----------------------------------------------------------------------------
# Geometría
# ----------------------------------------------------------------------------

func _angle(b: int) -> float:
	return -PI * 0.5 + TAU * float(b) / float(bridge_count())

func tower_pos(b: int) -> Vector2:
	var a := _angle(b)
	return CENTER + Vector2(cos(a) * RING.x, sin(a) * RING.y)

func bridge_start(b: int) -> Vector2:
	return CENTER + (tower_pos(b) - CENTER).normalized() * (HUB_R - 6.0)

func bridge_end(b: int) -> Vector2:
	return tower_pos(b) - (tower_pos(b) - CENTER).normalized() * (TOWER_R - 6.0)

## Sitio de cada jugador en la plataforma central.
func hub_slot(i: int) -> Vector2:
	if players.size() == 1:
		return CENTER
	var a := -PI * 0.5 + TAU * float(i) / float(players.size()) + PI / float(players.size())
	return CENTER + Vector2.from_angle(a) * (HUB_R * 0.56)

## Posición de un jugador ahora mismo (en el centro o cruzando su puente).
func player_pos(i: int) -> Vector2:
	var p := players[i]
	var home := hub_slot(i)
	var b: int = _picks.get(p.id, NO_PICK)
	if _phase == Phase.CHOOSE or b == NO_PICK:
		return home
	var k := 1.0 if _phase != Phase.CROSS else clampf(_t / (CROSS_TIME * 0.8), 0.0, 1.0)
	k = k * k * (3.0 - 2.0 * k)
	var stop := tower_pos(b)
	if _broken[b] == 1:
		k = minf(k, 0.55)
		stop = (bridge_start(b) + bridge_end(b)) * 0.5
		# Varios en el mismo puente: cada uno un poco desplazado.
		var n := 0
		for j in i:
			if _picks.get(players[j].id, NO_PICK) == b:
				n += 1
		var side := (tower_pos(b) - CENTER).normalized().orthogonal()
		stop += side * (float(n) - 0.5) * 22.0
		return home.lerp(stop, k / 0.55)
	return home.lerp(stop, k)

## Parte de la caída (0 = en pie, 1 = desaparecido) de un jugador cuyo puente se rompió.
func fall_amount(i: int) -> float:
	var b: int = _picks.get(players[i].id, NO_PICK)
	if b == NO_PICK or _broken[b] == 0 or _phase == Phase.CHOOSE:
		return 0.0
	if _phase != Phase.CROSS:
		return 1.0
	return clampf((_t - CROSS_TIME * BREAK_AT) / 0.7, 0.0, 1.0)

func _bridge_collapse(b: int) -> float:
	if _broken[b] == 0 or _phase == Phase.CHOOSE:
		return 0.0
	if _phase != Phase.CROSS:
		return 1.0
	return clampf((_t - CROSS_TIME * BREAK_AT) / 0.6, 0.0, 1.0)

# ----------------------------------------------------------------------------
# Dibujo
# ----------------------------------------------------------------------------

const PLANK := Color("B98A5A")
const PLANK_DARK := Color("7C5634")
const STONE := Color("8F84D6")
const STONE_TOP := Color("C9C1F5")
const CHASM := Color(0.08, 0.04, 0.22, 0.45)

func _draw_game() -> void:
	var s := surface
	# Abismo: sombra bajo toda la estructura.
	s.draw_set_transform(CENTER + Vector2(0, 24), 0.0, Vector2(1.0, RING.y / RING.x))
	s.draw_circle(Vector2.ZERO, RING.x + 70.0, CHASM)
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	for b in bridge_count():
		_draw_bridge(b)
	for b in bridge_count():
		_draw_tower(b)
	_draw_hub()
	# Los que se caen, debajo de los que están en pie.
	for i in players.size():
		if fall_amount(i) > 0.0:
			_draw_player(i)
	for i in players.size():
		if fall_amount(i) == 0.0:
			_draw_player(i)
	_draw_hud()
	_draw_scores()

## Jugadores cuya elección de `b` se puede mostrar en este PC.
func _visible_pick_owner(b: int) -> Array[PlayerData]:
	var out: Array[PlayerData] = []
	if _phase != Phase.CHOOSE:
		for p in players:
			if _picks.get(p.id, NO_PICK) == b:
				out.append(p)
		return out
	var me := _mouse_player()
	if me != null and _my_pick == b and not InputManager.is_simulated(me.id):
		out.append(me)
	# Partida local: varias personas en el mismo PC (no hay secreto posible): sus elecciones se ven.
	if is_authority and not NetworkManager.is_online:
		for p in players:
			if p != me and p.is_local_human and not InputManager.is_simulated(p.id) and _picks.get(p.id, NO_PICK) == b:
				out.append(p)
	return out

func _draw_bridge(b: int) -> void:
	var s := surface
	var a := bridge_start(b)
	var e := bridge_end(b)
	var dir := (e - a).normalized()
	var side := dir.orthogonal()
	var col := _bridge_collapse(b)
	var mine := _visible_pick_owner(b)
	var hl := _phase == Phase.CHOOSE and (_hover == b or not mine.is_empty())
	if hl:
		var c := mine[0].color if not mine.is_empty() else Palette.WHITE
		s.draw_line(a, e, Color(c, 0.55 + 0.2 * sin(_time * 6.0)), BRIDGE_W + 16.0, true)
	# Barandillas (cuerdas) y tablones; al romperse, los tablones del centro caen girando.
	var planks := int(a.distance_to(e) / 15.0)
	if col == 0.0:
		s.draw_line(a + side * BRIDGE_W * 0.5, e + side * BRIDGE_W * 0.5, PLANK_DARK, 4.0, true)
		s.draw_line(a - side * BRIDGE_W * 0.5, e - side * BRIDGE_W * 0.5, PLANK_DARK, 4.0, true)
	for k in planks:
		var f := (float(k) + 0.5) / float(planks)
		var c := a.lerp(e, f)
		var drop := 0.0
		var alpha := 1.0
		var rot := 0.0
		if col > 0.0 and k > 0 and k < planks - 1:     # quedan los tablones de los extremos
			var mid := absf(f - 0.5) * 2.0          # los del centro caen antes
			var local := clampf(col * 1.6 - mid * 0.6, 0.0, 1.0)
			drop = local * local * 140.0
			alpha = 1.0 - local
			rot = local * (1.5 if k % 2 == 0 else -1.8)
			if alpha <= 0.0:
				continue
		var half := side * BRIDGE_W * 0.5
		var along := dir * 5.5
		s.draw_set_transform(c + Vector2(0, drop), rot, Vector2.ONE)
		var pts := PackedVector2Array([-half - along, half - along, half + along, -half + along])
		s.draw_colored_polygon(pts, Color(PLANK if k % 2 == 0 else PLANK.darkened(0.08), alpha))
		s.draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[0]]), Color(PLANK_DARK, alpha), 2.0, true)
		s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_tower(b: int) -> void:
	var s := surface
	var c := tower_pos(b)
	var prize: int = _prizes[b] if b < _prizes.size() else 1
	s.draw_circle(c + Vector2(0, 16), TOWER_R, STONE.darkened(0.35))
	s.draw_rect(Rect2(c.x - TOWER_R, c.y, TOWER_R * 2.0, 16.0), STONE.darkened(0.35))
	s.draw_circle(c, TOWER_R, STONE)
	s.draw_circle(c, TOWER_R - 7.0, STONE_TOP)
	if _hover == b:
		s.draw_arc(c, TOWER_R + 3.0, 0.0, TAU, 48, Palette.WHITE, 4.0, true)
	# Premio: moneda que flota (el oro brilla). Se "recoge" cuando alguien llega solo.
	var taken := _phase != Phase.CHOOSE and _broken[b] == 0 and not _visible_pick_owner(b).is_empty() \
			and (_phase != Phase.CROSS or _t >= CROSS_TIME * 0.8)
	var coin_c := Palette.YELLOW if prize >= GOLD else (Palette.TEAL if prize == 2 else Palette.MINT)
	var bob := sin(_time * 3.0 + float(b)) * 4.0
	var cp := c + Vector2(0, -12.0 + bob)
	if taken:
		if _phase == Phase.CROSS or _phase == Phase.RESULT:
			var k := clampf((_t - CROSS_TIME * 0.8) / 0.5, 0.0, 1.0) if _phase == Phase.CROSS else 1.0
			cp += Vector2(0, -44.0 * k)
			s.text_centered(cp, "+%d" % prize, 36, Palette.YELLOW if prize >= GOLD else Palette.WHITE, 8)
		return
	if prize >= GOLD:
		s.draw_circle(cp, 30.0 + 3.0 * sin(_time * 5.0), Color(Palette.YELLOW, 0.3))
	s.draw_circle(cp + Vector2(0, 4), 22.0, coin_c.darkened(0.35))
	s.draw_circle(cp, 22.0, coin_c)
	s.text_centered(cp, "+%d" % prize, 22, Palette.PURPLE_DARK if prize >= GOLD else Palette.WHITE, 0 if prize >= GOLD else 4)

func _draw_hub() -> void:
	var s := surface
	s.draw_circle(CENTER + Vector2(0, 18), HUB_R, STONE.darkened(0.35))
	s.draw_rect(Rect2(CENTER.x - HUB_R, CENTER.y, HUB_R * 2.0, 18.0), STONE.darkened(0.35))
	s.draw_circle(CENTER, HUB_R, STONE)
	s.draw_circle(CENTER, HUB_R - 8.0, STONE_TOP)
	# Bajo cada jugador, su marca: coral = aún no eligió, menta = ya eligió (sin decir cuál).
	if _phase == Phase.CHOOSE:
		for i in players.size():
			var on: bool = _chosen.get(players[i].id, false)
			s.draw_circle(hub_slot(i) + Vector2(0, 8), _avatar_r() + 5.0, Palette.MINT if on else Palette.CORAL)

func _avatar_r() -> float:
	return 22.0 if players.size() <= 5 else 18.0

func _draw_player(i: int) -> void:
	var s := surface
	var p := players[i]
	var c := player_pos(i)
	var r := _avatar_r()
	var fall := fall_amount(i)
	var look := Vector2.ZERO
	var b: int = _picks.get(p.id, NO_PICK)
	if _phase == Phase.CROSS and b != NO_PICK:
		look = (tower_pos(b) - CENTER).normalized()
	elif _phase == Phase.CHOOSE and is_local_player(p) and _my_pick != NO_PICK:
		look = (tower_pos(_my_pick) - CENTER).normalized()
	if fall > 0.0:
		c += Vector2(0, fall * fall * 120.0)
		r *= 1.0 - 0.7 * fall
		if fall >= 1.0:
			return
	var bp: float = _pop[p.id]
	s.draw_set_transform(c, fall * 3.0, Vector2(1.0 + 0.25 * bp, 1.0 - 0.25 * bp))
	AvatarPainter.paint(s, Vector2.ZERO, r, Color(p.color, 1.0 - fall * 0.5), look)
	s.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if fall > 0.0:
		return
	if _phase == Phase.END and build_ranking()[0] == p.id:
		AvatarPainter.paint_crown(s, c, r)
	elif is_local_player(p) and NetworkManager.is_online:
		draw_local_marker(c, r)

func _draw_hud() -> void:
	var s := surface
	var title := ""
	var col := Palette.WHITE
	match _phase:
		Phase.CHOOSE:
			var left := maxf(0.0, CHOOSE_TIME - _t)
			title = "Ronda %d/%d · Elige puente: %d" % [_round + 1, ROUNDS, ceili(left)]
			col = Palette.YELLOW if left <= 3.0 else Palette.WHITE
		Phase.CROSS, Phase.RESULT:
			title = "¡A cruzar!" if not _broken.has(1) else "¡Crack! Los puentes compartidos se caen"
		Phase.END:
			var w := _player_by_id(build_ranking()[0])
			if w != null:
				title = "¡%s GANA!" % w.display_name.to_upper()
				col = Palette.YELLOW
	s.text_centered(Vector2(640, 34), title, 34, col, 8)
	if _phase == Phase.CHOOSE:
		var me := _mouse_player()
		var hint := "Haz clic en un puente (o apunta con WASD / flechas). Si alguien elige el mismo, se cae."
		if me != null and _my_pick != NO_PICK:
			hint = "Has elegido el puente de +%d. Puedes cambiar hasta que acabe el tiempo." % _prizes[_my_pick]
		s.text_centered(Vector2(640, 72), hint, 20, Color(1, 1, 1, 0.9), 5)

## Marcador abajo: un chip por jugador con su puntuación.
func _draw_scores() -> void:
	var s := surface
	var n := players.size()
	var w := minf(150.0, 1240.0 / float(n) - 8.0)
	var x0 := 640.0 - (w + 8.0) * float(n) * 0.5 + 4.0
	for i in n:
		var p := players[i]
		var rect := Rect2(x0 + float(i) * (w + 8.0), 678.0, w, 34.0)
		s.rounded_rect(rect, 17, Palette.PURPLE_DARK)
		s.rounded_rect(Rect2(rect.position + Vector2(3, 3), Vector2(8, 28)), 4, p.color)
		var name := p.label()
		if name.length() > 9:
			name = name.substr(0, 8) + "…"
		s.text_centered(rect.position + Vector2(w * 0.5 - 8.0, 17.0), name, 16, Palette.WHITE, 0)
		s.text_centered(rect.position + Vector2(w - 16.0, 17.0), str(_scores.get(p.id, 0)), 22, Palette.YELLOW, 0)
