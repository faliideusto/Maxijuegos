# Red y modelos de ejecución de minijuegos (fase 2)

Documento para auditar la implementación: qué se decidió, por qué, dónde está en el código y qué
está probado. Complementa [architecture.md](architecture.md).

## 1. Requisitos que guían el diseño

- 2–8 jugadores, **un jugador por PC** online. El que crea la sala es el **host**.
- El núcleo gestiona siempre: Lobby → selección de minijuego → preparación → cuenta atrás →
  ejecución → resultados → clasificación → siguiente minijuego.
- **Dos modelos de ejecución** de minijuego, declarados por el propio minijuego en su `meta.tres`
  (`execution_mode`), sin tocar GameManager, Lobby, puntuación ni networking:
  - `HOST_AUTHORITATIVE`: arena compartida; el host simula y valida; los clientes envían intenciones.
  - `LOCAL_PARALLEL`: cada jugador juega la prueba en su PC sin ver a los demás; el host da una
    semilla común, recoge los resultados y construye la clasificación.
- Añadir un minijuego = implementar solo el minijuego. Cero lógica de red por minijuego.
- Sin Steamworks todavía (transporte ENet por IP); el diseño permite cambiar a Steam sin tocar nada más.
- Modo de desarrollo local: bots, modo local por teclado/mandos, varias instancias fáciles.

## 2. Capas y responsabilidades

| Capa | Archivo | Responsabilidad | NO hace |
|---|---|---|---|
| Transporte | `autoload/network_manager.gd`, `net/` | Conectar/desconectar/expulsar; **canales** con nombre sobre 4 RPC; confianza host↔cliente | Conocer lobbies, minijuegos o reglas |
| Lobby | `autoload/lobby.gd` | Roster (jugadores, nombre, color), altas/bajas, validación de unión, sustitución por bot al desconectarse | Puntuación, flujo, minijuegos |
| Flujo/Puntos | `autoload/game_manager.gd`, `core/match_rules.gd` | Máquina de estados, playlist, reparto de puntos, difusión del estado a los clientes | Ejecutar minijuegos, gestionar jugadores |
| Entrada | `autoload/input_manager.gd` | "Qué quiere hacer cada jugador": local, remoto, bot, autopiloto | Red (la fija la sesión) |
| Sesión de minijuego | `core/minigame_session.gd` | Handshake, snapshots/entrada (HOST_AUTH), semilla/resultados (LOCAL_PARALLEL) | Saber qué minijuego es |
| Runner | `ui/screens/minigame_runner.gd` | Orquesta la ejecución en cada PC, cuenta atrás, avisos; llama a `GameManager.report_results` (solo host) | Lógica de juego |
| Minijuego | `core/minigame.gd` + `minigames/*` | Su propia lógica y dibujo | Red, flujo, puntos |

Dependencias: `Minigame` ← `MinigameSession` ← `NetworkManager`. `GameManager` y `Lobby` usan canales
de `NetworkManager` pero no se conocen entre sí más que por señales/lecturas (`Lobby.players`,
`GameManager.state`).

## 3. Transporte: `NetworkManager`

- API: `host_game`, `join_game`, `disconnect_from_game`, `kick`, `register_channel(canal, handler)`,
  `send_to_host`, `send_to_peer`, `broadcast`. Señales: `peer_joined/left`, `connected_to_host`,
  `connection_failed`, `disconnected`.
- 4 RPC cubren dirección × fiabilidad: `to_host` (cualquier peer; solo el host procesa) y `to_client`
  (autoridad = host; el motor rechaza otros remitentes). Fiable para control, `unreliable_ordered`
  para snapshots y entrada (30 Hz).
- **Backend** (`net/network_backend.gd`): solo fabrica el `MultiplayerPeer`. Hoy `ENetBackend` (IP:puerto
  24680, 8 jugadores, timeouts de detección de caída 3–6 s). Steam = `SteamBackend` con
  `SteamMultiplayerPeer` + `NetworkManager.set_backend(...)`. Los canales y RPC no cambian.
- Protocolo y versión: `net/net_protocol.gd` (`VERSION` se compara al unirse).

## 4. Protocolo por canal

Todos los mensajes son `Dictionary` con `op`. Un handler **nunca** confía en el contenido de un cliente.

**`lobby`** (`Lobby`)
- c→h `join {v, name}` · c→h `profile {name?|cycle?}` (solo toca el jugador del peer remitente)
- h→c `roster {players[]}` (completo, idempotente) · `joined` · `rejected {reason}`
- Rechazos: versión distinta, sala llena (8), partida ya empezada (solo se admite en LOBBY/SETUP).

