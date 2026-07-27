class_name Entity
extends Node2D

## Abstract parent for the two avatar kinds (Player, Monster) — NEVER instantiated directly.
## It is a PARTIAL contract (GDScript's substitute for an interface): identity + shared
## presentation only, not a full LSP base. Subclass-specific surfaces (Player's input latch,
## Monster's wind-up cues) are reached via explicit casts at call sites — those casts are
## deliberate, not cruft to remove.
##
## What lives here: the entity id + display name + tile identity the referees key on, and the
## committed-movement playback shared verbatim by both kinds — glide_to and its tween guards,
## the flash/shake cue primitives, attacker/target combat feedback, and the HP readout.
##
## Authority note: max_hp / weapon+bonus stats on subclasses are AUTHORED-CONFIG reads, host-side
## (the referee seeds HP once at spawn; display seeds labels). CombatReferee's _hp is the sole
## live-value authority — nothing on an Entity node is ever adjudication truth.
##
## Its @onready refs require the shared child node names (Sprite2D/NameLabel/HpLabel/Attack/Hit),
## which both existing scenes provide. A future entity kind without them (decorations etc.)
## generalizes then, not preemptively.

# The red used for both taking a hit (Entity.play_hurt) and a rejected commit (Player.play_bonk).
# Deliberately the SAME red for two distinct outcomes: the SOUND + context distinguish them
# (§2.3.4 — hurt plays the impact wav on the target, a bonk plays the thud on the sender), so the
# colour need not, and sharing one const keeps the two flashes visually identical on purpose.
const _HURT_FLASH_COLOR := Color(1.0, 0.3, 0.3)

# The "spent" tint held during an attacker's recovery window (§2.3.4 recovery tell, DESIGN §2.8):
# a dim, slightly-cool desaturate (modulate MULTIPLIES) — reads as "can't act yet", deliberately
# distinct from the bright-red hurt flash and the white windup coil. Held for the recovery duration
# then eased back to white. Shares the _flash_tween modulate-cue slot so a hurt flash landing during
# recovery cleanly replaces it (the documented flash-cue precedence).
const _RECOVERY_TINT := Color(0.55, 0.55, 0.62)

# The held tint for the DEFAULT player wind-up telegraph fallback (v0.17.1 review #6, play_windup_fallback):
# a BRIGHT flash (modulate MULTIPLIES, so >1 brightens) held for the windup window then eased back — the
# "winding up" tell for a committed player windup with no bespoke draw art. Deliberately distinct from the
# recovery dim (this brightens) and the red hurt flash. Only ever the defensive fallback path, never the bow.
const _WINDUP_FALLBACK_TINT := Color(1.6, 1.6, 1.6)

# The held tint for an item USE / drink telegraph (v0.18.0 chunk C, §2.3.4 — a distinct outcome gets a
# distinct cue): a GREEN cast held for the committed use window then eased back to white. modulate MULTIPLIES,
# so the boosted green channel + dimmed red/blue reads unmistakably green — deliberately distinct from the red
# hurt flash, the cool recovery dim, and the bright windup flash, so "drinking" never reads as any of them.
const _DRINK_TINT := Color(0.45, 1.4, 0.55)

# The SPRITE alpha held while an entity is resting off a spent stamina pool (v0.26.0, play_recovering):
# semi-transparent = "spent, not ready". Written to the SPRITE's own modulate, never the root's, so it
# composes with the root-modulate tint cues above instead of fighting them for the same slot.
const _RECOVERING_ALPHA := 0.55

# ── Signals ──────────────────────────────────────────────────────────────────

## Emitted the instant a glide begins (before the tween runs). Player wires it to block its own
## MoveInput so no new step is sampled mid-glide (the Commitment Rule at the input layer); the
## host wires Monster's to nothing — kept for shape parity.
signal glide_started
## Emitted when a glide's tween finishes naturally (a killed catch-up tween does NOT emit it).
## Player wires it to unblock MoveInput; the host wires Monster's to the MonsterBrain so it
## re-plans at its OWN step boundary (never a global tick).
signal glide_finished

## This tier's per-step glide time, read server-side when the referee stamps a glide's duration.
## Player: the scene assigns speed_normal.tres (the export binds by property name through
## inheritance, so player.tscn's assignment lands here); a designer swaps the tier by pointing
## this at a different resources/speed_tiers/*.tres. Monster: derived from monster_type in
## _ready, overwriting the null export (before the brain can ever submit a step).
@export var glide_speed: GlideSpeed = null

## The authored starting / maximum HP surface the combat referee seeds from ONCE at spawn (its
## container enter hook reads node.max_hp pre-tree; the referee owns the live value thereafter).
## Players author theirs in player.tscn — 20 is the player default. Monsters are OVERWRITTEN
## pre-tree by Main's spawn_function from MonsterType.max_hp, so the Monster inspector value is
## inert — the same documented quirk as glide_speed above it (the null/default export is a
## placeholder the spawn config always writes over before the brain or referee reads it).
@export var max_hp: int = 20

## This entity's equipped weapon (M3.7 → unified onto every Entity, v0.9.3, DESIGN §2.3.7). Drives
## the WeaponRig's swing on EVERY peer and is read HOST-side by the combat referee for this
## attacker's damage + occupied window (weapon-first, ahead of the per-kind legacy fallbacks). How
## it is set differs by kind: a PLAYER authors it in player.tscn (longsword) and the host reassigns
## it authoritatively via the swap validator (every peer adopts it through set_weapon on the swap
## event); a MONSTER seeds it in _ready from MonsterType.weapon (null = weaponless, e.g. the training
## dummy = deals nothing). When set, the weapon supplies the BASE damage / windup / recovery and the
## wielder's bonus_* modifiers are ADDED (v0.19.0). A client never adjudicates from a self-set value — the host reads it.
@export var equipped_weapon: WeaponType = null

# ── Public state ──────────────────────────────────────────────────────────────

## Entity id in the referees' ONE occupancy/HP space (plan decision 5): positive = a player's
## peer id, negative = a host-assigned monster id. Set PRE-tree by Main's spawn_function on
## every peer, so _ready and the referees' container enter hooks can read it.
var entity_id: int = 0

## The one name surface per entity, read HOST-side by the referees when they compose combat
## events/log lines. TIMING INVARIANT: assigned PRE-tree by the spawn config on every peer
## (Player from data.player_name, Monster from monster_type.display_name with a "Monster"
## fallback), so it is correct at ANY read time — including the referees' container enter hooks,
## which fire only after the spawn function has returned the fully-configured node. The
## subclasses' _ready merely SEEDS the name label from it, never assigns it.
var display_name: String = ""

