class_name PlayerData
extends RefCounted
## Datos de un jugador de la partida. Es independiente de la red y de los minijuegos.

const MAX_PLAYERS := 8

# Identificadores de dispositivo de entrada.
const DEVICE_KB1 := "kb1"         # modo local: WASD + Espacio
const DEVICE_KB2 := "kb2"         # modo local: Flechas + Enter
const DEVICE_JOY_PREFIX := "joy:" # modo local: "joy:0", "joy:1"... (índice de mando)
const DEVICE_LOCAL := "local"     # online: el jugador de ESTE PC (teclado o cualquier mando)
const DEVICE_REMOTE := "remote"   # online: jugador de otro PC (su entrada llega por red)
const DEVICE_BOT := "bot"         # controlado por la IA (pruebas, relleno, desconectados)

## Ranura estable 0..7. Define las acciones de entrada ("p3_left"...) y el color inicial.
var id: int = 0
var display_name: String = ""
var color_index: int = 0
var device: String = DEVICE_KB1
## Peer de red dueño de este jugador (1 = host / local).
var peer_id: int = 1
var score: int = 0
## true si el jugador se desconectó a mitad de partida y ahora lo juega un bot.
var disconnected: bool = false

var color: Color:
	get: return Palette.PLAYER_COLORS[color_index % Palette.PLAYER_COLORS.size()]

var is_bot: bool:
	get: return device == DEVICE_BOT

var is_remote: bool:
	get: return device == DEVICE_REMOTE

## true si lo maneja una persona en ESTE PC (online o modo local).
var is_local_human: bool:
	get: return device != DEVICE_BOT and device != DEVICE_REMOTE

## Nombre para mostrar (marca a los desconectados sustituidos por un bot).
func label() -> String:
	return display_name + " (bot)" if disconnected else display_name

## Nombre legible del dispositivo para la UI.
func device_label() -> String:
	match device:
		DEVICE_KB1: return "Teclado 1 · WASD + Espacio"
		DEVICE_KB2: return "Teclado 2 · Flechas + Enter"
		DEVICE_BOT: return "Bot (desconectado)" if disconnected else "Bot"
		DEVICE_LOCAL: return "Tú"
		DEVICE_REMOTE: return "Online"
		_:
			if device.begins_with(DEVICE_JOY_PREFIX):
				return "Mando %d" % (int(device.substr(DEVICE_JOY_PREFIX.length())) + 1)
			return device

## Serialización para sincronizar el roster por red.
func to_dict() -> Dictionary:
	return {"id": id, "name": display_name, "color": color_index, "device": device,
			"peer": peer_id, "score": score, "dc": disconnected}
