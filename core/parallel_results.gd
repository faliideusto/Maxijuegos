class_name ParallelResults
extends RefCounted
## Recoge los resultados de un minijuego LOCAL_PARALLEL: uno por jugador.
## Lo usa el host (online) o el runner (modo local por turnos). Es independiente de la red.
##
## Un resultado es {"score": float, "tiebreak": float}. Por defecto gana la mayor puntuación
## y el desempate favorece al menor `tiebreak` (ver Minigame.rank_results para personalizarlo).

## Puntuación de quien no llegó a terminar (queda último).
const DNF_SCORE := -1.0e30

var _player_ids: Array[int] = []
var _results: Dictionary = {}   # player_id -> {"score","tiebreak"}

func _init(players: Array[PlayerData]) -> void:
	for p in players:
		_player_ids.append(p.id)

## Guarda el resultado de un jugador. Devuelve false si no existe o ya había uno.
func set_result(player_id: int, score: float, tiebreak: float = 0.0) -> bool:
	if not _player_ids.has(player_id) or _results.has(player_id):
		return false
	if not is_finite(score) or not is_finite(tiebreak):
		return false
	_results[player_id] = {"score": score, "tiebreak": tiebreak}
	return true

func has_result(player_id: int) -> bool:
	return _results.has(player_id)

func is_complete() -> bool:
	return _results.size() >= _player_ids.size()

func count() -> int:
	return _results.size()

## Marca como "no terminado" a quien aún no tiene resultado. Devuelve cuántos eran.
func fill_missing_as_dnf() -> int:
	var missing := 0
	for id in _player_ids:
		if not _results.has(id):
			_results[id] = {"score": DNF_SCORE, "tiebreak": 0.0}
			missing += 1
	return missing

func to_dict() -> Dictionary:
	return _results.duplicate(true)