## Logical grid position. Presentation metadata mirrored on every peer (set at spawn, then at
## glide START from the broadcast `to`). NOT the adjudication truth — the host referee's own
## occupancy bookkeeping is authoritative; this is only what the avatar believes it stands on.
var tile: Vector2i

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _name_label: Label = $NameLabel
# Presentation-only HP readout under the feet, fed by attack events' hp_after via set_hp_display.
# The nameplate stays name-only; the authoritative HP lives in the host's CombatReferee.
@onready var _hp_label: Label = $HpLabel
# Combat feedback (§2.3.4). Streams are scene-assigned: the monster's Hit is a designed SFX
# (SFX_CombatHitDesigned02); the rest are still pitch-shifted placeholder wavs, real SFX later.
@onready var _attack_audio: AudioStreamPlayer = $Attack
@onready var _hit_audio: AudioStreamPlayer = $Hit
# Red slash streak drawn over the sprite when this entity takes a hit (§2.3.4 hit juice, v0.6.3).
# A child on both scenes; play_hurt drives it with the strike direction so the streak reads
# directional, and it rides the same attack event on every peer.
@onready var _slash_fx: SlashFx = $SlashFx
# The action-timeline weapon rig (M3.7 → shared by every Entity, v0.9.3). A component this node
# WIRES — the rig never reaches up: the subclass seeds its weapon at spawn (set_weapon) and every
# peer drives its swing off the attack event (play_weapon_swing). Present on both scenes (a null
# weapon leaves it hidden — the no-weapon fallback for a weaponless monster like the dummy).
@onready var _weapon_rig := $WeaponRig

# The glide's position tween, held so a newer server event can kill it and catch up (never to
# cancel a commitment — see glide_to). The flash/shake tweens are tracked separately so a real
# glide can pre-empt a lingering cue.
var _glide_tween: Tween = null
var _shake_tween: Tween = null
# The modulate flash tween (hurt / windup cues; the commit-sent flash was removed in v0.10.2), held
# so overlapping cues don't stack.
var _flash_tween: Tween = null

# Overhead SPELL-CAST sparkle (v0.19.8, lifted from Monster to Entity in v0.20.0 so players + monsters share
# it): a pulsing coloured star over the head for a cast window, driven per-peer from a cast event. GEN-tokened
# (v0.20.0, review #3) so a back-to-back re-cast's symbol isn't cleared early by the previous cast's timer.
var _cast_fx: Node2D = null
var _cast_fx_tween: Tween = null
var _cast_fx_gen: int = 0
# Overhead STUN icon (v0.20.0), on its OWN fx slot so it never collides with a cast symbol: a spinning yellow
# starburst held for the stun window, driven per-peer from status_applied / status_expired.
var _stun_fx: Node2D = null
var _stun_fx_tween: Tween = null
var _stun_fx_gen: int = 0
# The dizzy SPRITE wobble while stunned (v0.20.2), on its own slot; reset by hide_stun.
var _stun_wobble_tween: Tween = null
# Overhead THINKING cue (v0.24.0 stamina experiment): a grey "…" held for the monster's rolled hesitation
# window. Own fx slot + generation (never collides with stun/cast); self-clearing on a local timer —
# there is deliberately no expire event (the duration rides the one `thinking` broadcast).
var _think_fx: Node2D = null
var _think_fx_tween: Tween = null
var _think_fx_gen: int = 0
# Overhead EXHAUSTED cue (v0.24.3): a cyan sweat-drop shown while an entity's stamina pool sits at
# 0 (the crawl). Own slot; driven by the `exhausted` on/off edge events, not a local timer — the
# host owns when the crawl ends.
var _exhausted_fx: Node2D = null
var _exhausted_fx_tween: Tween = null
# Overhead BANTER line (v0.24.4): a short speech Label shown for a beat at pivotal moments, above
# the icon band so it can coexist with dots / "!" / sweat. Own slot — a new bark replaces.
var _banter_label: Label = null
var _banter_tween: Tween = null
# SIDE RECOVERY BAR (v0.26.0): a thin vertical fill beside the body while this entity is SPENT — one
# slot, now shared by TWO sources (v0.29.0), which is what `_recovery_fx_source` records:
#   "stamina" — resting off a spent stamina pool. Driven by the host's `stamina_recovery` event (its
#               stamped duration IS the fill time) and ended by the host's `exhausted` OFF edge. HOST-
#               OWNED LIFECYCLE, exactly as it has been since v0.26.0 — no local timer.
#   "attack"  — the WEAPON RECOVERY window after a strike (v0.29.0, players AND monsters), started off the
#               same `attack`/whiff event that already drives play_recovery's grey tint, from its stamped
#               `duration_sec`. There is NO host end event for this window (the recovery tail is stamped
#               once and never re-posted), so this source — and ONLY this source — SELF-CLEARS on a local
#               SceneTreeTimer of exactly that duration.
# ARBITRATION, stamina-priority: an "attack" call NO-OPS while a "stamina" bar is up (exhaustion is the
# rarer and more important state, and its bar must not be shortened by a swing landing inside it); a
# "stamina" call always takes the slot, replacing an attack bar. finish_recovering only ends the bar whose
# source it names, so a self-clear timer can never cut a stamina rest short.
# GENERATION token (`_recovery_fx_gen`), the same shape as the think/cast/stun cues and for the same reason:
# the attack timer is fire-and-forget, so a bar armed after it must be able to invalidate it — the timer
# captures the generation and no-ops on a mismatch. The READY BLINK on completion runs on its own tween so
# it can't be killed by a bar teardown mid-pulse.
var _recovery_fx: Node2D = null
var _recovery_fx_tween: Tween = null
var _recovery_fx_source: String = ""
var _recovery_fx_gen: int = 0
var _ready_blink_tween: Tween = null
# Overhead SHIELD-BLOCK icon (v0.26.0 instants experiment): a steel-blue shield held while this entity's
# one-shot guard is RAISED. Own slot in the icon band, mirrored across from the sweat drop — sweat (10,-46),
# shield (-10,-46) — so a blocking knight can still be winded/thinking without the cues stacking. NO
# generation token and no local expiry timer, unlike the stun icon: the host does not know when this comes
# down (a HIT does), so the paired status_expired is the only thing that clears it.
var _block_fx: Node2D = null
var _block_fx_tween: Tween = null
# The BLINK vanish/reappear flash (v0.26.0), on its own slot so a teleport's fade can't be clobbered by — or
# clobber — the recovery alpha it restores back to.
var _blink_tween: Tween = null


func _ready() -> void:
	# Contract guard: the shared presentation requires these exact child names. An @onready miss
	# resolves silently to null and only explodes at first use — name the missing node NOW instead.
	for missing in [["Sprite2D", _sprite], ["NameLabel", _name_label], ["HpLabel", _hp_label],
			["Attack", _attack_audio], ["Hit", _hit_audio], ["SlashFx", _slash_fx],
			["WeaponRig", _weapon_rig]]:
		if missing[1] == null:
			push_error("[Entity] %s (entity %d) scene is missing required child '%s'" % [
				name, entity_id, missing[0]])


# ── Public methods ────────────────────────────────────────────────────────────

## Hostility test (DESIGN §2.2.6), read HOST-side by the referees. Subclasses MUST override
## (Player: hostile to Monsters; Monster: hostile to Players; the debug all_hostile flag ORs on
## top in both). Loud, not silent, if a future subclass forgets.
func is_hostile_to(_other: Node) -> bool:
	push_error("subclass must override is_hostile_to")
	return false


