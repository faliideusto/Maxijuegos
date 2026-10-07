extends SceneTree
## Genera res://ui/theme.tres a partir de la paleta (ui/palette.gd).
## Ejecutar tras cambiar el estilo:
##   godot --headless --path . --script res://tools/build_theme.gd
## (Se usa preload en vez de class_name porque en modo --script la caché de clases
## globales puede no estar lista.)

const P := preload("res://ui/palette.gd")
const OUTPUT := "res://ui/theme.tres"

func _init() -> void:
	var theme := Theme.new()
	theme.default_font_size = 24

	# Fuente: redondeada y gruesa si está instalada; si no, la del sistema en negrita.
	# TODO (fase 2): incluir Fredoka/Baloo 2 (OFL) en res://ui/fonts/ y usarlas aquí.
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Fredoka", "Baloo 2", "Nunito", "Segoe UI", "Arial"])
	font.font_weight = 700
	font.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	theme.default_font = font

	_build_labels(theme)
	_build_buttons(theme)
	_build_panels(theme)
	_build_misc(theme)

	var err := ResourceSaver.save(theme, OUTPUT)
	if err == OK:
		print("Tema guardado en %s" % OUTPUT)
	else:
		push_error("No se pudo guardar el tema (%s)" % error_string(err))
	quit(0 if err == OK else 1)

# ---------------------------------------------------------------------------

