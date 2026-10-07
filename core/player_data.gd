class_name PlayerData
extends RefCounted
## Datos de un jugador de la partida. Es independiente de la red y de los minijuegos.

const MAX_PLAYERS := 8

# Identificadores de dispositivo de entrada.
const DEVICE_KB1 := "kb1"         # WASD + Espacio
const DEVICE_KB2 := "kb2"         # Flechas + Enter
const DEVICE_JOY_PREFIX := "joy:" # "joy:0", "joy:1"... (índice de mando de Godot)
const DEVICE_BOT := "bot"         # controlado por la IA (pruebas / jugar solo)
const DEVICE_REMOTE := "remote"   # jugador de otro PC (online)

## Ranura estable 0..7. Define las acciones de entrada ("p3_left"...) y el color inicial.
var id: int = 0
var display_name: String = ""
var color_index: int = 0
var device: String = DEVICE_KB1
## Peer de red dueño de este jugador (1 = host / local).
var peer_id: int = 1
var score: int = 0

var color: Color:
	get: return Palette.PLAYER_COLORS[color_index % Palette.PLAYER_COLORS.size()]

var is_bot: bool:
	get: return device == DEVICE_BOT

var is_remote: bool:
	get: return device == DEVICE_REMOTE

## Nombre legible del dispositivo para la UI.
func device_label() -> String:
	match device:
		DEVICE_KB1: return "Teclado 1 · WASD + Espacio"
		DEVICE_KB2: return "Teclado 2 · Flechas + Enter"
		DEVICE_BOT: return "Bot"
		DEVICE_REMOTE: return "Online"
		_:
			if device.begins_with(DEVICE_JOY_PREFIX):
				return "Mando %d" % (int(device.substr(DEVICE_JOY_PREFIX.length())) + 1)
			return device

## Serialización para sincronizar el lobby por red.
func to_dict() -> Dictionary:
	return {"id": id, "name": display_name, "color": color_index,
			"device": device, "peer": peer_id, "score": score}

static func from_dict(d: Dictionary) -> PlayerData:
	var p := PlayerData.new()
	p.id = int(d.get("id", 0))
	p.display_name = String(d.get("name", ""))
	p.color_index = int(d.get("color", 0))
	p.device = String(d.get("device", DEVICE_REMOTE))
	p.peer_id = int(d.get("peer", 1))
	p.score = int(d.get("score", 0))
	return p