## Play back a server-accepted glide (called on every peer by Main from the broadcast event).
## Idempotent-late-safe: it always kills any running tween and tweens from the CURRENT rendered
## position to the new target, so a verdict arriving after the client's safety-clear still renders
## as a catch-up glide rather than being ignored (ignoring would desync position permanently).
## This is the ONLY thing that starts a glide — there is no cancel/interrupt entry point.
func glide_to(to_tile: Vector2i, duration_sec: float) -> void:
	# A newer truth supersedes any in-flight visuals: kill the old glide (killed => no
	# glide_finished) and any lingering shake so the tween starts from a clean position base.
	if _glide_tween != null and _glide_tween.is_valid():
		_glide_tween.kill()
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()

	# tile updates at glide START (presentation metadata; the referee's occupancy is the truth).
	tile = to_tile
	glide_started.emit()
	# Subclass hook, at exactly this point in the sequence (after glide_started, before the tween)
	# — Player relays the accept to its own input sampler here.
	_on_glide_accepted(to_tile)

	var target := WorldGrid.tile_to_world(to_tile)
	_glide_tween = create_tween()
	_glide_tween.tween_property(self, "position", target, duration_sec).set_trans(Tween.TRANS_LINEAR)
	_glide_tween.finished.connect(_on_glide_finished)


## Play back a host-adjudicated BLINK (v0.26.0 instants experiment, DESIGN §2.11.1) — a TELEPORT, not a
## glide: there is no travel time to tween, so the body must read as "gone, then there". Called on every peer
## from the `blink` event (main.gd). The sibling of glide_to, and deliberately NOT a 0-second glide_to: that
## would still run the tween machinery, still emit glide_started, and still leave a client believing it moved
## through the tiles in between.
##
## Sequence: kill the in-flight glide tween (the ability's whole promise is leaving a committed step early —
## the host already erased that glide record, so its visual must not keep travelling) and any lunge shake,
## snap `tile` + `position` to the destination, then a ~0.1s fade-out/in on the SPRITE's own alpha so the jump
## is legible instead of a one-frame pop. The fade restores to whatever alpha was there BEFORE, not to 1.0, so
## blinking while stamina-recovering keeps the spent transparency (that cue owns the same channel).
##
## Then `_on_glide_accepted` + `glide_finished` — REQUIRED, not decoration: the local Player blocks its own
## input sampler on glide_started and unblocks on glide_finished, and a killed tween emits no `finished`. A
## blink out of a glide would otherwise leave the blinker's input latched shut forever. Both hooks are also
## exactly TRUE here: the host's movement record for this entity is gone, so the mover genuinely is free to
## act and its planning tile genuinely is the destination.
func snap_to_tile(to_tile: Vector2i) -> void:
	if _glide_tween != null and _glide_tween.is_valid():
		_glide_tween.kill()
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
	tile = to_tile
	position = WorldGrid.tile_to_world(to_tile)
	if _sprite != null:
		# Restore target derived from RECOVERY STATE, not the momentary alpha (GLM milestone review):
		# a ready-blink or earlier fade mid-flight would otherwise be captured (e.g. 0.45) and parked
		# as the permanent post-fade alpha. Kill both alpha tweens before starting ours.
		var base_alpha := _RECOVERING_ALPHA if _recovery_fx != null else 1.0
		if _blink_tween != null and _blink_tween.is_valid():
			_blink_tween.kill()
		if _ready_blink_tween != null and _ready_blink_tween.is_valid():
			_ready_blink_tween.kill()
		_blink_tween = create_tween()
		_blink_tween.tween_property(_sprite, "modulate:a", 0.0, 0.05)
		_blink_tween.tween_property(_sprite, "modulate:a", base_alpha, 0.05)
	_on_glide_accepted(to_tile)
	glide_finished.emit()


## Overhead SHIELD-BLOCK icon (v0.26.0 instants experiment, §2.3.4): a steel-blue shield over the shoulder
## while this entity's one-shot guard is raised, so "that knight is holding a block" reads at a glance from
## across the room — and so the later blocked hit has a cause the whole party already saw. Driven per-peer from
## `status_applied {status: "block"}`; cleared ONLY by the paired `status_expired` (hide_blocking) — the guard
## has no duration, so unlike the stun icon there is no local backup timer and none is wanted. A slow scale
## pulse marks it as HELD and ready, deliberately calmer than the stun burst's spin.
func play_blocking() -> void:
	hide_blocking()
	var shield := Polygon2D.new()
	# Heater-shield silhouette: flat top, straight flanks, tapering to a point — reads as a shield at 5px and
	# is unmistakable against the stun starburst, the think dots and the sweat teardrop.
	shield.polygon = PackedVector2Array([
		Vector2(-4.5, -5.0), Vector2(4.5, -5.0), Vector2(4.5, 0.5),
		Vector2(0.0, 6.0), Vector2(-4.5, 0.5)])
	shield.color = Color(0.58, 0.68, 0.95, 0.95)  # steel blue — its own colour, not stun yellow / sweat cyan
	shield.position = Vector2(-10, -46)  # mirror of the sweat drop's (10,-46): its own spot in the icon band
	add_child(shield)
	_block_fx = shield
	_block_fx_tween = create_tween().set_loops()
	_block_fx_tween.tween_property(shield, "scale", Vector2(1.18, 1.18), 0.5).from(Vector2.ONE)
	_block_fx_tween.tween_property(shield, "scale", Vector2.ONE, 0.5)


## Clear the block shield (the host's `status_expired` — i.e. the guard absorbed a hit — or a death teardown).
## Idempotent, like every other hide_* here.
func hide_blocking() -> void:
	if _block_fx_tween != null and _block_fx_tween.is_valid():
		_block_fx_tween.kill()
	_block_fx_tween = null
	if _block_fx != null and is_instance_valid(_block_fx):
		_block_fx.queue_free()
	_block_fx = null


## Attacker feedback for a landed strike (§2.3.4), played on every peer from the referee's `attack`
## event: Jeff's BOWSTRING lunge (pull back off the target, shoot forward past the tile edge, return)
## via _bowstring, optionally with the swing sound. Distinct from any input ack cue — this is a
## committed strike resolving. `with_sound` defaults true for API completeness, but the v0.6.0
## audio-trim rule (main.gd _handle_attack_event) passes FALSE on a landed hit so only the TARGET's
## hit sound plays and the exchange is one sound, not two overlapping. `dir` is the 8-way step toward
## the victim so the lunge reads directional; Vector2i.ZERO falls back to a horizontal lunge.
func play_attack(dir: Vector2i, with_sound := true) -> void:
	_bowstring(dir)
	if with_sound:
		# Reset the pitch a bow DRAW (play_draw) may have shifted down, so a following melee swing sounds
		# normal — the draw/loose are the only callers that repitch this stream.
		_attack_audio.pitch_scale = 1.0
		_attack_audio.play()


## Target feedback for taking a hit (§2.3.4), played on every peer from the referee's `attack`
## event: a distinct red flash + the impact sound + a directional red slash streak (v0.6.3 juice).
## Never confusable with the attacker's swing or a rejected commit — this is "I got hit." `dir` is
## the 8-way step from attacker toward this victim (main derives it per-peer from the same event);
## Vector2i.ZERO leaves the streak on its default diagonal.
## `pitch` scales the impact SFX playback (v0.11.0): 1.0 is the normal thud; a backstab passes it up a
## step (main.gd) so the sharper hit is audibly distinct (§2.3.4), reusing this one stream rather than a
## second clip. Set every call (default 1.0 restores normal pitch), so a prior pitched hit never lingers.
func play_hurt(dir: Vector2i = Vector2i.ZERO, pitch: float = 1.0) -> void:
	_flash(_HURT_FLASH_COLOR)
	_hit_audio.pitch_scale = pitch
	_hit_audio.play()
	if _slash_fx != null:
		_slash_fx.show_streak(dir)


