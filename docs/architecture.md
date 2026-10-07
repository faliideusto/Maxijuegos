# Arquitectura

## Estructura de carpetas

```
autoload/    GameManager, MinigameRegistry, InputManager, NetworkManager, Transition (autoloads)
core/        PlayerData, MinigameMeta, Minigame (clase base), MatchRules, DrawSurface
net/         NetworkBackend (abstracta) + ENetBackend   (futuro: SteamBackend)
ui/          theme.tres (generado), palette.gd, ui_kit.gd, components/, screens/
minigames/   <nombre>/ → meta.tres + scene.tscn + script       ← un minijuego = una carpeta
tools/       build_theme.gd (genera el tema), screenshot.gd (capturas de desarrollo)
tests/       smoke_test.gd (partida completa con bots), net_test.gd (host + cliente)
docs/        style_guide.md, architecture.md
```

## Flujo de partida

`GameManager` es una máquina de estados; las pantallas solo llaman a su API pública:

```
MENU → LOBBY → SETUP → [ INTRO → PLAYING → SCOREBOARD ] × N → FINAL
                          ▲                                      │
                          └────────── rematch() ◄────────────────┘
```

- `start_match()` pide al registro `pick_random(n, nº_jugadores)` (sin repetir, filtrando por
  `min_players/max_players`; si se piden más de los disponibles se vuelve a barajar sin repetir seguidos).
- `report_results(ranking)` reparte puntos con `MatchRules.points_for_rank` (1º = N puntos … último = 1).
- Las transiciones usan la cortina de `Transition`.

## Contrato de un minijuego

`Minigame` (extends Node) → `signal finished(results)`; `prepare(players)` (visual, antes de la cuenta atrás),
`start(players)` (empieza), `finish(ranking)` (ids del 1º al último; una sola vez).
Helpers: `move_input(p)`, `action_just_pressed(p)`, `rank_by_score(scores, tiebreak)`.
La IA de los bots se personaliza sobrescribiendo `_bot_move()` / `_bot_action()`.

### Añadir un minijuego (3 pasos)

1. Crear `res://minigames/<nombre>/` con un script `extends Minigame` y una `scene.tscn` cuyo nodo raíz lo use.
2. Crear `meta.tres` (recurso `MinigameMeta`): nombre, descripción, instrucciones, `min_players`, `max_players`,
   duración, escena y color de acento.
3. Nada más: `MinigameRegistry` lo descubre al arrancar.

## Entrada

`InputManager` crea acciones por jugador (`p<id>_left/right/up/down/action`) según el dispositivo
(`kb1` WASD+Espacio, `kb2` Flechas+Enter, `joy:<n>` mando) y simula bots (`bot`). Los minijuegos nunca leen
dispositivos directamente: así los jugadores remotos podrán alimentarse desde la red tocando solo este archivo.

## Red (host autoritativo)

`NetworkBackend` solo fabrica el `MultiplayerPeer` (`create_host` / `create_client`). `NetworkManager` expone
`host_game`, `join_game`, señales y los RPC de lobby; el resto del juego no conoce ENet.

**Cambiar a Steam**: crear `SteamBackend extends NetworkBackend` (GodotSteam: `SteamMultiplayerPeer`, lobbies de
Steam) y llamar a `NetworkManager.set_backend(SteamBackend.new())`. Los RPC y los minijuegos no cambian.

Estado actual (fase 1): conexión, detección de peers y lobby sincronizado. Los minijuegos online aún no se
sincronizan, así que el host no puede empezar una partida con jugadores remotos (`GameManager.start_blocker`).

## Estilo

Ver [style_guide.md](style_guide.md). Paleta en `ui/palette.gd`, tema en `ui/theme.tres` (generado por
`tools/build_theme.gd`).
