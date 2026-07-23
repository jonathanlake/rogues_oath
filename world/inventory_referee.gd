extends Node

## The HOST-ONLY inventory authority (v0.18.0, inventory chunk B). It owns each player's BAG — the
## authoritative list of the items they carry — and is the single place a walk-over pickup is adjudicated.
## It sits beside MoveReferee / CombatReferee / PaceReferee and, like them, is INERT on clients: the node
## exists on every peer (it's in main.tscn) but activate() is called only inside main.gd's is_server()
## branch, so a client's inventory referee never stores a bag or adjudicates a pickup. The CLIENT-side
## mirror (Player.inventory, adopted from the item_picked_up event) is presentation truth only; THIS dict
## is the authority (§2.5 — gameplay state adjudicated host-side, replicated as discrete commit events).
##
## Component pattern (CLAUDE.md): Main hands it the Players + Items containers via activate() and injects it
## into MoveReferee (set_inventory) so a completed glide's arrival tile routes a pickup through it. It never
## reaches up to Main — it reads only the containers it was given, and posts outcomes on the shared NetEvents
## pipe (item_picked_up / item_pickup_full) exactly as the combat referee posts attack/died.
##
## Who drives it:
##  - PICKUP — MoveReferee._finish_glide calls try_pickup(mover_id, arrival_tile) at the moment a glide's
##    arrival is finalized (a walk-over). The referee scans the Items container for a GroundItem on that tile
##    and, if the mover has room, moves it into the bag + frees the ground node (the spawner replicates the
##    despawn); a full bag posts a distinct blocked outcome and leaves the item lying there (§2.3.4 — never a
##    silent swallow). Monsters (negative ids) never loot.
##  - RESET — Main._reset_round calls reset_round() beside CombatReferee.reset_round(): a fresh round starts
##    every bag empty (the mass free() of players also fires the child-exit erase below; this is the belt).

# The HUD hotbar width (hud.gd INV_COLS) — a picked-up item lands in the next hotbar slot, so the bag caps at
# exactly the hotbar's slot count. COUPLING: this MUST stay equal to hud.gd's INV_COLS (the top inventory row
# painted by _build_inventory / _refresh_hotbar) and to the client mirror's cap in main.gd's item_picked_up
# handler — a bag bigger than the hotbar would carry items with nowhere to show (v1 has no scrolling inventory).
const INVENTORY_SLOTS := 5

# Authoritative BAGS: entity_id (peer id, always > 0 — monsters don't loot) -> Array[String] of item
# display_names, in pickup order (index == hotbar slot). THE inventory truth; Player.inventory on each peer is
# only a presentation mirror adopted from the item_picked_up events. Seeded EMPTY on demand at first pickup and
# erased wholesale when the player's node leaves (death / disconnect / F5 reset — permadeath: the bag dies with
# the player). A fresh spawn / late joiner therefore starts EMPTY by construction — no late-join bag sync
# exists, a DELIBERATE v1 scope decision (an item is picked up in the fresh round, not carried across).
var _inventories: Dictionary = {}

# The Players / Items containers, handed in by Main via activate() on the HOST only. _players resolves the
# mover node (its display_name for the event) + is the child-exit hook source; _items is scanned for the
# GroundItem on the arrival tile. Both null on clients (activate never runs there).
var _players: Node2D = null
var _items: Node2D = null

# The MoveReferee / CombatReferee / PaceReferee, handed in by Main via activate() on the HOST only (v0.18.0
# chunk C — the USE flow). The use validator needs all three: the move referee for the BUSY gate
# (is_entity_moving — the Commitment Rule) and the universal busy record that roots the drinker
# (commit_in_place); the combat referee for the liveness gate (is_alive) and the heal application
# (apply_heal); the pace resolver to stamp the committed use window at the user's resolved beat. Held
# untyped (their scripts expose no class_name, so their calls resolve dynamically — mirror of CombatReferee
# holding _move_referee / _pace untyped). All null on clients (activate never runs there).
var _move_referee = null
var _combat = null
var _pace = null

