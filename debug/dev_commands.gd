extends Node

## Host-only slash-command referee (v0.10.0, DESIGN §2.3.4 dev tools), extracted from main.gd (v0.10.1)
## so the ~1700-line session root sheds the whole dev-command surface. A scene Node in main.tscn beside
## the referees; Main activates it host-side with injected container/combat refs and registers its
## `validate` as the NetEvents "dev_command" handler. Inert on clients — activate() runs only inside
## main.gd's is_server() branch, so a client's node never adjudicates (mirrors the referees' contract).
##
## Component pattern (CLAUDE.md): it reads the containers/combat referee Main handed it plus the global
## GameManager config, and posts outcomes on the shared NetEvents pipe; it never reaches up to Main.
##
## ANY peer submits a dev_command {cmd, args} intent (the game_log "/" intercept parses + lowercases the
## tokens). validate() resolves the sender null-safe, then DISPATCHES on a command table: /w (weapon
## tuning), /m (monster tuning), /god (own invulnerability), /class (own class), and the bare-weapon
## alias ("/longsword 5" → /w longsword 5). The command table takes PRECEDENCE over the alias (a weapon
## named like a command is reachable only via /w). Most commands return a host-composed log line the
## generic dev_command event carries to every peer; /class instead broadcasts its own class_changed
## event and defers (no dev_command broadcast). Unknown command / bad field / non-number / out-of-range
## value → reject with a reason (sender-only, like a refused move).

# Plain-write game-field specs (v0.25.0): field -> { min, max } floats by default; "int": true /
# "bool": true switch the parse; "post" names a post-write hook. MUST stay in step with
# GameManager.DEV_GAME_FIELDS (the allowlist /help derives from) — an allowlisted field missing
# here AND missing a bespoke branch fails loudly in _dev_config_game_row.
const _GAME_FIELD_SPECS := {
	# v0.26.0: the single player idle dial split into the three ARMOR-WEIGHT bands (the light one also
	# covers UNARMORED); monsters keep their one dial.
	"player_regen_idle_light_beats": { "min": 0.0, "max": 100.0 },
	"player_regen_idle_medium_beats": { "min": 0.0, "max": 100.0 },
	"player_regen_idle_heavy_beats": { "min": 0.0, "max": 100.0 },
	"monster_regen_idle_beats": { "min": 0.0, "max": 100.0 },
	"player_regen_interval_beats": { "min": 0.25, "max": 100.0 },
	"monster_regen_interval_beats": { "min": 0.25, "max": 100.0 },
	"player_exhausted_step_beats": { "min": 1.0, "max": 100.0 },
	"monster_exhausted_step_beats": { "min": 1.0, "max": 100.0 },
	"player_refill_lockout_beats": { "min": 0.0, "max": 200.0 },
	"monster_refill_lockout_beats": { "min": 0.0, "max": 200.0 },
	"player_regen_refills_full": { "bool": true },
	"monster_regen_refills_full": { "bool": true },
	"player_passive_regen_beats": { "min": 0.0, "max": 100.0, "post": "passive" },
	"monster_passive_regen_beats": { "min": 0.0, "max": 100.0, "post": "passive" },
	# v0.27.1: both carry the "exhaust_cues" post hook — the `exhausted` event is EDGE-triggered and its
	# payload carries hard_stop, so flipping this dial while somebody sits at 0 stamina crosses no edge and
	# would leave that peer rendering the OTHER mode's cue (see MoveReferee.resync_exhaustion_cues).
	"player_exhausted_blocks_movement": { "bool": true, "post": "exhaust_cues" },
	"monster_exhausted_blocks_movement": { "bool": true, "post": "exhaust_cues" },
	"stamina_max": { "min": 1, "max": 12, "int": true },
	"monster_stamina_max": { "min": 1, "max": 12, "int": true },
	"monster_think_min_beats": { "min": 0, "max": 30, "int": true },
	"monster_think_max_beats": { "min": 0, "max": 30, "int": true },
	"swing_catches_adjacent": { "bool": true },
	# v0.26.0 instants experiment (DESIGN §2.11.1): the master toggle. Its two per-ability cooldown dials
	# moved onto the ability resources in v0.27.0 (`/ab <ability> cooldown_beats <n>`), so only the toggle
	# remains here — a plain host-side config write, no bespoke branch needed.
	"instant_abilities_enabled": { "bool": true },
	# v0.27.0 armor FLAT reduction per weight band (DESIGN §2.3.8) — the second armor term, min-combined with
	# the worn item's percentage. Small INTEGER amounts by nature (they are subtracted from a damage number),
	# and capped well below any weapon's damage so a dial turn can never make a band immune by itself.
	"armor_flat_reduction_light": { "min": 0, "max": 99, "int": true },
	"armor_flat_reduction_medium": { "min": 0, "max": 99, "int": true },
	"armor_flat_reduction_heavy": { "min": 0, "max": 99, "int": true },
	# v0.27.1 banter EARSHOT in TILES — how far a bark's reaction travels (0 = both reactions silent).
	# Capped at 60, comfortably past the map's diagonal, so a large value means "unlimited" in practice.
	"banter_earshot_tiles": { "min": 0, "max": 60, "int": true },
	# Both plain host-side writes, read live at their seams:
	#  whiff_recovery_beats   — v0.32.0, the FLOAT dial that replaced v0.28.0's `whiff_pays_recovery` bool:
	#                           -1 (default) = the whiff pays its FULL committed tail (pre-v0.26.0 §2.3.9),
	#                           0 = pays none (v0.26.0 "recovery only on contact"), N > 0 = pays N beats,
	#                           capped at the full tail. Min -1 because that ONE negative value is the
	#                           sentinel; max 30 matches the weapon `recovery_beats` clamp it carves up.
	#                           Read at each whiff resolve.
	#  recovery_locks_actions — v0.28.0 (Jeff's third batch): 0-stamina tactical entities cannot ACT
	#                           (movement stays the winded dials'); a no-op while stamina_enabled is off.
	#                           Read at each action validator.
	"whiff_recovery_beats": { "min": -1, "max": 30 },
	"recovery_locks_actions": { "bool": true },
	# v0.29.0 DEV PIN: everyone (players AND monsters) resolves TACTICAL while on — and stamina therefore
	# runs everywhere, since it gates on is_tactical. Host-side write, read live at each PaceReferee resolve.
	"force_tactical_pace": { "bool": true },
	# v0.30.0 the pack-rally SHOUT's reach in TRAVEL tiles (wall-bounded flood fill, not a radius).
	# 0 = no shout. Capped at 40 — comfortably past the largest room, so a big value means "the whole
	# connected region" in practice while still refusing an absurd typo. Plain host-side write, read
	# live at each organic aggro latch.
	"rally_travel_tiles": { "min": 0, "max": 40, "int": true },
	# v0.47.0 — the HOTBAR CAP the /ability grant validator enforces and the HUD draws from. Live-tunable so
	# the "can we go past five?" question is answerable in play rather than by rebuilding. Ceiling of 12 is
	# far past any plausible bar; the floor of 1 keeps a bar from vanishing.
	#
	# RAISING IT PAST 5 GIVES SOCKETS WITH NO KEYS until the input map gains matching `use_slot_N` actions
	# (see the GameConfig field). That is a real limitation of the dial, not a bug in it.
	"ability_slots": { "min": 1, "max": 12, "int": true },
	# v0.34.0 conditions — does damage BREAK the ROOTED condition? Ships OFF: a root runs its authored beats
	# and your own party focusing the held target does not free it. ON turns the root into a setup you spend.
	# The A/B switch for that feel question; read live at the apply_damage seam.
	"root_breaks_on_damage": { "bool": true },
	# v0.35.0 — the odds a bow monster with no clean lane AND no useful sidestep looses through its own
	# packmate anyway. A PROBABILITY, so 0-1; 0 = it holds, 1 = it always shoots (the setting to use when
	# you want to see the friendly-fire banter on demand instead of waiting on the roll). Plain host-side
	# write, read live at each archer think.
	"archer_reckless_shot_chance": { "min": 0, "max": 1 },
}

# The Players container + combat/move referees, handed in by Main via activate() on the HOST only.
# Players is read to resolve the sender's node (name, class); combat owns the /god invulnerability
# toggle; move answers the busy check for the /class equip guard (v0.17.0). Never reached up from;
# null on clients (activate never runs there).
var _players: Node2D = null
var _combat = null
var _move_referee = null
var _monsters: Node2D = null
# The host-only ground-item author API (v0.18.0), injected as a Callable by Main so /item can spawn WITHOUT
# reaching up into Main (the component never climbs the tree). Wraps Main._spawn_item_at(tile, type_path) ->
# bool, so every /item spawn still routes through the ONE guarded, id-assigning path. Empty (unbound) on
# clients — /item is host-adjudicated, so it is only ever called inside the host's validate.
var _spawn_item: Callable = Callable()
# NO INVENTORY REF (v0.28.1). v0.27.1 injected the InventoryReferee here so /class could put the armor you
# were wearing back in your bag; Jon's 2026-07-26 ruling reverted that — a class swap DISCARDS the old
# piece — so the field, its injection and the referee's try_add_to_bag primitive are all gone again. No
# dev command touches a bag now, and /class is the only path in the game that destroys an item (see the
# gear block in _dev_cmd_class for why that is sanctioned on a debug-only command).


