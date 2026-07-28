class_name Player
extends Entity

## A player avatar. Holds identity (peer_id, player_name, spawn_index) and the player-specific
## input surface; the shared presentation — sprite/labels, glide playback, combat cues — lives on
## Entity. It never adjudicates: the host's MoveReferee owns occupancy and outcomes.
##
## Movement flow, per peer:
##  - The LOCAL player's MoveInput (keys/stick, or its click-to-move target driver) emits
##    move_requested(dir, fresh); this node submits a "glide_to" intent. (The white commit-sent
##    input-ack flash was removed in v0.10.2 — Jon: the blink was noise; the glide itself is the ack.)
##  - When the server broadcasts the accepted event, Main calls glide_to() on THIS node — on
##    every peer, including the mover's own — and the glide begins. There is no client prediction
##    and, per the Commitment Rule, no cancel path: glide_to only ever kills a tween to catch up
##    to a newer server truth, never to abort a committed step.
##  - A reject reaches only the sender; Main calls play_bonk() on the sender's own player.

## Damage (HP) this player deals per landed melee attack — a bump (move into a hostile) or an
## attack of opportunity. Deterministic (no to-hit roll, DESIGN §2.3 amendment). Read HOST-side by
## the referees when they stamp this attacker's damage; never trusted from the wire.
@export var melee_damage: int = 5

## Recovery in BEATS after a bump lands: damage is instant, then the attacker is BUSY for this many
## beats — the symmetric attack shape (DESIGN §2.8) and the Commitment Rule tail (decision 2). The
## referee converts it to seconds at stamp time (beats × the attacker's resolved pace) into the from==to busy
## record; the local attacker mirrors that window as blocked input (commit_in_place) and every peer
## plays the recovery tell for it. 2.0 → attack rate = movement rate (a step is glide + 1 rest beat).
## NO-WEAPON FALLBACK (M3.7): this and melee_damage are read by the referee ONLY when equipped_weapon
## is null — a weapon's recovery_beats/damage win when one is equipped. equipped_weapon itself, the rig
## reference, set_weapon, and play_weapon_swing now live on Entity (v0.9.3, shared with Monster); this
## node keeps only the player-specific swap flow (the swap intent/validator/event and late-join sync).
@export var attack_recovery_beats: float = 2.0

## DAMAGE MODIFIER (v0.19.0 base+wielder-modifier model, DESIGN §2.3.7): a flat bonus ADDED to the equipped
## weapon's base damage, the same shape MonsterType.bonus_damage uses. 0 today — this is the hook a future
## strength stat / PlayerClass writes so a stronger player hits harder with the SAME weapon. Read HOST-side
## by CombatReferee.roll_damage_of (floored at 0 there); never trusted from the wire. Melee windup/recovery have
## no player bonus (players don't slow their own weapon — those bonuses are monster-only, and melee-gated).
@export var bonus_damage: int = 0

@onready var _move_input := $MoveInput
@onready var _path_marker: Node2D = $PathMarker
@onready var _commit_audio: AudioStreamPlayer = $CommitSent
@onready var _bonk_audio: AudioStreamPlayer = $Bonk

# Assigned by main.gd's spawn_function (from the replicated spawn config) before this
# node enters the tree, so _ready can read them on every peer.
var peer_id: int = 0
var player_name: String = ""
var spawn_index: int = 0

## This player's class (v0.10.0) — its appearance today, its stat identity in future. Seeded in _ready
## from GameConfig.class_roster[spawn_index % size] (the class resources ARE the old per-slot sprite
## table now), reassigned by the /class validator host-side and adopted on every peer via the
## class_changed event / late-join sync_player_field RPC (main.gd) through set_class. Read by the late-join
## loop to tell the joiner our current class. Presentation on the node; never adjudication truth.
var player_class: PlayerClass = null