## Recovery tell (§2.3.4; DESIGN §2.8): the attacker is SPENT for the recovery window after a
## committed strike — a dim desaturate held for `duration_sec`, then eased back to white. Played on
## EVERY peer from the attack event's stamped recovery duration (main.gd), so the spent window
## matches the host's busy record on the wire — no new sync. Both entity kinds use it (player bump,
## monster instant strike). Distinct from the hurt flash (bright red) and the windup coil (white
## pull-back). Shares the _flash_tween slot (the modulate-cue precedence): a hurt flash landing
## mid-recovery — e.g. a trade — cleanly replaces it. A non-positive duration is a no-op (an AoO or
## a telegraphed-windup landed hit carries none — recovery is the instant-strike/bump shape only).
func play_recovery(duration_sec: float) -> void:
	if duration_sec <= 0.0:
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	modulate = _RECOVERY_TINT
	_flash_tween = create_tween()
	# Hold the spent tint for the bulk of the window, then a short ease back to white so the release
	# reads as "ready again". The 0.12s ease is clamped inside the window for very short recoveries.
	var ease_sec := minf(0.12, duration_sec)
	_flash_tween.tween_interval(duration_sec - ease_sec)
	_flash_tween.tween_property(self, "modulate", Color.WHITE, ease_sec)


## Default player WIND-UP telegraph fallback (v0.17.1 review #6). Main plays this off a `windup` event when
## the entity is a PLAYER whose weapon is unresolvable or isn't a "draw" style — the two rendered branches
## (bow draw / monster coil) don't cover it, so without this a committed player windup would be SILENT
## (§2.3.4 forbids a committed action with no telegraph). A held bright flash over `windup_sec`, then eased
## back — distinct from the recovery dim (this brightens) and the hurt flash (red). Shares the _flash_tween
## slot like the other modulate cues. DEFENSIVE: no shipped content triggers it (the only player windup is
## the bow's draw); a flash floor suffices until a real non-draw player windup weapon earns a bespoke A/V.
## A non-positive window is a no-op (matches play_recovery).
func play_windup_fallback(windup_sec: float) -> void:
	if windup_sec <= 0.0:
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	modulate = _WINDUP_FALLBACK_TINT
	_flash_tween = create_tween()
	var ease_sec := minf(0.12, windup_sec)
	_flash_tween.tween_interval(windup_sec - ease_sec)
	_flash_tween.tween_property(self, "modulate", Color.WHITE, ease_sec)


## Item-use / DRINK telegraph (v0.18.0 chunk C, §2.3.4). Main plays this off an `item_used` event on the
## user's node on EVERY peer, so the whole party sees a teammate drink for the committed window. Structurally
## identical to play_windup_fallback / play_recovery — hold the green _DRINK_TINT for the bulk of the window,
## then a short ease back to white so the finish reads as "done" — and it shares the _flash_tween modulate-cue
## slot, so a hurt flash landing mid-drink cleanly replaces it (the documented flash-cue precedence). A
## non-positive duration is a no-op (matches the other held-tint cues).
func play_drink(duration_sec: float) -> void:
	if duration_sec <= 0.0:
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	modulate = _DRINK_TINT
	_flash_tween = create_tween()
	var ease_sec := minf(0.12, duration_sec)
	_flash_tween.tween_interval(duration_sec - ease_sec)
	_flash_tween.tween_property(self, "modulate", Color.WHITE, ease_sec)


## Update the under-feet HP readout ("hp/max") from an `attack` event's hp_after. Presentation
## only — the authoritative HP lives in the host's CombatReferee; this node just renders what the
## event carries. max rides the event so no peer needs to query the referee.
func set_hp_display(hp: int, max_value: int) -> void:
	_hp_label.text = "%d/%d" % [hp, max_value]


## Turn the sprite to face along `dx` (the x-sign of a movement/attack/telegraph direction, v0.10.0).
## The 32rogues art is authored FACING LEFT, so east (dx > 0) mirrors via flip_h and west (dx < 0)
## restores the authored facing; dx == 0 (a pure-vertical step, or a same-column attack) is a NO-OP,
## keeping whatever way the entity already faces. Flips $Sprite2D ONLY — NOT the root: a root-scale
## flip would mirror the nameplate/HP text and invert the WeaponRig's aim (the rig orbits by rotation
## from `dir`, so a sprite-local flip leaves it correct). Driven per-peer from the glide/attack/windup
## events in main.gd (every peer derives the same dx from the same event data, so facing is
## deterministic with no new wire field). Presentation only — never adjudication.
func face_toward(dx: int) -> void:
	if dx != 0:
		_sprite.flip_h = dx > 0


## Adopt a weapon (M3.7 → shared by every Entity, v0.9.3): update the authoritative-on-host
## equipped_weapon AND repaint the rig's idle region in ONE place, so a swap (player) or a spawn
## seed (monster) can never leave the rig showing the old weapon. This node wires the rig; the rig
## never reaches up. A null weapon hides the rig (the no-weapon fallback — a weaponless monster).
## Player drives this on the swap event + late-join sync; Monster seeds it once at spawn.
func set_weapon(weapon: WeaponType) -> void:
	equipped_weapon = weapon
	_weapon_rig.set_weapon(weapon)


## Drive the equipped weapon's swing toward `dir` over the stamped `duration_sec` (M3.7 → any
## Entity, v0.9.3). Called by Main off THIS entity's `attack` event on every peer (the event carries
## the stamped window + the weapon field that gates rig playback). Forwards to the rig — this node
## wires it, the rig owns the choreography. Composes with the body lunge (play_attack / a monster's
## whiff bowstring) and the recovery tint (play_recovery), exactly as a player's swing does.
func play_weapon_swing(dir: Vector2i, duration_sec: float) -> void:
	_weapon_rig.play_swing(dir, duration_sec)


## Bow-DRAW telegraph (v0.17.0), driven by Main off the `windup` event for a "draw"-style weapon (player OR
## a future monster archer). Forwards the aim + window to the rig (which raises the bow skyward then aims it,
## nocking the arrow) and plays a DRAW sound: the $Attack whoosh pitched DOWN so the creaky draw is audibly
## its own cue (Jon: "no string animation, but with a sound"). Every peer renders it from the one event — the
## telegraph is identical on the wire, no new sync. `dir` is the 8-way step toward the target tile.
func play_draw(dir: Vector2i, windup_sec: float, weapon: WeaponType = null) -> void:
	# Event-resolved weapon (v0.17.1 review #9): when Main passes the windup event's own weapon, the rig
	# repaints from it so a late-joiner still in the weapon-sync retry window draws the RIGHT art, not a stale
	# cache. Defaulted null keeps the rig's cached _weapon (any non-event caller is unaffected).
	_weapon_rig.play_draw(dir, windup_sec, weapon)
	_attack_audio.pitch_scale = 0.7
	_attack_audio.play()