## Host-only entry point, called by Main inside its is_server() branch after the referees are wired.
## Never called on clients (their node stays inert). `spawn_item` is the /item ground-item spawn Callable
## (v0.18.0) — Main binds it to _spawn_item_at so this component gains item-spawn access without a Main ref.
func activate(players: Node2D, combat: Node, move_referee: Node, spawn_item: Callable = Callable(),
		monsters: Node2D = null) -> void:
	_players = players
	_combat = combat
	_move_referee = move_referee
	_spawn_item = spawn_item
	# v0.25.0: the Monsters container joins the injection set — /mi resolves live instances and
	# /snapshot enumerates them. Null-safe like every other ref (inert on clients).
	_monsters = monsters


# ── Public methods ──────────────────────────────────────────────────────────────

## Host-only dev_command handler, registered with NetEvents by Main. Resolves the sender null-safe,
## then dispatches on the command table (table precedence over the bare-weapon alias). See the class
## header for the full contract.
func validate(sender_peer_id: int, data: Dictionary) -> Dictionary:
	var player_node := _players.get_node_or_null(str(sender_peer_id)) as Player
	if player_node == null:
		return { "ok": false, "reason": "not in session" }
	var by := player_node.display_name
	var cmd := str(data.get("cmd", "")).to_lower()
	# Coerce the wire args to a lowercased String array — never trust the wire's element types.
	var args: Array[String] = []
	var raw_args = data.get("args", [])
	if raw_args is Array:
		for a in raw_args:
			args.append(str(a).to_lower())
	match cmd:
		"w":
			return _dev_cmd_weapon(args, by)
		"m":
			return _dev_cmd_monster(args, by)
		"ab":
			return _dev_cmd_ability(args, by)
		"pa":
			return _dev_cmd_passive(args, by)
		"trait":
			return _dev_cmd_trait(sender_peer_id, args, by)
		"ability":
			return _dev_cmd_grant_ability(sender_peer_id, args, by)
		"god":
			return _dev_cmd_god(sender_peer_id, by)
		"class":
			return _dev_cmd_class(sender_peer_id, args, by)
		"item":
			return _dev_cmd_item(sender_peer_id, args, by)
		"config":
			return _dev_cmd_config(args, by)
		"stun":
			return _dev_cmd_stun(sender_peer_id, args, by)
		"root":
			return _dev_cmd_root(sender_peer_id, args, by)
		"ai":
			return _dev_cmd_ai(by)
		"stamina", "mp":
			# "mp" survives as an alias (v0.24.1 rename — muscle memory from the v0.24.0 playtest).
			return _dev_cmd_stamina(by)
		"winded":
			return _dev_cmd_winded(by)
		"mi":
			return _dev_cmd_monster_instance(args, by)
		"snapshot":
			return _dev_cmd_snapshot()
		_:
			# Bare-weapon alias: "/longsword 5" arrives as cmd "longsword", args ["5"]. Reachable ONLY when
			# cmd resolves to a real weapon (table precedence is handled by the match above). Re-dispatch as
			# /w by prepending the weapon name onto the args.
			if _resolve_weapon(cmd) != null:
				var aliased: Array[String] = [cmd]
				aliased.append_array(args)
				return _dev_cmd_weapon(aliased, by)
			return { "ok": false, "reason": "unknown command '%s'" % cmd }


# ── Private methods ─────────────────────────────────────────────────────────────

## /w <weapon> [field] <value|reset> — weapon tuning (v0.10.0). Resolve the weapon (roster first, then a
## filename load), then hand the rest to the shared tune pipeline for the reset / field-allowlist /
## range-clamp / mutate work shared with /m.
##
## THE SHORTHAND (v0.26.1): a LONE value ("/w club 3", and the "/club 3" alias) now COLLAPSES THE BAND —
## it sets damage_min AND damage_max to that value, which is exactly fixed damage. Before the bands
## landed this was "set `damage`", and keeping it meaningful matters twice over: it is the muscle-memory
## tuning command, and a collapsed band is the harness's determinism pin (no RNG seeding exists, so
## min == max is how a scripted run gets a predictable number). Implemented as TWO queued writes through
## the SAME _dev_tune_resource path, so the reject-not-clamp validation, the int/float kinds, and the
## reset-from-disk semantics are untouched — this function adds no rules of its own beyond the fan-out.
func _dev_cmd_weapon(args: Array[String], by: String) -> Dictionary:
	if args.size() < 2:
		return { "ok": false, "reason": "usage: /w <weapon> [field] <value|reset>" }
	var weapon := _resolve_weapon(args[0])
	if weapon == null:
		return { "ok": false, "reason": "unknown weapon '%s'" % args[0] }
	var rest := args.slice(1)
	# Lone value = the band-collapsing shorthand. A lone "reset" is left untouched so the shared
	# pipeline still sees it as a reset (which restores EVERY allowlisted field from disk, bands included).
	if rest.size() == 1 and rest[0] != "reset":
		var value_token: String = rest[0]
		# damage_min first; bail on its reject before touching damage_max. HONEST SCOPE (GLM v0.26.1
		# review): this only guarantees no-write on a MIN reject. Because both writes carry the SAME
		# token against the SAME clamp/kind, a max-reject-after-min-accept is unreachable today — if it
		# ever fires (clamps diverged, or _dev_tune_resource grew a post-mutation failure), the band IS
		# half-written, so we say so loudly instead of pretending atomicity we don't have.
		var min_verdict := _dev_tune_resource(weapon, GameManager.DEV_WEAPON_FIELDS,
				GameManager.DEV_WEAPON_INT_FIELDS, GameManager.DEV_WEAPON_CLAMPS,
				["damage_min", value_token] as Array[String], by, weapon.display_name)
		if not bool(min_verdict.get("ok", false)):
			return min_verdict
		var max_verdict := _dev_tune_resource(weapon, GameManager.DEV_WEAPON_FIELDS,
				GameManager.DEV_WEAPON_INT_FIELDS, GameManager.DEV_WEAPON_CLAMPS,
				["damage_max", value_token] as Array[String], by, weapon.display_name)
		if not bool(max_verdict.get("ok", false)):
			push_warning("[DevCommands] /w shorthand half-write: %s damage_min accepted but damage_max rejected (%s) — band left split; re-run '/w %s damage_max <n>' to mend it"
					% [weapon.display_name, str(max_verdict.get("reason", "?")), args[0]])
			return max_verdict
		# One composed line for the pair (the two per-field lines are discarded), naming the collapse so
		# nobody reads "set damage" and wonders which field moved.
		return { "ok": true, "data": { "line": "%s set %s damage to %s (band collapsed: min = max)."
				% [by, weapon.display_name, value_token] } }
	return _dev_tune_resource(weapon, GameManager.DEV_WEAPON_FIELDS, GameManager.DEV_WEAPON_INT_FIELDS,
			GameManager.DEV_WEAPON_CLAMPS, rest, by, weapon.display_name)


## /m <monster> <field> <value|reset> — MonsterType tuning (v0.10.0). Resolve the type by a filename load
## (exists-guarded — no roster for monsters, the .tres filename is the token), then hand the rest to the
## shared tune pipeline. No field default (a monster field is always explicit); max_hp carries a note that
## its change affects NEW spawns only (it is seeded at spawn), the one monster-specific rule.
func _dev_cmd_monster(args: Array[String], by: String) -> Dictionary:
	if args.size() < 2:
		return { "ok": false, "reason": "usage: /m <monster> <field> <value|reset>" }
	var monster := _resolve_monster(args[0])
	if monster == null:
		return { "ok": false, "reason": "unknown monster '%s'" % args[0] }
	return _dev_tune_resource(monster, GameManager.DEV_MONSTER_FIELDS, GameManager.DEV_MONSTER_INT_FIELDS,
			GameManager.DEV_MONSTER_CLAMPS, args.slice(1), by, monster.display_name,
			{ "max_hp": "(affects new spawns)" })


## /ab <ability> <field> <value|reset> — ACTIVE ABILITY tuning (v0.27.0). The third sibling of /w and /m:
## resolve the ability through GameConfig.ability_catalog by display_name SLUG (lowercase,
## spaces→underscores — so `shield_bash`, since the wire args arrive lowercased and a space would split into
## two tokens), then hand the rest to the shared tune pipeline for the reset / allowlist / clamp / mutate work.
##
## WHY IT EXISTS: Jeff's second verdict put COOLDOWNS on abilities (kick + shield bash at 40 beats) and
## retuned their stun and damage. Without a live dial, answering "is 40 beats right?" meant editing a `.tres`
## and restarting the session — the exact loop `/w` exists to avoid for weapons. The mutation lands on the
## SHARED loaded resource host-side, which every class's `active_abilities` points at, so a retune reaches
## every wielder at once and is read live at the next use (stamp-and-bake: a cooldown already running keeps
## the seconds it was stamped with). No per-instance form (the `/mi` equivalent) — abilities have no
## instances, only wielders.
func _dev_cmd_ability(args: Array[String], by: String) -> Dictionary:
	if args.size() < 2:
		return { "ok": false, "reason": "usage: /ab <ability> <field> <value|reset>" }
	var ability := GameManager.config.ability_by_name(args[0])
	if ability == null:
		return { "ok": false, "reason": "unknown ability '%s'" % args[0] }
	return _dev_tune_resource(ability, GameManager.DEV_ABILITY_FIELDS, GameManager.DEV_ABILITY_INT_FIELDS,
			GameManager.DEV_ABILITY_CLAMPS, args.slice(1), by, ability.display_name)