# Round generation (v0.18.0 chunk C), host-only. Bumped by reset_round() on every F5 dev round-reset and
# captured BY VALUE into each pending _resolve_use bind, then re-checked when the use timer fires — so a use
# in flight when the round resets heals NOTHING into the fresh round. A same-peer respawn reuses the peer id
# and so passes the is_alive guard, but its generation no longer matches. The exact v0.17.1 arrow idiom
# (CombatReferee._round_gen); an id that a stale timer can never match post-reset.
var _round_gen: int = 0


## Host-only entry point, called by Main inside its is_server() branch BEFORE any spawn (so the child-exit
## hook is armed for every player). Stores the containers and wires the Players container's child_exiting_tree
## to drop a leaving player's bag — inventory dies with the player (permadeath), and because a fresh spawn /
## late joiner starts with no bag entry there is deliberately NO late-join sync (v1 scope). Never called on
## clients (their inventory referee stays inert, _inventories always empty).
func activate(players: Node2D, items: Node2D, move_referee: Node, combat: Node, pace: Node) -> void:
	_players = players
	_items = items
	# The sibling referees the USE flow adjudicates against (v0.18.0 chunk C). Injected by Main the same way
	# CombatReferee receives its peers — the components hold each other's references so the use validator can
	# gate on busy/liveness, root the drinker, stamp at pace, and apply the heal, all without reaching up to Main.
	_move_referee = move_referee
	_combat = combat
	_pace = pace
	_players.child_exiting_tree.connect(_on_player_exiting)
	# Register the "use_item" intent validator on the shared pipe (the way CombatReferee registers "shoot").
	# Host-only — activate never runs on a client, so a client's inventory referee never adjudicates a use.
	NetEvents.register_handler("use_item", _validate_use_item)


## Host-only walk-over pickup adjudication, called by MoveReferee at a glide's finalized arrival. Scans the
## Items container for a GroundItem on `tile`; no item → nothing to do. With an item present:
##  - FULL bag (size >= INVENTORY_SLOTS): the item STAYS on the ground and a broadcast item_pickup_full event
##    fires. There is no unicast pipe in v1, so game_log self-filters that event to the mover's OWN instance
##    (the "You died." self-filter precedent) and renders "(your bag is full)" there — §2.3.4 forbids a
##    silently-swallowed outcome, so a blocked pickup is still surfaced, just not as party spam.
##  - Room available: append the item's name (the next slot), FREE the ground node host-side (the ItemSpawner
##    replicates the despawn to every peer), and broadcast item_picked_up so every peer mirrors the bag +
##    renders the log line + plays the cue (main.gd), and the picker's HUD repaints its hotbar.
## MONSTERS DON'T LOOT (v1): a NEGATIVE mover id (a monster's glide rides the same _finish_glide seam) returns
## immediately. A vanished mover node (killed the same frame) also returns — belt with MoveReferee's own
## stale-guard, which already cleared a dead mover's glide record before this could fire.
func try_pickup(mover_id: int, tile: Vector2i) -> void:
	# Monsters don't loot in v1 — their glide rides the same completion seam, so guard the sign here (one
	# early return) rather than at the call site. A future looting monster removes this line.
	if mover_id < 0:
		return
	var mover := _players.get_node_or_null(str(mover_id)) as Entity
	if mover == null:
		return  # mover despawned between arrival and this call — nothing to pick up onto
	var ground := GroundItem.on_tile(_items, tile)
	if ground == null:
		return  # no item underfoot — the common case
	# Seed the bag lazily on first pickup (a fresh player has no entry — that IS the empty-start contract).
	if not _inventories.has(mover_id):
		var fresh: Array[String] = []
		_inventories[mover_id] = fresh
	var bag: Array[String] = _inventories[mover_id]
	var item_name: String = ground.item_name
	var mover_name: String = mover.display_name
	# FULL bag: the item stays on the ground (no free, no bag mutation). Broadcast the blocked outcome so the
	# mover's own instance can surface it (§2.3.4 no-silent-swallow) — a broadcast event self-filtered in
	# game_log, because v1 has no per-peer unicast and a pickup is not an intent (so the reject-to-sender pipe
	# does not fit). entity_id lets game_log render the line ONLY on the mover's instance.
	if bag.size() >= INVENTORY_SLOTS:
		NetEvents.post_event("item_pickup_full", {
			"entity_id": mover_id,
			"name": mover_name,
			"item": item_name,
		})
		return
	# Room available: commit the pickup. Append to the bag (index == the hotbar slot it lands in), free the
	# ground node host-side (the spawner replicates the despawn — mirror of CombatReferee._kill_entity's free),
	# then broadcast so every peer mirrors the bag, logs the line, and plays the cue.
	var slot := bag.size()
	bag.append(item_name)
	ground.queue_free()
	NetEvents.post_event("item_picked_up", {
		"entity_id": mover_id,
		"name": mover_name,       # mover's display name (game_log line), server-resolved, never the wire
		"item": item_name,        # item display_name — the name-resolution key every peer maps to an ItemType
		"slot": slot,             # the hotbar slot index it occupies
	})


