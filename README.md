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
godot --headless --path . --script res://tests/cube_level_test.gd                  # nivel de Salto Neón: superable y con puertas efectivas
godot --headless --path . --script res://tests/wave_level_test.gd                  # pasillo de Onda Neón: superable (bot en bucle cerrado)
godot --headless --path . --script res://tests/practice_test.gd                     # práctica jugable de la presentación de cada minijuego
godot --headless --path . --script res://tests/ninja_test.gd                        # Ninja Trepador: salto, trayectoria de puntos y recorrido
godot --headless --path . --script res://tests/moon_test.gd                         # Salto Lunar: terreno, física y autopiloto
godot --headless --path . --script res://tests/knife_test.gd                        # Tronco de Dagas: colisión, turnos y partidas con bots
godot --headless --path . --script res://tests/target_test.gd                       # Puntería: dianas, puntuación y autopiloto
godot --headless --path . --script res://tests/spotlight_test.gd                    # Caza del Foco: reglas y partidas con bots
godot --headless --path . --script res://tests/bomb_party_test.gd                  # Bomba de Palabras: diccionario, niveles y reglas
godot --headless --path . --script res://tests/tongue_level_test.gd                # recorrido de Columpio de Lengua (se genera con tools/gen_tongue_level.gd)
GODOT=/ruta/godot tests/online_test.sh 4 4 0 normal                  # 4 instancias reales por red
GODOT=/ruta/godot tests/run_matrix.sh                                # matriz completa (varios minutos)
godot --headless --path . --script res://tools/build_theme.gd        # regenera ui/theme.tres
```

Documentación: [arquitectura](docs/architecture.md) · [red y modelos](docs/network.md) · [estilo](docs/style_guide.md).

## Sonido

Todo el audio (efectos y música) se genera por código al arrancar; no hay archivos de audio. **F10** silencia o activa el sonido (el ajuste se guarda en `user://settings.cfg`).