## /ability <name> [remove] — GRANT an active ability to the sender, or take it back (v0.47.0). The hotbar
## twin of `/trait`, and host-adjudicated the same way. (`/ab` is the TUNING command and stays what it was;
## this one hands the ability out.)
##
## Lands on the sender's own `granted_abilities`, never on `player_class.active_abilities` — that array is a
## SHARED resource, so appending there would put the ability on the hotbar of every player of that class.
##
## THE SLOT CAP IS ENFORCED HERE (Jon, 2026-07-28): a grant with no free slot is REFUSED and says so.
## Allowing a sixth into a five-socket bar would create an ability you own, can see in no socket, and can
## press no key for — the "looks like it worked" failure this codebase keeps writing guards against. The cap
## is `GameConfig.ability_slots`, authored so it can be raised (the field documents the input-map work that
## a sixth key needs).
##
## REMOVAL COMPACTS LEFT (Jon's ruling), because the alternative — leaving a hole — means the array carries
## nulls that every index-resolution site would have to reason about. The cost is honest and worth naming:
## removing a mid-bar ability SHIFTS the ones after it, so a key you had muscle memory for now casts its
## neighbour. Acceptable for a dev command; it would not be for an in-run acquisition mechanic.
##
## A CLASS ABILITY CANNOT BE GRANTED OR REMOVED through this: it is already in your slots, and duplicating
## it would give you two sockets sharing one cooldown key that drain together. Same refusal shape `/trait`
## uses for a class trait.
func _dev_cmd_grant_ability(sender_peer_id: int, args: Array[String], by: String) -> Dictionary:
	if args.is_empty():
		return { "ok": false, "reason": "usage: /ability <name> [remove]" }
	var removing: bool = args.size() > 1 and args[args.size() - 1] == "remove"
	var name_tokens := args.slice(0, args.size() - 1) if removing else args
	if name_tokens.is_empty():
		return { "ok": false, "reason": "usage: /ability <name> [remove]" }
	var wanted := " ".join(name_tokens)
	var ability := GameManager.config.ability_by_name(wanted)
	if ability == null:
		return { "ok": false, "reason": "unknown ability '%s'" % wanted }
	var player_node := _players.get_node_or_null(str(sender_peer_id)) as Player
	if player_node == null:
		return { "ok": false, "reason": "not in session" }
	var from_class: bool = player_node.player_class != null 			and ability in player_node.player_class.active_abilities
	var held: bool = ability in player_node.granted_abilities
	if from_class:
		return { "ok": false, "reason": "%s already has %s from their class" % [by, ability.display_name] }
	if removing and not held:
		return { "ok": false, "reason": "%s was not granted %s" % [by, ability.display_name] }
	if not removing:
		if held:
			return { "ok": false, "reason": "%s already has %s" % [by, ability.display_name] }
		# Measured against the ORDERED read, not against either raw array — that function applies the cap and
		# the de-duplication, so it is the only honest answer to "is there room".
		if player_node.ability_slots().size() >= GameManager.config.ability_slot_count():
			return { "ok": false, "reason": "%s has no free ability slot (%d/%d)" % [
					by, player_node.ability_slots().size(), GameManager.config.ability_slot_count()] }
	# Host-side first (authoritative), then broadcast — the /class and /trait shape. `erase` compacts, which
	# is the ruling above.
	if removing:
		player_node.granted_abilities.erase(ability)
	else:
		player_node.granted_abilities.append(ability)
	NetEvents.post_event("ability_removed" if removing else "ability_granted", {
		"entity_id": sender_peer_id,
		"name": player_node.display_name,
		"ability": ability.display_name,
		"by": by,
	})
	return { "ok": true, "deferred": true }


## /pa <trait> <field> <value|reset> — tune a TRAIT (v0.45.0). The fourth caller of the shared tune
## pipeline, resolving through the new `passive_catalog`. The mutation lands on the SHARED loaded resource
## host-side, which every wearer's class list (and every granted copy) points at, so a retune reaches
## everyone who has that trait at once and is read live at the next combat hook.
##
## THE ONE EXTRA GATE its three siblings do not need: a trait's fields live on its SUBCLASS, so
## `DEV_PASSIVE_FIELDS` is a union and a given field may not exist on the trait you named. Godot's
## `Object.set()` on a missing property is a SILENT no-op, so without this check
## `/pa backstab windup_beats_delta 2` would report success and change nothing. Checked BEFORE the shared
## pipeline runs, because that pipeline's allowlist can only answer "is this field tunable at all", not "on
## this resource".
func _dev_cmd_passive(args: Array[String], by: String) -> Dictionary:
	if args.size() < 2:
		return { "ok": false, "reason": "usage: /pa <trait> <field> <value|reset>" }
	var trait_res := _resolve_trait(args[0])
	if trait_res == null:
		return { "ok": false, "reason": "unknown trait '%s'" % args[0] }
	var rest := args.slice(1)
	# A trailing "reset" is the pipeline's whole-resource restore and names no field — let it through.
	if rest[rest.size() - 1] != "reset":
		var field: String = rest[0]
		if field in GameManager.DEV_PASSIVE_FIELDS and not _resource_has_property(trait_res, field):
			return { "ok": false, "reason": "'%s' has no %s" % [trait_res.display_name, field] }
	return _dev_tune_resource(trait_res, GameManager.DEV_PASSIVE_FIELDS,
			GameManager.DEV_PASSIVE_INT_FIELDS, GameManager.DEV_PASSIVE_CLAMPS, rest, by,
			trait_res.display_name)


## Does this resource actually declare `field`? A property-list check rather than `res.get(field) == null`,
## because a field authored to 0 / 0.0 is present and tunable while `get` on a MISSING property also returns
## null — the two cases must not collapse into one answer.
func _resource_has_property(res: Resource, field: String) -> bool:
	for prop in res.get_property_list():
		if str(prop.get("name", "")) == field:
			return true
	return false


## /trait <name> [remove] — GRANT a trait to the sender, or take it back (v0.45.0). Host-adjudicated.
##
## THIS IS THE POINT OF THE VERSION: a trait used to be a property of a CLASS and nothing else, so "give
## this player Archery" had no expression at all. It lands on the sender's own `granted_traits`, never on
## `player_class.passives` — that array is a SHARED resource, and appending to it would grant the trait to
## every player of that class on every peer (the `/w longsword` retune hazard, one level worse because it
## would look like it had worked).
##
## SENDER-ONLY, like `/class` and `/god`: an admin grants to themselves. Granting to someone else would need
## a target-resolution surface these commands do not have.
##
## A DUPLICATE GRANT IS REFUSED, not stacked — two copies in the union would run the trait's `modify_damage`
## twice and silently SQUARE its multiplier. Refusing says so rather than quietly doing the wrong thing, and
## a removal of something never granted is refused for the mirror reason: "you never had it" and "it is gone
## now" are different outcomes, and a no-op reporting success is how a command gets filed as broken.
func _dev_cmd_trait(sender_peer_id: int, args: Array[String], by: String) -> Dictionary:
	if args.is_empty():
		return { "ok": false, "reason": "usage: /trait <name> [remove]" }
	var removing: bool = args.size() > 1 and args[args.size() - 1] == "remove"
	var name_tokens := args.slice(0, args.size() - 1) if removing else args
	if name_tokens.is_empty():
		return { "ok": false, "reason": "usage: /trait <name> [remove]" }
	var wanted := " ".join(name_tokens)
	var trait_res := _resolve_trait(wanted)
	if trait_res == null:
		return { "ok": false, "reason": "unknown trait '%s'" % wanted }
	var player_node := _players.get_node_or_null(str(sender_peer_id)) as Player
	if player_node == null:
		return { "ok": false, "reason": "not in session" }
	# THE CLASS COUNTS AS HOLDING IT (GLM diff review, reproduced): checking `granted_traits` alone let a
	# ranger be granted the Archery its own class already gives, and the union then ran Archery's hook
	# twice — a measured 1.25s bow tail against the correct 1.5s. The referee dedupes as the real guard;
	# this refusal exists so the command can SAY why rather than silently doing nothing.
	var from_class: bool = player_node.player_class != null 			and trait_res in player_node.player_class.passives
	var held: bool = trait_res in player_node.granted_traits
	if not removing and from_class:
		return { "ok": false, "reason": "%s already has %s from their class" % [by, trait_res.display_name] }
	if removing and from_class and not held:
		# A class trait cannot be taken away by /trait — it is not in the granted list to remove, and
		# stripping a class of its own identity is a different feature (edit the class .tres).
		return { "ok": false, "reason": "%s is %s's class trait — not granted, so not removable" % [trait_res.display_name, by] }
	if removing and not held:
		return { "ok": false, "reason": "%s was not granted %s" % [by, trait_res.display_name] }
	if not removing and held:
		return { "ok": false, "reason": "%s already has %s" % [by, trait_res.display_name] }
	# Apply HOST-SIDE first (authoritative), then broadcast — the /class and swap_weapon shape. The
	# call_local re-apply on the host is idempotent: the handler assigns from the same name-resolved
	# resource, so applying it twice reaches the same array.
	if removing:
		player_node.granted_traits.erase(trait_res)
	else:
		player_node.granted_traits.append(trait_res)
	NetEvents.post_event("trait_removed" if removing else "trait_granted", {
		"entity_id": sender_peer_id,
		"name": player_node.display_name,
		"trait": trait_res.display_name,
		"by": by,
	})
	return { "ok": true, "deferred": true }