## TRAITS GRANTED TO THIS PLAYER SPECIFICALLY (v0.45.0) — the ones they were given, as opposed to the ones
## their CLASS carries (`player_class.passives`). Traits became plug-and-play this version: a trait is a
## catalogued object now, so it can belong to a body rather than only to a role.
##
## THIS FIELD IS WHY A PER-PLAYER LIST WAS NEEDED AT ALL. `player_class` is a SHARED loaded resource — every
## wizard in the session points at the same `wizard.tres` — so granting by appending to `player_class.passives`
## would hand the trait to everyone of that class, the same way `/w longsword` retunes the longsword for
## every wielder. Granting has to live beside the class list, never inside it.
##
## Replicated as NAMES, never resources: the host's `trait_granted` / `trait_removed` events and the
## late-join `sync_player_field` RPC carry a display_name each peer resolves through
## `GameConfig.passive_by_name` — the codebase-wide name-resolution model. Host-authoritative: the referee
## reads the union of this and the class list, and only the `/trait` validator writes it.
##
## DIES WITH THE PLAYER (permadeath, §2 — the bag already works this way), and it needs NO teardown code to
## do it: this array is state on the NODE, and death, disconnect and the F5 reset all free the node. A
## respawn builds a fresh Player whose array is empty, so a new life starts with only what its class gives
## it. Nothing to erase means nothing that can be forgotten in one of the three paths.
var granted_traits: Array[PassiveAbility] = []

## ACTIVE ABILITIES GRANTED TO THIS PLAYER SPECIFICALLY (v0.47.0) — the hotbar twin of `granted_traits`
## above, and it exists for the identical reason: `player_class.active_abilities` is a SHARED resource
## array, so granting by appending there would put the ability on every player of that class.
##
## Replicated as NAMES through `ability_granted` / `ability_removed` and the late-join `sync_player_field`
## RPC, resolved on each peer via `GameConfig.ability_by_name`. Dies with the player, like the traits and
## the bag — it is state on the node, and every death, disconnect and F5 frees the node.
##
## ORDER IS WIRE-VISIBLE HERE, which is the one way this differs from traits and the reason
## `ability_slots()` below exists. Traits are an unordered set whose order only affects chaining math; an
## ability is addressed by SLOT INDEX — `use_ability {index}` is the entire payload — so every peer must
## agree on the ordering or pressing "2" casts something other than what your bar shows. Append order is
## therefore load-bearing: grants append, removals compact left (Jon, 2026-07-28), and every peer applies
## the same events in the same order, so the arrays converge by construction.
var granted_abilities: Array[ActiveAbility] = []


## THE ONE TRAIT UNION (v0.49.0) — this player's class traits, then any granted to them specifically, then
## any their WORN GEAR carries (v0.50.0), deduped. Every trait read in the project goes through it: the
## host's hook dispatch (`CombatReferee._passives_of` delegates here), the resolver's source list
## (`resolve_stat`), and the HUD's reads.
##
## IT LIVES ON THE PLAYER, not on the referee, and that move is the whole reason Spellreach can work.
## The referee is host-only and inert on clients, so a client that needed the union — and it does, or the
## targeting ring would draw a reach the host refuses — would have had to re-walk class-then-granted
## itself. Two copies of that walk is exactly the drift this codebase keeps writing guards against, and
## the failure would be invisible: a ring that quietly disagrees with the gate.
##
## DEDUPED, and that guard is load-bearing rather than tidiness (reproduced in v0.45.0: a ranger granted
## the Archery its class already gives applied the -1 beat delta TWICE, shooting with a 1.25s tail instead
## of 1.5s). A trait appearing twice runs its hook twice, squaring a multiplier or doubling a delta,
## silently. Three paths can introduce a duplicate — the `/trait` command, the `trait_granted` event, and
## the late-join sync — so the guard belongs at the single read rather than at each writer.
##
## CLASS FIRST, THEN GRANTED, THEN GEAR. `modify_damage` chains in array order with each trait receiving
## the previous one's output, so with two multipliers the result depends on it. The class's own identity
## prices the blow; anything you were given modifies that; anything you put on modifies that. (Stat
## contributions through `Stats.resolve` are order-independent by construction — sums commute — so this
## ordering only ever matters to the chained hooks.)
##
## GEAR TRAITS ARE DERIVED, NEVER GRANTED (v0.50.0, the three-layer rule: fields for what an item IS,
## traits for the named behaviours it confers). A worn item's `granted_traits` are read THROUGH this
## union every time it is called; they are never written into the `granted_traits` FIELD above. That is
## the whole reason unequipping needs no bookkeeping — there is no copy to remember to undo, and no way
## for a robe's trait to outlive the robe.
##
## AND IT NEEDS NO WIRE TRAFFIC. Gear is already replicated everywhere (the class-driven spawn seed, the
## `equip_item` event, and the late-join `sync_player_field "body_armor"/"off_hand"`), and the traits
## themselves are resources every peer loads, so every peer's derived union agrees BY CONSTRUCTION rather
## than by a synced list. The client's targeting ring therefore sees a robe's reach the instant the host's
## gate does.
##
## The class list is COPIED, never appended to — it is a shared resource, so appending would permanently
## give the class whatever this one player was granted, on every peer.
func all_traits() -> Array:
	# ALWAYS A COPY, including the no-granted-traits path (GLM diff review). Returning
	# `player_class.passives` by reference handed every caller a live handle on a SHARED resource array —
	# one append or sort anywhere would permanently rewrite that class for every player on every peer, and
	# this method is public and called from three files. The docstring above promised a copy; now it is one.
	var out: Array = []
	if player_class != null:
		out.assign(player_class.passives)
	for t in granted_traits:
		if t != null and not (t in out):
			out.append(t)
	# WORN GEAR (v0.50.0), deduped by IDENTITY exactly like the granted list — so a wizard wearing a robe
	# whose trait their class already gives holds it ONCE (running a hook twice squares its multiplier, the
	# v0.45.0 bug this guard was written for), while two DISTINCT resources that merely share a script —
	# Spellreach and Farsight — are correctly both kept and stack additively.
	for t in gear_traits():
		if not (t in out):
			out.append(t)
	return out


