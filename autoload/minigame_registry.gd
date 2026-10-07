extends Node
## Registro de minijuegos (autoload). Descubre automáticamente cada carpeta
## res://minigames/<nombre>/ que contenga un meta.tres válido. Añadir un minijuego
## = crear su carpeta; no hay que registrarlo en ningún sitio.

const MINIGAMES_DIR := "res://minigames"
const META_FILE := "meta.tres"

var _all: Array[MinigameMeta] = []

func _ready() -> void:
	scan()

## Vuelve a escanear las carpetas de minijuegos.
func scan() -> void:
	_all.clear()
	var dir := DirAccess.open(MINIGAMES_DIR)
	if dir == null:
		push_error("MinigameRegistry: no se puede abrir %s" % MINIGAMES_DIR)
		return
	var folders := dir.get_directories()
	folders.sort()
	for folder in folders:
		var path := "%s/%s/%s" % [MINIGAMES_DIR, folder, META_FILE]
		# ResourceLoader.exists funciona también en builds exportadas (recursos remapeados).
		if not ResourceLoader.exists(path):
			continue
		var meta := load(path) as MinigameMeta
		if meta == null or meta.scene == null:
			push_warning("MinigameRegistry: '%s' no es un MinigameMeta válido o no tiene escena." % path)
			continue
		if meta.min_players > meta.max_players:
			push_warning("MinigameRegistry: '%s' tiene min_players > max_players." % folder)
			continue
		meta.id = StringName(folder)
		_all.append(meta)

func get_all() -> Array[MinigameMeta]:
	return _all

func get_by_id(id: StringName) -> MinigameMeta:
	for m in _all:
		if m.id == id:
			return m
	return null

## Minijuegos que admiten ese número de jugadores.
func get_compatible(player_count: int) -> Array[MinigameMeta]:
	var result: Array[MinigameMeta] = []
	for m in _all:
		if m.supports(player_count):
			result.append(m)
	return result

## Elige `count` minijuegos al azar entre los compatibles, sin repetir. Si se piden más
## de los disponibles, se vuelve a barajar el conjunto completo (evitando repetir justo
## el mismo dos veces seguidas cuando hay alternativa).
func pick_random(count: int, player_count: int, rng: RandomNumberGenerator = null) -> Array[MinigameMeta]:
	var result: Array[MinigameMeta] = []
	var compatible := get_compatible(player_count)
	if compatible.is_empty() or count <= 0:
		return result
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()
	while result.size() < count:
		var pool := compatible.duplicate()
		_shuffle(pool, rng)
		if not result.is_empty() and pool.size() > 1 and pool[0] == result.back():
			var tmp = pool[0]
			pool[0] = pool[1]
			pool[1] = tmp
		for m in pool:
			if result.size() >= count:
				break
			result.append(m)
	return result

# Fisher-Yates con el RNG dado (Array.shuffle() usa el RNG global).
func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
