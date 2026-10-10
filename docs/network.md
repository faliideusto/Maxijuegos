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
| `tests/cube_level_test.gd` | Nivel de Salto Neón: determinismo, superabilidad (bot de referencia) y controles negativos |
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

## 15. Salto Neón (`cube_dash`, LOCAL_PARALLEL)

Segundo minijuego LOCAL_PARALLEL: un cubo corre solo por un nivel larguísimo y el jugador solo salta
(**siempre a la misma altura**). Un único intento; gana quien llega **más lejos**.

- **Un solo nivel, diseñado a mano**, idéntico en todas las partidas y PC (no depende de la semilla). Se
  escribe como una lista de piezas en `_level_script()` (pinchos `S1–S3`, bloques `B1–B2`, huecos `G2–G4`,
  tramos de plataformas `R:` con escaleras, saltos entre plataformas y pinchos sobre ellas) y el código las
  coloca con la física real. ~2300 bloques: inalcanzable en los 100 s del tiempo límite.
- **La dificultad es el timing.** Pinchos de techo ("puertas") que obligan a saltar **antes o después** del
  momento natural: un techo sobre la subida castiga saltar pronto; uno sobre la bajada, saltar tarde. El
  salto de referencia se desplaza (`b+`/`b-`) al borde de la ventana en la que el obstáculo se puede saltar,
  descontando el margen humano de la zona, y ese margen **se estrecha con la distancia** (±0,12 s → ±0,045 s):
  cada vez hay que medir mejor. La velocidad sube de 10 a 19 bloques/s y el descanso entre saltos baja de
  0,45 s a 0,09 s. Las puertas son cadenas de celdas estrechas (`a`, `d`) cuya altura se calcula con la
  trayectoria de referencia ± margen, así que **siempre hay solución**.
- **Verificación (`tests/cube_level_test.gd`)**: el nivel es siempre el mismo; contiene todos los tipos de
  pieza; un bot que sigue la solución de referencia recorre **todo el nivel** con el margen humano de cada
  zona (sin error, tarde y pronto); controles negativos (sin saltar / saltos 6 bloques tarde o pronto / ±0,25 s
  de error) mueren; el control clave: **si el bot salta "centrado" ignorando el sesgo, choca con un techo**, y
  todas las puertas cuyo sesgo supera el margen humano bloquean realmente el salto natural. Si una pieza falla,
  el test indica cuál (texto del guion, posición y objetos cercanos).
- **Resultado y red**: `report_result(distancia)` al chocar o al llegar a 100 s; `_validate_result` rechaza
  distancias imposibles (> velocidad máxima × tiempo límite); bots/desconectados: distancia simulada (60–520
  bloques) calculada por el host con la semilla.
- **Estética**: inspirada en los "runners" de ritmo con neón (degradado que cambia de color con la distancia,
  suelo con línea brillante, bloques oscuros con borde luminoso, cubo con cara, partículas), dibujada por código
  con formas propias; no se usa ningún asset de terceros.
- Limitaciones: la dificultad subjetiva depende de personas reales (no probada con humanos a este nivel de
  exigencia); la solución de referencia es "perfecta", los humanos tendrán menos margen del garantizado si su
  latencia de entrada es alta.

### Última verificación completa (con Salto Neón como 5.º minijuego)

`tests/run_matrix.sh` con 5 minijuegos por partida (cada partida incluye los dos modelos): **10 de 10 OK**
(2, 4 y 8 jugadores; 4 humanos + 4 bots; caída en lobby, en minijuego de arena y en LOCAL_PARALLEL con 4 y 8;
caída del host; unión tardía). Además `cube_level_test`, `smoke_test`, `input_test` y `parallel_local_test` en verde.

## 16. Onda Neón (`wave_dash`, LOCAL_PARALLEL)

Tercer minijuego LOCAL_PARALLEL: la "onda" de los runners de ritmo. Mantener el botón = subir en
diagonal, soltar = bajar; velocidad horizontal constante. Un intento; gana quien llega **más lejos**.
Sin código de red (igual que `cube_dash`: `report_result(distancia)`, `_bot_result`, `_validate_result`).

- **Pasillo único**, generado con una semilla FIJA (`LEVEL_SEED`, no la de la partida): idéntico en todos
  los PC. Línea central de tramos con pendiente ±1 y paredes a ±h(x).
- **Dificultad**: medio ancho 3,6 → 1,8 bloques (x = 20..380), tramos cada vez más cortos, ráfagas de
  esquinas muy rápidas, algún tramo larguísimo y velocidad 8,5 → 12,5 bloques/s.
- **Siempre pasable**: la línea central es una trayectoria válida. `tests/wave_level_test.gd` recorre el
  pasillo entero con un bot en bucle cerrado con ±0,04 s de retardo de reacción y comprueba que
  un retardo de 0,15 s sí muere. Un bot en bucle abierto (sin corregir) acumula deriva, por eso el margen
  humano se valida con el bot de bucle cerrado.