## The ONE tune pipeline for /w, /m, /ab and /pa (v0.10.1 dedup). `args` is the tokens after the resource name:
## a shape whose LAST token is "reset" restores every allowlisted field from disk; otherwise it is
## [field, value]. Validates the field against the allowlist, parses the value as a number, and REJECTS
## (naming the range — never silently clamps) any value outside the field's clamp table before mutating
## the SHARED loaded resource host-side (adjudication reads it live at the next stamp). A field in
## `int_fields` is stored as an int, else as a float. `notes` maps a field to a suffix appended to the
## success line (e.g. max_hp → "(affects new spawns)"). Returns the host-composed verdict dict.
func _dev_tune_resource(res: Resource, fields: Array, int_fields: Array, clamps: Dictionary,
		args: Array, by: String, label: String, notes: Dictionary = {}) -> Dictionary:
	# reset: any shape whose LAST token is "reset" restores every allowlisted field from disk.
	if not args.is_empty() and args[args.size() - 1] == "reset":
		_dev_reset_resource(res, fields)
		return { "ok": true, "data": { "line": "%s reset the %s." % [by, label] } }
	if args.size() < 2:
		return { "ok": false, "reason": "usage: <field> <value|reset>" }
	# Explicit String types — indexing a typed Array returns Variant at parse time, so := can't infer.
	var field: String = args[0]
	var value_token: String = args[1]
	if not (field in fields):
		return { "ok": false, "reason": "unknown field '%s'" % field }
	if not value_token.is_valid_float():
		return { "ok": false, "reason": "'%s' is not a number" % value_token }
	var num := value_token.to_float()
	# Range clamp (v0.10.1 review fix 1): a per-field sane range enforced HERE, at the one validator, so
	# a fat-fingered "/w longsword -5" or "/m goblin max_hp 1e9" is refused with the allowed range named
	# rather than poisoning the shared resource. clamps[field] is [min, max].
	var lo = clamps[field][0]
	var hi = clamps[field][1]
	if num < float(lo) or num > float(hi):
		return { "ok": false, "reason": "%s must be between %s and %s" % [field, str(lo), str(hi)] }
	if field in int_fields:
		res.set(field, int(num))
	else:
		res.set(field, num)
	var line := "%s set %s %s to %s." % [by, label, field, value_token]
	if notes.has(field):
		line += " " + str(notes[field])
	return { "ok": true, "data": { "line": line } }


## /god — toggle the SENDER's invulnerability (v0.10.0). Flips the combat referee's godded entry for the
## sender's own entity id and returns the log line from the NEW state. Host-authoritative (the godded dict
## lives host-side); a godded target's hits then resolve as visible no-ops in CombatReferee.apply_damage.
func _dev_cmd_god(sender_peer_id: int, by: String) -> Dictionary:
	var now_godded: bool = _combat.toggle_godded(sender_peer_id)
	var line := ("%s is invulnerable." % by) if now_godded else ("%s is mortal again." % by)
	return { "ok": true, "data": { "line": line } }


## /ai — toggle the utility-AI SCORE BROADCAST (v0.22.0), the /god pattern applied to a diagnostic. Flips the
## host's GameManager.debug_ai_decisions and returns the log line from the NEW state. Host-authoritative by
## construction: this validator only ever runs on the host, and the host is the only peer with monster brains,
## so a client can neither turn the firehose on for itself nor off for everyone. While ON, every utility-AI
## monster posts an `ai_decision` event after each think and the F3 overlay renders the last one per monster on
## EVERY peer — which is the point: a two-instance tuning session watches the same weights. Default off, so
## normal play pays nothing.
func _dev_cmd_ai(by: String) -> Dictionary:
	GameManager.debug_ai_decisions = not GameManager.debug_ai_decisions
	var line := ("%s turned AI score debug ON (F3 overlay)." % by) if GameManager.debug_ai_decisions \
			else ("%s turned AI score debug off." % by)
	return { "ok": true, "data": { "line": line } }


## /stamina (alias /mp) — toggle the STAMINA experiment (v0.24.0, renamed v0.24.1), the /ai pattern
## applied to a game rule. Flips the host's config flag (host-side reads are the whole authority story:
## MoveReferee's check/spend/regen/crawl and MonsterBrain's hesitation all gate on it host-side; no
## client reads it). OFF mutates no pool — byte-for-byte pre-experiment movement, the live half of the
## rollback story. ON reseeds every tracked entity to max (clean slate: nobody resumes a fight with an
## unearned partial pool) and bumps the regen generations, so no stale chain survives the off-window.
func _dev_cmd_stamina(by: String) -> Dictionary:
	GameManager.config.stamina_enabled = not GameManager.config.stamina_enabled
	if GameManager.config.stamina_enabled:
		_move_referee.reseed_all_stamina()
		return { "ok": true, "data": { "line": "%s turned STAMINA ON (pools reset to full)." % by } }
	# v0.24.3: clear any showing sweat-drops (presentation only — pools stay untouched on disable).
	_move_referee.clear_exhaustion_cues()
	return { "ok": true, "data": { "line": "%s turned stamina off." % by } }


## /winded — toggle HARD-STOP exhaustion (v0.24.6, Jon's ask): on = 0 stamina refuses movement
## outright (players AND monsters — the one validator gates both); off = the v0.24.1 crawl. The
## /ai-family pattern: host-side config flip is the whole authority story (read at adjudication).
func _dev_cmd_winded(by: String) -> Dictionary:
	# CONVERGENT toggle (v0.25.0 split): reads the PLAYER field and sets BOTH sides to its negation,
	# so a pair diverged through the per-side GUI dials snaps back together — the recovery primitive.
	var hard_stop := not GameManager.config.player_exhausted_blocks_movement
	GameManager.config.player_exhausted_blocks_movement = hard_stop
	GameManager.config.monster_exhausted_blocks_movement = hard_stop
	# RE-SYNC THE CUE (v0.27.1): the `exhausted` event is an EDGE and its payload carries hard_stop, and
	# since v0.27.0 the sweat-drop marks the CRAWL — so an entity already sitting at 0 when the mode flips
	# crossed no edge and kept the previous mode's cue (a crawler flipped to hard stop wore both
	# signatures at once; a hard-stopped body flipped to crawl never grew a drip). Re-posting the edge
	# rebuilds every payload from the live dial. Clients need no change — they already render the payload.
	_move_referee.resync_exhaustion_cues()
	if hard_stop:
		return { "ok": true, "data": { "line": "%s set exhaustion to HARD STOP (0 stamina = no moving, both sides)." % by } }
	return { "ok": true, "data": { "line": "%s set exhaustion back to the slow crawl (both sides)." % by } }


## /mi <id> <field|hp|stamina|stun|kill|reset> [value] — PER-INSTANCE monster tuning (v0.25.0, Jon's
## overhaul: "individually tweak each enemy instance"). The id is the entity id (negative; a bare
## positive is negated as a convenience). Stat fields run the SAME allowlist/clamp pipeline as /m,
## but against an INSTANCE-LOCAL duplicate of the MonsterType, lazily created on the first tune —
## untouched monsters keep sharing the authored .tres, so global /m tuning still reaches them. The
## duplicate + brain-ref migration happen synchronously in this validator (set_instance_type), so
## there is no window where the brain reads the old resource. `reset` reloads the SHARED .tres and
## swaps it back in (the instance rejoins global tuning). hp/stamina/stun/kill are live-state pokes
## through the owning referees, so every peer's presentation rides the normal events.
func _dev_cmd_monster_instance(args: Array[String], by: String) -> Dictionary:
	if _monsters == null or args.size() < 2:
		return { "ok": false, "reason": "usage: /mi <id> <field|hp|stamina|stun|kill|reset> [value]" }
	if not args[0].is_valid_int():
		return { "ok": false, "reason": "mi: '%s' is not an entity id" % args[0] }
	var entity_id := int(args[0].to_int())
	if entity_id > 0:
		entity_id = -entity_id
	var node := _monsters.get_node_or_null(str(entity_id)) as Monster
	if node == null or not _combat.is_alive(entity_id):
		# Stale-panel safety (GLM plan point #2): ids are monotonic and never reused in-session, so
		# a dead/gone id rejects cleanly here — a stale row can never tune the wrong monster.
		return { "ok": false, "reason": "mi: no living monster with id %d" % entity_id }
	var label := "%s#%d" % [node.display_name, entity_id]
	var sub: String = args[1]
	match sub:
		"hp":
			if args.size() < 3 or not args[2].is_valid_float():
				return { "ok": false, "reason": "mi %s: hp needs a number" % label }
			var target_hp := clampi(int(args[2].to_float()), 0, _combat.max_hp_of(entity_id))
			var current_hp: int = _combat.hp_of(entity_id)
			if target_hp > current_hp:
				_combat.apply_heal(entity_id, target_hp - current_hp, by)
			elif target_hp < current_hp:
				# Self-sourced admin damage: rides the full attack/death pipeline so every peer's
				# HP label, popup and (at 0) the death path behave exactly as a real hit.
				_combat.apply_damage(entity_id, entity_id, current_hp - target_hp, "admin", 0.0)
			return { "ok": true, "data": { "line": "%s set %s HP → %d." % [by, label, target_hp] } }
		"stamina":
			if args.size() < 3 or not args[2].is_valid_float():
				return { "ok": false, "reason": "mi %s: stamina needs a number" % label }
			if not _move_referee.admin_set_stamina(entity_id, int(args[2].to_float())):
				return { "ok": false, "reason": "mi %s: no stamina pool" % label }
			return { "ok": true, "data": { "line": "%s set %s stamina → %d." % [
					by, label, int(args[2].to_float())] } }
		"stun":
			var stun_beats := 3.0
			if args.size() >= 3 and args[2].is_valid_float():
				stun_beats = args[2].to_float()
			_combat.apply_stun(entity_id, stun_beats)
			return { "ok": true, "data": { "line": "%s stunned %s (%.1f beats)." % [by, label, stun_beats] } }
		"kill":
			_combat.apply_damage(entity_id, entity_id, _combat.hp_of(entity_id), "admin", 0.0)
			return { "ok": true, "data": { "line": "%s killed %s." % [by, label] } }
		"reset":
			var shared_path := str(node.get_meta("shared_type_path", ""))
			if shared_path.is_empty():
				return { "ok": true, "data": { "line": "%s: %s had no instance overrides." % [by, label] } }
			# Null-guarded reload (GLM diff review #3): a stale/unloadable path must reject, never
			# hand set_instance_type a null (glide_speed deref would crash the host).
			var restored := load(shared_path) as MonsterType
			if restored == null:
				return { "ok": false, "reason": "mi %s: shared type '%s' failed to load" % [label, shared_path] }
			node.set_instance_type(restored)
			node.remove_meta("shared_type_path")
			return { "ok": true, "data": { "line": "%s reset %s to its shared type." % [by, label] } }
		_:
			# Stat field: lazily fork the shared type into an instance-local duplicate. A duplicate
			# has no resource_path, which doubles as the "already forked" flag; the original path is
			# stashed as metadata so `reset` can rejoin the shared resource later.
			if node.monster_type == null:
				return { "ok": false, "reason": "mi %s: no monster type" % label }
			if node.monster_type.resource_path != "":
				node.set_meta("shared_type_path", node.monster_type.resource_path)
				node.set_instance_type(node.monster_type.duplicate())
			var tune_args: Array[String] = [sub]
			for extra_index in range(2, args.size()):
				tune_args.append(args[extra_index])
			return _dev_tune_resource(node.monster_type, GameManager.DEV_MONSTER_FIELDS,
					GameManager.DEV_MONSTER_INT_FIELDS, GameManager.DEV_MONSTER_CLAMPS,
					tune_args, by, label)


