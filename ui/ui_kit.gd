class_name UIKit
extends RefCounted
## Utilidades para construir pantallas por código con el tema global.
## Los estilos NO se fijan aquí: solo se elige la variación de tipo (ver ui/theme.tres).

static func label(text: String, variation: StringName = &"", align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	if variation != &"":
		l.theme_type_variation = variation
	return l

static func button(text: String, variation: StringName = &"PrimaryButton", min_size: Vector2 = Vector2(260, 0)) -> JuicyButton:
	var b := JuicyButton.new()
	b.text = text
	b.theme_type_variation = variation
	b.custom_minimum_size = min_size
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	return b

## Pantalla base: un Control a pantalla completa con el fondo violeta ya añadido.
static func setup_screen(root: Control) -> void:
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(BackgroundFX.new())

## Contenedor centrado a pantalla completa; devuelve el VBox donde añadir contenido.
static func centered_vbox(root: Control, separation: int = 20) -> VBoxContainer:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", separation)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(vbox)
	return vbox

## Si el contenido de `box` es más alto que la pantalla (mucho texto), lo reduce lo justo para que quepa entero,
## escalándolo desde su centro. Hay que llamarlo cuando el contenido ya esté añadido (espera un fotograma).
static func fit_to_screen(box: Control, margin: float = 36.0) -> void:
	await box.get_tree().process_frame
	if not is_instance_valid(box):
		return
	var screen_h := box.get_viewport_rect().size.y
	var avail := screen_h - margin
	var h := box.get_combined_minimum_size().y
	if h > avail and h > 0.0:
		# Un CenterContainer cuyo hijo no cabe se estira y deja el hijo pegado arriba: se escala desde el borde
		# superior y se baja lo justo para que quede centrado en pantalla.
		var s := avail / h
		box.size = box.get_combined_minimum_size()
		box.pivot_offset = Vector2(box.size.x * 0.5, 0.0)
		box.scale = Vector2.ONE * s
		box.position.y = (screen_h - h * s) * 0.5

## Aparición con rebote (escala desde 0). Funciona dentro de contenedores.
static func pop_in(node: Control, delay: float = 0.0) -> void:
	node.modulate.a = 0.0
	await node.get_tree().process_frame
	if not is_instance_valid(node):
		return
	node.pivot_offset = node.size * 0.5
	node.scale = Vector2.ZERO
	var t := node.create_tween().set_parallel(true)
	t.tween_property(node, "modulate:a", 1.0, 0.15).set_delay(delay)
	t.tween_property(node, "scale", Vector2.ONE, 0.45).set_delay(delay) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## Pequeño "salto" del número/etiqueta al cambiar de valor.
static func punch(node: Control, amount: float = 1.3) -> void:
	node.pivot_offset = node.size * 0.5
	node.scale = Vector2.ONE * amount
	node.create_tween().tween_property(node, "scale", Vector2.ONE, 0.3) \
			.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