- Estética propia (espacial): nebulosas, planeta con anillo, 3 capas de estrellas y paredes de neón con
  campo de energía; el color de las paredes cambia con la distancia.
- Prueba online: `ONLY=wave_dash tests/online_test.sh 4 2 0 normal` y `... 4 1 0 kill_in_parallel` OK.

## 17. Columpio de Lengua (`tongue_swing`, LOCAL_PARALLEL)

Cuarto minijuego LOCAL_PARALLEL. Una rana se columpia con la lengua de gancho en gancho sobre un pantano
mientras una niebla venenosa la persigue. **No se encontraron las reglas del "Tongue Swing" original de
Playus** (la búsqueda no dio nada fiable): es una interpretación propia; se ajusta con la opinión del equipo.

- **Control** (un botón): mantener = la lengua se agarra al SIGUIENTE gancho (resaltado) si está por delante,
  por encima y a 8 bloques; colgada, la rana se balancea y la lengua se acorta (conserva el momento angular,
  coge impulso). Soltar = vuela con la inercia. Pulsar sin gancho a tiro deja la lengua "armada" 0,35 s.
- **Un solo recorrido**, idéntico en todos los PC (`tongue_level.gd`, 900+ bloques), generado con
  `tools/gen_tongue_level.gd` por un planificador que usa la MISMA física (`_phys`, paso fijo 1/60). Un gancho
  solo se coloca si hay una ventana de suelta de ±win s (de 0,20 a 0,09 s según la distancia), la niebla no
  alcanza al bot y los errores de suelta de media ventana (también repetidos) siguen siendo recuperables.
  Las coordenadas se guardan con 3 decimales y el generador trabaja con ellas (si no, el bot diverge).
- **Dificultad**: más separación entre ganchos, más ganchos frágiles (se rompen a 1,15 s), ventana de suelta
  más estrecha y niebla que acelera (1,8 → 5,4 bloques/s).
- **Pruebas**: `tests/tongue_level_test.gd` (el bot recorre los 900 m; con ±0,02 s de error aleatorio llega
  a > 300 m; controles negativos). `ONLY=tongue_swing tests/online_test.sh 4 2 0 normal`, `8 1 0 normal` y
  `4 1 0 kill_in_parallel` OK. El autopiloto (pruebas) suelta con ±0,07 s de error y se "cansa" a los 28 s.
- Limitación: la garantía de superabilidad es para el bot con la ventana nominal y errores pequeños; un
  humano que falle varias veces seguidas puede quedarse sin ganchos alcanzables (es parte del juego).

## 18. Texto en el canal del minijuego y Bomba de Palabras (`bomb_party`, HOST_AUTHORITATIVE)

**Extensión genérica (núcleo, sin código de red por minijuego):** los minijuegos HOST_AUTHORITATIVE pueden
recibir texto de los jugadores. `Minigame.submit_text(text, final)` lo entrega directamente en el host (o en
partida local) y en un cliente viaja por el canal del minijuego como `{"op":"tx","t":texto,"f":bool}`
(`f=true` confirmado, fiable; `f=false` borrador mientras escribe, no fiable). `MinigameSession._host_on_text`
solo acepta texto del dueño del jugador, de tipo String y recortado a `Minigame.MAX_TEXT_LENGTH` (32); el
minijuego lo recibe en `_on_player_text(player, text, final)`. En partida local `player` es null y el
minijuego decide a quién le toca. Estadística de pruebas: `texts=N` en el log `mg_session`.

**Bomba de Palabras** (inspirada en BombParty): los jugadores se pasan una bomba por turnos; en cada turno hay
una combinación de 2-4 letras y hay que escribir una palabra española que la contenga, sin repetir. La mecha
es secreta (10-30 s al azar) y no se reinicia al acertar; al pasarla el siguiente recibe al menos 5 s reales.
**Al explotar, quien la tenía queda eliminado**; se sortea una bomba nueva (mecha nueva, mismo nivel y misma
aceleración) y se sigue con los que quedan. Termina cuando solo queda uno: gana, y el ranking sigue el orden
de eliminación (último eliminado = 2.º). Con 8 jugadores son hasta 7 explosiones (varios minutos).
- **Validación**: solo el host valida, con `SpanishDictionary` (`core/spanish_dictionary.gd`): 593 mil formas en
  `data/es_words.txt`, comparadas sin tildes (la ñ se conserva). Los datos se generan con
  `tools/build_dictionary.py` a partir del diccionario es_ES de LibreOffice (triple licencia GPLv3+/LGPLv3+/
  MPL 1.1+; se usa bajo MPL 1.1; textos de licencia en `data/DICCIONARIO_LICENCIA.md` y `data/MPL-1.1.txt`).
  **Antes de vender en Steam conviene que alguien con criterio jurídico revise esta licencia.** Para exportar
  el juego hay que incluir `*.txt` en los recursos exportados.
- **Dificultad**: 5 niveles de combinaciones (`data/es_tiers.txt`, 15 por nivel, de «AR» a «PSIC»); el nivel sube
  cada 5 palabras acertadas entre todos. Además la mecha corre un 4 % más deprisa por acierto (hasta ×2,2).
