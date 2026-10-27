# MaxiJuegos

Party game multijugador (2-8 jugadores, un jugador por PC online) de minijuegos, hecho en Godot 4
(GDScript). Título de trabajo.

- Godot 4.7 (Compatibility renderer). Abrir la carpeta con el editor y pulsar ▶.
- **Online**: "JUGAR ONLINE" → uno crea la sala (host) y los demás se unen por IP (puerto 24680).
  Controles: WASD o flechas + Espacio/Enter, o mando (stick + A).
- **Modo local (pruebas)**: teclado 1 = WASD + Espacio · teclado 2 = flechas + Enter · mando; con bots.
- Dos modelos de minijuego (`execution_mode` en su `meta.tres`): `HOST_AUTHORITATIVE` (arena compartida) y
  `LOCAL_PARALLEL` (cada uno su prueba, el host recoge resultados). Ver [docs/network.md](docs/network.md).

## Probar varias instancias a mano (Windows)

```powershell
.\tools\dev_multi.ps1 -Count 3                       # 3 ventanas (host + 2 clientes)
.\tools\dev_multi.ps1 -Count 2 -Bots 6 -AutoStart    # 8 jugadores con 2 ventanas
```

Necesita la variable de entorno `GODOT` (o `-Godot <ruta>`).

## Pruebas (sin ventana)

```bash
godot --headless --path . --import                                   # primera vez
godot --headless --path . --script res://tests/smoke_test.gd -- 4 4  # partida local con bots
godot --headless --path . --script res://tests/input_test.gd
godot --headless --path . --script res://tests/parallel_local_test.gd -- --log
godot --headless --path . --script res://tests/idle_turn_test.gd                   # modo local por turnos: un turno sin nadie lo juega la IA
godot --headless --path . --script res://tests/cube_level_test.gd                  # nivel de Salto Neón: superable y con puertas efectivas
godot --headless --path . --script res://tests/wave_level_test.gd                  # pasillo de Onda Neón: superable (bot en bucle cerrado)
godot --headless --path . --script res://tests/practice_test.gd                     # práctica jugable de la presentación de cada minijuego
godot --headless --path . --script res://tests/ninja_test.gd                        # Ninja Trepador: salto, trayectoria de puntos y recorrido
godot --headless --path . --script res://tests/obstacle_test.gd                     # Carrera de Ruinas 3D: recorrido, física, IA y resultado
godot --headless --path . --script res://tests/uphill_test.gd                       # Cuesta Arriba 3D: tráfico, puntos, atropellos, saltos e IA
godot --headless --path . --script res://tests/word_fight_test.gd                    # Pelea de Palabras 3D: casillas, golpes, segundo botón, IA y red
godot --headless --path . --script res://tests/impostor_test.gd                     # Impostor a Bordo 3D: nave, tareas, eliminar, votar, victoria, IA y red
godot --headless --path . --script res://tests/pair_escape_test.gd                  # Fuga en Pareja 3D: solo con nº par, laberinto, tropiezos, rejas a dúo, relevos con botones, IA y red
godot --headless --path . --script res://tests/moon_test.gd                         # Salto Lunar: terreno, física y autopiloto
godot --headless --path . --script res://tests/knife_test.gd                        # Tronco de Dagas: colisión, turnos y partidas con bots
godot --headless --path . --script res://tests/target_test.gd                       # Puntería: dianas, puntuación y autopiloto
godot --headless --path . --script res://tests/spotlight_test.gd                    # Caza del Foco: reglas y partidas con bots
godot --headless --path . --script res://tests/blind_timer_test.gd                 # Crono a Ciegas: objetivo, crono que desaparece, ranking y partidas con bots
godot --headless --path . --script res://tests/personal_bridge_test.gd             # Puente Personal: puentes según jugadores, clic/dirección, puentes que se rompen y partidas con bots
godot --headless --path . --script res://tests/diligent_shots_test.gd            # Disparos Diligentes: 3 dianas por jugador, A/W-S/D apuntan, ritmo creciente, bombas, clic y partidas con bots
godot --headless --path . --script res://tests/sniper_test.gd                     # Francotiradores 3D: mapa según jugadores, tiros, paredes, protección, red y partidas con bots
godot --headless --path . --script res://tests/feather_catch_test.gd            # Plumas al Vuelo: atrapar plumas (+1/+3/-3), una por cierre, ratón, red y partidas con bots
godot --headless --path . --script res://tests/rail_cannons_test.gd              # Vagonetas Cañoneras: raíles según jugadores, conducción, balas (diana/empujón), setos, moneda S y partidas con bots
godot --headless --path . --script res://tests/rainbow_kart_test.gd             # Karts Arcoíris 3D: pista con puente, conducción, derrape y turbo, caídas y nube, rampa, objetos, carreras con bots, red y pantalla partida
godot --headless --path . --script res://tests/bomb_party_test.gd                  # Bomba de Palabras: diccionario, niveles y reglas
godot --headless --path . --script res://tests/tongue_level_test.gd                # recorrido de Columpio de Lengua (se genera con tools/gen_tongue_level.gd)
GODOT=/ruta/godot tests/online_test.sh 4 4 0 normal                  # 4 instancias reales por red
GODOT=/ruta/godot tests/run_matrix.sh                                # matriz completa (varios minutos)
godot --headless --path . --script res://tools/build_theme.gd        # regenera ui/theme.tres
```

Documentación: [arquitectura](docs/architecture.md) · [red y modelos](docs/network.md) · [estilo](docs/style_guide.md).

## Sonido

Todo el audio (efectos y música) se genera por código al arrancar; no hay archivos de audio. **F10** silencia o activa el sonido (el ajuste se guarda en `user://settings.cfg`).

## Versión web (online con salas por código)

```bash
godot --headless --path . --export-release "Web" build/web/index.html   # necesita las plantillas de exportación web
python -m http.server 8765 --directory build/web                         # y abrir http://localhost:8765
```

En web el menú ofrece "JUGAR CON AMIGOS" y "JUGAR CONTRA BOTS" (tú + 3 bots). **Online en web**: "CREAR SALA" da un código
de 4 caracteres (y "COPIAR ENLACE" un enlace `...?sala=K7QF` que abre el juego directamente en esa sala); los demás lo escriben en
"UNIRSE". Los navegadores se conectan entre sí por WebRTC (`net/webrtc_backend.gd`) y solo usan el servidor público de PeerJS para
encontrarse: no hace falta servidor propio. La versión de escritorio sigue uniéndose por IP (no juegan entre sí).
**Música en web**: la exportación sin hilos no puede generarla al arrancar, así que usa las pistas ya generadas de `audio/music/`;
tras cambiar `MusicCatalog` o `SynthMusic`, regenerarlas con `GODOT=/ruta/godot tools/bake_music.sh` (necesita ffmpeg).
**Publicación**: `.github/workflows/web.yml` exporta en cada push a `main` y deja el resultado en la rama `web`, que publica Vercel.
Prueba online en navegadores: `tests/web/serve.sh` y `node tests/web/online_test.js 2 2` (Playwright + PeerJS local).

En móvil o tableta aparecen controles táctiles
(`autoload/touch_controls.gd`): joystick y botones en los minijuegos con movimiento, y tocar la pantalla en los de un botón. El preset `Web` de
`export_presets.cfg` deja fuera Bomba de Palabras y el diccionario (`data/`), las pruebas y las herramientas.
