class_name FrameBands
extends ColorRect
## Rellena las franjas que quedan a los lados (o arriba/abajo) del minijuego 1280x720 cuando la
## ventana tiene otra proporción. En vez de un fondo ajeno, prolonga el propio borde del juego:
## toma los píxeles junto a cada borde, los difumina y los oscurece un poco hacia fuera.
## No deforma el juego: solo pinta fuera de su rectángulo (dentro se descarta).

const SHADER_CODE := """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform vec4 game_rect = vec4(0.0, 0.0, 1.0, 1.0); // posición y tamaño del juego en UV de pantalla
uniform float dim_near = 0.88;
uniform float dim_far = 0.5;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 lo = game_rect.xy;
	vec2 hi = game_rect.xy + game_rect.zw;
	if (uv.x >= lo.x && uv.x <= hi.x && uv.y >= lo.y && uv.y <= hi.y) {
		discard;
	}
	// Desenfoque de caja de 7x7 alrededor del punto del borde más cercano (metido hacia dentro
	// para que ninguna muestra caiga fuera del juego).
	vec2 stp = game_rect.zw * vec2(0.012, 0.01);
	vec2 inset = stp * 3.5;
	vec2 p = clamp(uv, lo + inset, hi - inset);
	vec3 acc = vec3(0.0);
	for (int i = -3; i <= 3; i++) {
		for (int j = -3; j <= 3; j++) {
			acc += texture(screen_tex, p + vec2(float(i), float(j)) * stp).rgb;
		}
	}
	acc /= 49.0;
	// Oscurece según se aleja del juego (en fracción del tamaño del juego).
	vec2 outside = max(lo - uv, uv - hi) / game_rect.zw;
	float d = clamp(max(outside.x, outside.y) / 0.25, 0.0, 1.0);
	COLOR = vec4(acc * mix(dim_near, dim_far, smoothstep(0.0, 1.0, d)), 1.0);
}
"""

static var _shader: Shader

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	material = mat

## `offset`: esquina del juego en la ventana; `game_size`: tamaño del juego (1280x720).
func set_game_rect(offset: Vector2, game_size: Vector2) -> void:
	var vr := get_viewport_rect().size
	if vr.x <= 0.0 or vr.y <= 0.0:
		return
	(material as ShaderMaterial).set_shader_parameter("game_rect",
			Vector4(offset.x / vr.x, offset.y / vr.y, game_size.x / vr.x, game_size.y / vr.y))