## Host-only F5 round-reset hook (v0.18.0), called by Main._reset_round beside CombatReferee.reset_round():
## a fresh round starts every bag empty (fresh round, fresh bags). Belt-and-suspenders with the child-exit
## erase (the mass free() of players in _reset_round fires that per player), but clearing wholesale here is
## the plain, order-independent guarantee. Idempotent; safe to call any time. v0.18.0 chunk C: bump the round
## generation FIRST so a use in flight (its SceneTreeTimer still pending) heals nothing into the fresh round —
## the captured generation in its _resolve_use bind no longer matches (a same-peer respawn defeats is_alive, so
## the generation is the identity that catches it). Same idiom as CombatReferee.reset_round's ghost-arrow guard.
func reset_round() -> void:
	_round_gen += 1
	_inventories.clear()


# ── Use flow (v0.18.0 chunk C — drink / consume a hotbar item) ────────────────

## The "use_item" intent validator (host-only; registered on the shared pipe in activate()). A player submits
## use_item {slot}; the host adjudicates from ITS OWN authoritative bag + the shared item catalog (never a client
## value, §2.5), CONSUMES the item on commit, roots the drinker for the committed window, telegraphs the use, and
## resolves the effect (a heal) when that window ends. Reject reasons are DISTINCT per §2.2.8 (reject-to-sender).
## Returns a DEFERRED accept on success — the item_used event IS the outcome (mirror of the shoot validator), so
## no generic "use_item" event is broadcast.
func _validate_use_item(sender_peer_id: int, data: Dictionary) -> Dictionary:
	# Liveness — log-suppressed (mirror the glide/shoot dead reject; the `died` event already told the player,
	# so a second "you're dead" line would be noise). A monster (negative id) never submits a use.
	if not _combat.is_alive(sender_peer_id):
		return { "ok": false, "reason": "dead" }
	# BUSY — the Commitment Rule gate. is_entity_moving covers a glide AND a commit_in_place record (the SAME
	# predicate melee/swap/shoot read), so a drink can never interrupt or overlap a committed action.
	if _move_referee.is_entity_moving(sender_peer_id):
		return { "ok": false, "reason": "busy" }
	# Slot shape + emptiness: never trust the wire. Read the sender's AUTHORITATIVE bag (an untracked player —
	# one who has picked nothing up — has no entry, i.e. an empty bag by construction, so every slot is empty).
	var slot := int(data.get("slot", -1))
	var bag: Array[String] = _inventories.get(sender_peer_id, [] as Array[String])
	if slot < 0 or slot >= bag.size():
		return { "ok": false, "reason": "nothing in that slot" }
	var item_name: String = bag[slot]
	# Resolve the bag entry's ItemType from the shared catalog (server-authoritative — the codebase-wide
	# name-resolution model, item_by_name). An unresolvable name is a stale mirror or a mis-authored bag entry:
	# LOUD, not silent (config drift), and refused with a distinct reason (§2.3.4 never a silent swallow).
	var item: ItemType = GameManager.config.item_by_name(item_name)
	if item == null:
		push_warning("[InventoryReferee] use_item: '%s' not resolvable via item_catalog — unknown item (config drift)" % item_name)
		return { "ok": false, "reason": "unknown item" }
	# Not a consumable (an inert item — a key / quest token that occupies a slot but has no use action).
	if not item.usable:
		return { "ok": false, "reason": "can't use that" }

	# ── Accept ──
	# a. CONSUME-ON-COMMIT (the Commitment Rule bite): remove the item from the slot NOW — no refund for a real
	# use. remove_at() COMPACTS the array, so higher slots RE-PACK left (a use of slot 0 shifts slot 1 → 0, ...).
	# Every peer's HUD repaints from the item_used event below, which carries the used slot, and re-derives the
	# same re-pack from its own mirror — the referee and the mirrors stay in lockstep without sending the whole bag.
	bag.remove_at(slot)
	# b. Stamp the committed window at the user's RESOLVED pace (beats × beat_sec — the shared stamp rule, so a
	# use scales with tempo exactly like an attack's attack_beats or a step's glide).
	var use_sec: float = item.use_beats * PaceReferee.beat_or_explore(_pace, sender_peer_id)
	# c. Root the drinker for the WHOLE window through the universal busy record (from==to — no occupancy move,
	# the Commitment Rule tail; the same record a bump/wind-up/shot uses). A false means the entity went busy
	# between the is_entity_moving check above and now — impossible on the single-threaded host, so purely
	# defensive. The refund here (put the item BACK, reject "busy") is LEGAL precisely because the commit never
	# started: nothing was telegraphed (no item_used posted yet), so no decision has been backed out of.
	if not _move_referee.commit_in_place(sender_peer_id, use_sec):
		bag.insert(slot, item_name)
		return { "ok": false, "reason": "busy" }
	# d. Telegraph the use to EVERY peer (the log line + drink cue + HUD re-pack all ride this ONE event). name
	# is server-resolved off the node (never the wire); as_peer = the user (mirrors an attack's as_peer = attacker).
	var user := _players.get_node_or_null(str(sender_peer_id)) as Entity
	var user_name: String = user.display_name if user != null else "?"
	NetEvents.post_event("item_used", {
		"entity_id": sender_peer_id,
		"name": user_name,
		"item": item_name,
		"slot": slot,
		"duration_sec": use_sec,
	}, sender_peer_id)
	# e. Resolve the EFFECT (the heal) when the committed window ends — a host SceneTreeTimer (survives despawn by
	# construction, like CombatReferee's windup/arrow timers). Bind BY VALUE, captured PRIMITIVES only (the
	# v0.17.1 arrow idiom): the round generation (an F5 mid-drink resolves NOTHING into the fresh round), the user
	# id, the heal amount, and the item name (the heal event's source field). No node ref is captured, so a user
	# that despawns mid-drink can't crash the resolve.
	get_tree().create_timer(use_sec).timeout.connect(
			_resolve_use.bind(_round_gen, sender_peer_id, item.heal_amount, item_name))
	return { "ok": true, "deferred": true }