- **En tiempo real**: lo que escribe el jugador al que le toca (borrador) se ve en vivo en todos los PC
  (snapshots a 30 Hz); los eventos ok/bad/boom son fiables y disparan sonidos y animaciones.
- **Bots y autopiloto**: escriben palabras de ejemplo del diccionario (a veces fallan y la bomba explota). El
  autopiloto de un cliente envía su texto por la misma vía que una persona (así se prueba la red).
- **Sonido**: sintetizado por código (`core/synth_sfx.gd`), sin assets de terceros: tictac, tecla, acierto,
  error, paso de bomba, siseo de mecha y explosión.
- **Limitaciones**: hace falta teclado (un mando no puede escribir); la validación es la del diccionario
  ortográfico (no incluye todo el léxico coloquial ni los nombres propios).
- Pruebas: `tests/bomb_party_test.gd` y `ONLY=bomb_party tests/online_test.sh 4 1 0 normal` / `8 1 0 normal` /
  `4 1 0 kill_in_game` OK.

### Verificación completa con 8 minijuegos (Bomba de Palabras incluida)
Matriz de 10 escenarios con 9 rondas cada uno (sale cada minijuego al menos una vez; `tests/online_test.sh` lo
comprueba): 2/4/8 jugadores, 4 humanos + 4 bots, caída en lobby / minijuego de arena / LOCAL_PARALLEL (4 y 8),
caída del host y unión tardía: **10/10 OK** (7 en la primera pasada y 3 tras corregir el reloj del tope de espera
de LOCAL_PARALLEL). Cambios derivados de esa verificación:
- El tope de espera del host en LOCAL_PARALLEL usa el mismo reloj que los minijuegos (delta limitado a 0,05 s);
  antes, con las pruebas aceleradas, daba por no terminados a clientes que aún jugaban.
- El autopiloto de Salto Neón, Onda Neón y Columpio de Lengua se "cansa" a los 28 s de juego (solo pruebas) para
  que las partidas automáticas no se eternicen.

## 19. Audio (autoload `Audio`)

Todo el sonido se sintetiza por código (sin assets de terceros ni descargas):
- `core/sfx_catalog.gd` (`SfxCatalog`): ~40 efectos por nombre (interfaz, partida y minijuegos), generados la primera vez
  que se piden y cacheados. `core/synth_sfx.gd`: los de Bomba de Palabras.
- `core/synth_music.gd` (`SynthMusic`) + `core/music_catalog.gd` (`MusicCatalog`): generador de música (bajo, arpegio,
  melodía, batería y colchón sobre una escala y una progresión) con bucles exactos. 10 pistas; se renderizan en un hilo al
  arrancar (unos 12 s en total, el menú en ~1 s) y suenan en cuanto están listas.
- `autoload/audio_manager.gd`: buses `Music` y `SFX`, pool de efectos, fundido cruzado de música, ajustes en
  `user://settings.cfg` y F10 = silenciar/activar. En modo headless (pruebas) no genera ni reproduce nada.

Automático: todos los botones suenan (pasar el ratón y pulsar; los `DangerButton` suenan a "atrás"), música por estado de
la partida (menú/lobby/ajustes → `menu`, marcador → `scoreboard`, final → fanfarria + `final`), entrar/salir jugadores del
lobby, presentación del minijuego, transiciones, cuenta atrás (3-2-1-¡YA!), fin de minijuego, marcador (cada fila, los +N, el
tictac de los números y confeti) y pantalla final.

Por minijuego: la pista se declara en su `meta.tres` (`music`) y empieza en `Minigame.start()`; Reflejos va SIN música (pide
concentración). Los efectos propios se piden con `Audio.sfx(&"nombre")`; `Minigame.is_audible(player)` decide si un sonido
es "tuyo" (fuerte) o ajeno (bajito/ninguno). Machaca: pop que sube de tono + pitidos finales; Plataforma: crujidos, empujones,
caída y chapuzón; Monedas: moneda normal/dorada y sprint; Reflejos: señal, error y acierto; Salto Neón: salto, aterrizaje,
choque y hitos cada 100 m; Onda Neón: giro, choque y hitos; Columpio de Lengua: lengua, agarre, suelta, crujido y rotura del
gancho rojo, chapuzón, gruñido de la niebla y hitos; Bomba de Palabras: mecha, tic-tac, acierto, error, paso y explosión.

## 20. Caza del Foco (`spotlight`, HOST_AUTHORITATIVE)