## Melee WINDUP pose (v0.18.x, the goblin's club), driven by Main off the `windup` event for a melee
## weapon on EVERY peer — forwards the aim + window to the rig, which parks the weapon raised behind the
## swing's start edge and holds it over the body's away-coil until the swing resolves. NO SOUND: the
## monster telegraph is deliberately silent (v0.6.2 grammar — the visual carries the tell), unlike the
## bow draw above (which pitches the whoosh). This node wires the rig; the rig owns the pose choreography.
## `dir` is the 8-way step TOWARD the target; the event-resolved weapon lets a late-joiner pose the right art.
## `self is Player` picks the pose STYLE (v0.27.0, Jeff's second playtest verdict): a player draws back in one
## long eased pull, a monster plants and jitters. The ENTITY answers "what am I" and passes it DOWN — the rig
## is a component and must never reach up to inspect its parent (CLAUDE.md), and the alternative (a per-weapon
## `.tres` style field) would be wrong twice over: the same club is wielded by both, and the difference is
## about the WIELDER, not the weapon.
func play_windup_pose(dir: Vector2i, hold_sec: float, weapon: WeaponType = null) -> void:
	_weapon_rig.play_windup_pose(dir, hold_sec, weapon, self is Player)


## Bow release (v0.17.0), driven by Main off the matching `projectile_launched`. Snaps the rig's release (bow
## + arrow spring forward, then hide) and plays the LOOSE sound — the $Attack whoosh at normal pitch (a
## distinct pitch from the draw above, per §2.3.4). The flying arrow itself is a separate Projectile node.
func play_loose(dir: Vector2i, weapon: WeaponType = null) -> void:
	# Event-resolved weapon (v0.17.1 review #9): same as play_draw — a late-joiner paints the RIGHT release
	# art from the launch event rather than a stale rig cache. Defaulted null keeps the cached _weapon.
	_weapon_rig.play_loose(dir, weapon)
	_attack_audio.pitch_scale = 1.0
	_attack_audio.play()


## Force-hide the weapon rig (v0.17.0). Main calls this off the `died` event so a shooter killed mid-draw
## never leaves a drawn bow hanging (the node despawns a beat later, but this clears the visual at once —
## mirroring how a monster's windup coil vanishes with its node). A no-op for a rig already hidden.
func hide_weapon_rig() -> void:
	_weapon_rig.hide_draw()


## Overhead SPELL-CAST sparkle (lifted from Monster in v0.20.0 so players + monsters share it): a pulsing star
## in `symbol_color` over the head for `hold_sec` — the "channeling" tell (§2.3.4), distinct from the wind-up.
## GEN-tokened so a re-cast's symbol survives the previous cast's expiry timer (review #3). Drawn as a Polygon2D
## (font-independent) above the name label; cleared on re-cast, at hold end, and with the node on death.
func play_spell_cast(hold_sec: float, symbol_color: Color) -> void:
	_clear_cast_fx()
	_cast_fx_gen += 1
	var gen := _cast_fx_gen
	var star := Polygon2D.new()
	# 4-pointed sparkle (outer r≈7, inner r≈1.8) centred on the node origin.
	star.polygon = PackedVector2Array([
		Vector2(7, 0), Vector2(1.8, 1.8), Vector2(0, 7), Vector2(-1.8, 1.8),
		Vector2(-7, 0), Vector2(-1.8, -1.8), Vector2(0, -7), Vector2(1.8, -1.8)])
	star.color = symbol_color
	star.position = Vector2(0, -50)  # above the name label
	add_child(star)
	_cast_fx = star
	_cast_fx_tween = create_tween().set_loops()
	_cast_fx_tween.tween_property(star, "scale", Vector2(1.3, 1.3), 0.35).from(Vector2(0.85, 0.85))
	_cast_fx_tween.parallel().tween_property(star, "modulate:a", 0.55, 0.35).from(1.0)
	_cast_fx_tween.tween_property(star, "scale", Vector2(0.85, 0.85), 0.35)
	_cast_fx_tween.parallel().tween_property(star, "modulate:a", 1.0, 0.35)
	if hold_sec > 0.0:
		get_tree().create_timer(hold_sec).timeout.connect(_clear_cast_fx.bind(gen))


## Clear the cast sparkle. No-arg (gen -1) = unconditional (re-cast pre-clear / death); a bound generation (from
## the expiry timer) no-ops if a newer cast has started (gen mismatch, review #3). Idempotent — safe any time.
func _clear_cast_fx(gen: int = -1) -> void:
	if gen != -1 and gen != _cast_fx_gen:
		return
	if _cast_fx_tween != null and _cast_fx_tween.is_valid():
		_cast_fx_tween.kill()
	_cast_fx_tween = null
	if _cast_fx != null and is_instance_valid(_cast_fx):
		_cast_fx.queue_free()
	_cast_fx = null


## Overhead STUN icon (v0.20.0, §2.3.4): a spinning yellow starburst over the head held for `hold_sec`, so a
## stunned entity reads at a glance. On its OWN fx slot (never collides with a cast symbol). Driven per-peer from
## status_applied (hold_sec = the stun window); status_expired (hide_stun) clears it, a local timer backs that up.
func play_stunned(hold_sec: float) -> void:
	hide_stun()
	# INTERRUPT the visual (v0.20.2): drop any in-flight ATTACK pose so a stunned entity visibly STOPS attacking
	# (Jon: stun interrupts, not just blocks-next). The coil/lunge share _shake_tween; the weapon rig is the swing.
	# Killing them mirrors the host-side gameplay interrupt (the damage resolve fizzles for a stunned actor).
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
	if _weapon_rig != null:
		_weapon_rig.hide_draw()
	_stun_fx_gen += 1
	var gen := _stun_fx_gen
	var burst := Polygon2D.new()
	# A 6-point starburst (12 verts, alternating outer/inner) — visually distinct from the 4-point cast sparkle.
	var pts := PackedVector2Array()
	for i in 12:
		var ang := TAU * i / 12.0
		var r := 7.0 if i % 2 == 0 else 3.0
		pts.append(Vector2(cos(ang) * r, sin(ang) * r))
	burst.polygon = pts
	burst.color = Color(1.0, 0.9, 0.2)  # stun yellow
	burst.position = Vector2(0, -50)
	add_child(burst)
	_stun_fx = burst
	# Slow spin reads as "dizzy" for the whole window.
	_stun_fx_tween = create_tween().set_loops()
	_stun_fx_tween.tween_property(burst, "rotation", TAU, 0.9).from(0.0)
	# Dizzy WOBBLE (v0.20.2, WoW-style): rock the SPRITE back and forth for the window, on its own slot.
	if _stun_wobble_tween != null and _stun_wobble_tween.is_valid():
		_stun_wobble_tween.kill()
	_sprite.rotation = 0.0
	_stun_wobble_tween = create_tween().set_loops()
	_stun_wobble_tween.tween_property(_sprite, "rotation", 0.22, 0.18).from(-0.22)
	_stun_wobble_tween.tween_property(_sprite, "rotation", -0.22, 0.18)
	if hold_sec > 0.0:
		get_tree().create_timer(hold_sec).timeout.connect(hide_stun.bind(gen))


