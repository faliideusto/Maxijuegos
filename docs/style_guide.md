# Guía de estilo visual

Referencia de estilo: la app móvil **playus: Daily Group Challenge** (Dapps Pte. Ltd., `club.playus` en Google Play).
Objetivo: replicar el **estilo**, nunca los assets. Todo lo del juego es original, generado por código o con licencia libre.

> **Fuentes y limitaciones de esta investigación.**
> Lo que he podido ver es la ficha de Google Play: icono y 5 capturas promocionales (a baja resolución),
> más el texto de la ficha. No he podido ver vídeos de gameplay ni reseñas con detalle visual, así que lo que
> sigue es una **aproximación** sacada de material de marketing, que suele estar más pulido que el juego real.
> Los hex se han **muestreado de la captura** (píxeles del fondo, icono y barras) y redondeado a mano.
> Si pasas capturas de gameplay (pantallas de partida, marcador, menús) afinamos esta guía y `ui/palette.gd`.

## 1. Paleta

| Rol | Hex aprox. | Uso |
|---|---|---|
| Fondo principal (violeta) | `#6A58EA` | Fondo de todas las pantallas, con degradado suave a `#4F3FC4` abajo |
| Violeta oscuro | `#3B2A9E` | Sombras "duras" de botones, contornos de texto, tarjetas oscuras de marcador |
| Violeta tarjeta | `#4A3AB8` | Paneles/tarjetas sobre el fondo (marcador, lobby) |
| Amarillo acción | `#FFC81E` | Botón primario, destacados, títulos, el "1º" |
| Amarillo oscuro | `#C98F00` | Borde inferior (sombra) del botón primario |
| Blanco | `#FFFFFF` | Texto principal, botón secundario, contornos de avatares |
| Coral | `#FA7473` | Barras/acentos de jugador, botón de peligro/salir |
| Verde menta | `#2ED1A2` | Confirmaciones, barras de jugador, "listo" |
| Turquesa | `#2DC7D9` | Acento secundario |

**Colores de jugador (8)**, saturados y alegres, distinguibles entre sí y sobre el violeta:
coral `#FF5A6E`, naranja `#FF9F43`, amarillo `#FFD23F`, verde `#4ADE80`, turquesa `#2DD4BF`,
azul `#4DA8FF`, rosa `#FF7AC6`, lila claro `#E1DAFF`.

Reglas de uso: un solo fondo violeta dominante; el **amarillo es el único color de "acción principal"**;
el resto de colores saturados se reservan para jugadores y minijuegos. Nunca texto gris sobre el violeta.

## 2. Formas e ilustración

- **Muy redondeado**: radios de 20-32 px en tarjetas y botones, "píldoras" para chips. Cero esquinas rectas.
- **Plano con volumen "falso"**: colores planos, sin texturas; el volumen viene de una **sombra dura inferior**
  (un borde más oscuro de 6-8 px debajo del botón) y de brillos blancos sutiles, no de degradados realistas.
- **Contornos**: el texto de título lleva contorno oscuro grueso; los avatares, un borde blanco/oscuro.
- Los minijuegos de las capturas son **isométricos / low-poly** (bloques, caminos en zigzag, pelotas) con colores
  vivos sobre fondo violeta. Nosotros empezamos en 2D plano con formas simples y el mismo lenguaje de color.
- Los elementos decorativos de fondo (formas flotantes, destellos) son sutiles y de baja opacidad.

## 3. Tipografía

Estilo: **redondeada, gruesa, muy legible**, con titulares en mayúsculas, inclinados o con contorno/sombra, y
números grandes. Alternativas libres (licencia OFL, Google Fonts) que encajan:

- **Fredoka** (titulares y botones) — la más cercana: redondeada y amistosa.
- **Baloo 2** (alternativa) — redondeada, muy buena para texto en español (acentos, ñ).
- **Nunito** (texto de párrafo/instrucciones) — legible a tamaños pequeños.

Estado actual: el tema usa `SystemFont` con esa lista de nombres como preferencia y cae a la fuente del sistema.
Pendiente: incluir los `.ttf` (OFL) en `res://ui/fonts/` y apuntar el tema a ellos.

Jerarquía: título 72-96 px · cabecera 40 px · cuerpo 24 px · botones 32 px · números de marcador 48 px.

## 4. Componentes de UI

- **Botón primario**: amarillo, texto violeta oscuro, borde inferior `#C98F00` de 6 px, radio 24.
  Hover: escala 1.06. Pulsado: se hunde (el borde inferior desaparece) y escala 0.94, rebota al soltar.
- **Botón secundario**: blanco, texto violeta oscuro, sombra violeta oscuro.
- **Botón de peligro**: coral. **Deshabilitado**: violeta apagado con 50 % de opacidad.
- **Tarjetas**: violeta `#4A3AB8` (o blanco para destacar), radio 28, sombra suave desplazada hacia abajo.
- **Marcador**: filas tipo píldora con avatar, nombre, barra de puntuación coloreada y números grandes;
  las filas se reordenan con animación y aparece un "+N" que salta junto al total.
- **Cuenta atrás**: números enormes con rebote (3, 2, 1, ¡YA!).

## 5. Transiciones y animaciones

Todo "juicy": nada aparece de golpe.
- Entrada de elementos con **rebote elástico** (`TRANS_BACK`/`TRANS_ELASTIC`), escalonada de 60-80 ms.
- Transición entre pantallas: **cortina** de color que barre la pantalla (~0.35 s).
- Botones con micro-rebotes al pasar el ratón / pulsar; números que "saltan" al cambiar.
- Final de partida: **confeti** y avatar ganador grande con corona.
- Duraciones cortas (0.15-0.45 s); la UI nunca hace esperar.

## 6. Jugadores

- Avatar = **círculo de color de jugador** con borde, dos ojos grandes y blancos con pupila, y mirada que sigue la
  dirección de movimiento; sin brazos ni piernas (formas puras, fácil de generar por código).
- En el marcador: avatar + nombre + color; el color identifica al jugador en **todos** los minijuegos.
- Hasta 8 colores fijos por ranura; el jugador puede cambiar su color en el lobby (sin duplicados).

## 7. Tono y sensaciones

Casual, **alegre y competitivo suave**: partidas cortas, textos breves y en tono cercano ("¡A machacar!"),
mucho feedback visual (rebotes, squash & stretch, confeti, números grandes), colores saturados sobre fondo
violeta. Nada serio ni oscuro; el rival es un amigo, no un enemigo.

## 8. Implementación

- Paleta y constantes: [`ui/palette.gd`](../ui/palette.gd) (única fuente de verdad).
- Tema global: [`ui/theme.tres`](../ui/theme.tres), **generado** por [`tools/build_theme.gd`](../tools/build_theme.gd).
  Para cambiar el estilo: editar `palette.gd`/`build_theme.gd` y ejecutar
  `godot --headless --path . --script res://tools/build_theme.gd`.
- Variaciones de tipo del tema: `PrimaryButton`, `SecondaryButton`, `DangerButton`, `TitleLabel`, `HeaderLabel`,
  `CardPanel`, `LightCardPanel`, `ChipPanel`.
- Componentes: `JuicyButton`, `PlayerAvatar`, `BackgroundFX`, `Confetti` en `ui/components/`.