Sillas musicales con luces. Hay un foco menos que jugadores vivos y se mueven por la pista (trayectorias curvas con rebote);
quien entra primero en un foco libre se lo queda mientras siga dentro (0,3 s de margen al salirse) y nadie puede robárselo
entrando. Al acabar la ronda, quien no tiene foco queda eliminado y desaparece un foco; se repite hasta que queda uno. El
ranking sigue el orden de eliminación (último eliminado = 2.º; dentro de una misma ronda, el más lejos de un foco cae antes).
- **Control**: moverse y un empujón con la acción (enfriamiento 1,3 s): alcanzar un foco que se escapa o sacar a un rival.
- **Dificultad por ronda**: focos más rápidos (190 → 390 px/s, siempre por debajo de lo que corre un jugador, ≈456 px/s, para
  que se puedan seguir), más pequeños (62 → 42 px de radio: poco más que un jugador, cabe uno solo; si entras en un foco ya ocupado sale una ✕ roja sobre tu avatar) y rondas más cortas (10 → 5,5 s). La ronda acaba antes si todos los focos
  están ocupados 1 s. Si nadie tuviera foco, se salva al más cercano a uno (siempre queda un superviviente).
- **Red**: sin código propio. El host simula; snapshots a 30 Hz (jugadores y focos, con extrapolación y suavizado en los
  clientes) y eventos fiables (`round`, `claim`, `unclaim`, `lock`, `win`, `dash`, `bump`) que disparan sonidos y animaciones.
- **Bots**: persiguen el foco libre (o el suyo) más cercano, con torpeza y un empujón ocasional.
- **Sonido**: pista propia `spot` (baile con tensión), `claim`/`unclaim` al ocupar o perder un foco, `lock` al cerrarse la ronda,
  pitidos en los 3 últimos segundos, choques y empujones; la fanfarria del final la pone el runner.
- Pruebas: `tests/spotlight_test.gd` (reglas, reclamar/soltar, eliminación, partidas de 2/3/6/8 bots) y
  `ONLY=spotlight tests/online_test.sh 4 1 0 normal` / `8 1 0 normal` / `4 1 0 kill_in_game` / `2 1 0 normal` OK.

## 21. Puntería (`target_range`, LOCAL_PARALLEL)

Juego de precisión: cada jugador juega en su pantalla (sin verse) y el host ordena por puntos; sin código de red propio
(`report_result(puntos, fallos)`, `_bot_result`, `_validate_result`).
- **Dianas**: aparecen y se esfuman si no se aciertan a tiempo (anillo de tiempo que se cierra). Las **doradas** duran la mitad,
  son más pequeñas y valen el triple (300 vs 100). Puntos por precisión (centro 100 %, borde 55 %) y por racha (cada 5 aciertos
  seguidos: ×1, ×2, ×3). Fallar: −25, rompe la racha y bloquea el disparo 0,2 s. Desempate: menos fallos.
- **Justo**: todas las dianas (posiciones y tiempos) salen de la semilla común (`Minigame.seed_value`), idénticas en todos los PC.
  Dificultad creciente en 30 s: aparecen cada vez más deprisa (0,78 → 0,30 s), duran menos (1,9 → 1,0 s) y se encogen (46 → 29 px).
- **Controles**: ratón (apuntar y clic; el cursor del sistema se oculta y se dibuja una mirilla), o teclado/mando: mover la mirilla y la
  acción para disparar. En partida local, cada humano juega su turno.
- **Validación**: el host rechaza puntuaciones por encima de (suma de puntos base × racha máxima).
- **Bots/autopiloto**: apuntan con tiempo de reacción humano y algo de error (`debug_ai_skill`); los bots offline puntúan un 22-75 %.
- **Sonido**: pista propia `aim` (arcade), `shot`, `hit`, `hit_gold`, `miss`, `combo`, aviso `gold_spawn` y pitidos finales.
- Pruebas: `tests/target_test.gd` y `ONLY=target_range tests/online_test.sh` (2/4/8 jugadores y `kill_in_parallel`) OK.

## 22. Tronco de Dagas (`knife_log`, HOST_AUTHORITATIVE)

Todos ven el mismo tronco girando y juegan por turnos (empieza uno al azar, sorteado en el host). En tu turno, la acción lanza
la daga: si cae sobre otra (ángulo local a menos de 0,2 rad), el jugador queda eliminado; si cae en un hueco, se clava y sigue el
siguiente vivo. Gana el último y el ranking sigue el orden de eliminación.
- **Dificultad**: cada daga acelera el giro (1,5 → 4,2 rad/s), a partir de la 6.ª el tronco "respira" (±35 %) y cada 5 dagas invierte
  el sentido pasando por cero. Caben unas 15 dagas, así que el hueco libre se estrecha. Sin lanzar en 6 s, la daga sale sola.
- **Física justa**: la daga tarda 0,1 s en llegar y el tronco sigue girando durante el vuelo; el impacto se evalúa al final con el
  giro de ese instante (un único cálculo en el host: nadie ve nada distinto).
- **Red**: sin código propio. Snapshots a 30 Hz (giro, velocidad, dagas, turno, tiempo) con extrapolación del giro en los clientes y
  eventos fiables (`turn`, `throw`, `stick`, `clang`, `win`) para sonidos y animaciones. El host consume las pulsaciones de todos
  los jugadores cada fotograma y solo cuenta la del que tiene el turno.
