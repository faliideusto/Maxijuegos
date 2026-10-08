extends SceneTree
## Herramienta de desarrollo: genera el recorrido FIJO de Columpio de Lengua (tongue_level.gd).
## Va colocando ganchos de uno en uno con un bot-planificador que usa la física real del minijuego.
##
## Un gancho NUEVO solo se acepta si, con él ya puesto, el bot puede encadenar TODOS los ganchos
## pendientes (los tres últimos) con una ventana de suelta de al menos ±win s en cada uno: un gancho de
## delante puede cambiar a cuál se agarra la lengua, así que cada plan se valida con los ganchos
## siguientes ya colocados. Además, en cada tramo: la niebla no alcanza al bot y un error de suelta de
## media ventana deja a la rana en un estado desde el que aún se llega al gancho siguiente. El primer
## gancho pendiente se "compromete" cuando hay tres por delante. La dificultad sube con la distancia:
## más separación, ganchos frágiles y ventana de suelta más estrecha.
##   godot --headless --path . --script res://tools/gen_tongue_level.gd

const SCRIPT_PATH := "res://minigames/tongue_swing/tongue_swing.gd"
const OUT_PATH := "res://minigames/tongue_swing/tongue_level.gd"
const SEED := 424242
const TAIL := 70.0                # se sigue generando un poco más allá del final (cola sin verificar)
const MIN_LEAD_PATH := 1.2        # distancia mínima a la niebla en todo el trayecto
const MIN_LEAD_ARRIVE := 2.5      # y al agarrar cada gancho
const PENDING := 3                # ganchos por delante del comprometido que se validan juntos
const ROBUST_DEPTH := 2           # errores de suelta consecutivos que debe poder absorber el recorrido

var _done: bool = false
var _mg = null

## Valida la cadena s → c+1 → ... → r. Devuelve {} si falla o {"state","t"} del primer eslabón.
func _chain(s, c: int, r: int, t: float, wins: Array[float]) -> Dictionary:
	var cur = s
	var tt := t
	var first := {}
	for i in range(c + 1, r + 1):
		var plan: Dictionary = _mg._plan(cur, i, wins[i])
		if plan.is_empty():
			return {}
		var run: Dictionary = _mg._run_plan(cur, int(plan["k"]), i, tt)
		if run.is_empty() or float(run["min_lead"]) < MIN_LEAD_PATH:
			return {}
		var st = run["state"]
		var t2: float = tt + int(run["steps"]) * _mg.STEP
		if st.pos.x - _mg.chase_at(t2) < MIN_LEAD_ARRIVE:
			return {}
		if i == c + 1:
			# Un error de suelta de media ventana a cada lado tiene que ser recuperable, también si se repite
			# en los ganchos siguientes (hasta ROBUST_DEPTH seguidos).
			if not _robust_after(cur, plan, i, tt, r, wins, ROBUST_DEPTH):
				return {}
			first = {"state": st, "t": t2}
		cur = st
		tt = t2
	return first