func _box(bg: Color, radius: int = P.RADIUS_BUTTON, border_bottom: int = 0, border_color: Color = Color.TRANSPARENT,
		margins: Vector4 = Vector4(24, 10, 24, 10)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.anti_aliasing = true
	if border_bottom > 0:
		sb.border_width_bottom = border_bottom
		sb.border_color = border_color
	sb.content_margin_left = margins.x
	sb.content_margin_top = margins.y
	sb.content_margin_right = margins.z
	sb.content_margin_bottom = margins.w
	return sb

func _build_labels(theme: Theme) -> void:
	theme.set_color("font_color", "Label", P.WHITE)
	theme.set_font_size("font_size", "Label", 26)

	theme.add_type("TitleLabel")
	theme.set_type_variation("TitleLabel", "Label")
	theme.set_font_size("font_size", "TitleLabel", 88)
	theme.set_color("font_color", "TitleLabel", P.YELLOW)
	theme.set_color("font_outline_color", "TitleLabel", P.PURPLE_DARK)
	theme.set_constant("outline_size", "TitleLabel", 18)
	theme.set_color("font_shadow_color", "TitleLabel", Color(0, 0, 0, 0.25))
	theme.set_constant("shadow_offset_y", "TitleLabel", 8)

	theme.add_type("HeaderLabel")
	theme.set_type_variation("HeaderLabel", "Label")
	theme.set_font_size("font_size", "HeaderLabel", 44)
	theme.set_color("font_color", "HeaderLabel", P.WHITE)
	theme.set_color("font_outline_color", "HeaderLabel", P.PURPLE_DARK)
	theme.set_constant("outline_size", "HeaderLabel", 10)

	theme.add_type("DarkLabel")  # texto oscuro sobre tarjetas claras
	theme.set_type_variation("DarkLabel", "Label")
	theme.set_color("font_color", "DarkLabel", P.PURPLE_DARK)

	theme.add_type("HintLabel")  # texto secundario, algo apagado
	theme.set_type_variation("HintLabel", "Label")
	theme.set_font_size("font_size", "HintLabel", 20)
	theme.set_color("font_color", "HintLabel", Color(1, 1, 1, 0.7))

func _button_variation(theme: Theme, name: String, face: Color, shadow: Color, text: Color) -> void:
	theme.add_type(name)
	theme.set_type_variation(name, "Button")
	# Normal: sombra dura de 8 px abajo. Pulsado: se hunde (sombra 2 px y texto más bajo).
	var normal := _box(face, P.RADIUS_BUTTON, 8, shadow, Vector4(32, 10, 32, 18))
	var hover := _box(face.lightened(0.12), P.RADIUS_BUTTON, 8, shadow, Vector4(32, 10, 32, 18))
	var pressed := _box(face.darkened(0.08), P.RADIUS_BUTTON, 2, shadow, Vector4(32, 16, 32, 12))
	var disabled := _box(face.lerp(P.CARD, 0.65), P.RADIUS_BUTTON, 8, P.CARD.darkened(0.2), Vector4(32, 10, 32, 18))
	var focus := _box(Color.TRANSPARENT, P.RADIUS_BUTTON + 4, 0, Color.TRANSPARENT, Vector4(0, 0, 0, 0))
	focus.draw_center = false
	focus.set_border_width_all(4)
	focus.border_color = P.WHITE
	focus.expand_margin_left = 4
	focus.expand_margin_right = 4
	focus.expand_margin_top = 4
	focus.expand_margin_bottom = 4
	theme.set_stylebox("normal", name, normal)
	theme.set_stylebox("hover", name, hover)
	theme.set_stylebox("pressed", name, pressed)
	theme.set_stylebox("disabled", name, disabled)
	theme.set_stylebox("focus", name, focus)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		theme.set_color(c, name, text)
	theme.set_color("font_disabled_color", name, Color(1, 1, 1, 0.5))
	theme.set_font_size("font_size", name, 32)

func _build_buttons(theme: Theme) -> void:
	# "Button" a secas = secundario (blanco). Luego las variaciones.
	_button_variation(theme, "SecondaryButton", P.WHITE, P.CARD_LIGHT.darkened(0.35), P.PURPLE_DARK)
	_button_variation(theme, "PrimaryButton", P.YELLOW, P.YELLOW_DARK, P.PURPLE_DARK)
	_button_variation(theme, "DangerButton", P.CORAL, P.CORAL_DARK, P.WHITE)
	# Botón base: copia del secundario.
	for style in ["normal", "hover", "pressed", "disabled", "focus"]:
		theme.set_stylebox(style, "Button", theme.get_stylebox(style, "SecondaryButton"))
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		theme.set_color(c, "Button", P.PURPLE_DARK)
	theme.set_color("font_disabled_color", "Button", Color(1, 1, 1, 0.5))
	theme.set_font_size("font_size", "Button", 32)

func _build_panels(theme: Theme) -> void:
	var card := _box(P.CARD, P.RADIUS_CARD, 0, Color.TRANSPARENT, Vector4(24, 20, 24, 20))
	card.shadow_color = Color(0, 0, 0, 0.25)
	card.shadow_size = 8
	card.shadow_offset = Vector2(0, 6)
	theme.set_stylebox("panel", "PanelContainer", card)

	theme.add_type("CardPanel")
	theme.set_type_variation("CardPanel", "PanelContainer")
	theme.set_stylebox("panel", "CardPanel", card)

	var light := _box(P.WHITE, P.RADIUS_CARD, 8, P.CARD_LIGHT.darkened(0.35), Vector4(24, 16, 24, 24))
	theme.add_type("LightCardPanel")
	theme.set_type_variation("LightCardPanel", "PanelContainer")
	theme.set_stylebox("panel", "LightCardPanel", light)

	var chip := _box(P.CARD, 40, 0, Color.TRANSPARENT, Vector4(20, 8, 20, 8))
	theme.add_type("ChipPanel")
	theme.set_type_variation("ChipPanel", "PanelContainer")
	theme.set_stylebox("panel", "ChipPanel", chip)

func _build_misc(theme: Theme) -> void:
	# Campo de texto: blanco, redondeado, texto oscuro.
	var edit := _box(P.WHITE, 18, 4, P.CARD_LIGHT.darkened(0.3), Vector4(16, 8, 16, 12))
	theme.set_stylebox("normal", "LineEdit", edit)
	var edit_focus := _box(P.WHITE, 18, 4, P.YELLOW, Vector4(16, 8, 16, 12))
	theme.set_stylebox("focus", "LineEdit", edit_focus)
	theme.set_stylebox("read_only", "LineEdit", _box(P.CARD_LIGHT, 18, 4, P.CARD_LIGHT.darkened(0.3), Vector4(16, 8, 16, 12)))
	theme.set_color("font_color", "LineEdit", P.PURPLE_DARK)
	theme.set_color("font_placeholder_color", "LineEdit", P.PURPLE_DARK.lerp(P.WHITE, 0.55))
	theme.set_color("caret_color", "LineEdit", P.PURPLE_DARK)
	theme.set_color("selection_color", "LineEdit", P.YELLOW)
	theme.set_font_size("font_size", "LineEdit", 26)

	# Barra de progreso (temporizadores).
	var bg := _box(P.PURPLE_DARK, 16)
	var fill := _box(P.YELLOW, 16)
	theme.set_stylebox("background", "ProgressBar", bg)
	theme.set_stylebox("fill", "ProgressBar", fill)
	theme.set_font_size("font_size", "ProgressBar", 18)
	theme.set_color("font_color", "ProgressBar", P.WHITE)

	# Tooltips.
	var tip := _box(P.PURPLE_DARK, 14, 0, Color.TRANSPARENT, Vector4(12, 6, 12, 6))
	theme.set_stylebox("panel", "TooltipPanel", tip)
	theme.set_font_size("font_size", "TooltipLabel", 20)