- **Bots**: esperan un hueco con margen y lanzan con un retraso humano (a más velocidad, más fácil fallar).
- **Sonido**: pista `log` (taberna con tensión), `throw`, `stick`, `clang`, pitidos cuando a tu turno le quedan 2 s y aviso de turno.
- Pruebas: `tests/knife_test.gd` (colisión, turnos, salida aleatoria, dificultad, partidas de 2/3/5/8 bots) y
  `ONLY=knife_log tests/online_test.sh` (2/4/8 jugadores; la caída en partida con 3 rondas) OK.

## 23. Salto Lunar (`moon_hop`, LOCAL_PARALLEL)

Un astronauta rueda y vuela por las colinas de la Luna; la partida dura **40 s** y gana quien llega más lejos (segundo, el segundo más
lejos, etc.). Cada jugador juega en su pantalla sobre el MISMO terreno (sale de la semilla común) y el host ordena por distancia; sin
código de red propio (`report_result(metros)`, `_bot_result`, `_validate_result`). **No se encontraron las reglas del "Moon Shot"
original de Playus** (la búsqueda no dio nada): es una interpretación propia del género de "colinas".
- **Control**: un botón. MANTENER = bajar (en el aire cae en picado; en el suelo la gravedad a lo largo de la pendiente es mayor: más
  ganancia bajando y más pérdida subiendo). SOLTAR = planear: se despega por las cimas y se flota con **poca gravedad** (420 px/s²) para
  volar muy alto (más de 1 000 px sobre el suelo).
- **Cámara con zoom**: encuadra siempre la bola Y el punto más bajo del terreno en los próximos ~700 px (donde va a caer): cuanto más
  alto vuelas, más se aleja (zoom de 1,0 a 0,2) y el astronauta se dibuja más grande para no perderlo. `tests/moon_test.gd` comprueba que
  la bola y el suelo se ven en ≥ 97 % de los fotogramas y también a 2 400 px de altura.
- **Nunca se para**: hay una velocidad mínima (260 px/s) en el suelo y en el aire, y la partida no termina antes de los 40 s.
- **Física** (paso fijo 120 Hz): en el suelo `v += −G·sen θ·dt` (G = 1400, 2600 manteniendo); despega cuando la trayectoria balística queda
  por encima del terreno; al aterrizar solo se conserva la velocidad a lo largo del terreno (más un 20 % de perdón de la caída contra el
  suelo). Caer paralelo a una ladera de bajada (cos ≥ 0,90) es **¡PERFECTO!** y da un +12 % de velocidad; caer contra una subida o en llano
  frena (¡PORRAZO!). Tope de velocidad 2 100 px/s en el suelo y 2 600 en el aire.
- **Terreno**: puntos de control de cima y valle alternados unidos con coseno suave; montañas cada vez más altas y cortas (pendiente
  máx. ≈ 58°), alguna extra alta; 140 000 px (2 800 m) de longitud.
- **Autopiloto/bots**: la IA mantiene al bajar y suelta al subir; en el aire sube primero y pica al caer sobre una bajada. `debug_skill` la
  hace más torpe. Políticas ingenuas: nunca mantener ≈ 320 m, siempre mantener ≈ 400 m; la IA ≈ 500-600 m.
- **Sonido**: pista `moon` (espacial), `dive`, `launch`, `perfect`, golpe en los porrazos, hitos cada 100 m y pitidos finales.
- Pruebas: `tests/moon_test.gd` y `ONLY=moon_hop tests/online_test.sh` (2/4/8 jugadores y `kill_in_parallel`) OK.

## 24. Ninja Trepador (`ninja_climb`, LOCAL_PARALLEL)

Inspirado en Ninja Climb: dos paredes verticales enfrentadas y un ninja que sube saltando de una a otra. Cada jugador juega en su
pantalla sobre las MISMAS paredes (semilla común) durante 45 s; gana la **altura máxima** (segundo, el segundo más alto...); sin
código de red propio (`report_result(metros)`, `_bot_result`, `_validate_result`).
- **Mecánica central**: desde el ninja sale una trayectoria de PUNTOS que oscila sola entre 20° y 60° (periodo 1,6 s → 1,1 s con la
  altura). El jugador no la dirige: el único botón (acción o clic izquierdo) hace saltar AL INSTANTE con el ángulo de ese momento; no
  hay carga de potencia. Sin pulsar, el ninja se desliza despacio (36 px/s). Un tic suave marca cada extremo de la oscilación.
- **Los puntos son el salto**: la misma función (`pos_at`/`trajectory`, paso 1/240) calcula el dibujo, el salto y la comprobación de
  choques; la trayectoria acaba en ○ (aterrizaje libre) o en ✕ (choque con pinchos). `tests/ninja_test.gd` comprueba que coinciden al píxel.
- **Física**: velocidad inicial fija (1 238 px/s) y gravedad 1 800 px/s²; la horizontal es constante, así que siempre llega a la otra pared
  y el ángulo solo decide la altura ganada (29 px a 20° → 303 px a 60°, creciente en todo el rango): más vertical = más altura.
