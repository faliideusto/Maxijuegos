class_name FrameBands
extends ColorRect
## Rellena las franjas que quedan a los lados (o arriba/abajo) del minijuego 1280x720 cuando la
## ventana tiene otra proporción. En vez de un fondo ajeno, prolonga el propio borde del juego:
## promedia la tira de píxeles junto a cada borde por tramos y funde un tramo con el siguiente (así
## estrellas, suelo o texto no se estiran en rayas), y lo oscurece hacia fuera.
## No deforma el juego: solo pinta fuera de su rectángulo (dentro se descarta).

const SHADER_CODE := """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform vec4 game_rect = vec4(0.0, 0.0, 1.0, 1.0); // posición y tamaño del juego en UV de pantalla
uniform float dim_near = 0.7;
uniform float dim_far = 0.3;

const int SEGMENTS = 8;     // tramos a lo largo del borde
const int TAPS = 6;         // muestras por lado de cada tramo (6x6)
const float STRIP = 0.06;   // grosor de la tira del borde que se promedia (fracción del juego)

// Color medio de un tramo de la tira del borde. Las muestras están en posiciones FIJAS (no siguen al
// píxel), así que el resultado no hace escalones aunque haya estrellas o texto justo en el borde.
vec3 segment_avg(vec2 strip_lo, vec2 strip_size, bool along_y, int seg) {
	vec3 acc = vec3(0.0);
	for (int i = 0; i < TAPS; i++) {
		for (int j = 0; j < TAPS; j++) {
			float a = (float(i) + 0.5) / float(TAPS);
			float b = (float(seg) + (float(j) + 0.5) / float(TAPS)) / float(SEGMENTS);
			vec2 f = along_y ? vec2(a, b) : vec2(b, a);
			acc += texture(screen_tex, strip_lo + f * strip_size).rgb;
		}
	}
	return acc / float(TAPS * TAPS);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 lo = game_rect.xy;
	vec2 hi = game_rect.xy + game_rect.zw;
	if (uv.x >= lo.x && uv.x <= hi.x && uv.y >= lo.y && uv.y <= hi.y) {
		discard;
	}
	bool sides = uv.x < lo.x || uv.x > hi.x;
	// Tira del juego pegada al borde más cercano.
	vec2 strip_size = sides ? vec2(game_rect.z * STRIP, game_rect.w) : vec2(game_rect.z, game_rect.w * STRIP);
	vec2 strip_lo = lo;
	if (uv.x > hi.x) strip_lo.x = hi.x - strip_size.x;
	if (uv.y > hi.y) strip_lo.y = hi.y - strip_size.y;
	// Posición a lo largo del borde → mezcla suave entre los dos tramos más cercanos.
	float along = sides ? (uv.y - lo.y) / game_rect.w : (uv.x - lo.x) / game_rect.z;
	float t = clamp(along * float(SEGMENTS) - 0.5, 0.0, float(SEGMENTS - 1));
	int s0 = int(floor(t));
	int s1 = min(s0 + 1, SEGMENTS - 1);
	vec3 col = mix(segment_avg(strip_lo, strip_size, sides, s0), segment_avg(strip_lo, strip_size, sides, s1),
			smoothstep(0.0, 1.0, fract(t)));
	// Oscurece según se aleja del juego (en fracción del tamaño del juego).
	vec2 outside = max(lo - uv, uv - hi) / game_rect.zw;
	float d = clamp(max(outside.x, outside.y) / 0.25, 0.0, 1.0);
	COLOR = vec4(col * mix(dim_near, dim_far, smoothstep(0.0, 1.0, d)), 1.0);
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
