extends Node2D

## Floating-combat-text FX layer (v0.10.1), extracted from main.gd. A Node2D under Main in WORLD space,
## ordered AFTER Monsters so its popups draw over the entities. Owns the one damage_popup spawn helper the
## attack handler calls (per-peer, off the same broadcast `attack` event every peer receives). Pure local
## presentation — never adjudication, nothing crosses the wire from here.

## Floating-combat-text spawn offset in PIXELS from the struck tile's centre (v0.10.0): lifted up so the
## popup starts above the sprite's head rather than over its face, then rises further from there.
@export var damage_popup_offset_px: Vector2 = Vector2(0.0, -14.0)

## Minimum seconds a held CUE stays up (v0.35.0). Every self-clearing cue in the codebase is armed from a
## host-stamped window, and a window can legitimately stamp ZERO (a 0-beat authored windup, a dial tuned to
## instant). Zero must mean "blink", never "forever": a cue whose teardown is gated on a positive duration
## leaks its node AND its looping tween when the duration is 0. One shared floor, named once, so the
## fx-layer and Entity cue families can't drift on the answer. Short enough to still read as instant.
const _MIN_CUE_HOLD_SEC := 0.15


## Spawn one floating-combat-text popup for `text`/`color` over `tile` (v0.10.0). The popup is parented
## HERE (this FX layer), NEVER the struck entity, so a killing-blow popup survives the victim's despawn —
## the same rationale as the follow camera and the hurt vignette. Position is set BEFORE add_child so the
## popup's rise/fade tween (its _ready) starts from the correct spot.
func damage_popup(text: String, color: Color, tile: Vector2i) -> void:
	var popup := DamagePopup.make(text, color)
	popup.position = WorldGrid.tile_to_world(tile) + damage_popup_offset_px
	add_child(popup)


## Spawn a one-shot GREEN particle burst over `tile` when a heal LANDS (v0.19.9, §2.3.4 — a distinct recovery
## cue). Parented HERE (world-space FX layer), never the healed entity, so it survives a despawn like the
## popup. CPUParticles2D (not GPU) for GL-Compatibility safety; rising green sparkles that fade via the ramp,
## then the node frees itself just past its lifetime. Fired for EVERY heal (shaman cast, potion drink alike).
func heal_burst(tile: Vector2i) -> void:
	var p := CPUParticles2D.new()
	p.position = WorldGrid.tile_to_world(tile) + damage_popup_offset_px
	p.one_shot = true
	p.explosiveness = 0.85
	p.amount = 18
	p.lifetime = 0.7
	p.direction = Vector2(0, -1)
	p.spread = 55.0
	p.gravity = Vector2(0, -28.0)   # drift UP — a "recovery/rising" read
	p.initial_velocity_min = 16.0
	p.initial_velocity_max = 46.0
	p.scale_amount_min = 1.5
	p.scale_amount_max = 3.0
	var grad := Gradient.new()
	grad.set_color(0, Color(0.45, 1.0, 0.55, 1.0))   # heal green, opaque → transparent
	grad.set_color(1, Color(0.45, 1.0, 0.55, 0.0))
	p.color_ramp = grad
	add_child(p)
	p.emitting = true
	# Free just past the burst's lifetime (one-shot never re-emits). Host-tree timer, survives fine.
	get_tree().create_timer(p.lifetime + 0.2).timeout.connect(p.queue_free)


## MAGIC MISSILE colours (v0.43.0) — the same arcane blue family as the mana bar and the wizard's channel
## tell, so the caster's whole vocabulary reads as one school of magic (§2.3.4).
const _ORB_CORE := Color(0.72, 0.82, 1.0, 1.0)
const _ORB_GLOW := Color(0.34, 0.52, 0.95, 0.55)
## Orb geometry, in pixels. The bloom radius is deliberately under half a tile so three orbs read as
## hovering around the wizard rather than trespassing on the neighbouring squares.
const _ORB_RADIUS_PX := 3.0
const _ORB_BLOOM_PX := 11.0
## How long the initial fan-out takes. Deliberately SHORTER than one orb interval at the shipped tuning
## (0.5 beats × 0.25s = 0.125s), so the bloom finishes before the first orb is due to leave and the volley
## never runs behind the damage it belongs to. Raising `orb_interval_beats` only widens that margin.
const _ORB_BLOOM_SEC := 0.09