- **Recorrido** (igual para todos): bloques con pinchos en las paredes. Cada zona de aterrizaje es un hueco entre dos bloques que se
  estrecha con la altura (±80 → ±52 px); el ninja muere al aterrizar contra un bloque, al deslizarse contra uno o al caer más de 250 px por
  debajo de la cámara (que solo sube). Las zonas son alcanzables unas desde otras con el rango de ángulos.
- **Bot/autopiloto**: salta en cuanto el ángulo actual (y los de alrededor, según su tolerancia) llevan a un aterrizaje seguro con progreso y
  margen para deslizarse; un bot exacto sube ~235 m en 45 s sin morir y con ±4° y 0,06 s de retraso llega a ~115 m.
- **Sonido**: pista `ninja` (pentatónica oriental), `swish` al saltar, `wall` al agarrarse, tic en los extremos de la oscilación, golpe al
  morir, hitos cada 25 m y pitidos finales.
- Pruebas: `tests/ninja_test.gd` y `ONLY=ninja_climb tests/online_test.sh` (2/4/8 jugadores y `kill_in_parallel`) OK.

## 25. Práctica jugable en la pantalla de presentación (`MinigamePractice`)

Cada minijuego se presenta con un recuadro en miniatura donde **se juega de verdad** (con los controles reales y los bots de rivales) y un
texto corto (`MinigameMeta.short_text`, ≤ 90 letras; el `instructions` largo ya no se muestra). La práctica no cuenta para nada y se
reinicia sola al acabar.
- **Cómo**: el propio minijuego corre dentro de un `SubViewport` reducido (con `size_2d_override` 1280x720, así que el juego ve su pantalla
  de siempre) y un `SubViewportContainer` le reenvía ratón y teclado (clic para Puntería/Ninja, escribir en Bomba de Palabras...). Se ejecuta
  con `Minigame.demo = true` (sin música propia: sigue la del menú; Puntería no oculta el cursor) y `is_authority = true` sin sesión de red.
- **Quién juega**: en los minijuegos compartidos (HOST_AUTHORITATIVE) hay un recuadro y juegan a la vez todas las personas de este PC (modo local:
  todas; online: la de este PC), y el resto del reparto (remotos incluidos) como bots con su nombre y color. En los de "cada uno en su pantalla"
  (LOCAL_PARALLEL) sale solo TU pantalla de práctica (la de la primera persona de este PC), sin las de los demás.
- **Pantalla**: el botón de acción se usa para jugar, así que ya no salta la presentación; avanza con ¡LISTO! (clic), ESC o sola a los 25 s (7 s en
  pruebas/autopiloto). Online solo avanza el host; los demás siguen practicando hasta que empiece. Si el contenido no cabe, se reduce (`UIKit.fit_to_screen`).
- **Headless** (pruebas automáticas): no se crea la práctica (solo el marco), para no meter ruido ni coste en los tests online.
- Pruebas: `tests/practice_test.gd` (fuerza la práctica en headless: arrancan los 15 minijuegos, un solo recuadro, textos cortos y reinicio).

## 26. Carrera de Ruinas (obstacle_run) — primer minijuego en 3D

- **Modelo**: HOST_AUTHORITATIVE: todos corren A LA VEZ por el mismo recorrido y se ven unos a otros; la cámara de cada PC va en tercera persona
  detrás de SU personaje (nombre flotando sobre cada corredor, flecha amarilla sobre el tuyo, minimapa con todos). Controles: WASD o flechas (o
  palanca) relativos a la cámara y ESPACIO o CLIC para saltar (el clic izquierdo es un botón de acción más para el teclado 1 y el jugador online).
  Inspirado en un parkour de ruinas flotantes sobre la niebla.
- **Recorrido** (`_ensure_level`, de la semilla común; ~220 m con giros): SALIDA → PIEDRAS (pilares con huecos) → VIGA (pasarela estrecha con
  hueco y esquina) → ESCALERAS → PLATAFORMAS (losas que se deslizan) → BARRA (barra giratoria que lanza a todos) → COLUMNAS (cada vez más altas) →
  FINAL (saltos largos) → arco de meta. Cada zona empieza con un punto de control; caer a la niebla (y < -11) devuelve al último.
- **Host**: simula a todos a 60 Hz fijos (`_simulate`; sin motor de físicas): un `RS` por corredor con colisión contra cajas alineadas a los
  ejes (`Solid`), subida automática de escalones (0,55 m), salto con coyote time y buffer (la pulsación queda pendiente hasta el siguiente paso),
  plataformas móviles que arrastran y barra giratoria. Los corredores no chocan entre sí. Quien va muy rezagado corre hasta un 10 % más.
  La entrada se interpreta respecto al `yaw` de cada jugador (sigue el recorrido y viaja en el estado), así que es igual en todos los PCs.
- **Red**: estado ~30 Hz con `PackedFloat32Array` (18 floats por corredor) + tiempo/cuenta atrás/fin; eventos `jump/land/fall/bar/cp/zone/fin/beep/go/over`.
  Los clientes interpolan posición, orientación y tiempo de carrera (losas y barra).
