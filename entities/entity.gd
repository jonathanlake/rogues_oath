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
func play_windup_pose(dir: Vector2i, hold_sec: float, weapon: WeaponType = null) -> void:
	_weapon_rig.play_windup_pose(dir, hold_sec, weapon)


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