## /snapshot — post the full tuning-truth payload as a `dev_snapshot` event (v0.25.0, the debug
## panel's repaint source). DEFERRED verdict: the snapshot event IS the outcome (the /class
## precedent), so no generic dev_command line spams the log on every panel open/refresh. Values are
## read HOST-side (config, catalogs, referees), so a client's stale local config never leaks in.
func _dev_cmd_snapshot() -> Dictionary:
	var game := {}
	for field in GameManager.DEV_GAME_FIELDS:
		if field == "tactical_beat_sec":
			game[field] = GameManager.tactical_beat_sec
		else:
			game[field] = GameManager.config.get(field)
	# The toggles whose commands live outside the g-field table, included read-only-with-command:
	game["stamina_enabled"] = GameManager.config.stamina_enabled
	game["banter_enabled"] = GameManager.config.banter_enabled
	game["banter_chance"] = GameManager.config.banter_chance
	var weapons := {}
	for weapon in GameManager.config.weapon_catalog:
		weapons[weapon.display_name] = {
			"damage_min": weapon.damage_min, "damage_max": weapon.damage_max,
			"windup_beats": weapon.windup_beats, "recovery_beats": weapon.recovery_beats,
		}
	# CLASSES → their ABILITIES → the five tunable fields (v0.27.0), the panel's CLASSES section source.
	# Keyed by class display_name then by ability display_name, because that is how the panel presents it
	# ("pick a class, see its abilities") — even though the resource underneath is SHARED, which is exactly
	# what the section heading says out loud ("all wielders"). Read off the roster host-side, so a client's
	# panel shows host truth like every other section.
	var classes := {}
	for player_class in GameManager.config.class_roster:
		if player_class == null:
			continue
		var abilities := {}
		for ability in player_class.active_abilities:
			if ability == null:
				continue
			var ability_fields := {}
			for field in GameManager.DEV_ABILITY_FIELDS:
				ability_fields[field] = ability.get(field)
			abilities[ability.display_name] = ability_fields
		classes[player_class.display_name] = abilities
	var monster_types := {}
	var dir := DirAccess.open("res://resources/monsters")
	if dir != null:
		for file in dir.get_files():
			# Exports list .tres as .tres.remap sometimes — normalize; skip the personality resources.
			var file_name := file.trim_suffix(".remap")
			if not file_name.ends_with(".tres") or file_name.begins_with("personality"):
				continue
			var res := load("res://resources/monsters/" + file_name)
			if res == null or not (res is MonsterType):
				continue
			var type_fields := {}
			for field in GameManager.DEV_MONSTER_FIELDS:
				type_fields[field] = res.get(field)
			monster_types[file_name.trim_suffix(".tres")] = type_fields
	var instances := {}
	if _monsters != null:
		for child in _monsters.get_children():
			if not (child is Monster) or not _combat.is_alive(child.entity_id):
				continue
			var pool: Dictionary = _move_referee.stamina_of(child.entity_id)
			# Per-instance CURRENT stat values (the instance may hold a /mi duplicate diverged from
			# its shared type) — the panel's per-instance grid seeds from these, never from the type.
			var instance_fields := {}
			if child.monster_type != null:
				for field in GameManager.DEV_MONSTER_FIELDS:
					instance_fields[field] = child.monster_type.get(field)
			instances[str(child.entity_id)] = {
				"name": child.display_name,
				"hp": _combat.hp_of(child.entity_id),
				"max_hp": _combat.max_hp_of(child.entity_id),
				"stamina": pool["points"], "stamina_max": pool["max"],
				"tile": _move_referee.tile_of_entity(child.entity_id),
				"instanced": child.monster_type != null and child.monster_type.resource_path == "",
				"fields": instance_fields,
			}
	# TRAITS (v0.46.0) — enumerated from the CATALOG rather than from the class roster, deliberately. Every
	# other section here walks what is EQUIPPED or AUTHORED-ON-A-CLASS, but a trait can now be granted to
	# anyone, so "the traits that exist" is the honest set and the catalog is what defines it. It is also
	# the same index `/pa` resolves through, which is what keeps the panel from rendering rows whose edits
	# would reject (ROADMAP's split-index trap, which the trait catalog's coverage guard already prevents
	# from the other direction).
	var passives := {}
	for trait_res in GameManager.config.passive_catalog:
		if trait_res == null:
			continue
		var trait_fields := {}
		for field in GameManager.DEV_PASSIVE_FIELDS:
			# A trait only carries the fields its own subclass declares, so the union is filtered per
			# trait — the panel shows Sneak Attack a multiplier and Archery two deltas, not both to both.
			if _resource_has_property(trait_res, field):
				trait_fields[field] = trait_res.get(field)
		passives[trait_res.display_name] = trait_fields
	NetEvents.post_event("dev_snapshot", {
		"game": game, "weapons": weapons, "classes": classes, "passives": passives,
		"monster_types": monster_types, "instances": instances,
	})
	return { "ok": true, "deferred": true }