- **Fin**: llegan todos, 20 s después del primero o a los 90 s. Ranking: quien llega, por tiempo; los demás, por metros.
- **3D**: `SubViewport` con `own_world_3d = true` (cámara, luz con sombras, cielo de atardecer, niebla, mar de nubes, ruinas lejanas y escombros
  flotantes) detrás del `DrawSurface`, que dibuja el HUD. Piedra con textura procedural y personajes con contorno. Funciona dentro de la práctica.
- **IA** (bots, autopiloto, práctica): sigue la ruta guardada (`_route`) por su carril (reparte a los bots por las losas anchas), salta en bordes y
  muros, espera alineada con las losas móviles, salta la barra y frena en el aire para caer sobre la losa. Las pruebas exigen que complete todos
  los recorridos y que una carrera con 5 corredores acabe con ranking correcto y estado idéntico en un "cliente".
- Pruebas: `tests/obstacle_test.gd`; captura: `tools/run_shot.gd`.

## 27. Pelea de Palabras (word_fight) y el segundo botón

- **Juego** (copia de la "Pelea de palabras" de Pummel Party): HOST_AUTHORITATIVE, 3D con cámara fija. Arena metálica sci-fi con 26 casillas con letras
  (A-F abajo … Y-Z arriba, centradas). Sobre cada cabeza flota la palabra del momento (la misma para todos; en verde lo que llevas). Se deletrea
  PISANDO la casilla y pulsando ESPACIO o CLIC IZQUIERDO: +1 por letra acertada (el fallo bloquea 0,35 s); quien completa la palabra gana +3 y la palabra
  cambia para todos (el progreso de todos vuelve a 0). Con E o CLIC DERECHO se golpea al que tengas delante: aturde 1,7 s, empuja, le quita una letra
  de lo que llevaba y le da inmunidad un momento (no se encadena). Dura 90 s; gana quien más puntos tenga. Las palabras se alargan con la partida.
- **Segundo botón** (nuevo en la capa de entrada): acción "action2" por jugador (teclado 1: E y clic derecho; teclado 2: 0 del teclado numérico o ".";
  online: E / 0 numérico / clic derecho; mando: X/Y). `InputManager.action2_presses`, `Minigame.action2_presses/_bot_action2`, y por la red el
  contador monótono "c2" en el mensaje de entrada (`{"op":"in","m":..,"c":..,"c2":..}`), igual que "c". En el mando, acción = A/B y action2 = X/Y.
- **Red**: estado ~30 Hz (11 floats por jugador + palabra, tiempo, cuenta atrás); eventos `ok/bad/word/swing/hit/over/beep/go`.
- **IA**: va a la casilla de su siguiente letra, espera un tiempo de reacción y pulsa; a veces se lanza a por el líder y le golpea.
- **3D**: `SubViewport` con mundo propio: suelo de paneles (textura procedural), franjas de peligro, vórtices azules que giran, consola con luces,
  gusanos decorativos, personajes con contorno y anillo de color, estrellas al estar aturdidos, letras que se hunden y brillan al pulsarse.
- Pruebas: `tests/word_fight_test.gd`; captura: `tools/word_shot.gd`.

## 28. Crono a Ciegas (`blind_timer`, HOST_AUTHORITATIVE)

Un cronómetro en el centro y todos los jugadores sentados alrededor. Hay un tiempo objetivo al azar (entero, 5-15 s, de la semilla
común) y el crono cuenta desde 0, pero al poco rato desaparece: hay que seguir contando de cabeza y pulsar la acción justo en el objetivo.
- **Reglas**: cada jugador para UNA vez (las pulsaciones del primer segundo no cuentan, para evitar paradas por accidente). Se cierra
  cuando han parado todos o 4 s después del objetivo. Gana quien queda más cerca, por arriba o por abajo; a igual error, quien pulsó
  antes; quien no paró queda último.
- **Anuncio**: al empezar, el objetivo sale en grande a pantalla completa («PÁRALO EN 13 SEGUNDOS») durante 2,6 s; el crono arranca
  después (evento `go`) y hasta entonces no se puede parar ni se ve el objetivo en el reloj.
- **El crono desaparece** al 40 % del objetivo (mínimo 2 s, máximo 5 s) y se desvanece en 0,6 s; el objetivo sigue siempre a la vista.
- **Destape**: nadie ve ningún tiempo (ni el suyo) hasta el final; entonces se destapan del último al primero con su diferencia (±).
- **Red**: sin código propio. Snapshots a 30 Hz (fase, crono, objetivo y quién ha parado) y eventos fiables (`announce`, `go`, `hide`, `stop`, `reveal`).
  Los tiempos solo viajan en el evento `reveal`, así que un cliente no puede verlos antes. El cliente hace avanzar el crono entre snapshots.