## Resolve a completed use at the end of its committed window (host-only, from the use timer). Bailing here is
## silent BY DESIGN — the two bail cases are both "the potion was spent for nothing", a Commitment-Rule outcome:
## the drink played to completion, but its effect no longer has a valid target.
func _resolve_use(round_gen: int, user_id: int, heal_amount: int, item_name: String) -> void:
	# Round-generation guard FIRST (v0.18.0 chunk C): a use in flight when F5 reset the round heals NOTHING into
	# the fresh round. is_alive alone can't catch a same-peer respawn (it reuses the id and is alive again), so
	# the captured generation — bumped by reset_round — is the identity that no longer matches.
	if round_gen != _round_gen:
		return
	# Killed mid-drink = the potion is WASTED (the Commitment Rule: the drink was committed and played out, but
	# the drinker died before the heal landed). Deliberately SILENT beyond the death itself — no refund, no heal,
	# no extra line; the `died` event already told the story. Mirrors _loose_arrow's mid-draw is-alive guard.
	if not _combat.is_alive(user_id):
		return
	# Apply the heal through the combat referee's OWN pipe (its `heal` event carries hp_after so every peer
	# renders the bar + popup — never a client compute). god mode does NOT block a heal (see apply_heal): god
	# blocks damage, not recovery.
	_combat.apply_heal(user_id, heal_amount, item_name)


# ── Private methods ───────────────────────────────────────────────────────────

## Drop a player's bag as its node leaves the Players container (death / disconnect / F5 reset — all
## indistinguishable here, and all mean the same thing: the carried inventory is gone with the player,
## permadeath). Idempotent with reset_round()'s wholesale clear. Non-Player exits are impossible on this
## container, but the Entity guard keeps it defensive.
func _on_player_exiting(node: Node) -> void:
	if node is Entity:
		_inventories.erase((node as Entity).entity_id)