**`flow`** (`GameManager`) h→c `state {s, playlist[], i, rank, pts, prev, scores}`: estado completo e
idempotente en cada cambio (SETUP es solo del host). Los clientes reflejan y cambian de pantalla;
sus llamadas a `run_minigame/report_results/continue_match/start_match` son no-ops.

**`mg`** (`MinigameSession`)
- Común: c→h `ready` · h→c `begin {seed}` · h→c `end {d}`.
- HOST_AUTHORITATIVE: h→c `snap {d}` (no fiable, 30 Hz), `ev {n,d}` · c→h `in {m:Vector2, c:int}`
  (no fiable, 30 Hz; movimiento + **contador acumulado** de pulsaciones, tolerante a pérdida/desorden).
- LOCAL_PARALLEL: c→h `result {s, t}`.

## 5. Ciclo de vida de una partida online

```
MENU ──crear/unirse──► LOBBY ─host─► SETUP ─host─► [INTRO → PLAYING → SCOREBOARD]×N ─► FINAL
(host: Lobby.host_room · cliente: Lobby.join_room → join → joined)       └─ REVANCHA / LOBBY (host)
```

Dentro de **PLAYING** (todos los PC cargan el runner por el mensaje `flow`):

1. Cada PC instancia el minijuego y abre su `MinigameSession`.
2. Cliente: `ready` → espera `begin`. Host: espera `ready` de todos los remotos (**tope 8 s reales**,
   los lentos no bloquean) → genera la **semilla** → `begin {seed}`.
3. Todos: `configure(modo, semilla, jugador_local)` → `prepare` → cuenta atrás (3-2-1-¡YA!) → `start`.
4. Ejecución según modelo (§6).
5. Fin: el host llama a `finish(ranking)` → `end` a los clientes → todos muestran "¡FIN!" →
   el host (solo él) llama a `GameManager.report_results(ranking)` → reparte puntos → difunde `SCOREBOARD`.

Solo el **host** avanza el flujo; la pantalla de presentación y el marcador avanzan por temporizador
(o por la acción del jugador del host).

## 6. Los dos modelos

### HOST_AUTHORITATIVE
- El minijuego existe en todos los PC; solo el host llama a `_simulate(delta)`. El host serializa su
  estado (`_serialize_state`) ~30 veces/s; los clientes lo copian (`_apply_state`) y suavizan lo que
  dibujan. Eventos puntuales: `send_event(nombre, datos)` → `_on_event` en todos.
- La entrada llega al host vía `InputManager.set_remote_input` desde la sesión; el minijuego la lee con
  `move_input(p)` / `action_presses(p)` igual para locales, remotos y bots.
- El host valida: el remitente solo controla a su jugador; vector normalizado a ≤1; contador monótono;
  pulsaciones por frame acotadas (`MAX_REMOTE_PRESSES_PER_FRAME`).
- **Nada** que decida resultados viene del cliente.

### LOCAL_PARALLEL
- Cada PC ejecuta `_play(delta)` solo para su jugador (`local_player`), con `rng` sembrado por el host:
  la prueba procedural es idéntica para todos. No hay snapshots ni se ve a los demás
  (la sesión ni siquiera procesa estado ajeno; el test lo comprueba).
- Al terminar: `report_result(score, tiebreak)` (mayor puntuación = mejor; "menor tiempo" → `-tiempo`).
  El cliente lo envía; el host valida (`validate_result`), completa los bots/desconectados con
  `_bot_result` (determinista a partir de la semilla), espera a todos y construye la clasificación con
  `rank_results` (orden por defecto: puntuación desc., desempate `tiebreak` asc.; sobrescribible).
- Tope de seguridad: `meta.max_duration` (o `approx_duration×2+15`). Quien no responde queda "no
  terminado" (DNF, último) y la partida sigue.
- El jugador que termina ve "Esperando a los demás…" sin resultados ajenos.
- **Compromiso asumido**: en este modelo el resultado lo calcula el cliente (es inherente: no hay
  simulación en el host). Mitigación: `validate_result` (plausibilidad, p. ej. tiempos humanamente
  posibles) y tope de tiempo. No usar este modelo donde una trampa importe sin añadir validación.
- Sin red (modo local): los humanos de ese PC juegan **por turnos** (cartel "Turno de X"); los bots
  generan su resultado; misma clasificación.