## EVERY TRAIT THIS PLAYER'S WORN GEAR CONFERS, in slot order, null-safe (v0.50.0). Not deduped — the
## caller merges it, because `all_traits()` dedupes against the class and granted lists while the HUD
## dedupes for display and colours by provenance.
##
## IT EXISTS SO THE SLOT LIST IS WRITTEN ONCE (GLM diff review). `all_traits()` above and
## `hud._refresh_passives` both need "what are they wearing, and what does it give" — and the HUD cannot
## just call `all_traits()`, because a merged union has thrown away the provenance the panel colours by.
## Two hand-copied slot lists would have to be kept in step by memory, and the failure mode is the quiet
## kind: a trait that adjudicates correctly but never appears in the panel, or the reverse.
##
## WHICH SLOTS: every equipped-slot FIELD that exists on this class — `equipped_body` and
## `equipped_off_hand`. `ItemType.EquipSlot` names seven, but the other five have no state here and no
## referee reads them (§2.10 — they are still cosmetic HUD sockets). When one becomes real, it is added
## HERE, once, and both callers follow automatically.
func gear_traits() -> Array:
	var out: Array = []
	for item in [equipped_body, equipped_off_hand]:
		if item == null:
			continue
		for t in item.granted_traits:
			if t != null:
				out.append(t)
	return out


## Resolve a NAMED STAT for this player (v0.50.0) — the thin wrapper that hands the resolver this
## player's sources. See `resources/stats.gd` for the algorithm, the stat registry and each stat's ctx.
##
## IT LIVES ON THE PLAYER for the same reason `all_traits()` does, and that placement is load-bearing: a
## referee is host-only and inert on a client, but a CLIENT must resolve presentation stats itself (the
## targeting ring) from replicated data. So the resolve lives where both sides can reach it, and the host
## delegates by duck-typing exactly as `CombatReferee._passives_of` already does. One implementation, so
## the ring and the gate cannot disagree.
##
## Sources are `all_traits()` today — class, granted and worn-gear traits. When items and potions become
## sources in their own right (the resolver's whole point is that they can) they join the array HERE, and
## no adjudication site changes.
func resolve_stat(stat: StringName, base: float, ctx: Dictionary) -> float:
	return Stats.resolve(stat, base, all_traits(), ctx)


