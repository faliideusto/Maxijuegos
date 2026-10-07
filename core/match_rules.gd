class_name MatchRules
extends RefCounted
## Reglas de puntuación de la partida (un único sitio para cambiarlas).

## Puntos por posición (rank 0 = primero). Con N jugadores: el 1º recibe N, el último 1.
static func points_for_rank(rank: int, player_count: int) -> int:
	return maxi(player_count - rank, 0)

## Jugadores ordenados por puntuación total (desc.). Empates: por ranura.
static func standings(players: Array[PlayerData]) -> Array[PlayerData]:
	var sorted: Array[PlayerData] = players.duplicate()
	sorted.sort_custom(func(a: PlayerData, b: PlayerData) -> bool:
		if a.score != b.score:
			return a.score > b.score
		return a.id < b.id)
	return sorted