## /class <name> — set the SENDER's class (v0.10.0). Resolve the class through the roster, apply it
## host-side to the sender's player (set_class), then BROADCAST a class_changed event (mirror of
## swap_weapon) every peer adopts + logs, and return a DEFERRED verdict so NetEvents does NOT also
## broadcast a generic dev_command event (the class_changed event is the whole outcome — no double log).
## Late-join is handled separately (sync_player_field "class" in peer_ready).
##
## v0.27.1 — /class RECONCILES THE BODY SLOT to the class loadout. v0.28.1 — and the piece you were wearing
## is DISCARDED (Jon's ruling, 2026-07-26), never bagged. See the gear block below for the two rules and the
## three distinct skip reasons.
func _dev_cmd_class(sender_peer_id: int, args: Array[String], by: String) -> Dictionary:
	if args.is_empty():
		return { "ok": false, "reason": "usage: /class <name>" }
	var player_class := GameManager.config.class_by_name(args[0])
	if player_class == null:
		return { "ok": false, "reason": "unknown class '%s'" % args[0] }
	var player_node := _players.get_node_or_null(str(sender_peer_id)) as Player
	if player_node == null:
		return { "ok": false, "reason": "not in session" }
	# Apply host-side FIRST (authoritative), then broadcast — mirrors _validate_swap_weapon. set_class
	# repaints the host's own sprite at validator time too; the call_local re-apply stays idempotent.
	player_node.set_class(player_class)
	# MANA RECONCILE (v0.43.0) — immediately after the class is authoritative, because the pool's max IS a
	# property of the class. CLAMPS DOWN ONLY: becoming a druid (10) while holding 14 leaves you at 10, and
	# becoming a barbarian drops the pool entirely (the HUD bar goes with it). It never refunds and never
	# tops you up mid-session — a class swap is a dev tool, not a mana potion — EXCEPT for a player who had
	# no pool at all, who starts full simply because they have not spent anything yet.
	_combat.reconcile_mana(sender_peer_id)
	# Class loadout (v0.17.0): a class with its own weapon_roster equips its FIRST weapon (roster[0]) on the
	# switch — a ranger becomes a ranger holding the longsword, no bare-hands gap. Equipping RIDES the existing
	# swap_weapon event (host-side set_weapon first, then broadcast so every peer adopts it) — NEVER a
	# client-side class→weapon inference. A class with no roster (empty) leaves the current weapon untouched.
	# Resolve the equip's eligibility FIRST (v0.17.1), BEFORE posting class_changed, so a busy-skip can ride
	# a flag ON that event (you cannot amend an event peers already received). Two skip reasons, handled apart:
	var has_roster := not player_class.weapon_roster.is_empty()
	var starting: WeaponType = player_class.weapon_roster[0] if has_roster else null
	# #3: a NULL roster[0] slot (a misconfigured class .tres) — warn host-side and skip, never set_weapon(null).
	# This is an authoring bug, not a runtime state, so it is a dev-facing push_warning, not a player line.
	if has_roster and starting == null:
		push_warning("[dev_commands] /class %s: weapon_roster[0] is null — fix the class .tres. Weapon equip skipped." % player_class.display_name)
	# #5: BUSY skip (GLM chunk-1 review) — mid-commit the equip is SKIPPED (the class change itself is cosmetic
	# + passives and stays); re-arming a weapon inside a committed window is exactly the overlap the swap
	# validator's busy reject prevents (Commitment Rule). This is RECOVERABLE (Tab after), so surface it
	# player-visibly via a weapon_skipped flag on class_changed — the "success" line must not silently mislead.
	var busy: bool = _move_referee.is_entity_moving(sender_peer_id)
	var weapon_skipped: bool = has_roster and starting != null and busy
	# BODY ARMOR — /class IS A FULL LOADOUT SWAP, AND THE OLD PIECE IS DISCARDED (v0.28.1, Jon's ruling
	# 2026-07-26, after Jeff hit the v0.27.1 behavior: "when you change class it unequips the armor it's
	# wearing and puts it in the inventory"). Two rules:
	#
	# 1. RECONCILE, don't only equip (v0.27.1, KEPT). The body slot is set to the class's
	#    `starting_body_armor` UNCONDITIONALLY — INCLUDING null, which STRIPS you. v0.27.0 equipped only
	#    when the new class authored armor, so becoming an armour-less class silently left you in the
	#    PREVIOUS class's chainmail: /class stopped being a live read of the class you are, which is its
	#    whole contract. "Give me the starting equipment of class X" means exactly that, empty slot included.
	# 2. THE OLD PIECE IS DESTROYED, NOT BAGGED (v0.28.1, reverting v0.27.1's rule 2). A DELIBERATE,
	#    Jon-approved EXCEPTION to DESIGN §2.10's "swap in place so nothing is lost" — and it is scoped to
	#    exactly this command: you cannot change class in real play, so no player decision is ever undone by
	#    it, and v0.27.1's bagging made a character swap FILL YOUR BAG, which is the worse bug. It also makes
	#    the two slots consistent: the weapon step below has always discarded (a bare set_weapon, no bag call
	#    on any path). NOT SILENT, though — the `discarded` field below drives a log line that names the piece
	#    (§2.3.4). This overrules v0.27.1 review finding #6 on Jon's authority; do not re-file it.
	#
	# GATES stay the bag equip's — dead → stunned → busy (all three are "you cannot re-arm right now"). The
	# class change itself still lands in every case: it is cosmetic + passives, and skipping it would make the
	# command useless mid-fight. Each skip reason travels as its OWN string so the log line can say WHICH.
	# The v0.27.1 "bag full" reason is GONE with the bag traffic that could produce it.
	var starting_body: ItemType = player_class.starting_body_armor
	var worn: ItemType = player_node.equipped_body
	# Nothing to do when the slot already holds exactly what the class wants (including both null) — no
	# event, no bag traffic, no skip clause. Re-running /class on your own class is then a clean no-op.
	var gear_reconcile: bool = worn != starting_body
	var gear_skip_reason := ""
	if gear_reconcile:
		if not _combat.is_alive(sender_peer_id):
			gear_skip_reason = "dead"
		elif _combat.is_stunned(sender_peer_id):
			gear_skip_reason = "stunned"
		elif busy:
			gear_skip_reason = "busy"
	var gear_skipped: bool = not gear_skip_reason.is_empty()
	var class_data := {
		"entity_id": sender_peer_id,
		"class": player_class.display_name,
		"by": by,
	}
	if weapon_skipped:
		class_data["weapon_skipped"] = true  # present-only, like other optional event fields
	if gear_skipped:
		class_data["gear_skipped"] = true  # present-only, the weapon_skipped pattern exactly
		class_data["gear_skip_reason"] = gear_skip_reason  # v0.28.1: THREE distinct skips, three distinct lines
	NetEvents.post_event("class_changed", class_data)
	if has_roster and starting != null and not busy:
		player_node.set_weapon(starting)
		NetEvents.post_event("swap_weapon", {
			"entity_id": sender_peer_id,
			"weapon": starting.display_name,
			"by": by,
		}, sender_peer_id)
	if gear_reconcile and not gear_skipped:
		# Host-authoritative apply FIRST, then broadcast — the set_weapon precedent directly above, and the
		# SAME `equip_item {gear: true}` event the bag equip posts, so every peer adopts gear through ONE
		# handler. slot -1 still says "this did not come out of a bag" (main.gd's bag-slot mirror guard skips
		# it), and an EMPTY `equipped` is the STRIP.
		#
		# `discarded` (present-only, v0.28.1) names the piece that was DESTROYED. Deliberately NOT `returned`:
		# on the bag-equip path that field means "went back into your bag", so reusing it here would tell every
		# consumer the armor is recoverable when it no longer exists. The two fields are MUTUALLY EXCLUSIVE BY
		# CONSTRUCTION — this is the only producer of `discarded` and the bag path (InventoryReferee's
		# _validate_equip_item / _equip_body) never sets it, while this path no longer sets `returned` at all —
		# so game_log's branch on `discarded` cannot mislabel a bag return.
		player_node.set_body_armor(starting_body)
		var gear_data := {
			"entity_id": sender_peer_id,
			"name": player_node.display_name,
			"slot": -1,
			"equipped": starting_body.display_name if starting_body != null else "",
			"gear": true,
		}
		if worn != null:
			gear_data["discarded"] = worn.display_name
		# OFF-HAND reconciled in the SAME breath and by the SAME rule (v0.39.0): applied UNCONDITIONALLY,
		# including null, which empties the hand. Without the null half, switching knight → rogue would
		# leave a kite shield floating in a rogue's hand forever — the exact asymmetry the body slot's
		# "INCLUDING null, which STRIPS you" contract exists to prevent.
		#
		# IT RIDES THE EXISTING gear EVENT rather than only being set host-side (GLM diff review). The
		# obvious-looking shortcut — set it locally and let the class_changed broadcast sort the rest out —
		# is WRONG, and the reason is worth writing down: `set_class` only repaints the sprite and `_ready`
		# fires once at spawn, so nothing re-seeds gear on a live class change. A CLIENT running `/class
		# knight` would have had the shield set on the host's copy of its node and never on its own, so its
		# own HUD (which reads its own node) would show an empty hand. A present-only field on the event the
		# body slot already posts costs nothing, needs no new log line, and keeps both slots on one path.
		var starting_off: ItemType = player_class.starting_off_hand
		gear_data["off_hand"] = starting_off.display_name if starting_off != null else ""
		player_node.set_off_hand(starting_off)
		NetEvents.post_event("equip_item", gear_data, sender_peer_id)
	# Deferred: the class_changed broadcast IS the outcome — suppress the generic dev_command broadcast
	# (ok:true so it isn't a reject; deferred:true so NetEvents skips the broadcast + seq).
	return { "ok": true, "deferred": true }