## Clear the stun icon. No-arg (gen -1) = unconditional (status_expired / re-stun pre-clear / death); a bound
## generation (from the local backup timer) no-ops if a newer stun is active. Idempotent — safe any time.
func hide_stun(gen: int = -1) -> void:
	if gen != -1 and gen != _stun_fx_gen:
		return
	if _stun_fx_tween != null and _stun_fx_tween.is_valid():
		_stun_fx_tween.kill()
	_stun_fx_tween = null
	if _stun_fx != null and is_instance_valid(_stun_fx):
		_stun_fx.queue_free()
	_stun_fx = null
	# Stop the dizzy wobble + straighten the sprite (v0.20.2).
	if _stun_wobble_tween != null and _stun_wobble_tween.is_valid():
		_stun_wobble_tween.kill()
	_stun_wobble_tween = null
	if _sprite != null:
		_sprite.rotation = 0.0


## Overhead THINKING cue (v0.24.0 stamina experiment, §2.3.4-distinct): three grey dots that pulse over the
## head for `hold_sec` — a hesitating monster reads as "considering", never confusable with the yellow
## stun starburst or a cast symbol. Self-clearing (generation-guarded local timer); a re-roll replaces.
func play_thinking(hold_sec: float, alert: bool = false) -> void:
	hide_thinking()
	_think_fx_gen += 1
	var gen := _think_fx_gen
	var fx := Node2D.new()
	fx.position = Vector2(0, -50)
	add_child(fx)
	_think_fx = fx
	# ALERT lead-in (v0.24.3, the aggro flavor): a bright "!" pops first — "it noticed you" — then
	# hands over to the pondering dots. Built from polygons like every other cue (bar + dot); the
	# swap is a one-shot timer capped at the hold (a 1-beat think is nearly all "!", which is right).
	var alert_sec := minf(0.35, hold_sec) if alert else 0.0
	if alert:
		var mark := Node2D.new()
		var bar := Polygon2D.new()
		bar.polygon = PackedVector2Array([
			Vector2(-2, -9), Vector2(2, -9), Vector2(1.2, 2), Vector2(-1.2, 2)])
		bar.color = Color(1.0, 0.85, 0.3)  # alarm yellow-gold — brighter kin of the stun family
		mark.add_child(bar)
		var dot := Polygon2D.new()
		dot.polygon = PackedVector2Array([
			Vector2(-1.6, 5), Vector2(1.6, 5), Vector2(1.6, 8), Vector2(-1.6, 8)])
		dot.color = bar.color
		mark.add_child(dot)
		mark.scale = Vector2(0.2, 0.2)
		fx.add_child(mark)
		# Pop-in scale — the "!" lands with a snap, unlike the dots' lazy bob.
		var pop := create_tween()
		pop.tween_property(mark, "scale", Vector2(1.15, 1.15), 0.12)\
				.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		pop.tween_property(mark, "scale", Vector2.ONE, 0.08)
		get_tree().create_timer(alert_sec).timeout.connect(func():
			if gen == _think_fx_gen and is_instance_valid(mark):
				mark.queue_free())
	var dots := Node2D.new()
	for i in 3:
		var dot := Polygon2D.new()
		var pts := PackedVector2Array()
		for j in 8:
			var ang := TAU * j / 8.0
			pts.append(Vector2(cos(ang) * 2.2, sin(ang) * 2.2))
		dot.polygon = pts
		dot.color = Color(0.75, 0.75, 0.78)  # neutral grey — deliberately NOT stun yellow
		dot.position = Vector2((i - 1) * 8.0, 0)
		dots.add_child(dot)
	dots.visible = not alert
	fx.add_child(dots)
	if alert:
		get_tree().create_timer(alert_sec).timeout.connect(func():
			if gen == _think_fx_gen and is_instance_valid(dots):
				dots.visible = true)
	# Gentle bob loop — reads as pondering, visually quieter than the stun spin.
	_think_fx_tween = create_tween().set_loops()
	_think_fx_tween.tween_property(fx, "position:y", -54.0, 0.35).from(-50.0)
	_think_fx_tween.tween_property(fx, "position:y", -50.0, 0.35)
	if hold_sec > 0.0:
		get_tree().create_timer(hold_sec).timeout.connect(hide_thinking.bind(gen))


## Overhead EXHAUSTED cue (v0.24.3, §2.3.4-distinct): a cyan sweat-drop that drips while this
## entity's stamina sits at 0 — a crawling body must read as WINDED, never as lag or glitchy-slow.
## Loops until hide_exhausted (the host's `exhausted` off-edge event); no local timer.
func play_exhausted() -> void:
	hide_exhausted()
	var drop := Polygon2D.new()
	# Teardrop: a fan from a top point over a round bottom.
	var pts := PackedVector2Array([Vector2(0, -6)])
	for i in 9:
		var ang := PI * i / 8.0
		pts.append(Vector2(cos(ang) * 3.2, 2.0 + sin(ang) * 3.2))
	drop.polygon = pts
	drop.color = Color(0.45, 0.8, 1.0, 0.9)  # sweat cyan — kin to the stamina pips, not a status
	drop.position = Vector2(10, -46)  # offset beside the head so it can coexist with a think/stun
	add_child(drop)
	_exhausted_fx = drop
	# Drip loop: swell, fall a few px, fade, reset — reads as panting/sweating at a glance.
	_exhausted_fx_tween = create_tween().set_loops()
	_exhausted_fx_tween.tween_property(drop, "position:y", -40.0, 0.55).from(-46.0)
	_exhausted_fx_tween.parallel().tween_property(drop, "modulate:a", 0.25, 0.55).from(0.9)
	_exhausted_fx_tween.tween_property(drop, "position:y", -46.0, 0.0)
	_exhausted_fx_tween.tween_property(drop, "modulate:a", 0.9, 0.1)