## Play a MAGIC MISSILE volley from `caster` to `target` (v0.43.0). PURE PRESENTATION — every point of
## damage arrives on its own `attack` event, and if this function did nothing the spell would still work,
## it would merely be invisible. Nothing here is adjudication and nothing crosses the wire.
##
## THE CHOREOGRAPHY, in the order Jon described it: all `count` orbs bloom out of the caster at once and
## hang there, then they peel off ONE BY ONE at `interval_sec` and home into the target. Orb i therefore
## departs at i × interval, which is the same cadence the host's damage chain ticks on — so each orb's
## arrival lands next to its own popup without either side being told about the other. They are only ever
## approximately in step (two independent timers), and that is fine for a cue; if they ever need to be
## exact, the honest fix is a per-orb event, not a shared clock.
##
## PARENTED HERE, NEVER TO EITHER ENTITY — the same rule the damage popup and the danger tile follow. An
## orb outliving its target (the last one is mid-flight when the goblin dies) must still land and clean
## itself up, and a node parented to a freed body cannot. Positions are therefore SAMPLED at launch rather
## than tracked: a target that dies mid-volley leaves the final orb flying to where it stood, which is the
## correct read anyway — the orb was already loosed.
func missile_volley(caster: Node2D, target: Node2D, count: int, interval_sec: float) -> void:
	if caster == null or target == null or count <= 0:
		return
	var origin: Vector2 = caster.global_position + Vector2(0.0, -10.0)
	var destination: Vector2 = target.global_position + Vector2(0.0, -6.0)
	var gap := maxf(interval_sec, 0.0)
	for i in count:
		var orb := _make_orb()
		orb.position = origin
		add_child(orb)
		# BLOOM: fan the orbs evenly around the caster so three of them read as three, not as one blurred
		# smear. The half-step offset keeps the arc from putting an orb directly under the wizard's feet.
		var angle := TAU * ((float(i) + 0.5) / float(count))
		var bloom := origin + Vector2(cos(angle), sin(angle) * 0.6) * _ORB_BLOOM_PX
		var t := create_tween()
		t.tween_property(orb, "position", bloom, _ORB_BLOOM_SEC).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		# HOLD until this orb's turn — measured from the VOLLEY's start, not from the end of this orb's
		# bloom (GLM diff review). Adding the wait on top of the bloom pushed every departure late by the
		# bloom's length, so the host's first damage popup could land while the orbs were still fanning out.
		# Subtracting it means orb i leaves at `gap × i` from the volley's start, which is the same clock
		# `_orb_tick` damages on. The bloom is short enough (see _ORB_BLOOM_SEC) that orb 0's wait floors at
		# zero rather than going negative, so it simply departs the instant it has fanned.
		var wait := gap * float(i) - _ORB_BLOOM_SEC
		if wait > 0.0:
			t.tween_interval(wait)
		# HOME: accelerate into the target (EASE_IN), so the flight reads as drawn toward the body rather
		# than thrown at it — the difference between a missile and an arrow.
		t.tween_property(orb, "position", destination, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		t.parallel().tween_property(orb, "modulate:a", 0.0, 0.22).set_delay(0.10)
		t.tween_callback(orb.queue_free)


## One orb: a bright core inside a soft glow, both Polygon2D circles (GL-Compatibility safe, like every
## other cue in this file). Built in code rather than as a scene for the same reason the popup is — it has
## no authored content a designer would ever edit.
func _make_orb() -> Node2D:
	var orb := Node2D.new()
	orb.add_child(_orb_disc(_ORB_RADIUS_PX * 2.2, _ORB_GLOW))
	orb.add_child(_orb_disc(_ORB_RADIUS_PX, _ORB_CORE))
	return orb


## A filled circle approximated as a 10-gon — plenty at this radius, and cheaper than a draw call per frame.
func _orb_disc(radius: float, color: Color) -> Polygon2D:
	var pts := PackedVector2Array()
	for i in 10:
		var a := TAU * float(i) / 10.0
		pts.append(Vector2(cos(a), sin(a)) * radius)
	var disc := Polygon2D.new()
	disc.polygon = pts
	disc.color = color
	return disc


## Paint a DANGER tile over `tile` for `hold_sec` (v0.19.10, Rogue-Fable telegraph): a translucent pulsing
## square marking where a committed ground-target cast will land — step off it before the cast ends to dodge.
## Drawn HERE in world space (a full TILE_PX square centred on the tile), removed when the cast resolves.
## Parented to the FX layer so it never depends on the caster node.
##
## `color` (v0.34.0) is the CHANNEL, per §2.3.4's one-cue-per-outcome rule: RED (the default, byte-identical
## to every pre-v0.34.0 call) is a monster's damaging smite, GREEN is the druid's Entangling Roots. Two
## committed ground casts that do entirely different things must never paint the same square.
func danger_tile(tile: Vector2i, hold_sec: float, color: Color = Color(0.95, 0.2, 0.2, 0.5)) -> void:
	var half := WorldGrid.TILE_PX / 2.0
	var mark := Polygon2D.new()
	mark.polygon = PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)])
	mark.color = color
	mark.position = WorldGrid.tile_to_world(tile)
	add_child(mark)
	# Pulse the alpha so the danger reads as active; killed + freed at the FLOORED hold below.
	var t := create_tween().set_loops()
	t.tween_property(mark, "modulate:a", 1.0, 0.3).from(0.55)
	t.tween_property(mark, "modulate:a", 0.55, 0.3)
	# THE HOLD IS FLOORED, NEVER GATED (v0.35.0 fix). This used to arm the kill/free timers only
	# `if hold_sec > 0.0` — so a ZERO-length cast left an orphan Polygon2D with an INFINITE looping
	# tween parented here for the rest of the session, and every subsequent cast stacked another one.
	# That is reachable from the shipped game, not just a theoretical: cast_sec is
	# `ability.windup_beats × beat`, and windup_beats is editable to 0 from the debug panel's CLASSES
	# section, so tuning a cast down to instant quietly littered the room with permanent squares.
	# A floor rather than an early return because the mark is a §2.3.4 CUE: an instant cast still gets
	# a visible blip saying where it landed, it just can't outlive itself.
	var hold := maxf(hold_sec, _MIN_CUE_HOLD_SEC)
	get_tree().create_timer(hold).timeout.connect(t.kill)
	get_tree().create_timer(hold).timeout.connect(mark.queue_free)
