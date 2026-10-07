# Arquitectura

Detalle de red, modelos de ejecución, protocolo y pruebas: [network.md](network.md).
Estilo visual: [style_guide.md](style_guide.md).

## Estructura de carpetas

```
autoload/    MinigameRegistry, InputManager, NetworkManager, Lobby, GameManager, Transition, DevCli
core/        PlayerData, MinigameMeta, Minigame (base), MinigameSession, ParallelResults, MatchRules, DrawSurface
net/         NetProtocol, NetworkBackend (abstracta) + ENetBackend   (futuro: SteamBackend)
ui/          theme.tres (generado), palette.gd, ui_kit.gd, components/, screens/
minigames/   <nombre>/ → meta.tres + scene.tscn + script        ← un minijuego = una carpeta
tools/       build_theme.gd, screenshot.gd, dev_multi.ps1 (varias ventanas)
tests/       smoke, input, parallel_local, online_test.sh, run_matrix.sh
docs/        style_guide.md, architecture.md, network.md
```

## Capas (separación de responsabilidades)

```
 Pantallas (ui/screens)  ──llaman──►  GameManager (flujo + puntos)   Lobby (jugadores)
                                          │ canal "flow"                │ canal "lobby"
                                          └──────────► NetworkManager ◄──┘      (transporte, canales)
 Runner ──► MinigameSession ───────────────────────────► canal "mg"            ▲
    │                                                                     NetworkBackend
    └──► Minigame (HOST_AUTHORITATIVE | LOCAL_PARALLEL)                  (ENet hoy, Steam mañana)
```

- **GameManager**: máquina de estados `MENU → LOBBY → SETUP → [INTRO → PLAYING → SCOREBOARD]×N → FINAL`,
  playlist (`pick_random`, filtrando por nº de jugadores), reparto de puntos (`MatchRules`), difusión del
  estado a los clientes. Solo el host avanza.
- **Lobby**: roster, nombre/color, altas/bajas, validación de unión, sustitución por bot al desconectarse.
- **NetworkManager**: transporte con canales genéricos y confianza host↔cliente. No conoce el juego.
- **Minigame**: lógica propia; declara su modelo en `meta.tres`.

## Modelos de ejecución de minijuegos

| | HOST_AUTHORITATIVE | LOCAL_PARALLEL |
|---|---|---|
| Escenario | compartido, se ven e interactúan | cada uno el suyo, sin ver a los demás |
| Quién simula | el host | cada PC (solo su jugador) |
| Red durante el juego | snapshots (host→clientes) + entrada (cliente→host) | ninguna |
| Aleatoriedad | `rng` (semilla común disponible) | `rng` con semilla común → misma prueba |
| Resultado | lo decide el host (`finish(ranking)`) | cada cliente envía `report_result`; el host valida, completa con bots, ordena |
| Ejemplos | machacar, plataforma, monedas | reflejos |

Ambos comparten TODO el flujo (lobby, handshake, cuenta atrás, fin, puntos, marcador). Añadir un modelo
nuevo en el futuro = ampliar `MinigameMeta.ExecutionMode`, `Minigame` y `MinigameSession`; el resto no cambia.

## Contrato de un minijuego

`Minigame` (extends Node): ver la cabecera de [core/minigame.gd](../core/minigame.gd) para los métodos de
cada modelo. Común: `_on_prepare`, `_on_start`, `_animate`, `_bot_move/_bot_action`. Helpers: `move_input(p)`,
`action_presses(p)`, `rank_by_score`, `rng`, `local_player`, `is_local_player(p)`.

### Añadir un minijuego

1. Carpeta `res://minigames/<nombre>/` con `scene.tscn` (nodo `Node` + script `extends Minigame`).
2. `meta.tres` (`MinigameMeta`): nombre, descripción, instrucciones, `min_players`, `max_players`, duración,
   escena, color y **`execution_mode`**.
3. Implementar los métodos de su modelo. Nada más: el registro lo descubre y la red no se toca.

## Entrada

`InputManager` crea acciones por jugador y simula bots/autopiloto; la entrada remota la fija la sesión del
host. Dispositivos: `kb1`, `kb2`, `joy:N` (modo local), `local` (online: WASD/flechas + Espacio/Enter o
cualquier mando), `remote`, `bot`.

## Red (host autoritativo)

`NetworkBackend` solo fabrica el `MultiplayerPeer`. **Cambiar a Steam**: `SteamBackend extends NetworkBackend`
(GodotSteam, `SteamMultiplayerPeer`, lobbies) + `NetworkManager.set_backend(...)`. Canales, RPC, lobby,
sesiones y minijuegos no cambian.

## Estilo

Paleta en `ui/palette.gd`; tema en `ui/theme.tres` (generado por `tools/build_theme.gd`).