## THE ONE TARGETED-CAST REACH (v0.50.0) — this ability's authored `range_tiles` plus every source's
## contribution, in TILES. Replaces v0.49.0's four hand-threaded `spell_range_bonus()` sites.
##
## THE ROUNDING LIVES HERE AND NOWHERE ELSE, which is the entire safety argument for this function. The
## resolver returns a float (a future `+50% reach` source makes fractions real); tiles are integers; and
## the host's range gate, the client's targeting ring and the ability tooltip all need the SAME integer.
## Two sites rounding independently — one flooring, one rounding — is a ring that draws a tile the host
## refuses, which is precisely the failure this migration exists to make structurally impossible.
##
## IT FLOORS, deliberately (GLM diff review). A fraction of a tile is not a tile, and the gate is
## `cheb > reach` — equality passes — so rounding 7.5 UP would hand out a whole extra tile of reach for
## half a tile of bonus. Flooring fails closed, which is this codebase's instinct everywhere else, and it
## makes a `+50%` reach source read honestly: it must buy a WHOLE tile before it grants one. No effect
## today (every contribution is an integer flat); the choice is pinned now so the first percentage source
## does not silently decide it.
##
## SCOPED TO TARGETED CASTS BY ITS CALLERS. `WeaponType.range_tiles` shares only a name with
## `ActiveAbility.range_tiles` and is the codebase's is-this-ranged predicate in a dozen places, so a BOW
## must never be passed through here.
func targeted_reach(ability: ActiveAbility) -> int:
	if ability == null:
		return 0
	return floori(resolve_stat(Stats.ABILITY_RANGE, float(ability.range_tiles), { "ability": ability }))


## THE ONE ORDERED HOTBAR READ (v0.47.0) — class abilities first, then granted ones, capped at the authored
## `GameConfig.ability_slots`. Every site that turns a slot INDEX into an ability calls this: the host's
## adjudication (`CombatReferee._ability_of`), the client's targeting-cursor routing
## (`main._ability_in_slot`), and the HUD's icon/tooltip/cooldown painter (`hud._refresh_abilities`).
##
## IT IS A FUNCTION RATHER THAN THREE LOOPS ON PURPOSE, and this is the whole safety story of the feature.
## The wire carries an index and nothing else, so if those three sites each built their own "class then
## granted" list and one ever diverged — a filter added in one place, a different cap, a null skipped
## differently — the failure would be SILENT and horrible: your bar shows Blink in slot 2, you press 2, the
## host resolves slot 2 to Magic Missile and casts that. One function means they cannot disagree; the only
## way to change the order is to change it for everybody.
##
## The CAP is applied here too, so a hotbar can never present a slot the input map and the grant validator
## do not both agree exists.
func ability_slots() -> Array[ActiveAbility]:
	var out: Array[ActiveAbility] = []
	if player_class != null:
		for a in player_class.active_abilities:
			if a != null:
				out.append(a)
	for a in granted_abilities:
		# Skip a duplicate rather than showing the same ability twice: two sockets that share a cooldown
		# key would drain together and read as a bug. The grant validator refuses this case up front; this
		# is the belt, and it also covers the event/late-join paths.
		if a != null and not (a in out):
			out.append(a)
	var cap: int = GameManager.config.ability_slot_count()
	return out.slice(0, cap) if out.size() > cap else out


## Client-side inventory MIRROR (v0.18.0 chunk B): the item display_names this player carries, adopted from
## the host's item_picked_up events (main.gd appends here, in slot order). PRESENTATION TRUTH ONLY — the
## authoritative bag lives in the host's InventoryReferee._inventories; this exists so every peer's HUD hotbar
## (own player) and any future teammate-inventory UI can render without a query. Empty at spawn (a fresh player
## carries nothing) and never carried across a death/reset — the node is freed and re-made empty. Capped at the
## hotbar width in main.gd's handler (see the coupling note there).
var inventory: Array[String] = []

## The WORN BODY ARMOR (v0.27.0 equipment phase 2) — the ItemType in this player's one real equipment
## slot, or null for unarmored. PLAYER-ONLY on purpose: monsters do not wear gear (MonsterType keeps its
## own `phys_damage_reduction` as the armored-monster seam), so the field lives here rather than on Entity.
##
## HOST-AUTHORITATIVE where it matters: the host's own copy of this node is what CombatReferee's armor seam
## and MoveReferee's stamina rest wait read (both duck-typed, both LIVE at every hit / arm). Every peer also
## keeps it in step — the spawn seed below and the `equip_item` gear event both resolve the item by NAME
## through the shared catalog, exactly as weapons and classes do — so the HUD can paint the socket with no
## query. It is not a mirror of authoritative state; it IS the state on the host and a name-resolved copy
## everywhere else, which is the same contract equipped_weapon has carried since v0.9.3.
var equipped_body: ItemType = null
## The OFF-HAND item (v0.39.0, the knight's kite shield). Same contract as `equipped_body` above in every
## respect — host-authoritative, name-resolved on every peer, written only through set_off_hand — with one
## difference worth stating: NOTHING ADJUDICATES FROM IT YET. No referee reads the off-hand, and
## `worn_armor_weight()` deliberately reads the BODY slot alone, so a shield can neither mitigate damage
## nor move the wearer's weight band. Today it is identity and a tooltip; see set_off_hand for the rest.
var equipped_off_hand: ItemType = null


