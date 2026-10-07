class_name Palette
extends RefCounted
## Paleta de colores y constantes de estilo. ÚNICA fuente de verdad visual:
## la usan tanto el generador del tema (tools/build_theme.gd) como el código de juego.
## Ver docs/style_guide.md.

# --- Fondos y superficies ---
const BG_TOP := Color("6A58EA")        # violeta principal
const BG_BOTTOM := Color("4F3FC4")     # violeta del degradado inferior
const PURPLE_DARK := Color("3B2A9E")   # sombras duras, contornos de texto
const CARD := Color("4A3AB8")          # tarjetas sobre el fondo
const CARD_LIGHT := Color("E1DAFF")    # lila claro (plataformas, chips)

# --- Acentos ---
const YELLOW := Color("FFC81E")        # acción principal
const YELLOW_DARK := Color("C98F00")   # sombra del botón primario
const WHITE := Color("FFFFFF")
const CORAL := Color("FA7473")
const CORAL_DARK := Color("B84A4A")
const MINT := Color("2ED1A2")
const TEAL := Color("2DC7D9")

# --- Colores de jugador (8 ranuras) ---
const PLAYER_COLORS: Array[Color] = [
	Color("FF5A6E"), # coral
	Color("FF9F43"), # naranja
	Color("FFD23F"), # amarillo
	Color("4ADE80"), # verde
	Color("2DD4BF"), # turquesa
	Color("4DA8FF"), # azul
	Color("FF7AC6"), # rosa
	Color("E1DAFF"), # lila claro
]

# --- Formas ---
const RADIUS_BUTTON := 24
const RADIUS_CARD := 28

## Resolución base del juego (coincide con project.godot).
const VIEWPORT_SIZE := Vector2(1280, 720)