## /item <name> [x,y] — spawn a ground item (v0.18.0), host-adjudicated. Resolve the item by display_name
## through GameManager.config.item_by_name (reject unknown); a MULTI-WORD name ("health potion") is supported
## because the trailing [x,y] is a single comma-joined token — if the LAST arg parses as "x,y" it is the tile
## and the name is the tokens before it, else every token forms the name and the tile is the SENDER's
## FACING-neighbor (its tile + MoveReferee.facing_of — NEVER its own tile). Three distinct §2.2.8 rejects:
## unknown item / bad tile (no facing yet, or not walkable) / tile blocked (an item already sits there). On
## success it spawns through Main's guarded item API (the injected _spawn_item Callable) and returns the
## host-composed line every peer logs. Server-authoritative: the tile + walkability + collision are all
## resolved host-side from shared config/grid, never a client value.
func _dev_cmd_item(sender_peer_id: int, args: Array[String], by: String) -> Dictionary:
	if args.is_empty():
		return { "ok": false, "reason": "usage: /item <name> [x,y]" }
	# Split off an optional trailing "x,y" tile token (a single comma-joined token, so it never collides with
	# a multi-word name). If the last arg is a valid tile, the name is everything before it; else the whole
	# arg list is the name and the tile comes from the sender's facing.
	var name_tokens := args
	var explicit_tile := Vector2i.ZERO
	var has_explicit_tile := false
	var last: String = args[args.size() - 1]  # indexing a typed Array yields Variant at parse — annotate
	var comma_parts := last.split(",", false)
	if comma_parts.size() == 2 and comma_parts[0].strip_edges().is_valid_int() and comma_parts[1].strip_edges().is_valid_int():
		explicit_tile = Vector2i(comma_parts[0].strip_edges().to_int(), comma_parts[1].strip_edges().to_int())
		has_explicit_tile = true
		name_tokens = args.slice(0, args.size() - 1)
	if name_tokens.is_empty():
		return { "ok": false, "reason": "usage: /item <name> [x,y]" }
	var item_name := " ".join(name_tokens)
	# Resolve item_catalog FIRST, then weapon_catalog (v0.21.0) — the SAME item-first order GameConfig's
	# category_of and hud.gd's _bag_icon_coords use, kept unambiguous by _warn_cross_catalog_collisions.
	# Weapons became spawnable here because v0.21.0 made autopickup POTION-ONLY: a weapon on the ground is
	# now the thing you must pick up deliberately with G, so a dev testing or tuning that flow has to be able
	# to PLACE one. Main's _spawn_item_at already accepts either type (it branches on ItemType vs WeaponType),
	# so this only widens the lookup. Held as Resource: both types expose display_name + resource_path, which
	# is all the rest of this function reads.
	var item: Resource = GameManager.config.item_by_name(item_name)
	if item == null:
		item = GameManager.config.weapon_by_name(item_name)
	if item == null:
		return { "ok": false, "reason": "unknown item or weapon '%s'" % item_name }
	# Resolve the target tile. Explicit x,y wins; otherwise the sender's facing-neighbor (their tile + the
	# authoritative 8-way facing the move referee tracks). A never-moved sender has ZERO facing (no
	# facing-neighbor exists) — reject as a bad tile rather than dropping the item on the sender's own tile.
	var tile := explicit_tile
	if not has_explicit_tile:
		var player_node := _players.get_node_or_null(str(sender_peer_id)) as Player
		if player_node == null:
			return { "ok": false, "reason": "not in session" }
		var facing: Vector2i = _move_referee.facing_of(sender_peer_id)
		if facing == Vector2i.ZERO:
			return { "ok": false, "reason": "no facing yet — move first, or give x,y" }
		tile = player_node.tile + facing
	# Bad tile: not walkable (a wall / off-grid). Checked HERE so the "tile blocked" reject below is
	# unambiguous. A broken resource_path is ALSO pre-checked (GLM v0.18.0 review #1): _spawn_item_at's
	# first guard is ResourceLoader.exists, so without this check a stale catalog path would be
	# misreported as "already has an item" — with both pre-checks, a false from the spawn call can only
	# mean an item-collision.
	if not ResourceLoader.exists(item.resource_path):
		return { "ok": false, "reason": "'%s' has a broken resource path (catalog drift)" % item.display_name }
	if not WorldGrid.is_walkable(tile):
		return { "ok": false, "reason": "(%d, %d) is not a walkable tile" % [tile.x, tile.y] }
	# Spawn through Main's guarded API (path + walkable re-checked + item-collision). Both other guards
	# passed above, so a false here can only mean an item already occupies the tile.
	if not _spawn_item.call(tile, item.resource_path):
		return { "ok": false, "reason": "(%d, %d) already has an item" % [tile.x, tile.y] }
	return { "ok": true, "data": { "line": "%s spawned a %s at (%d, %d)." % [by, item.display_name, tile.x, tile.y] } }


## /config <alias> — apply a named BUNDLE of weapon/monster tunings in one command (v0.19.7 dev tool). The
## alias indexes GameManager.CONFIG_PRESETS; each row [kind, name, field, value] is applied through the SAME
## per-field allowlist + clamp pipeline /w and /m use (_dev_tune_resource), so a preset row can't bypass
## validation. A bad row (unknown resource / field / out-of-range) REJECTS the whole /config naming that row
## (rows before it were already set host-side — a preset is author-controlled, so this is a defensive path, not
## a rollback need). On success one host-composed summary line broadcasts to every peer (like /w). Values apply
## to the SHARED resources adjudication reads live, so the loadout takes effect from the next stamp.
##
## v0.22.1 adds the GAME-LEVEL row kind "g" (GameManager.DEV_GAME_FIELDS), handled BEFORE the w/m dispatch
## because it resolves no resource at all: a game-level value lives on GameManager (per-peer) or behind a
## host-adjudicated broadcast, so it is dispatched PER FIELD here rather than through _dev_tune_resource.
## The bundle's summary line names the tempo it set, so the outcome is legible without reading the table.
func _dev_cmd_config(args: Array[String], by: String) -> Dictionary:
	var known := ", ".join(PackedStringArray(GameManager.CONFIG_PRESETS.keys()))
	if args.is_empty():
		return { "ok": false, "reason": "usage: /config <alias> | /config <field> <value> (aliases: %s; fields: %s)" % [
				known, ", ".join(PackedStringArray(GameManager.DEV_GAME_FIELDS))] }
	# DIRECT game-field form (v0.24.2): `/config regen_idle_beats 5` sets ONE game-level field live,
	# without a preset. Before this, the DEV_GAME_FIELDS dials were only reachable through preset table
	# rows — allowlisted but untypeable (found while writing the stamina playtest instructions). Same
	# per-field dispatch/clamps as a preset's g row; "live" is the alias label in its reject lines.
	if args.size() >= 2 and str(args[0]) in GameManager.DEV_GAME_FIELDS:
		var direct_verdict := _dev_config_game_row("live", str(args[0]), str(args[1]), by)
		if not bool(direct_verdict.get("ok", false)):
			return direct_verdict
		return { "ok": true, "data": { "line": "%s set %s." % [by, str(direct_verdict.get("note", args[0]))] } }
	var alias: String = args[0]
	if not GameManager.CONFIG_PRESETS.has(alias):
		return { "ok": false, "reason": "unknown config '%s' (known: %s)" % [alias, known] }
	var rows: Array = GameManager.CONFIG_PRESETS[alias]
	# Extra clauses appended to the bundle's summary line by the game-level rows (a "w"/"m" row is already
	# summarized by the row count). Empty for a preset with no "g" rows.
	var game_notes: Array[String] = []
	for row in rows:
		var kind: String = str(row[0])
		var res_name: String = str(row[1])
		var field: String = str(row[2])
		var value_token: String = str(row[3])
		# GAME-LEVEL row (v0.22.1) — BEFORE the w/m dispatch, since there is no resource to resolve.
		if kind == "g":
			var game_verdict := _dev_config_game_row(alias, field, value_token, by)
			if not bool(game_verdict.get("ok", false)):
				return game_verdict
			var note := str(game_verdict.get("note", ""))
			if not note.is_empty():
				game_notes.append(note)
			continue
		var res: Resource = null
		var fields: Array
		var int_fields: Array
		var clamps: Dictionary
		if kind == "w":
			res = _resolve_weapon(res_name)
			fields = GameManager.DEV_WEAPON_FIELDS
			int_fields = GameManager.DEV_WEAPON_INT_FIELDS
			clamps = GameManager.DEV_WEAPON_CLAMPS
		elif kind == "ab":
			# ABILITY row kind (v0.27.0). No shipped preset uses it yet — it is here so an ability-tuning
			# loadout is a table entry rather than a code change, exactly as the "w"/"m" kinds are. Resolved
			# through the catalog by display_name slug, the same lookup /ab uses.
			res = GameManager.config.ability_by_name(res_name)
			fields = GameManager.DEV_ABILITY_FIELDS
			int_fields = GameManager.DEV_ABILITY_INT_FIELDS
			clamps = GameManager.DEV_ABILITY_CLAMPS
		else:
			res = _resolve_monster(res_name)
			fields = GameManager.DEV_MONSTER_FIELDS
			int_fields = GameManager.DEV_MONSTER_INT_FIELDS
			clamps = GameManager.DEV_MONSTER_CLAMPS
		if res == null:
			return { "ok": false, "reason": "config %s: unknown %s '%s'" % [alias, _row_kind_label(kind), res_name] }
		# Reuse the ONE tune pipeline per row — same allowlist / clamp / int-or-float / mutate as /w & /m. Its
		# per-field success line is discarded (we compose a bundle summary); its REJECT reason is surfaced.
		var tune_args: Array[String] = [field, value_token]
		var verdict := _dev_tune_resource(res, fields, int_fields, clamps, tune_args, by, str(res.get("display_name")))
		if not bool(verdict.get("ok", false)):
			return { "ok": false, "reason": "config %s @ %s.%s: %s" % [alias, res_name, field, str(verdict.get("reason", "failed"))] }
	var line := "%s applied config %s (%d settings)." % [by, alias, rows.size()]
	if not game_notes.is_empty():
		line += " " + ", ".join(PackedStringArray(game_notes)) + "."
	return { "ok": true, "data": { "line": line } }