func _ready() -> void:
	super()
	# Seed the class-driven sprite from the spawn slot (v0.10.0): the class roster replaced the old
	# per-slot _SPRITE_TILES, so slot N wears roster[N % size]'s tile — identical default appearance,
	# now a swappable PlayerClass. set_class paints the region; a /class change or late-join sync
	# repaints it thereafter. An empty roster (misconfig) leaves the scene-default region untouched.
	var roster := GameManager.config.class_roster
	if not roster.is_empty():
		set_class(roster[spawn_index % roster.size()])
	# Seed the class's STARTING BODY ARMOR (v0.27.0 equipment phase 2), right after the class seed and by
	# the same rule: every peer derives it from the SAME shared config (the slot's class → its
	# starting_body_armor), so a fresh spawn / F5 respawn is dressed identically everywhere with no wire
	# traffic — the shape the scene-default weapon seed below already uses. Seeded HERE and not inside
	# set_class deliberately: set_class also runs for every live class change on every peer, and equipping
	# gear there would bypass the busy gate the /class validator applies (Commitment Rule). A class with no
	# starting armor (four of the six) leaves the slot empty.
	if player_class != null and player_class.starting_body_armor != null:
		set_body_armor(player_class.starting_body_armor)
	# The OFF-HAND seeds by the identical rule (v0.39.0, the knight's kite shield) — same shared config,
	# same "every peer derives it independently, no wire traffic" contract, same reason it lives here
	# rather than in set_class. Only the knight authors one today; every other class leaves it empty.
	if player_class != null and player_class.starting_off_hand != null:
		set_off_hand(player_class.starting_off_hand)
	# Nameplate is name-only, seeded from the pre-tree display_name; the HP readout rides its own
	# label under the feet. max_hp is locally known everywhere (an Entity export), so the seed is
	# correct on every peer with no query; the combat referee's attack events drive live updates via
	# set_hp_display, the single formatting site. Full HP at spawn.
	_name_label.text = display_name
	set_hp_display(max_hp, max_hp)

	# Seed the STARTING WEAPON on every peer, so a fresh spawn / F5 respawn shows the right weapon with no
	# wire traffic; a later change arrives via a swap event or the late-join sync. set_weapon (not the raw
	# rig call) so the local sampler's ranged flag is seeded too.
	#
	# v0.29.0 — the CLASS's own roster wins (Jon: "a rogue should start on the dagger"). The class seeded
	# above is derived from shared config on every peer (class_roster[slot]), so roster[0] is the same
	# deterministic answer everywhere — the identical no-traffic shape the class + body-armor seeds use, and
	# the same "first entry of the loadout" rule /class already applies on a live class change. Deliberately
	# ONE seed site (not a second set_weapon call below): a class with no roster of its own — four of the six
	# — keeps the scene-assigned weapon (longsword, from player.tscn), which is what the late-join sync filter
	# treats as the default. The GLOBAL GameConfig.weapon_roster is deliberately NOT consulted here: it is the
	# Tab-cycle fallback for a roster-less class, not a spawn loadout, and reading it would silently re-seed
	# every class off a dial meant for cycling.
	# roster[0] null-guarded (GLM r2): a .tres authored with a null first entry falls back to the scene
	# default HERE too, matching the late-join filter's guard in main.gd — without it the seed and the
	# filter would disagree about what such a class starts holding (bare hands vs longsword).
	if player_class != null and not player_class.weapon_roster.is_empty() \
			and player_class.weapon_roster[0] != null:
		set_weapon(player_class.weapon_roster[0])
	else:
		set_weapon(equipped_weapon)

	# MoveInput samples only on the local player's node. Every peer instantiates the child (uniform
	# node graph) but only ours is enabled.
	_move_input.enabled = (peer_id == multiplayer.get_unique_id())
	_move_input.move_requested.connect(_on_move_requested)
	# Seed the sampler's planning tile with the server-derived spawn tile (set by main.gd's
	# spawn_function before this node entered the tree); on_accepted advances it thereafter.
	_move_input.set_current_tile(tile)
	# The node owns the glide<->input handshake: it blocks its own sampler for the whole glide.
	glide_started.connect(func(): _move_input.set_blocked(true))
	glide_finished.connect(func(): _move_input.set_blocked(false))
	# Path-marker wiring, local player only — only the local sampler ever emits target signals,
	# and only the clicker should see their own marker.
	if _move_input.enabled:
		_move_input.path_target_set.connect(_on_path_target_set)
		_move_input.path_target_cleared.connect(func(): _path_marker.visible = false)
		# Ranged-shot click (v0.17.0): the sampler reports a shoot target; this node owns the wire (mirror of
		# move_requested → glide_to). Local player only — only our sampler ever emits it.
		_move_input.shoot_requested.connect(_on_shoot_requested)
		# TARGETED ability click (v0.34.0): the sampler reports the picked tile for the armed slot; this node
		# owns the wire (mirror of shoot_requested → shoot). Local player only — only our sampler ever emits.
		# There is no cancel signal: Main re-syncs its range ring off the latch every frame, so a right-click
		# cancel needs no wiring at all.
		_move_input.ability_target_picked.connect(_on_ability_target_picked)