- **Bots/autopiloto**: paran en el objetivo con un error humano (σ ≈ 0,18 s + 4,5 % del objetivo).
- **Sonido**: SIN música (un ritmo de fondo serviría para contar); tic por segundo mientras el crono se ve, `swoosh` al desaparecer,
  `claim` al parar y redoble en el destape.
- Pruebas: `tests/blind_timer_test.gd` y `ONLY=blind_timer tests/online_test.sh 4 2 0 normal` OK; captura: `tools/timer_shot.gd`.

## Puente Personal (`personal_bridge`, HOST_AUTHORITATIVE)

Copia del "Puente personal" de Pummel Party. Todos en una plataforma central rodeada de torres; cada torre tiene su puente y un
premio (+1, un +2 desde 4 puentes y un oro +3, barajados con la semilla común en cada ronda).
- **Se adapta al nº de jugadores**: jugadores + 1 puentes (mínimo 3, máximo 9) en círculo. 3 rondas de 8 s para elegir.
- **Elegir**: con el RATÓN (clic en el puente o su torre) o apuntando con la dirección (WASD / flechas / stick). Se puede cambiar
  hasta que acaba el tiempo. Al acabar, todos cruzan: un puente con más de un jugador se rompe (nadie cobra, cuenta una caída);
  quien cruza solo cobra su premio. Quien no eligió se queda en el centro. Gana quien más suma; a igualdad, menos caídas.
- **Secreto**: durante la elección el estado solo dice QUIÉN ha elegido (marca coral → menta bajo cada jugador), no QUÉ. Las
  elecciones viajan en el evento `reveal` y en el estado ya fuera de la fase de elegir. Cada PC pinta su propia elección al momento.
- **Red**: sin código propio. El clic va al host por el canal de texto del minijuego (`submit_text("b:<n>")`; en partida local
  llega sin dueño y es del jugador del ratón: teclado 1). La dirección llega con la entrada normal; el host solo la aplica cuando
  cambia el puente señalado, para no pisar un clic. Eventos `pick` (sin el puente), `reveal`, `round`, `end`.
- **Bots/autopiloto**: eligen en un momento al azar; el oro les tienta (≈30 % + algo más con pocos jugadores), luego el +2.
- Pruebas: `tests/personal_bridge_test.gd` y `ONLY=personal_bridge tests/online_test.sh 3 1 1 normal` OK; captura: `tools/bridge_shot.gd`.

## Disparos Diligentes (`diligent_shots`, HOST_AUTHORITATIVE)

Copia del "Disparos diligentes" de Pummel Party: una caseta de feria con una fila de huecos y todos los jugadores delante, cada uno
con su escopeta láser apuntando a la fila.
- **Se adapta al nº de jugadores**: cada jugador tiene su tramo de huecos con su color (4 con 2 jugadores, 3 hasta 5 y 2 a partir
  de 6: de 8 a 16 huecos), pero cualquiera puede disparar a cualquier hueco. 45 s.
- **Oleadas** (semilla común): pausa de 0,7-1,5 s y después, o bien dianas en varios huecos a la vez (del 35 % al 100 %), o bien
  bombas con la mecha encendida durante 0,9-2 s que luego se cambian por dianas (la trampa para los que disparan sin mirar). Las
  dianas duran de 2,6 s (al principio) a 1,9 s (al final) o hasta que no queda ninguna. Desde el 40 % de la partida, algunas oleadas
  de dianas traen alguna bomba mezclada.
- **Puntos**: el primero que acierta una diana se la lleva: +7 ¡EXCELENTE! (antes de 0,5 s), +5 ¡BIEN! (antes de 1 s), +2 ¡LENTO!.
  Bomba: -5 ¡BANG! y aturdido 1,4 s (sin mira ni disparo). Hueco vacío o entre huecos: -2 ¡FALLASTE! y arma encasquillada 0,45 s.
  0,22 s entre disparos. Los puntos no bajan de 0. Si varios disparan en el mismo frame, el orden se sortea. Gana quien más
  puntos tiene; a igualdad, quien tocó menos bombas.
- **Controles**: izquierda/derecha mueve la mira (760 px/s); la acción dispara. Ratón: clic en un hueco = apuntar ahí y disparar;
  clic fuera de la fila = disparar donde se apunta. Táctil: joystick + botón DISPARAR.
- **Red**: sin código propio. Snapshots a 30 Hz (fase, tiempo, contenido de los huecos, miras, puntos y aturdimiento) y eventos
  fiables `shot` (jugador, hueco, resultado, puntos, x de la mira: popups, sonido y fogonazo) y `end`. El clic va al host por el
  canal de texto del minijuego (`submit_text("s:<hueco>")`; en partida local llega sin dueño y es del jugador del ratón: teclado 1).
- **Bots/autopiloto**: reaccionan a los 0,25-0,85 s de salir la oleada, van a la diana libre más cercana y disparan al tenerla en
  la mira; en un 10 % de las oleadas de bombas "se les escapa el dedo" y disparan a una.
- Pruebas: `tests/diligent_shots_test.gd`; captura: `tools/shots_shot.gd`.