## One GAME-LEVEL ("g") preset row (v0.22.1). Validates `field` against GameManager.DEV_GAME_FIELDS (an unknown
## field REJECTS the bundle naming the field, mirroring the resource path's unknown-field reject), then
## dispatches PER FIELD — each game-level value has its own authority story, so there is deliberately no generic
## "set a GameManager member" path here. Returns { ok, reason } like the tune pipeline, plus an optional `note`
## clause the caller appends to the bundle's summary line.
##
## tactical_beat_sec: snapped + clamped EXACTLY as main.gd's _validate_set_tactical_tempo does (snappedf to
## config.tempo_step_sec, clamped to [tempo_min_sec, tempo_max_sec]) — the shared GameConfig band is the sole
## authority on the grid, read here server-side, so a preset can't set a beat the [ / ] keys couldn't. The value
## is then published as a normal set_tactical_tempo EVENT rather than written onto GameManager: the beat is a
## PER-PEER variable, so a host-side write would leave every client's dial (and its readout) stale. Posting the
## event means every peer — host included, via call_local — adopts through the ONE _apply_tactical_tempo
## chokepoint (main.gd), exactly as a [ / ] nudge does, and game_log prints its usual "Tactical: …" line.
## Precedent: /class posts its own class_changed event instead of relying on the generic dev_command line.
##
## NO "no change" REJECT (unlike the host validator, which refuses an unchanged beat so the display/log don't
## churn): a preset is a LOADOUT, and applying config 1 twice in a session must be idempotent, not a failure —
## a re-apply that hit the reject would fail the whole bundle mid-way. Re-posting the same beat is harmless
## (every adopt path is idempotent); one duplicate log line is the whole cost.
func _dev_config_game_row(alias: String, field: String, value_token: String, by: String) -> Dictionary:
	if not (field in GameManager.DEV_GAME_FIELDS):
		return { "ok": false, "reason": "config %s: unknown game field '%s'" % [alias, field] }
	if not value_token.is_valid_float():
		return { "ok": false, "reason": "config %s @ %s: '%s' is not a number" % [alias, field, value_token] }
	# TABLE-DRIVEN plain writes (v0.25.0 overhaul): every field in _GAME_FIELD_SPECS shares ONE
	# authority story — host-side config write, read live at the referee's arm/stamp/resolve sites,
	# no client ever reads it — so they share one dispatch (clamp per spec, typed set, optional
	# post-write hook). A field with a DIFFERENT story (tactical_beat_sec broadcasts an event)
	# keeps its bespoke branch below.
	if _GAME_FIELD_SPECS.has(field):
		var spec: Dictionary = _GAME_FIELD_SPECS[field]
		var note: String
		if bool(spec.get("bool", false)):
			var flag := value_token.to_float() != 0.0
			GameManager.config.set(field, flag)
			note = "%s → %s" % [field, "ON" if flag else "off"]
		elif bool(spec.get("int", false)):
			var int_value := clampi(int(value_token.to_float()), int(spec["min"]), int(spec["max"]))
			GameManager.config.set(field, int_value)
			note = "%s → %d" % [field, int_value]
		else:
			var float_value := clampf(value_token.to_float(), float(spec["min"]), float(spec["max"]))
			GameManager.config.set(field, float_value)
			note = "%s → %.2f" % [field, float_value]
		# Post-write hooks, by name (v0.27.1: a match, so a third hook is one arm):
		#  "passive"      — re-arm the always-on regen chains so a knob turned on mid-session reaches
		#                   every already-spawned entity (both split fields share it).
		#  "exhaust_cues" — re-post the exhaustion edge for anyone already at 0, because this write
		#                   CHANGES WHAT THE CUE MEANS and no edge is crossed by the write itself.
		match str(spec.get("post", "")):
			"passive":
				_move_referee.start_passive_regen_all()
			"exhaust_cues":
				_move_referee.resync_exhaustion_cues()
		return { "ok": true, "note": note }
	match field:
		"tactical_beat_sec":
			var cfg := GameManager.config
			var beat := clampf(snappedf(value_token.to_float(), cfg.tempo_step_sec), cfg.tempo_min_sec, cfg.tempo_max_sec)
			NetEvents.post_event("set_tactical_tempo", { "beat_sec": beat, "by": by })
			return { "ok": true, "note": "tactical beat → %.2fs/beat" % beat }
	# Unreachable while DEV_GAME_FIELDS, _GAME_FIELD_SPECS and the match stay in step — but a field
	# allowlisted without a handler must fail LOUDLY here, not silently no-op into a "success" line.
	return { "ok": false, "reason": "config %s: game field '%s' has no handler" % [alias, field] }


## /stun [me|<monster>] [beats] — apply a STUN (v0.20.0 dev tool, for testing the status effect before abilities
## exist). No arg / "me" / "self" stuns the SENDER (test the player can't-act bonk + overhead icon); a monster
## display_name stuns the first LIVE monster of that name (test a frozen goblin + icon). A numeric token = beats
## (default 3). Host-adjudicated + broadcast (the icon shows on every peer). Rejects an unknown monster name.
func _dev_cmd_stun(sender_peer_id: int, args: Array[String], by: String) -> Dictionary:
	var beats := 3.0
	var name_arg := ""
	for a in args:
		if a.is_valid_float():
			beats = a.to_float()
		elif not (a in ["me", "self"]):
			name_arg = a
	var target_id := sender_peer_id
	var target_name := by
	if name_arg != "":
		var mid: int = _combat.find_monster_by_name(name_arg)
		if mid == 0:
			return { "ok": false, "reason": "no live monster named '%s'" % name_arg }
		target_id = mid
		target_name = name_arg
	_combat.apply_stun(target_id, beats)
	return { "ok": true, "data": { "line": "%s stunned %s for %.0f beats." % [by, target_name, beats] } }


## /root [me|<monster>] [beats] — apply the ROOTED condition (v0.34.0 conditions framework). The exact
## sibling of /stun above, argument for argument: no arg / "me" / "self" roots the SENDER (test the movement
## bonk + the tendril cue + that you can still SWING while held); a monster display_name roots the first LIVE
## monster of that name (test a goblin that stops chasing but keeps attacking). A numeric token = beats
## (default 30 — the shipped Entangling Roots duration, so the dev poke feels like the real ability rather
## than a 3-beat blip). Host-adjudicated + broadcast, so the cue and the log line land on every peer.
##
## WHY IT EXISTS beside the druid ability: it exercises the CONDITION half alone, with no cast, no range, no
## targeting cursor and no class in the way — which is what makes a rooted-lifecycle assertion a one-line
## scripted run, and what will test the next condition (slow, poison) the day it lands.
func _dev_cmd_root(sender_peer_id: int, args: Array[String], by: String) -> Dictionary:
	var beats := 30.0
	var name_arg := ""
	for a in args:
		if a.is_valid_float():
			beats = a.to_float()
		elif not (a in ["me", "self"]):
			name_arg = a
	var target_id := sender_peer_id
	var target_name := by
	if name_arg != "":
		var mid: int = _combat.find_monster_by_name(name_arg)
		if mid == 0:
			return { "ok": false, "reason": "no live monster named '%s'" % name_arg }
		target_id = mid
		target_name = name_arg
	_combat.apply_condition(target_id, "rooted", beats)
	return { "ok": true, "data": { "line": "%s rooted %s for %.0f beats." % [by, target_name, beats] } }


## The human label for a `/config` preset ROW KIND, used only in the unknown-resource reject (v0.27.0 — the
## reject used to inline a two-way "weapon" / "monster" ternary, which quietly mislabelled the new "ab" kind
## as a monster). One place to name a kind, so the fourth kind cannot repeat the mistake.
func _row_kind_label(kind: String) -> String:
	match kind:
		"w":
			return "weapon"
		"ab":
			return "ability"
	return "monster"


## Resolve a weapon by lowercase name (v0.10.0 /w): GameConfig.weapon_by_name FIRST (catalog display_name),
## else a filename load guarded by ResourceLoader.exists — so a weapon not in the player roster (e.g. the
## goblin's club) is still reachable by its filename (= its display_name). Null if neither resolves. Host-side.
## Resolve a TRAIT by catalog display_name slug, falling back to its .tres FILENAME (v0.45.0) — the exact
## shape `_resolve_weapon` below uses, and for a sharper reason here.
##
## THE TWO NAMES GENUINELY DIVERGE for the shipped traits, permanently and on purpose: the rogue's file is
## `backstab.tres` while its display_name is "Sneak Attack" (v0.27.0 renamed the concept and deliberately
## kept the filename, because renaming a `.tres` breaks loads through Godot's uid cache — a known landmine
## in this repo, recorded at backstab.gd's header). So a dev reading the resources folder types
## `/trait backstab` and a dev reading the HUD types `/trait sneak_attack`, and BOTH are the obvious thing
## to type. Refusing either would be the command being pedantic about an inconsistency the codebase chose.
##
## Catalog FIRST so the authored name always wins; the filename is the convenience path.
func _resolve_trait(name: String) -> PassiveAbility:
	var p := GameManager.config.passive_by_name(name)
	if p != null:
		return p
	# The token becomes part of a path, so it must be a bare filename (GLM diff review). A dev command is a
	# trusted surface and the `as PassiveAbility` cast already fails a wrong-type load safely, but building
	# a path out of unvalidated text is the kind of thing that stops being harmless when someone reuses the
	# helper somewhere less trusted. Refuse separators outright rather than sanitizing them away.
	var file := name.to_lower().replace(" ", "_")
	if file.contains("/") or file.contains("\\") or file.contains(".."):
		return null
	var path := "res://resources/passives/%s.tres" % file
	if ResourceLoader.exists(path):
		return load(path) as PassiveAbility
	return null


func _resolve_weapon(name: String) -> WeaponType:
	var w := GameManager.config.weapon_by_name(name)
	if w != null:
		return w
	var path := "res://resources/weapons/%s.tres" % name
	if ResourceLoader.exists(path):
		return load(path) as WeaponType
	return null


## Resolve a MonsterType by lowercase name via a filename load, exists-guarded (v0.10.0 /m). No roster for
## monsters — the .tres filename is the token ("goblin" → goblin.tres). Null if the file is absent.
func _resolve_monster(name: String) -> MonsterType:
	var path := "res://resources/monsters/%s.tres" % name
	if ResourceLoader.exists(path):
		return load(path) as MonsterType
	return null


## Restore `fields` on a shared resource from a FRESH disk copy (v0.10.0 /w & /m reset). Loads the same
## .tres with CACHE_MODE_IGNORE (Godot 4.7's cache_mode param) so it reads the authored on-disk values
## regardless of the live mutated cached instance, then copies each allowlisted field onto the shared
## resource. The resource's own resource_path is the source — a roster-resolved weapon carries it just like
## a filename-loaded one, so both reset paths share this.
func _dev_reset_resource(res: Resource, fields: Array) -> void:
	var fresh := ResourceLoader.load(res.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if fresh == null:
		return
	for f in fields:
		res.set(f, fresh.get(f))