# ── Public methods ────────────────────────────────────────────────────────────

## Hostility test (DESIGN §2.2.6, plan decision 6), read HOST-side by the referee/combat. A player
## is hostile to any monster and NEVER to another player. The debug-only GameManager.all_hostile
## flag ORs on top (every entity hostile to every other, itself excepted) so the AoO/combat wiring
## can be demoed two-instance with `hostile=1`. Symmetric with Monster.is_hostile_to.
func is_hostile_to(other: Node) -> bool:
	if GameManager.all_hostile and other != self:
		return true
	return other is Monster


## Adopt a class (v0.10.0): update player_class AND repaint the sprite's region from its atlas_coords in
## ONE place, so a /class change (via the class_changed event) or a late-join sync (sync_player_field) can never
## leave the sprite showing the old class. FLIP PRESERVED: face_toward flips $Sprite2D via flip_h, which
## a region_rect assignment does not touch — but we capture + restore it explicitly so the invariant is
## documented at the site and survives any future region-set that might reset it. A null class is a no-op
## (the misconfig / empty-roster guard) — the scene-default region stays. Driven on the swap/sync event on
## every peer; every peer resolves the same PlayerClass through GameConfig.class_by_name (roster = truth).
func set_class(new_class: PlayerClass) -> void:
	player_class = new_class
	if new_class == null:
		return
	var was_flipped := _sprite.flip_h
	_sprite.region_enabled = true
	_sprite.region_rect = WorldGrid.atlas_region(new_class.atlas_coords)
	_sprite.flip_h = was_flipped


## Adopt a weapon (v0.17.0 override): the Entity base updates equipped_weapon + repaints the rig; on top of
## that, PUSH the weapon's range down to the local input sampler so a left-click knows whether to shoot
## (range_tiles > 0) or step. Driven on the swap/sync event and the spawn seed on every peer; the sampler is
## enabled only on our own node, but pushing the value on every peer is harmless (a remote sampler never samples).
func set_weapon(weapon: WeaponType) -> void:
	super(weapon)
	_move_input.weapon_range_tiles = weapon.range_tiles if weapon != null else 0


## Adopt a BODY ARMOR item (v0.27.0 equipment phase 2) — the one write path for `equipped_body`, so the
## slot can never be set from three places with three different meanings. `null` strips the slot (unarmored),
## which is a legal state, not an error. Driven from: the spawn seed (_ready above), the host-side equip
## validator + its broadcast `equip_item {gear: true}` event on every peer, the `/class` loadout equip, and
## the late-join `sync_player_field "body_armor"` snap. NO presentation of its own — the worn item shows in
## the HUD's Body socket, which repaints off the same events (hud.refresh_self); there is no paper-doll
## sprite layer, so unlike set_weapon this touches no rig.
func set_body_armor(item: ItemType) -> void:
	equipped_body = item