## RECOVERY presentation (v0.26.0, DESIGN §2.2.10 graduation — §2.3.4 distinct outcome): this entity's
## stamina pool sits at ZERO and the host has armed a rest-to-recover wait of exactly `duration_sec`
## (stamp-and-bake — the bar fills over the host's own span, never a locally re-derived beat count).
## Two reads, both deliberately about the BODY rather than the icon band: the sprite goes SEMI-
## TRANSPARENT ("spent" at a glance, even off-screen-edge or in a crowd) and a thin vertical bar beside
## it fills bottom-up as the wait elapses ("ready in…"). Players AND monsters — a resting goblin is
## readable intel, and the pool is binary now, so "how long until it can act again" is the whole story.
##
## Placement: the bar sits at the sprite's SIDE (x ≈ 14, centred on the body), deliberately clear of the
## overhead icon band — sweat drop (10,-46), think dots / cast / stun (-50), banter (-74) — so a
## recovering entity can still be thinking, stunned or talking without the cues colliding.
##
## Own fx slot + own generation, like every other cue here: a re-call REPLACES (the host re-posts the
## event on every re-arm, i.e. every time activity restarts the clock, and the bar must restart with it).
## A non-positive duration falls back to a static full-height bar rather than a zero-length tween, so a
## degenerate dial can never leave the "spent" alpha with no visible explanation.
##
## v0.29.0 — SECOND SOURCE: `source` names which spent state this bar is showing, "stamina" (the v0.26.0
## rest, the default so the two existing call sites read unchanged) or "attack" (the WEAPON RECOVERY window
## after a strike, players and monsters alike — the same green fill answering the same question, "when can
## it act again?"). See the `_recovery_fx` field block for the arbitration + lifecycle contract; the two
## rules enforced HERE are (1) stamina-priority — an attack bar never displaces a rest bar — and (2) the
## attack bar's local SELF-CLEAR timer, which no source-"stamina" call ever arms.
func play_recovering(duration_sec: float, source: String = "stamina") -> void:
	# STAMINA-PRIORITY (v0.29.0): a swing's recovery must not overwrite (and so visually shorten) an
	# in-flight exhaustion rest — the rest is the rarer, more consequential read, and the host owns its
	# end edge. The reverse is deliberately unguarded: a "stamina" call always takes the slot.
	if source == "attack" and _recovery_fx != null and _recovery_fx_source == "stamina":
		return
	_clear_recovery_fx()
	_recovery_fx_source = source
	_recovery_fx_gen += 1
	var gen := _recovery_fx_gen
	var holder := Node2D.new()
	holder.position = Vector2(14, -18)  # right of the body, vertically centred on it
	add_child(holder)
	_recovery_fx = holder
	# Dark backing (2 x 24 px) so the fill reads against any floor colour.
	var backing := Polygon2D.new()
	backing.polygon = PackedVector2Array([
		Vector2(-1, 0), Vector2(1, 0), Vector2(1, 24), Vector2(-1, 24)])
	backing.color = Color(0.08, 0.09, 0.12, 0.75)
	holder.add_child(backing)
	# The fill: a full-height rect anchored at the BOTTOM (scale:y grows upward from y = 24), so one
	# scale tween is the whole animation — no per-frame redraw, no polygon rebuild.
	var fill := Polygon2D.new()
	fill.polygon = PackedVector2Array([
		Vector2(-1, -24), Vector2(1, -24), Vector2(1, 0), Vector2(-1, 0)])
	fill.color = Color(0.35, 0.85, 0.45, 0.95)  # ready-green — deliberately NOT the sweat cyan
	fill.position = Vector2(0, 24)
	holder.add_child(fill)
	# SPENT alpha on the SPRITE (not the root modulate): the root slot is owned by the flash/tint cues
	# (hurt, recovery tint, drink), so writing the sprite's own alpha lets a hit still flash red over a
	# recovering body without either cue clobbering the other. Kill any in-flight alpha tween first
	# (blink fade / ready blink) so a finishing tween can't overwrite the spent look a beat later.
	if _sprite != null:
		if _blink_tween != null and _blink_tween.is_valid():
			_blink_tween.kill()
		if _ready_blink_tween != null and _ready_blink_tween.is_valid():
			_ready_blink_tween.kill()
		_sprite.modulate.a = _RECOVERING_ALPHA
	if duration_sec <= 0.0:
		fill.scale = Vector2(1.0, 1.0)
	else:
		fill.scale = Vector2(1.0, 0.0)
		_recovery_fx_tween = create_tween()
		_recovery_fx_tween.tween_property(fill, "scale", Vector2(1.0, 1.0), duration_sec)\
				.set_trans(Tween.TRANS_LINEAR)
	# SELF-CLEAR, "attack" ONLY (v0.29.0): the weapon-recovery window has no host end event — the tail is
	# stamped once onto the attack event and never re-posted — so this cue owns its own ending, on the same
	# local-timer + generation shape the cast sparkle uses (_clear_cast_fx). The generation is what makes it
	# safe: a newer bar (another strike, or an exhaustion rest taking the slot) bumps it, and this timer then
	# no-ops instead of blinking over the newer state. A "stamina" bar arms NOTHING here — the host's
	# `exhausted` OFF edge remains the only thing that ends a rest.
	if source == "attack":
		get_tree().create_timer(maxf(duration_sec, 0.0)).timeout.connect(
				_finish_recovering_if_current.bind(gen))


## End the recovery presentation (v0.26.0): drop the bar, restore the sprite's alpha, and play a brief
## READY BLINK — two quick alpha pulses — so "I can act again" is its own positive tell rather than the
## mere absence of a cue (§2.3.4). Driven by the host's `exhausted` OFF edge (the regained point), and
## idempotent: safe to call on an entity that was never recovering (no bar, no blink queued twice) and
## from the same teardown paths that clear the sweat-drop.
##
## v0.29.0 — `source` names WHOSE ending this is ("stamina" = the host's exhausted OFF edge, the default so
## the existing call site reads unchanged; "attack" = the weapon-recovery self-clear timer). It must match
## the LIVE bar's source or this is a no-op: the two lifecycles share one slot, so without the match a
## swing's timer could cut an exhaustion rest short — blink included — while the host still holds that
## entity spent, which is precisely the "ready" lie §2.3.4 forbids.
func finish_recovering(source: String = "stamina") -> void:
	var was_recovering := _recovery_fx != null
	# SOURCE GUARD (v0.29.0): only the owner of the live bar may end it. A call arriving with NO bar up falls
	# through to the was_recovering early-out below — the pre-existing idempotent path, unchanged.
	if was_recovering and _recovery_fx_source != source:
		return
	_clear_recovery_fx()
	# Early-out BEFORE touching the alpha (GLM milestone review): this is called on every exhausted
	# OFF edge, including ones where no bar ever existed (hard-stop mode, admin edges) — an entity
	# that wasn't recovering keeps whatever its sprite alpha was doing.
	if _sprite == null or not was_recovering:
		return
	if _blink_tween != null and _blink_tween.is_valid():
		_blink_tween.kill()
	if _ready_blink_tween != null and _ready_blink_tween.is_valid():
		_ready_blink_tween.kill()
	_sprite.modulate.a = 1.0
	_ready_blink_tween = create_tween()
	for _i in 2:
		_ready_blink_tween.tween_property(_sprite, "modulate:a", 0.45, 0.05)
		_ready_blink_tween.tween_property(_sprite, "modulate:a", 1.0, 0.05)


## Tear down the recovery bar + its tween (v0.26.0). Idempotent; shared by play_recovering's replace
## and finish_recovering. Deliberately does NOT touch the sprite alpha — the two callers want
## different endings (replace keeps the spent look, finish restores + blinks).
## v0.29.0: also clears the SOURCE tag, so "no bar" and "no owner" can never disagree — play_recovering
## re-stamps it immediately after this call, finish_recovering leaves the slot genuinely unowned.
func _clear_recovery_fx() -> void:
	if _recovery_fx_tween != null and _recovery_fx_tween.is_valid():
		_recovery_fx_tween.kill()
	_recovery_fx_tween = null
	if _recovery_fx != null and is_instance_valid(_recovery_fx):
		_recovery_fx.queue_free()
	_recovery_fx = null
	_recovery_fx_source = ""


## The attack bar's self-clear timeout (v0.29.0), generation-guarded exactly like _clear_cast_fx's: a
## newer play_recovering — another strike, or an exhaustion rest claiming the slot — has already bumped
## `_recovery_fx_gen`, so a stale timer returns without touching the newer cue. On a match it ends the bar
## through the ordinary source-tagged path, so the ready blink is the same one a rest gets.
func _finish_recovering_if_current(gen: int) -> void:
	if gen != _recovery_fx_gen:
		return
	finish_recovering("attack")


