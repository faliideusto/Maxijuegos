# MaxiJuegos

Party game multijugador (2-8 jugadores) de minijuegos, hecho en Godot 4 (GDScript). Título de trabajo.

- Godot 4.7 (Compatibility renderer). Abrir la carpeta con el editor y pulsar ▶.
- Controles: Teclado 1 = WASD + Espacio · Teclado 2 = Flechas + Enter · Mando = stick/cruceta + A.
- Se pueden añadir **bots** en el lobby para probar solo.

## Pruebas (sin ventana)

```bash
godot --headless --path . --import                                   # primera vez
godot --headless --path . --script res://tests/smoke_test.gd -- 4 3  # 4 jugadores, 3 minijuegos
godot --headless --path . --script res://tests/net_test.gd -- host   # y en otra terminal: -- client
godot --headless --path . --script res://tools/build_theme.gd        # regenera ui/theme.tres
```

Más información: [docs/architecture.md](docs/architecture.md) · [docs/style_guide.md](docs/style_guide.md).
