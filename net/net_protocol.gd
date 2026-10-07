class_name NetProtocol
extends RefCounted
## Constantes del protocolo de red del juego. Un único sitio para canales y versión.
##
## Todos los mensajes viajan por NetworkManager en "canales" con nombre. Cada sistema
## (lobby, flujo de partida, sesión de minijuego) registra el suyo; añadir minijuegos
## nunca requiere tocar este archivo ni NetworkManager.

## Se incrementa cuando cambian los mensajes de forma incompatible. El host rechaza
## clientes con otra versión.
const VERSION := 1

## Lobby: unirse, perfil, lista de jugadores (clase Lobby).
const CH_LOBBY := "lobby"
## Flujo de partida: cambios de estado host → clientes (GameManager).
const CH_FLOW := "flow"
## Sesión de minijuego: listo/inicio, snapshots, entrada, eventos (MinigameSession).
const CH_MINIGAME := "mg"
