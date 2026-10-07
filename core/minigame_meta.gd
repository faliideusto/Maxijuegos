class_name MinigameMeta
extends Resource
## Metadatos de un minijuego. Cada carpeta res://minigames/<nombre>/ contiene un
## meta.tres de este tipo; el MinigameRegistry los descubre automáticamente.

## Modelo de ejecución del minijuego. El núcleo (Lobby, GameManager, puntuación, red) es
## idéntico para ambos; solo cambia cómo se ejecuta el minijuego.
enum ExecutionMode {
	## Todos comparten escenario y pueden verse/interactuar. El host simula; los clientes
	## envían intenciones y reciben el estado. (Plataforma menguante, monedas, machacar...)
	HOST_AUTHORITATIVE,
	## Cada jugador juega la prueba en SU PC, sin ver a los demás. No hay sincronización
	## frame a frame: el host da una semilla común, cada cliente envía su resultado al
	## terminar y el host construye la clasificación. (Reflejos, memoria, puzzles...)
	LOCAL_PARALLEL,
}

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
## Modelo de ejecución (ver ExecutionMode).
@export var execution_mode: ExecutionMode = ExecutionMode.HOST_AUTHORITATIVE
## (LOCAL_PARALLEL) Tope de seguridad en segundos: si algún jugador no envía su resultado a
## tiempo, el host lo da por no terminado y cierra el minijuego. 0 = automático.
@export var max_duration: float = 0.0

func supports(player_count: int) -> bool:
	return player_count >= min_players and player_count <= max_players

## Texto corto para la pantalla de presentación.
func mode_hint() -> String:
	match execution_mode:
		ExecutionMode.LOCAL_PARALLEL: return "Cada uno juega por su cuenta"
		_: return "Todos en la misma arena"