## Adopt an OFF-HAND item (v0.39.0, the knight's kite shield) — the one write path for `equipped_off_hand`,
## the exact twin of set_body_armor above and driven by the same four sources (spawn seed, `/class` loadout,
## the late-join `sync_player_field "off_hand"` snap, and any future equip validator). `null` empties the
## hand, which is a legal state. No presentation of its own: the HUD's Off socket repaints off the same
## events, and there is no paper-doll layer, so this touches no rig.
##
## IT GRANTS NOTHING (v0.39.0, and this is deliberate). The kite shield's tooltip reads "Grants Shield
## Block ability", but the ability still comes from PlayerClass.active_abilities exactly as before —
## unequipping the shield would leave Shield Block in the bar. That gap is KNOWN and Jon's call for now;
## making equipment a real ability source is the "abilities from gear" item in ROADMAP's parking lot
## (DESIGN §2.11 lists it as envisioned). Do not "fix" the tooltip by wiring an ability source here
## without that decision — it changes what happens to a slotted ability when you unequip mid-cooldown.
func set_off_hand(item: ItemType) -> void:
	equipped_off_hand = item


## THE armor WEIGHT BAND this player currently sits in (v0.27.1) — the ONE resolver, living beside
## set_body_armor because this node owns `equipped_body`. An empty slot reads UNARMORED, which is a real
## band (0% and flat 0), not an error: the absence of armor must never itself mitigate (§2.3.8).
##
## WHY IT LIVES HERE. Two referees need the band and each had duck-read `equipped_body.armor_weight`
## itself — CombatReferee's flat-reduction term (§2.3.8) and MoveReferee's stamina rest wait (§2.2.10) —
## so the promotion rule below had two homes while its own doc comment claimed one. Both now call this
## (duck-typed via `has_method`, keeping the monster / non-player fallbacks in each referee intact).
##
## PROMOTION (DESIGN §2.10, future): with ONE armor slot the body item's band IS the wearer's band. When
## the other sockets land, the heaviest worn piece sets the band — and THIS FUNCTION is the single site
## that changes; neither referee needs touching.
func worn_armor_weight() -> ItemType.ArmorWeight:
	if equipped_body == null:
		return ItemType.ArmorWeight.UNARMORED
	return equipped_body.armor_weight


## Inject the local sampler's shoot-target predicate (v0.17.1). Main wires this on the LOCAL player when it
## (re)acquires the follow camera; the predicate closes over the entity containers and decides whether a
## clicked tile holds a shootable hostile, so a ranged click only looses at a hostile (else it falls through
## to a step). Component pattern: Main OWNS the predicate (it can see the containers), this node just forwards
## it down to its MoveInput child — the sampler never reaches up. CLIENT-SIDE convenience only (§2.2.9); the
## host still adjudicates every shot. Mirrors the set_weapon push-down: parent wires, component consumes.
func set_shoot_target_check(cb: Callable) -> void:
	_move_input.shoot_target_check = cb


## ARM the local sampler's targeting cursor for ability slot `index` (v0.34.0) — the exact push-down shape
## set_shoot_target_check uses: Main owns the 1-5 keys and the range ring, this node just forwards down to
## its MoveInput child, and the component never reaches up. Pre-commit and freely cancelable: nothing has
## been submitted until the click lands.
func arm_targeting(index: int) -> void:
	_move_input.arm_targeting(index)


## Drop an armed cursor without firing (v0.34.0), Main's cancel path. Idempotent.
func cancel_targeting() -> void:
	_move_input.cancel_targeting()


## The armed ability slot, or -1 (v0.34.0). Main reads it to decide arm vs cancel vs plain submit.
func targeting_index() -> int:
	return _move_input.targeting_index()


## Relay a reject to the local sampler WITHOUT any cue (1a, v0.10.2). Used for "occupied_hostile":
## the sender was mid-commitment gliding into a hostile it can't bump yet (pipelined) — the bonk's
## thud/flash would misread as "input didn't register" (§2.2.8), so it is suppressed, but the reject
## must still reach the sampler's reject-counting (a walk into an enemy still stops). Mirrors
## play_bonk's on_rejected relay with none of its cues. Local player only (only our sampler is live).
func note_reject_no_cue() -> void:
	if _move_input.enabled:
		_move_input.on_rejected()