## WHIFF feedback (§2.3.4) — a committed strike that resolved against empty ground. Lifted from Monster
## to Entity in v0.26.0: a PLAYER can whiff too (a telegraphed melee windup, or an active ability whose
## target stepped off), and §2.3.4 forbids an outcome being silently swallowed — before this, main.gd
## warned and rendered NOTHING for a player whiff. The base cue is the same bowstring lunge a landed
## strike uses plus the swing sound at normal pitch: on a whiff the swing STAYS audible (the v0.6.0
## audio-trim rule suppresses the attacker's sound only on a LANDED hit), so "missed" reads audibly
## apart from "landed". Monster OVERRIDES this to use its own designed whiff stream.
func play_whiff(dir: Vector2i) -> void:
	_bowstring(dir)
	_attack_audio.pitch_scale = 1.0
	_attack_audio.play()


## Overhead BANTER (v0.24.4): show one short spoken line — small but readable (outlined, so it
## survives any floor color), popped in, held, faded out. Presentation only; the host picked the
## text. A new bark replaces the previous one (one mouth per goblin).
func play_banter(text: String) -> void:
	hide_banter()
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 9)
	label.add_theme_color_override("font_color", Color(0.95, 0.93, 0.8))
	label.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.08))
	label.add_theme_constant_override("outline_size", 4)
	# Wide centred box above the icon band (-50 slot) so speech never overlaps the dots/sweat.
	label.position = Vector2(-70, -74)
	label.size = Vector2(140, 14)
	add_child(label)
	_banter_label = label
	label.scale = Vector2(0.4, 0.4)
	label.pivot_offset = Vector2(70, 7)
	_banter_tween = create_tween()
	_banter_tween.tween_property(label, "scale", Vector2.ONE, 0.12)\
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_banter_tween.tween_interval(1.8)
	_banter_tween.tween_property(label, "modulate:a", 0.0, 0.4)
	_banter_tween.tween_callback(hide_banter)


## Clear the banter line. Idempotent (death teardown / replacement bark).
func hide_banter() -> void:
	if _banter_tween != null and _banter_tween.is_valid():
		_banter_tween.kill()
	_banter_tween = null
	if _banter_label != null and is_instance_valid(_banter_label):
		_banter_label.queue_free()
	_banter_label = null


## Clear the sweat-drop (the `exhausted` off edge / death teardown). Idempotent.
func hide_exhausted() -> void:
	if _exhausted_fx_tween != null and _exhausted_fx_tween.is_valid():
		_exhausted_fx_tween.kill()
	_exhausted_fx_tween = null
	if _exhausted_fx != null and is_instance_valid(_exhausted_fx):
		_exhausted_fx.queue_free()
	_exhausted_fx = null


## Clear the thinking cue. No-arg = unconditional (death teardown); a bound generation no-ops if a
## newer roll replaced this one. Idempotent — safe any time.
func hide_thinking(gen: int = -1) -> void:
	if gen != -1 and gen != _think_fx_gen:
		return
	if _think_fx_tween != null and _think_fx_tween.is_valid():
		_think_fx_tween.kill()
	_think_fx_tween = null
	if _think_fx != null and is_instance_valid(_think_fx):
		_think_fx.queue_free()
	_think_fx = null


# ── Private methods ───────────────────────────────────────────────────────────

## Protected ordering hook, called by glide_to after glide_started.emit and before the tween is
## built. Empty here; Player overrides it to relay the accept — with the destination — to its own
## MoveInput sampler at exactly the point the relay has always sat.
func _on_glide_accepted(_to_tile: Vector2i) -> void:
	pass


func _on_glide_finished() -> void:
	glide_finished.emit()


## Modulate flash to `color`, tweening back to white. Held in _flash_tween so overlapping cues
## (bonk over commit, hurt over windup) cleanly replace rather than stack.
func _flash(color: Color) -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	modulate = color
	_flash_tween = create_tween()
	_flash_tween.tween_property(self, "modulate", Color.WHITE, 0.18)


## Jeff's bowstring attack lunge (v0.6.0 rhythm build), the shared drive for play_attack/play_whiff:
## pull BACK ~4px away from the target over ~0.10s (the wind-up read — its pull-back doubles as the
## monster telegraph tell), then shoot FORWARD ~11px toward it over ~0.06s (the sprite edge crosses
## the 16px half-tile boundary — Jeff's "out of his square a tiny bit"), then settle to base over the
## remaining ~0.09s. Total ≈0.25s = one action beat. Shares _shake_tween with the bonk jitter (the
## two never fire on one entity at once), so glide_to's kill of _shake_tween pre-empts it exactly as
## before, and it touches position ONLY, never modulate. `dir` is the 8-way step toward the target;
## Vector2i.ZERO falls back to a horizontal lunge.
## SETTLE-AT-CENTRE INVARIANT (v0.9.2): the lunge always springs from and returns to the entity's
## TILE CENTRE, never the live rendered `position`. An attacker is stationary at its tile (busy
## record) for the whole strike, so tile-centre is the exact truth — and capturing `position` instead
## let repeated cues that share this _shake_tween slot compound their displacement (a bonk killing a
## bonk mid-flight adopting the offset as its new base → monotonic drift into a wall). Basing on the
## tile removes that class of bug for BOTH kinds (the Monster override no longer needs to re-base — a
## held windup coil offsets position, which tile-centre ignores by construction).
func _bowstring(dir: Vector2i) -> void:
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
	var base := WorldGrid.tile_to_world(tile)
	var unit := Vector2(dir.x, dir.y).normalized() if dir != Vector2i.ZERO else Vector2(1, 0)
	_shake_tween = create_tween()
	_shake_tween.tween_property(self, "position", base - unit * 4.0, 0.10)
	_shake_tween.tween_property(self, "position", base + unit * 11.0, 0.06)
	_shake_tween.tween_property(self, "position", base, 0.09)


## A quick 2px position wobble that settles back to the entity's TILE CENTRE (v0.9.2 — the
## settle-at-centre invariant, same as _bowstring). `dir` (an 8-way step) makes the wobble lunge
## TOWARD the struck tile for an attack; the default Vector2i.ZERO is the symmetric horizontal jitter
## used by the rejection bonk. SKIPPED ENTIRELY while a glide tween is active: a bonk can fire
## mid-glide from an "already moving" reject, and re-basing to the tile centre mid-glide would
## teleport the sprite off its running tween — so the position shake is suppressed there and the
## modulate flash (play_bonk) carries the reject on its own (§2.3.4, still a distinct visual).
func _shake(dir: Vector2i = Vector2i.ZERO) -> void:
	if _glide_tween != null and _glide_tween.is_valid():
		return
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
	var base := WorldGrid.tile_to_world(tile)
	# A directional lunge for an attack (toward → back), or the two-sided jitter for a bonk.
	var offset := Vector2(dir.x, dir.y).normalized() * 3.0 if dir != Vector2i.ZERO else Vector2(2, 0)
	_shake_tween = create_tween()
	_shake_tween.tween_property(self, "position", base + offset, 0.03)
	if dir == Vector2i.ZERO:
		_shake_tween.tween_property(self, "position", base - offset, 0.03)
	_shake_tween.tween_property(self, "position", base, 0.03)