## 7. Entrada

`InputManager` (único lector de dispositivos): locales (`kb1`, `kb2`, `joy:N` en modo local; `local` =
WASD/flechas + Espacio/Enter o cualquier mando en online), remotos (estado fijado por la sesión),
bots y autopiloto (`is_simulated`). Los minijuegos usan `move_input`/`action_presses`; para jugadores
simulados llaman a sus `_bot_move/_bot_action` (IA propia por minijuego).

## 8. Desconexiones (política)

Principio: **ninguna caída puede bloquear la partida** y los minijuegos no necesitan casos especiales.

| Momento | Quién | Qué ocurre |
|---|---|---|
| Lobby/Setup | cliente | El host lo detecta (≤6 s) y elimina su jugador; difunde el roster |
| Partida en curso | cliente | Su jugador pasa a **bot** (`disconnected`, se muestra "(bot)"): en HOST_AUTH lo mueve la IA del minijuego; en LOCAL_PARALLEL el host calcula su resultado. La sesión deja de esperar su `ready`/resultado. **Desde ese momento no puntúa**: recibe 0 puntos por minijuego (conserva los que ya tenía), no ocupa posición en el reparto ni desplaza a los demás, y no puede ser el ganador final |
| Cualquiera | host | Los clientes detectan la caída, salen al menú con aviso. No hay migración de host |
| Cualquiera | uniones tardías | Rechazadas ("la partida ya ha empezado") |
| Tras la partida | revancha/lobby | Los desconectados se descartan (`Lobby.prune_disconnected`) |

Entre la caída real y su detección (≤6 s, timeouts ENet) su entrada queda congelada.

## 9. Cómo escribir un minijuego

1. Carpeta `res://minigames/<nombre>/` con `scene.tscn` (nodo raíz `Node` + script) y `meta.tres`
   (`MinigameMeta`: nombre, textos, jugadores, duración, escena, color, **`execution_mode`**).
2. Script `extends Minigame`. Implementa **solo** los métodos de su modelo (ver cabecera de
   `core/minigame.gd`). Ejemplos: `button_mash`, `shrinking_platform`, `coin_grab` (HOST_AUTH) y
   `reaction_test` (LOCAL_PARALLEL).
3. No hay nada más que registrar. No uses `NetworkManager`, `Lobby` ni `GameManager` desde un minijuego.

Reglas: lo procedural sale de `rng` (nunca `randf()` global) en LOCAL_PARALLEL; el estado de
HOST_AUTH se serializa con tipos simples (preferir `Packed*Array`); los efectos puramente visuales se
derivan del estado o de eventos, nunca se simulan por separado en el cliente.

## 10. Decisiones y alternativas descartadas

1. **Canales genéricos en vez de RPC por funcionalidad** → añadir sistemas/minijuegos sin tocar el
   transporte. Descartado: un `@rpc` por minijuego (acopla red y juego).
2. **Estado completo (snapshots) en vez de replicación por propiedad** (`MultiplayerSynchronizer`):
   el estado de un minijuego son objetos internos; un snapshot explícito es simple, testeable e
   independiente del árbol de nodos. Coste: más ancho de banda (§11).
3. **Contador acumulado de pulsaciones** en vez de eventos "pulsado": robusto ante pérdida y desorden en
   canal no fiable.
4. **Desconectado → bot** en vez de eliminar al jugador: evita casos especiales en los minijuegos y
   nunca bloquea.
5. **Semilla común + `rng` base** para lo procedural: sin sincronizar contenido por red.
6. **Solo el host avanza el flujo**; mensajes de estado completos e idempotentes (un mensaje perdido
   se corrige con el siguiente; los de flujo son fiables).
7. **Resultado de LOCAL_PARALLEL calculado en el cliente**: único camino viable sin simulación en el
   host; mitigado con validación y tope (§6).
8. **Modo local conservado** (bots, teclado/mando compartidos, turnos en LOCAL_PARALLEL) solo para desarrollo.

## 11. Limitaciones conocidas (para auditoría)

- **Sin predicción en el cliente**: la respuesta en HOST_AUTH incluye el RTT. Suavizado/extrapolación
  solo visual. Probado en loopback, **no con latencia ni pérdida de paquetes reales** (pendiente:
  emulación de red, p. ej. clumsy/netem).
- **Snapshots sin compresión delta**: ≈0,5–1 KB a 30 Hz por cliente; con 8 jugadores el host sube
  ≈ 1 Mbps. Aceptable para LAN/Steam; optimizable (cuantizar, menos Hz).