## Local attacker's BUSY mirror for a bump (decision 2), driven by the attacker's own `attack`
## event. A bump adjudicates as a `deferred` verdict (no glide_to broadcast), so unlike a glide the
## local player never receives a glide_to to clear its input latch — this does it: it mirrors
## glide_to's signal/relay shape EXACTLY, minus the position tween (the attacker never leaves its
## tile — decision 2's "no client tween"). glide_started blocks MoveInput; on_accepted clears the
## AWAITING latch (advancing nothing — the current tile); a SceneTreeTimer ends the swing window
## and unblocks. No cancel path: the swing plays to completion (the Commitment Rule at the input layer).
func commit_in_place(duration_sec: float) -> void:
	# Kill any lingering glide tween FIRST (mirrors glide_to): the previous step's visual tail can
	# outlive the server's state by ~RTT/2, and its finished callback would emit glide_finished
	# mid-swing — unblocking input early. Killed => no finished, so the swing window owns the end.
	if _glide_tween != null and _glide_tween.is_valid():
		_glide_tween.kill()
	glide_started.emit()
	if _move_input.enabled:
		_move_input.on_accepted(tile)
	get_tree().create_timer(duration_sec).timeout.connect(func(): glide_finished.emit())


## Rejection feedback (§2.3.4): a distinct red flash + a short 2px shake + the thud, all three, so
## "the host refused" is never confusable with the commit ack or with a silent no-op. Called on
## the sender's own player. A bonk only ever fires when NOT gliding (you were refused), but we
## still guard the shake against an active glide tween so the two can't fight over position.
##
## LOCAL MUTE (v0.31.0): GameManager.mute_reject_sfx gates the AUDIO HALF ONLY. The flash, the shake
## and the sampler relay stay unconditional — §2.3.4's rule is that a rejection is never confusable
## with a silent no-op, so the visual tell must survive the mute. Process-local presentation: the
## flag is never networked and never adjudicated on.
func play_bonk() -> void:
	_flash(_HURT_FLASH_COLOR)
	if not (_glide_tween != null and _glide_tween.is_valid()):
		_shake()
	if not GameManager.mute_reject_sfx:
		_bonk_audio.play()
	# Relay the reject to our own sampler (local player only) so it enters the retry cooldown.
	if _move_input.enabled:
		_move_input.on_rejected()


# ── Private methods ───────────────────────────────────────────────────────────

## Entity's glide ordering hook (after glide_started.emit, before the tween is built): relay the
## accept — with the destination — to our own sampler (local player only) so it leaves the
## AWAITING latch and advances its planning tile for the next path recompute.
func _on_glide_accepted(to_tile: Vector2i) -> void:
	if _move_input.enabled:
		_move_input.on_accepted(to_tile)


func _on_move_requested(dir: Vector2i, _fresh: bool) -> void:
	# The white commit-sent input-ack flash was removed in v0.10.2 (Jon: the blink was noise). The
	# submit fires identically for fresh AND auto-walk continuation steps, so `fresh` is now unused.
	# Vector2i survives RPC natively; the host re-derives everything from ITS origin + this dir.
	NetEvents.submit_intent("glide_to", { "dir": dir })


## The local sampler reported a ranged-shot target (v0.17.0): submit the "shoot" intent through the one pipe
## (mirror of _on_move_requested). The host validates from ITS truth (range/busy/occupancy) and, on accept,
## commits the draw + looses the arrow; a reject bonks our own player. Vector2i survives RPC natively.
func _on_shoot_requested(target_tile: Vector2i) -> void:
	NetEvents.submit_intent("shoot", { "target_tile": target_tile })


## The local sampler picked a tile for the armed ability slot (v0.34.0): submit the "use_ability" intent
## through the one pipe (mirror of _on_shoot_requested), now carrying a target_tile beside the index. The
## host resolves the slot against the SENDER's class server-side and adjudicates range/busy/occupancy from
## ITS truth; a reject bonks our own player. Vector2i survives RPC natively.
func _on_ability_target_picked(index: int, target_tile: Vector2i) -> void:
	NetEvents.submit_intent("use_ability", { "index": index, "target_tile": target_tile })


## A click set/replaced the walk target: plant the marker on the tile. top_level marker →
## global_position exclusively. (The commit-sent flash was removed in v0.10.2 — the marker plant is
## now the sole click ack.)
func _on_path_target_set(target_tile: Vector2i) -> void:
	_path_marker.global_position = WorldGrid.tile_to_world(target_tile)
	_path_marker.visible = true
