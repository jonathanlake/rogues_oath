// Coiled white telegraph tell (v0.6.1, DESIGN §2.3.4). A TRUE white flash the monster's
// windup needs: `modulate` MULTIPLIES, so any multiplier on a green sprite yields brighter
// green, never white — the yellow modulate tell it replaces could never actually whiten.
// mix() toward vec3(1.0) DOES, so flash_amount = 1.0 paints the sprite pure white while
// preserving its alpha (transparent pixels stay transparent). Driven by a tween on the
// Sprite2D's ShaderMaterial (Monster._set_flash): snapped near-peak and HELD for the whole
// windup, then cut to 0 at the strike's release.
shader_type canvas_item;

uniform float flash_amount : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	COLOR = vec4(mix(tex.rgb, vec3(1.0), flash_amount), tex.a);
}