- **Anti-trampas limitado**: HOST_AUTH robusto; LOCAL_PARALLEL depende de `validate_result`.
  Entrada limitada por frame, pero un cliente puede enviar a ≤360 pulsaciones/s.
- Entrada congelada hasta detectar una caída (≤6 s). Sin reconexión ni migración de host.
- Presentación/marcador: solo el host puede saltarlos con la acción; los clientes esperan.
- No hay sincronización de reloj: la cuenta atrás es local a cada PC tras `begin`.
- El camino de teclado/mando real solo está verificado con eventos sintéticos (`tests/input_test.gd`) y
  la prueba local por turnos; **no se ha probado con un mando físico** ni con partidas online manejadas
  a mano (los tests online usan autopiloto).
- Steam: sin integrar (`SteamBackend`, lobbies e invitaciones pendientes).

## 12. Pruebas

| Prueba | Qué cubre |
|---|---|
| `tests/smoke_test.gd` | Partida local completa con bots (registro, selección, puntos) |
| `tests/input_test.gd` | InputMap local (kb1/kb2/local) y saneado de entrada remota |
| `tests/parallel_local_test.gd` | LOCAL_PARALLEL local por turnos con teclas reales |
| `tests/online_test.sh <humanos> <minijuegos> [bots] [escenario]` | Instancias **reales** (una por jugador, headless, autopiloto) por loopback ENet: `normal`, `kill_in_lobby`, `kill_in_game`, `kill_in_parallel`, `kill_host`, `late_join` |
| `tests/run_matrix.sh` | Toda la matriz (2/4/8 jugadores, 4+4 bots, caídas) |

Comprobaciones del test online: el host llega a FINAL; todos los clientes llegan a FINAL con la
**clasificación idéntica**; en HOST_AUTH hay snapshots y entrada en cada minijuego; en LOCAL_PARALLEL el
host recoge **N resultados sin DNF** y los clientes no reciben estado ajeno; sin errores de script;
tras caídas la partida termina; tras caer el host los clientes vuelven al menú.

Resultados de la última ejecución de la matriz: ver el final de este documento.

## 13. Herramientas de desarrollo

- `tools/dev_multi.ps1 -Count N [-Bots M] [-AutoStart] [-Autopilot]`: N ventanas (host + clientes) en cuadrícula.
- `DevCli` (`autoload/dev_cli.gd`): `--host --join=IP --name= --bots= --players= --games= --autopilot
  --timescale= --log --quit-at-end --shot=`. Sin argumentos no hace nada.
- Modo local ("MODO LOCAL (PRUEBAS)" en el menú) y bots en el lobby del host.

## 14. Resultados de la última ejecución (2026-10-08)

Matriz `tests/run_matrix.sh` (instancias reales por loopback ENet, 4 minijuegos por partida = los dos
modelos en cada partida): **10 de 10 OK**.

| Escenario | Resultado |
|---|---|
| 2 jugadores, normal | OK |
| 4 jugadores, normal | OK |
| 8 jugadores humanos, normal | OK |
| 4 humanos + 4 bots (8 jugadores) | OK |
| Caída de un cliente en el lobby (4) | OK |
| Caída de un cliente en un minijuego (4) | OK (sustituido por bot) |
| Caída de un cliente durante LOCAL_PARALLEL (4 y 8) | OK (resultado simulado por el host) |
| Caída del host durante una partida (4) | OK (clientes vuelven al menú) |
| Unión tardía con la partida empezada (3) | OK (rechazada) |

Además: `smoke_test` (5 jugadores, 4 minijuegos), `input_test` y `parallel_local_test`, OK.

### Errores encontrados y corregidos al introducir el segundo modelo
- La sesión decidía el modo en `setup()`, antes de que el runner lo configurase, y nunca recogía resultados de
  LOCAL_PARALLEL (la partida se quedaba parada). Ahora `is_parallel` se lee del minijuego.
- El cliente podía perder su primer `ready` si el host cargaba la escena más tarde (espera de 8 s):
  ahora lo reenvía cada 0,5 s hasta recibir `begin`.
- `Transition` ignoraba un cambio de escena pedido durante otra transición: ahora lo encola.
- Test: matar solo el envoltorio "console" de Godot dejaba procesos huérfanos ocupando el puerto;
  ahora se mata el árbol de procesos y el test aborta si el puerto UDP 24680 está ocupado.