func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_mg = (load(SCRIPT_PATH) as GDScript).new()
	var mg = _mg
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	mg._ax = PackedFloat64Array([0.0])
	mg._ay = PackedFloat64Array([12.0])
	mg._af = PackedByteArray([0])
	var wins: Array[float] = [0.2]
	var s = mg._start_state()      # agarrada al último gancho "comprometido" (índice c)
	var c := 0
	var hist_s: Array = [s]
	var hist_t: Array[float] = [0.0]
	var best_c := 0
	var fails := 0
	var t := 0.0
	var failed := false
	var rejected := 0
	while mg._ax[mg._ax.size() - 1] < mg.LEVEL_END + TAIL:
		var n: int = mg._ax.size()
		var x: float = mg._ax[n - 1]
		var y: float = mg._ay[n - 1]
		var d := clampf(x / 600.0, 0.0, 1.0)
		var target_sp := lerpf(5.5, 11.0, d)
		var win := lerpf(0.20, 0.09, d)
		var frag_p := 0.0 if x < 110.0 else lerpf(0.06, 0.42, d)
		var accepted := false
		for attempt in 90:
			var factor := 1.0 - attempt * 0.0085
			var sp: float = maxf(target_sp * factor * rng.randf_range(0.85, 1.1), 3.0)
			var ny: float = clampf(y + rng.randf_range(-3.2, 2.2), 8.0, 13.2)
			var frag: bool = rng.randf() < frag_p and not (mg._af[n - 1] == 1 and rng.randf() < 0.5)
			mg._ax.append(snappedf(x + sp, 0.001))   # se guarda con 3 decimales: el bot tiene que ver lo mismo
			mg._ay.append(snappedf(ny, 0.001))
			mg._af.append(1 if frag else 0)
			wins.append(win)
			var r: int = mg._ax.size() - 1
			var res := _chain(s, c, r, t, wins)
			if not res.is_empty():
				if r >= c + PENDING:
					s = res["state"]
					t = res["t"]
					c += 1
					hist_s.append(s)
					hist_t.append(t)
					if c > best_c:
						best_c = c
						fails = 0
				accepted = true
				break
			rejected += 1
			mg._ax.remove_at(r)
			mg._ay.remove_at(r)
			mg._af.remove_at(r)
			wins.remove_at(r)
		if not accepted:
			# Callejón sin salida: se retrocede (cada vez más ganchos) y se vuelve a intentar con otros.
			fails += 1
			if fails > 400:
				print("NO SE PUDO colocar un gancho tras x=%.1f (t=%.1f s, c=%d)" % [x, t, c])
				failed = true
				break
			var new_c := maxi(c - (1 + fails / 4), 0)
			var keep := mini(new_c + PENDING, mg._ax.size())
			while mg._ax.size() > keep:
				var last: int = mg._ax.size() - 1
				mg._ax.remove_at(last)
				mg._ay.remove_at(last)
				mg._af.remove_at(last)
				wins.remove_at(last)
			s = hist_s[new_c]
			t = hist_t[new_c]
			c = new_c
			hist_s.resize(new_c + 1)
			hist_t.resize(new_c + 1)
	print("ganchos: %d, rechazados: %d, tiempo del bot: %.1f s, distancia: %.0f" % [mg._ax.size(), rejected, t, mg._ax[mg._ax.size() - 1]])
	if failed:
		quit(1)
		return true
	var parts: PackedStringArray = []
	for k in mg._ax.size():
		parts.append("%.3f, %.3f, %d.0" % [mg._ax[k], mg._ay[k], mg._af[k]])
	var text := "extends RefCounted\n## Recorrido de Columpio de Lengua (x, y, tipo por gancho: 0 normal, 1 frágil).\n"
	text += "## GENERADO con tools/gen_tongue_level.gd: no editar a mano.\n"
	text += "const DATA: Array = [\n\t" + ",\n\t".join(parts) + "\n]\n"
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	print("escrito ", OUT_PATH)
	quit(0)
	return true

## ¿Sigue habiendo plan si se suelta hasta `0,5·win` antes o después de lo planificado (`plan`) en el gancho
## i, y si ese error se repite en los siguientes (`depth` niveles)? En el primer nivel se prueban TODOS los
## instantes de suelta del rango (la viabilidad no es continua: puede haber "agujeros"); en los siguientes,
## los dos extremos. Solo se mira hasta el último gancho (r).
func _robust_after(s, plan: Dictionary, i: int, t: float, r: int, wins: Array[float], depth: int) -> bool:
	var w_steps := int(ceil(0.5 * wins[i] / _mg.STEP))
	var ks: Array = []
	if depth == ROBUST_DEPTH:
		for kk in range(int(plan["k"]) - w_steps, int(plan["k"]) + w_steps + 1):
			ks.append(kk)
	else:
		ks = [int(plan["k"]) - w_steps, int(plan["k"]) + w_steps]
	for kk in ks:
		var rp: Dictionary = _mg._run_plan(s, kk, i, t)
		if rp.is_empty() or float(rp["min_lead"]) < 0.6:
			return false
		if i >= r:
			continue
		var nxt = rp["state"]
		var t2: float = t + int(rp["steps"]) * _mg.STEP
		var p2: Dictionary = _mg._plan(nxt, i + 1, 0.6 * wins[i + 1])
		if p2.is_empty():
			return false
		if depth > 1 and not _robust_after(nxt, p2, i + 1, t2, r, wins, depth - 1):
			return false
	return true
