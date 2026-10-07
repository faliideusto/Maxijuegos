class_name MinigameMeta
extends Resource
## Metadatos de un minijuego. Cada carpeta res://minigames/<nombre>/ contiene un
## meta.tres de este tipo; el MinigameRegistry los descubre automáticamente.

## Se rellena en el registro a partir del nombre de la carpeta.
var id: StringName = &""

@export var display_name: String = "Minijuego"
@export_multiline var description: String = ""
@export_multiline var instructions: String = ""
@export_range(1, 8) var min_players: int = 2
@export_range(1, 8) var max_players: int = 8
## Duración aproximada en segundos (informativa; para la UI y el equilibrado).
@export var approx_duration: float = 30.0
## Escena raíz del minijuego (su script debe extender Minigame).
@export var scene: PackedScene
## Color de acento mostrado en la pantalla de presentación.
@export var accent_color: Color = Color("FFC81E")

func supports(player_count: int) -> bool:
	return player_count >= min_players and player_count <= max_players
