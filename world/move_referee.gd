extends Node

## The HOST-ONLY movement brain (DESIGN §2.5.3). It owns the authoritative tile bookkeeping
## and is the "glide_to" validator registered with NetEvents: clients submit a DIRECTION intent,
## this referee decides from ITS own state (never the wire, never a node's rendered position)
## whether the step is legal, stamps the duration server-side, and mutates occupancy. Every
## client just plays back the broadcast event.
##
## Component pattern: Main hands it the Players container via activate() and it never reaches up
## — it only reads the container it was given, GameManager.config, and the mover's own resource.
## It runs on the host alone; clients instantiate the node (it's in main.tscn on every peer) but
## activate() is called only inside main.gd's is_server() branch, so a client's referee is inert.
##
## Two designer toggles change its behaviour, both read live from GameConfig so Jeff can flip
## them in playtest without code (DESIGN §2.2.7 / Part 4 Q4):
##  - origin_frees_at_glide_start: true = the departed tile frees the instant the glide STARTS
##    (conga-line); false = the origin stays held until the glide finishes.
##  - bodies_block_corners: a diagonal squeeze is refused for WALLS only when BOTH flanks are walls
##    (a single wall corner may be rounded freely); this dial adds bodies — when true, EITHER
##    occupied flank also blocks the diagonal.
##
## Pipelined next step (§2.2.5 amendment, v0.3.4): under origin_frees_at_glide_start, the referee
## holds at most ONE accepted-but-unbroadcast step per mover — adjudicated at accept, broadcast
## only when the mover's current glide completes. See `_pending` for the full invariant.

# Sentinel returned by _tile_of_peer when a peer has no occupancy. (0,0) is a wall in every room
# (full border), so it can never be a real resting tile — an unambiguous "not found".
const _NO_TILE := Vector2i(0, 0)

## Emitted host-side the instant an in-place BUSY record is released EARLY (finish_busy_early — a
## whiffed swing owes no recovery beats, v0.26.0). Past-tense, fire-and-forget: this referee never
## reaches sideways to a brain, so Main wires it (the same rule PaceReferee.tactical_entered follows)
## to wake the affected monster's AI at the moment its window actually ended. Without it a monster
## paces itself on the FULL quoted windup+recovery and idles out beats the referee just refunded —
## the players' own input revalidates naturally, so this is a monster-side seam only.
signal busy_released(entity_id: int)

## Fallback per-step glide time in BEATS used only when a mover has no GlideSpeed resource
## assigned — a misconfiguration guard, warned once. The real value comes from the mover's tier.
## Converted to seconds at the mover's resolved pace (× beat) at stamp time like every authored beat value.
@export var fallback_glide_beats: float = 1.0

# The Players container, handed in by Main via activate(). We read child Player nodes from it
# (membership, the mover's GlideSpeed) but never reach up to Main — component pattern.
var _players: Node2D = null
# The Monsters container, handed in by Main via set_monsters() on the HOST only (a client's
# referee is inert and never sets it). Monsters are seeded/cleaned via the same enter/exit hooks
# as players and resolved through _node_of_id. Null on clients and until set_monsters runs.
var _monsters: Node2D = null
# The CombatReferee, handed in by Main via set_combat() on the HOST only (chunk 2). The two referees
# are peers wired by Main (component pattern) and call each other ONLY through these references: this
# referee asks combat to resolve bump/AoO damage and to test liveness; combat asks this one to erase
# a dead entity's occupancy and to read a wind-up's target tile. Untyped (combat's script has no
# class_name) so its calls resolve dynamically — locals off it are typed explicitly. Null on clients.
var _combat = null
# The PaceReferee, handed in by Main via set_pace() on the HOST only (Tactical Zones v1, §2.8.7). Every
# step/rest window this referee stamps reads the mover's resolved beat through it (beat_sec_for), so an
# entity in the fight stamps tactical and one out of it stamps explore — the ONE pace decision, shared
# by all stamp sites. Also armed for a player's bump: _begin_bump reports the hostile action to it
# BEFORE stamping the bump's own window (no fast first swing). Held untyped (its instance calls resolve
# dynamically); the null-resolver → explore fallback lives in PaceReferee.beat_or_explore. Null on clients.
var _pace = null
# The InventoryReferee, handed in by Main via set_inventory() on the HOST only (v0.18.0 chunk B). At a glide's
# finalized arrival (_finish_glide) this referee asks it to pick up any ground item on the arrival tile — a
# walk-over pickup. Untyped (its script has no class_name, like the other referees) so its call resolves
# dynamically. Null on clients (a client's referee is inert and never completes an authoritative glide) and
# null until set_inventory runs; every call site guards on non-null so the pickup seam is simply absent then.
var _inventory = null

# Authoritative occupancy: tile (Vector2i) -> ENTITY ID. THE adjudication truth; a node's `tile`
# is only presentation. An entity id is a peer id (> 0) for a player or a host-assigned negative
# int for a monster (plan decision 5) — one occupancy space, no overlap. Seeded from each entity's
# spawn tile on child_entered_tree (players and monsters alike).
var _occupied: Dictionary = {}
# In-flight glides: entity_id -> {from: Vector2i, to: Vector2i, token: int}. Presence here IS the
# "already moving" state (the Commitment Rule backstop). The token disambiguates a stale
# completion timer from a superseded/reconnected glide.
var _gliding: Dictionary = {}
# Destination reservations: tile (Vector2i) -> peer_id. ONLY populated in the
# origin_frees_at_glide_start=false branch, where the origin is held until arrival, so the
# destination must be reserved separately for the duration of the glide. Empty in the true branch.
var _reserved: Dictionary = {}
# Pending pipelined step: entity_id -> {from, to, slide_sec, busy_sec}. At most ONE per mover — the
# next step, adjudicated AT ACCEPT (origin = the current glide's destination) but its broadcast HELD
# until that glide's completion boundary (_finish_glide promotes it). Players use it to hide client
# RTT; MONSTERS (negative ids) use it too as of v0.9.3 (chase parity) — the host-local brain submits
# its next step at the SLIDE boundary so the promotion lands at the action-window boundary with zero
# gap, the identical held-key machinery (see monster_brain._try_pipeline_next_step). The gate no
# longer excludes negative ids; only the conga toggle + a free slot admit a step, for any mover.
#
# Adjudicate-at-accept is NOT a prediction under origin_frees_at_glide_start=true: occupancy
# mutates ONLY at sequential accepts (the pending slot swaps _occupied immediately, one step
# deeper), while the completion timers touch only _gliding/broadcast — so every later accept
# reads authoritative referee truth, never a guessed future. M3 CAUTION: forced movement that
# bypasses the intent pipe (knockback, teleport, etc.) breaks this — any such mechanic MUST
# clear or re-adjudicate a mover's pending slot, or it will broadcast a step from a tile the
# mover no longer occupies. The false branch (origin_frees_at_glide_start off) never accepts
# into this slot: the pipeline is simply off and the stop-and-go RTT gap returns until that
# branch's mechanics are designed. Disconnect is the SOLE cancel path (_on_player_exiting).
var _pending: Dictionary = {}

# Authoritative 8-way FACING: entity_id -> Vector2i unit/sign direction the entity currently faces.
# Server-side truth (v0.11.0, DESIGN §2.3 backstab prerequisite) — presentation's sprite flip is
# still derived per-peer and unchanged; this is the facing a passive (backstab) reads to decide a
# behind-arc hit. MUTATION RULES (explicit, so a passive author can rely on them): facing changes
# ONLY on an ACCEPTED verdict — an accepted glide (the glide dir), an executed bump (sign-vector
# toward the struck tile), and a monster's wind-up ENTRY (set by CombatReferee via set_facing, toward
# its target). A REJECTED intent — including 1a's silent `occupied_hostile` reject — NEVER touches
# facing, so no player can face-fish by spam-bumping. Spawn facing is ABSENT (facing_of → ZERO) BY
# DESIGN: a never-moved entity has no back to stab; its first accepted action sets a real facing.
# Cleared wholesale on death (clear_entity) and on container exit, like every other per-entity record.
var _facing: Dictionary = {}
# ARRIVING window (v0.19.2): entity_id -> the tile it is currently sliding INTO. Under conga a glider
# claims its destination in _occupied at glide START, but the sprite tweens in over slide_sec — so an
# entity is "logically there" a fraction of a beat before it is "visually there." This tracks that gap:
# set when a glide's VISIBLE slide begins (direct accept + pipelined promotion), CLEARED at slide_sec (a
# token-guarded timer, so a superseded glide's stale timer can't clear a newer arrival) — i.e. at VISUAL
# arrival, NOT at the later action-window end. The bump validator refuses a strike against a still-arriving
# hostile so you can't hit a goblin before it's in the square (Jeff's report). Cleared on death/exit too.
var _arriving: Dictionary = {}
# STAMINA (v0.24.0 experiment, renamed v0.24.1 — DESIGN §2.2.10): entity_id -> { "points": int,
# "max": int }. Host-authoritative battle budget — a tactical glide spends 1; at 0 the step still
# commits as an exhausted CRAWL (exhausted_step_beats), never a hard stop. Seeded full on entity
# enter, reset to a LAZILY re-resolved max on each tactical entry (Main wires
# PaceReferee.tactical_entered here), erased with the other per-entity records on death/exit.
var _stamina: Dictionary = {}
# Rest-to-recover regen generation counter: entity_id -> int. Every activity, reset, teardown and
# /stamina toggle bumps it; a regen timer that fires holding a stale generation no-ops (stun-system
# precedent). This is the sole stale-timer guard — one regen chain per entity by construction.
var _stamina_generation: Dictionary = {}
# Refill lockout (v0.24.3, the pace-flicker fix): entity_id -> Time.get_ticks_msec() of the last
# tactical EXIT. A tactical re-entry within stamina_refill_lockout_beats of this keeps its current
# pool — only a genuinely fresh fight refills. Written by note_tactical_exit (wired to
# PaceReferee.tactical_exited); erased with the other per-entity records.
var _last_tactical_exit_msec: Dictionary = {}
# Passive-regen chain latch (v0.24.9): entity_id -> true while a passive chain is armed. NOT
# generation-guarded (activity must never cancel passive regen — that's its point); membership +
# the enable knobs are its guards. Erased at each fire and re-set by the re-arm.
var _passive_regen_running: Dictionary = {}
# FORCED-MOVEMENT interrupt GENERATION (v0.26.0 instants experiment): entity_id -> int, bumped by
# `teleport_entity` and by NOTHING ELSE. It is the identity a deferred resolve captures at COMMIT and
# re-checks at FIRE: a bump means "this actor was picked up and moved somewhere else mid-action", so the
# resolve fizzles silently (the same shape as the `is_stunned` resolve gates). Distinct from the per-glide
# `token` — that answers "is this the same glide?"; this answers "is the actor still where it committed
# from?", which a token cannot, because a teleport ERASES the record the token belongs to.
#
# INERT WHEN THE EXPERIMENT IS OFF, by construction: teleport_entity has exactly one caller
# (CombatReferee._use_shadow_step) and that caller is gated on GameConfig.instant_abilities_enabled, so
# with the toggle off this dict never changes and every downstream guard compares 0 == 0 forever.
# Erased on death/exit like every other per-entity record (GLM milestone review, v0.26.0): a respawn
# reuses a PEER id, and a resolve captured in the PREVIOUS life (gen >= 1 after any blink) must fizzle
# against the new life — the erase resets the new life to 0, which an old nonzero capture can never
# match. (A never-blinked life captures 0 and would match a reset 0 — but that pairing is exactly the
# pre-existing exposure of the unguarded resolves, unchanged by this counter in either direction.)
var _interrupt_gen: Dictionary = {}

# Monotonic per-glide id, stamped into each _gliding record so a completion timer can tell "my"
# glide from a later one for the same peer (disconnect+rejoin, or any superseding glide).
var _next_token: int = 0
# One-shot latch so a mover with no GlideSpeed resource warns exactly once, not every step.
var _warned_null_speed: bool = false


## Host-only entry point, called by Main inside its is_server() branch BEFORE the host spawns
## its own player — so child_entered_tree seeds occupancy for every player including the host's.
## Registers the validator and wires the container's membership signals.
func activate(players: Node2D) -> void:
	_players = players
	NetEvents.register_handler("glide_to", _validate_glide)
	# Seed occupancy as each Player enters (spawn sets tile + entity_id before it enters the tree,
	# so both are readable here) and forget a peer wholesale as its node leaves (disconnect/teardown).
	# Players and monsters share the one Entity enter/exit contract — one id space.
	_players.child_entered_tree.connect(_on_entity_entered)
	_players.child_exiting_tree.connect(_on_entity_exiting)


## Host-only, called by Main right after activate() and BEFORE the host spawns any monster — so the
## monster enter hook seeds occupancy for every monster. Wires the Monsters container's membership
## signals the same way activate() wires the Players container. Never called on clients (their
## referee is inert), so _monsters stays null there.
func set_monsters(monsters: Node2D) -> void:
	_monsters = monsters
	_monsters.child_entered_tree.connect(_on_entity_entered)
	_monsters.child_exiting_tree.connect(_on_entity_exiting)


## Host-only, called by Main right after the CombatReferee is activated and BEFORE any spawn — so
## the bump/AoO paths and the wind-up commit have the combat reference the moment the first intent
## is adjudicated. Null on clients (their referee is inert and never adjudicates).
func set_combat(combat: Node) -> void:
	_combat = combat


## Host-only, called by Main right after the PaceReferee is activated and BEFORE any spawn — so the
## first step/rest window this referee stamps already routes through the resolver. Null on clients
## (their referee is inert and never stamps).
func set_pace(pace: Node) -> void:
	_pace = pace


## Host-only, called by Main right after the InventoryReferee is activated and BEFORE any spawn (v0.18.0
## chunk B) — so the pickup seam in _finish_glide has the reference the first time a glide completes onto an
## item. Null on clients (their referee is inert and never completes an authoritative glide).
func set_inventory(inventory: Node) -> void:
	_inventory = inventory


## The one id -> node resolver (plan decision 5). Positive ids are players, negatives are monsters;
## each resolves against its own container, or null if absent/off-host. Used everywhere the referee
## needs the node behind an occupancy value. Node-typed on purpose — callers that need a concrete
## field (glide_speed, player_name) read it dynamically, since a player and a monster share the
## duck-typed surface the referee touches but not a common class.
func _node_of_id(entity_id: int) -> Node:
	if entity_id > 0:
		return _players.get_node_or_null(str(entity_id))
	if _monsters != null:
		return _monsters.get_node_or_null(str(entity_id))
	return null


## True if no body rests on, is gliding onto, or has reserved this tile — the single occupancy
## predicate, used by the validator and by Main's spawn-slot skip. Works for both origin-timing
## branches: in the true branch a glider sits at its destination in _occupied (origin already
## freed) and _reserved is empty; in the false branch the origin stays in _occupied and the
## destination lives in _reserved, so the union covers both resting and in-flight bodies.
func is_tile_free(tile: Vector2i) -> bool:
	return not _occupied.has(tile) and not _reserved.has(tile)


## Host-only entry for a MonsterBrain's decided step. Runs the SAME validator a player intent does
## (host-local — no RPC; monsters have no RTT) and, on a clean accept, broadcasts the glide_to on
## the entity's behalf so every peer plays it back. Returns true on accept, false on any refusal so
## the brain can back off and re-think. A brain-submitted intent bypasses NetEvents._handle_intent
## (which is what broadcasts a player's accepted verdict), so the referee must post the event here.
##
## As of v0.9.3 monsters DO pipeline (chase parity): a mid-glide submit returns a DEFERRED accept —
## the referee already committed the step (occupancy swapped one deeper) and HELD the broadcast for
## _finish_glide's promotion at the action-window boundary. That is a success with nothing to post
## here; report accepted so the brain skips its backstop and lets the promoted step's glide_finished
## drive the next think. (Monsters never bump, so a deferred monster verdict is always a pipelined
## accept — never the bump path's deferred shape, which is players-only.)
func submit_monster_intent(entity_id: int, dir: Vector2i) -> bool:
	var verdict := _validate_glide(entity_id, { "dir": dir })
	if not verdict.get("ok", false):
		return false
	if verdict.get("deferred", false):
		return true
	var data: Dictionary = verdict["data"]
	NetEvents.post_event("glide_to", data, entity_id)
	return true


## Brain accessor: is this entity mid-glide right now? The referee's _gliding is the authoritative
## "committed and moving" state (the same predicate that yields "already moving").
func is_entity_moving(entity_id: int) -> bool:
	return _gliding.has(entity_id)


## Brain accessor: the tile this entity currently occupies in authoritative truth, or a wall
## sentinel (0,0) if it holds none (untracked / despawned). (0,0) is a wall in every room, so no
## live body ever rests there — callers treat a wall result as "gone".
func tile_of_entity(entity_id: int) -> Vector2i:
	return _tile_of_peer(entity_id)


## Host-only facing setter (v0.11.0). The ONLY external writer is CombatReferee, at a monster's
## wind-up ENTRY (toward its target) — a mid-windup monster faces its victim and can't be "backstabbed
## sideways" during the telegraph. The referee's own glide/bump accepts write _facing directly (below).
## `dir` is a sign-vector; ZERO would erase the facing, so callers pass a real direction (wind-up always has one).
func set_facing(entity_id: int, dir: Vector2i) -> void:
	if dir == Vector2i.ZERO:
		return
	_facing[entity_id] = dir


## The authoritative 8-way facing for an entity, or Vector2i.ZERO if unknown (never moved / untracked /
## despawned). ZERO is the deliberate "faces nowhere" state — a backstab check treats a ZERO defender
## facing as un-backstabbable (a never-moved entity has no back). Read host-side by the passive dispatch.
func facing_of(entity_id: int) -> Vector2i:
	return _facing.get(entity_id, Vector2i.ZERO)


## Brain accessor: every player's authoritative tile (occupancy values > 0). Under conga timing a
## gliding player's entry sits at its DESTINATION, so a chaser paths toward where the player is
## heading — the honest read of the Commitment Rule (you can't dodge to a tile you've committed off).
func player_tiles() -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	for tile in _occupied:
		if _occupied[tile] > 0:
			tiles.append(tile)
	return tiles


## Brain accessor (v0.10.4): every OTHER monster's authoritative tile — occupancy values < 0, excluding
## exclude_id (the querying monster's own tile must never be treated as an obstacle). Mirrors
## player_tiles(); a monster brain hands the result to WorldGrid.find_path as `avoid` so it routes AROUND
## its waiting siblings instead of submitting a blocked straight step every boundary. Under conga a
## gliding sibling's entry sits at its DESTINATION, so the chaser routes around where the sibling is
## heading — the honest Commitment-Rule read (a committed tile is as good as taken).
func monster_tiles(exclude_id: int) -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	for tile in _occupied:
		var id: int = _occupied[tile]
		if id < 0 and id != exclude_id:
			tiles.append(tile)
	return tiles


## The authoritative entity id resting on / claiming a tile, or 0 (never a real id) if free. Used by
## CombatReferee to resolve a wind-up's target-tile occupant. Mirrors is_tile_free's union: a body
## sits in _occupied (both timing branches), or _reserved while gliding onto the tile (hold-origin).
func entity_at(tile: Vector2i) -> int:
	if _occupied.has(tile):
		return _occupied[tile]
	if _reserved.has(tile):
		return _reserved[tile]
	return 0


## Host-only: record a from==to BUSY commit for an entity for `duration_sec`, with NO occupancy
## mutation of any kind (the entity never leaves its tile — decision 2). The single shared busy-record
## path for BOTH a player's bump swing and a monster's wind-up, so the "already moving" machinery has
## exactly one authoring site. Presence in _gliding IS the busy state (is_entity_moving reads it);
## the existing _finish_glide runs at the timer verbatim — it promotes a pending slot (a differently-
## directed intent committed mid-swing → swing-then-move) or, with none, erases the record. Returns
## false if the entity is already busy or untracked (the caller declines).
func commit_in_place(entity_id: int, duration_sec: float) -> bool:
	if _gliding.has(entity_id):
		return false
	var from := _tile_of_peer(entity_id)
	if from == _NO_TILE:
		return false
	var token := _next_token
	_next_token += 1
	_gliding[entity_id] = { "from": from, "to": from, "token": token }
	get_tree().create_timer(duration_sec).timeout.connect(_finish_glide.bind(entity_id, token))
	# Every committed busy window — bump swing, wind-up, cast, drink — is ACTIVITY: it cancels any
	# in-progress rest-to-recover regen and restarts the idle clock (v0.24.0, Jon: "moving or doing
	# an action will stop the regeneration"). Attacks still never SPEND points — this only gates rest.
	note_activity(entity_id)
	return true


## Host-only (v0.26.0 recovery-on-contact): release an in-place BUSY record RIGHT NOW, ahead of its
## own completion timer. The only callers are CombatReferee's WHIFF resolves — a swing that touched
## nothing owes no recovery beats, so the remainder of the window is dropped the moment the miss is
## adjudicated. Returns false when there is nothing releasable.
##
## Commitment Rule standing (§2.1; Jeff 2026-07-26, Jon approved): this REDEFINES the committed
## duration, it does not cancel a commitment. A swing commits to its WINDUP unconditionally; only the
## RECOVERY portion is now conditional on contact. No input path reaches here — it is called solely
## from the server's own resolve functions, so no player can shorten their own window by pressing
## anything, and nobody backs out of a decision (the swing already happened and missed).
##
## Guard: the record must exist AND be a from==to in-place commit. A real glide (from != to) is NEVER
## released early — finishing one ahead of time would jump the mover's arrival forward, which IS a
## redirect. Bump swings, wind-ups, casts and drinks are all from==to, so the whiff sites are covered.
##
## Body: run _finish_glide synchronously with the record's own token — its NORMAL completion, including
## PROMOTING a pipelined pending step (intended: a whiff means the held next move starts sooner). The
## original create_timer callback still fires later and no-ops on the token / missing-record stale-guard,
## so nothing ever double-finishes.
func finish_busy_early(entity_id: int) -> bool:
	var rec = _gliding.get(entity_id)
	if rec == null:
		return false
	if rec["from"] != rec["to"]:
		return false
	_finish_glide(entity_id, int(rec["token"]))
	# The window is genuinely over NOW — tell whoever paced themselves on the quoted duration (a
	# monster's brain; see the signal's doc). Emitted AFTER _finish_glide so any promoted pipelined
	# step is already broadcast and the listener reads a settled record (is_entity_moving is true in
	# that case, which is exactly the "don't re-think, you're moving" answer the brain wants).
	busy_released.emit(entity_id)
	return true


## Host-only (v0.26.0 instants experiment, DESIGN §2.11.1): the FORCED-MOVEMENT API — put `entity_id` on
## tile `to` RIGHT NOW, with no glide, no duration and no intent. The one caller today is
## CombatReferee._use_shadow_step (the rogue blink), which is itself gated on
## `GameConfig.instant_abilities_enabled`; a future knockback / pull / trap would reuse this same door.
## Returns false — mutating NOTHING — when the move is illegal, so a caller can reject cleanly.
##
## Commitment Rule standing (§2.1; SANCTIONED EXPERIMENT, Jon 2026-07-25): this is the ONE place a player
## may interrupt their OWN committed action, and it exists behind the experiment toggle precisely because
## that is a suspension of §2.1.3, not a reinterpretation of it. The §2.2.5 forced-movement CAUTION note
## (see `_pending`) named this exact hazard years of comments ago: any mechanic that bypasses the intent
## pipe MUST clear or re-adjudicate the mover's pending slot. It does, below.
##
## AUTHORITY RE-CHECK: the caller already validated, but this is the mutation site, so it re-derives
## membership + origin + walkable + free from ITS OWN state (never a passed-in belief). A caller can
## therefore never talk this function into overlapping two bodies.
##
## What it does, and deliberately does NOT do:
##  - BUMPS `_interrupt_gen` first, so any resolve already in flight for this entity fizzles at its fire.
##  - ERASES the glide record, the pipelined pending slot and the arriving mark. The stale completion /
##    arriving timers then no-op on their own missing-record guards, so nothing double-finishes and no
##    ghost `glide_to` is ever broadcast from a slot whose origin the mover has left (GLM resolution).
##  - erases occupancy AND reservations BY VALUE, which frees the abandoned tile in BOTH origin-timing
##    branches and releases the pending slot's destination reservation — no leaked claim either way.
##  - FACING is left exactly as it was: you blink backwards while still facing your enemy (that is the
##    tactical point of the ability, and a silent turn would also break a backstab adjudication).
##  - NO attack of opportunity: §2.2.6 grants a free strike for "starting a glide out of a tile", and a
##    blink is not a glide — it is the ability's whole promise that you get out clean.
##  - NO walk-over pickup: `_finish_glide`'s pickup seam is a MOVEMENT settle; a teleport never lands as
##    an arrival, so vanishing onto a potion does not loot it.
##  - does NOT emit `busy_released`: that signal means "an in-place window ended early" and wakes a
##    monster's brain. A blink is not a window ending, and the blinker's tile change must never read to a
##    watching brain as its own whiff-wake.
##  - counts as ACTIVITY (note_activity) — it cancels rest-regen and restarts the idle clock like any
##    other deliberate act — but costs NO stamina: the spend site is the glide validator, untouched here.
func teleport_entity(entity_id: int, to: Vector2i) -> bool:
	if _node_of_id(entity_id) == null:
		return false
	var from := _tile_of_peer(entity_id)
	if from == _NO_TILE:
		return false
	if not WorldGrid.is_walkable(to):
		return false
	# `from` is this entity's own single occupancy entry, and `to != from` for every real blink direction,
	# so this union check can never trip over the mover itself.
	if not is_tile_free(to):
		return false
	_interrupt_gen[entity_id] = int(_interrupt_gen.get(entity_id, 0)) + 1
	_gliding.erase(entity_id)
	_pending.erase(entity_id)
	_arriving.erase(entity_id)
	_erase_by_value(_occupied, entity_id)
	_erase_by_value(_reserved, entity_id)
	_occupied[to] = entity_id
	note_activity(entity_id)
	return true


## The entity's current forced-movement interrupt generation (v0.26.0), 0 for an id never teleported.
## Captured by every deferred resolve at COMMIT and re-checked at FIRE — see `_interrupt_gen`.
func interrupt_gen_of(entity_id: int) -> int:
	return int(_interrupt_gen.get(entity_id, 0))


## Host-only (v0.24.0 stamina experiment): reset an entity's stamina pool to its lazily-resolved
## max. Wired by Main to PaceReferee.tactical_entered (battle entry = fresh pool) and used as the
## seed on entity enter. Bumping the generation kills any regen chain from a previous engagement,
## closing the stale-timer race (an orphaned timer fires, sees a newer generation, no-ops).
func reset_stamina(entity_id: int, force: bool = false) -> void:
	# Refill LOCKOUT (v0.24.3): a re-entry within stamina_refill_lockout_beats (explore-beat clock)
	# of the last tactical exit is pace flicker, not a new battle — keep the earned pool exactly as
	# it stands (regen chains, if resting, keep ticking; activity gates still apply). `force` (the
	# /stamina enable reseed) bypasses the gate — a toggle flip is an explicit clean slate.
	if not force and _last_tactical_exit_msec.has(entity_id):
		var lockout_ms := int(_refill_lockout_beats_of(entity_id)
				* GameManager.explore_beat_sec * 1000.0)
		if Time.get_ticks_msec() - int(_last_tactical_exit_msec[entity_id]) < lockout_ms:
			return
	var was_exhausted := _is_exhausted(entity_id)
	var max_points := _stamina_max_of(entity_id)
	_stamina[entity_id] = { "points": max_points, "max": max_points }
	_stamina_generation[entity_id] = int(_stamina_generation.get(entity_id, 0)) + 1
	_post_stamina(entity_id)
	if was_exhausted:
		_post_exhausted(entity_id, false)


## Host-only (v0.24.3): timestamp a tactical EXIT for the refill lockout. Wired by Main to
## PaceReferee.tactical_exited.
func note_tactical_exit(entity_id: int) -> void:
	_last_tactical_exit_msec[entity_id] = Time.get_ticks_msec()


## Host-only (v0.24.0): reseed EVERY tracked entity to max. Called by the /stamina toggle on ENABLE
## only (clean slate — nobody resumes a fight with an unearned partial pool). Disable mutates nothing.
func reseed_all_stamina() -> void:
	for entity_id in _stamina.keys():
		reset_stamina(entity_id, true)


## Host-only read (v0.25.0, the /snapshot payload): an entity's stamina pool as {points, max},
## zeros for an untracked id.
func stamina_of(entity_id: int) -> Dictionary:
	var pool: Dictionary = _stamina.get(entity_id, {})
	return { "points": int(pool.get("points", 0)), "max": int(pool.get("max", 0)) }


## Host-only (v0.25.0, /mi stamina): set an entity's stamina outright (clamped 0..max), posting the
## usual pool + exhaustion-edge events. Counts as ACTIVITY afterward (note_activity) so a pool set
## below max arms the normal rest-regen chain — an admin-drained entity must not be regen-orphaned.
func admin_set_stamina(entity_id: int, points: int) -> bool:
	if not _stamina.has(entity_id):
		return false
	var pool: Dictionary = _stamina[entity_id]
	var was_exhausted := int(pool["points"]) <= 0
	pool["points"] = clampi(points, 0, int(pool["max"]))
	_post_stamina(entity_id)
	var now_exhausted := int(pool["points"]) <= 0
	if now_exhausted != was_exhausted:
		_post_exhausted(entity_id, now_exhausted)
	note_activity(entity_id)
	return true


## Host-only (v0.24.3): clear every showing sweat-drop — the /stamina DISABLE path calls this so a
## crawl that just stopped existing doesn't keep its exhausted cue (a presentation event, not a pool
## mutation; the pools themselves stay untouched on disable, per the toggle contract).
func clear_exhaustion_cues() -> void:
	for entity_id in _stamina.keys():
		if _is_exhausted(entity_id):
			_post_exhausted(entity_id, false)


## Host-only (v0.24.0): register activity — an accepted glide or any committed busy window. Bumps
## the generation (cancelling any pending idle wait or in-progress regen chain) and, if the pool is
## below max, arms a fresh rest-to-recover idle timer: regen_idle_beats of unbroken quiet at the
## entity's resolved pace, then +1 point per regen_interval_beats until max or the next activity.
func note_activity(entity_id: int) -> void:
	if not GameManager.config.stamina_enabled:
		return
	var generation := int(_stamina_generation.get(entity_id, 0)) + 1
	_stamina_generation[entity_id] = generation
	var pool: Dictionary = _stamina.get(entity_id, {})
	if pool.is_empty() or int(pool["points"]) >= int(pool["max"]):
		return
	var idle_sec: float = _regen_idle_beats_of(entity_id) * PaceReferee.beat_or_explore(_pace, entity_id)
	get_tree().create_timer(idle_sec).timeout.connect(_stamina_regen_tick.bind(entity_id, generation))
	# RECOVERY EVENT (v0.26.0, §2.3.4): an entity resting at ZERO is the read that matters now the pool
	# is binary (max 1) — "am I ready yet" replaced "how many steps left", so the wait itself gets a cue.
	# STAMP-AND-BAKE: the host posts the EXACT seconds it just armed the timer with, so every peer's bar
	# fills over the same span the host will actually take to grant the point (no client-side beat math,
	# no re-derivation if a dial or the tempo moves mid-wait — §2.8.2). Posted for BOTH kinds (unlike the
	# player-only `stamina` pool event): a resting monster reads as recovering too.
	# EVERY re-arm re-posts, deliberately — activity restarted the clock, so the client bar restarts with
	# it. note_activity fires ONLY on accepted glides and this entity's OWN committed windows, never on
	# incoming damage, so being hit can never restart someone's recovery bar (GLM-verified; keep it so).
	if int(pool["points"]) <= 0:
		NetEvents.post_event("stamina_recovery", {
			"entity_id": entity_id, "duration_sec": idle_sec,
		})


## Host-only: erase ALL of a dead entity's occupancy bookkeeping in ONE synchronous pass (decision 7)
## — occupancy by value, any in-flight glide, any pending slot, any reservation — so the instant a
## kill resolves no stale record blocks another mover. Called by CombatReferee from inside
## apply_damage, BEFORE it despawns the node; the container exit hooks fire later and are idempotent
## (this reuses the very same erases, so re-erasing already-gone keys is a no-op).
func clear_entity(entity_id: int) -> void:
	_gliding.erase(entity_id)
	_pending.erase(entity_id)
	_facing.erase(entity_id)
	_arriving.erase(entity_id)
	_erase_by_value(_occupied, entity_id)
	_erase_by_value(_reserved, entity_id)
	# Stamina experiment (v0.24.0): drop the pool and bump the generation so any in-flight regen
	# timer for this entity no-ops (ids are never recycled in-session, but a respawn reuses a PEER
	# id — the bump makes the old chain stale either way). v0.24.3: the exit stamp goes too, so a
	# respawned peer's first battle entry is never lockout-blocked by its previous life.
	_stamina.erase(entity_id)
	_stamina_generation[entity_id] = int(_stamina_generation.get(entity_id, 0)) + 1
	_last_tactical_exit_msec.erase(entity_id)
	_passive_regen_running.erase(entity_id)
	# Instants experiment (v0.26.0): a respawned peer id starts a fresh interrupt life — any resolve
	# captured against the previous life's gen (>= 1 after a blink) fizzles at its fire.
	_interrupt_gen.erase(entity_id)


# ── Private methods ───────────────────────────────────────────────────────────

## The "glide_to" validator (host-only; NetEvents calls it synchronously on the main thread, so
## each verdict mutates state before the next intent is examined — cross-diagonal swaps resolve
## deterministically in arrival order). Validation order is fixed: membership → dir shape →
## already-moving → origin (from referee truth) → dest walkable → corner rule → dest free →
## stamp duration → mutate + accept. Returns { ok: false, reason } or { ok: true, data }.
func _validate_glide(sender_peer_id: int, data: Dictionary) -> Dictionary:
	# Membership: only an entity with a live node is adjudicable — a player (positive id) or a
	# monster (negative id), resolved through the one id -> node helper. Untyped on purpose so the
	# duration/AoO reads below duck-type across player and monster. (`sender_peer_id` keeps its name
	# for minimal churn; it is an entity id, positive OR negative, throughout this validator.)
	var mover = _node_of_id(sender_peer_id)
	if mover == null:
		return { "ok": false, "reason": "not in session" }

	# Direction shape: must be a Vector2i with components in {-1,0,1} and non-zero. The wire is
	# never trusted — a malformed intent is refused, not coerced.
	var dir_raw = data.get("dir")
	if typeof(dir_raw) != TYPE_VECTOR2I:
		return { "ok": false, "reason": "bad direction" }
	var dir: Vector2i = dir_raw
	if dir == Vector2i.ZERO or absi(dir.x) > 1 or absi(dir.y) > 1:
		return { "ok": false, "reason": "bad direction" }

	# Liveness gate: a dead entity's in-flight intent (killed by an AoO while its RPC crossed the
	# wire — the node still exists until queue_free lands) must reject cleanly, not adjudicate from
	# erased occupancy or reach the bump path as a dead attacker. "dead" is log-suppressed like
	# "already moving" (the died event already told the player everything).
	if _combat != null and not _combat.is_alive(sender_peer_id):
		return { "ok": false, "reason": "dead" }
	# STUNNED (v0.20.0): can't START a new glide while stunned. Rejected BEFORE the already-moving/pipeline
	# gate below, and it never touches the busy/pending records — so an in-flight glide (and an already-committed
	# pending step) still play out (§2.1). Covers players AND monsters (both ride this validator). Distinct
	# "stunned" reason → the §2.2.8 bonk for a player; a monster's brain also self-skips while stunned.
	if _combat != null and _combat.is_stunned(sender_peer_id):
		return { "ok": false, "reason": "stunned" }

	# The Commitment Rule backstop and the pipeline gate. A mover already gliding may commit ONE
	# next step into the pending slot (§2.2.5 amendment) — but only under the conga toggle, and
	# only if the slot is free. A third intent (one gliding + one held) is the same "already
	# moving" bonk as before. When pipelined, the check chain below runs UNCHANGED: _tile_of_peer
	# already returns the current glide's destination (its single _occupied entry), which IS this
	# step's origin, so walkable/corner/dest-free/duration all adjudicate against the right tile.
	var is_pipelined := false
	if _gliding.has(sender_peer_id):
		# A mover already gliding may commit ONE next step into the pending slot — but only under the
		# conga toggle, and only if the slot is free; a third intent (one gliding + one held) is the
		# same "already moving" bonk as before. Players pipeline to hide client RTT; MONSTERS pipeline
		# too as of v0.9.3 (chase parity) — the host-local brain submits its next step at the SLIDE
		# boundary (mid-settle, still committed) so the promotion lands at the action-window boundary
		# with zero gap, exactly the held-key path. Negative ids are no longer excluded here; the
		# promotion in _finish_glide resolves the mover untyped so it handles players AND monsters.
		if not GameManager.config.origin_frees_at_glide_start or _pending.has(sender_peer_id):
			return { "ok": false, "reason": "already moving" }
		is_pipelined = true

	# Origin is read from referee truth, never the node's position. A non-gliding member always
	# has exactly one _occupied entry (seeded at spawn); its absence is a bug, not a legal state.
	var from := _tile_of_peer(sender_peer_id)
	if from == _NO_TILE:
		push_error("[MoveReferee] no occupancy for member peer %d — refusing glide" % sender_peer_id)
		return { "ok": false, "reason": "not in session" }

	# Destination must be in-bounds and floor. OOB counts as wall in WorldGrid, so this one check
	# covers both — reported as "blocked" (a wall is in the way).
	var to := from + dir
	if not WorldGrid.is_walkable(to):
		return { "ok": false, "reason": "blocked" }

	# Corner rule (diagonals only, DESIGN §2.2.7 — relaxed to the classic roguelike rule, Jon
	# 2026-07-21): a diagonal is refused for WALLS only when BOTH orthogonal flanks are walls. You
	# may round a single wall corner; you may not squeeze between two walls that touch only at a
	# corner. The body branch is UNCHANGED and deliberately stricter: bodies are dodgeable and walls
	# aren't, so when bodies_block_corners is on EITHER occupied flank still blocks the diagonal.
	if dir.x != 0 and dir.y != 0:
		var flank_x := from + Vector2i(dir.x, 0)
		var flank_y := from + Vector2i(0, dir.y)
		if WorldGrid.is_wall(flank_x) and WorldGrid.is_wall(flank_y):
			return { "ok": false, "reason": "corner" }
		if GameManager.config.bodies_block_corners:
			if not is_tile_free(flank_x) or not is_tile_free(flank_y):
				return { "ok": false, "reason": "corner" }

	# Destination must not be held by another body (resting, gliding-onto, or reserved). From IDLE
	# ONLY (decision 1), a dest held by a hostile LIVING entity becomes a BUMP attack instead of a
	# reject: move-into-enemy = attack. A PIPELINED intent into a held tile keeps the plain reject —
	# the held slot never holds an attack, so there is no dead-target-at-boundary problem. `is_pipelined`
	# spans the WHOLE committed ACTION window (glide term + rest — _gliding persists through both,
	# rest 0 by default), not just the visible slide; so a move-into-hostile issued during the SETTLE
	# (the slide has ended visually but the action window has not) is likewise refused rather than
	# promoted to a bump, because the mover is still committed to this step (Commitment Rule — the
	# parked queued-attack-slot follow-up in ROADMAP is the design venue for letting a mid-commit attack be queued).
	if not is_tile_free(to):
		# Resolve the blocker once: a LIVING HOSTILE occupant reads differently from an inert one. From
		# IDLE the bump branch promotes it to an attack; when the bump can't apply (a PIPELINED/mid-glide
		# step, or a monster mover) the reject is still tagged "occupied_hostile" so the sender's client
		# can suppress the bonk cue (1a, v0.10.2) — the player was mid-commitment TRYING to attack, not
		# fumbling into a wall; with input held the next from-idle submit becomes the bump. A non-hostile
		# blocker (another player, the training dummy) keeps plain "occupied". Applied uniformly across
		# player and monster movers — no client listens to a monster's rejects, so the tag is harmless there.
		var occupant_id := entity_at(to)
		var occupant := _node_of_id(occupant_id)
		var blocker_is_hostile: bool = _combat != null and occupant != null \
			and _combat.is_alive(occupant_id) and mover.is_hostile_to(occupant)
		# sender > 0: only PLAYERS bump (M3 monsters attack solely via the telegraphed wind-up; the
		# brain's adjacency branch fires before any step toward a player could be chosen — this is
		# the structural backstop that keeps a monster intent from ever dealing bump damage).
		if not is_pipelined and sender_peer_id > 0 and blocker_is_hostile:
			# Arriving gate (v0.19.2): the hostile claims `to` at glide START (conga) but may still be sliding
			# in — don't let the player strike it before it's VISUALLY in the square (Jeff's report). Refuse
			# "arriving", cue-suppressed in main._on_intent_rejected like occupied_hostile, so held input re-lands
			# the moment the slide settles. Cleared at slide_sec, so the settle period (visually on-tile) is fair game.
			if _arriving.has(occupant_id):
				return { "ok": false, "reason": "arriving" }
			# Player melee WINDUP (v0.19.2, opt-in): a MELEE weapon whose RESOLVED windup > 0 telegraphs like the
			# goblin — route the bump through the shared wind_up path (commits in place, posts the windup event,
			# resolves against `to` after the telegraph, distinct WHIFF if the target flees). windup 0 (every
			# weapon's default) or a ranged weapon (kick) falls straight through to the byte-identical instant bump.
			if _combat != null and _combat.melee_windup_beats_of(mover) > 0.0:
				var wait: float = _combat.wind_up(sender_peer_id, to)
				if wait >= 0.0:
					return { "ok": true, "deferred": true }  # the windup + attack/whiff events ARE the outcome
				return { "ok": false, "reason": "busy" }      # declined (defensive — from-idle isn't busy)
			return _begin_bump(sender_peer_id, mover, occupant_id, occupant, dir)
		if blocker_is_hostile:
			return { "ok": false, "reason": "occupied_hostile" }
		return { "ok": false, "reason": "occupied" }

	# STAMINA (v0.24.0 experiment, v0.24.1 crawl): battle-only budget check + spend, placed HERE by
	# design — every earlier return (bump, wind-up route, occupied, corner, busy…) is structurally
	# exempt (attacking is not moving), and both accept paths below (pipelined + direct) flow through
	# this point, so an accepted tactical glide spends EXACTLY once. Pace read via is_tactical (never
	# a beat comparison — the two dials can be authored equal). At 0 stamina the step is NOT rejected
	# (v0.24.1, Jon: "still able to move, just very slow"): it commits as an exhausted CRAWL — the
	# stamp below swaps the mover's tier for exhausted_step_beats, and the Commitment Rule does the
	# punishing. The only post-spend abort is the AoO death below (pool torn down by clear_entity).
	var exhausted_crawl := false
	if GameManager.config.stamina_enabled and _pace != null and _pace.is_tactical(sender_peer_id):
		var stamina_pool: Dictionary = _stamina.get(sender_peer_id, {})
		if stamina_pool.is_empty():
			# Untracked mid-battle (defensive — enter-seed should have run): seed full rather than
			# hard-deny a mover the experiment never met.
			reset_stamina(sender_peer_id)
			stamina_pool = _stamina[sender_peer_id]
		if int(stamina_pool["points"]) <= 0:
			# HARD-STOP mode (v0.24.6, per-side v0.25.0): 0 stamina refuses the step outright —
			# distinct §2.2.8 reject; each side has its own dial (/winded converges both).
			if _exhausted_blocks_movement_of(sender_peer_id):
				return { "ok": false, "reason": "winded" }
			exhausted_crawl = true
		else:
			stamina_pool["points"] = int(stamina_pool["points"]) - 1
			_post_stamina(sender_peer_id)
			# Crossing INTO exhaustion (v0.24.3): the sweat-drop cue rides its own event, for every
			# entity kind — a crawling MONSTER must read as winded, not glitchy-slow (players get the
			# pips + log line on top). 0-crossings only, so the wire cost is a handful per fight.
			if int(stamina_pool["points"]) == 0:
				_post_exhausted(sender_peer_id, true)
	# EVERY accepted glide — budgeted, exhausted, or explore-pace — is ACTIVITY: it cancels any
	# rest-to-recover regen in progress (Jon: "moving... will stop the regeneration").
	note_activity(sender_peer_id)

	# Stamp THREE windows ONCE here (stamp-and-bake, DESIGN §2.8), so a live tempo change never
	# re-derives this in-flight commit. glide_sec is the GLIDE term (tier beats × beat × diagonal
	# multiplier). busy_sec = glide + rest is the mover's committed ACTION/OCCUPANCY window: it owns
	# the completion timer and gates the pipelined promotion, so the next step promotes at the END of
	# it (rest defaults 0 in v0.8.0, so the action window equals the glide term). slide_sec is the
	# VISIBLE tween that rides the broadcast — slide_fraction of the GLIDE TERM, never of glide+rest;
	# the settle (action − slide) is the on-tile grid tell and exists even at rest 0.
	var glide_sec := _step_duration(mover, dir, sender_peer_id)  # GLIDE term (tier beats × PACE beat × mult)
	# Exhausted CRAWL override (v0.24.1): a 0-stamina tactical step commits at exhausted_step_beats
	# per tile instead of the mover's tier — same stamp-and-bake, same diagonal multiplier, so the
	# busy window and visible slide below scale with it automatically.
	if exhausted_crawl:
		glide_sec = _exhausted_step_beats_of(sender_peer_id) * PaceReferee.beat_or_explore(_pace, sender_peer_id)
		if dir.x != 0 and dir.y != 0:
			glide_sec *= GameManager.config.diagonal_step_multiplier
	var busy_sec := glide_sec + _rest_duration(sender_peer_id)   # ACTION window (rest default 0 in v0.8.0)
	var slide_sec := _slide_fraction() * glide_sec        # visible tween: fraction of the glide term

	# Pipelined accept: the mover is mid-glide, so this step is committed NOW (occupancy swaps one
	# step deeper, exactly as the conga branch below) but its broadcast — and its AoO scan — are
	# held to the completion boundary (_finish_glide promotes the slot). No _gliding write and no
	# timer here: the current glide's timer owns the boundary. The debug print is the only stdout
	# trace of a deferred accept (the broadcast that would otherwise log it fires a step later).
	if is_pipelined:
		_occupied.erase(from)
		_occupied[to] = sender_peer_id
		# Accepted glide → face the glide direction (v0.11.0 facing, mutation rule: accepted verdict only).
		_facing[sender_peer_id] = dir
		# Both stamped windows travel in the slot: slide_sec for the deferred broadcast/tween,
		# busy_sec for the completion timer the promotion arms (the action window carries through the pipe).
		_pending[sender_peer_id] = { "from": from, "to": to, "slide_sec": slide_sec, "busy_sec": busy_sec }
		if OS.is_debug_build():
			print("[MoveReferee] pipelined accept peer=%d %s→%s" % [sender_peer_id, from, to])
		return { "ok": true, "deferred": true }

	# Attack of opportunity (DESIGN §2.2.6): starting a glide OUT of a tile grants a free attack to
	# each hostile adjacent to the origin. Fired at verdict time, BEFORE the occupancy mutation below
	# — the mover must still be counted at `from` (§2.2.6 "starting a glide out of a tile"), and in
	# the conga branch the swap that follows erases `from` and claims `to`, which would change the
	# adjacency this scan reads. Names/damage are resolved host-side; no wire value is ever trusted.
	#
	# Chunk 2 makes AoO REAL damage in BOTH directions (decision 4): the chunk-1 player-only guard
	# is gone (monsters take AND deal AoO now), occupants resolve via _node_of_id, and the scan can
	# KILL the mover. If it does, the glide is aborted here — no occupancy mutation, no broadcast,
	# reject "dead" (Q1 placeholder: does a committed action complete post-mortem? — parked OPEN).
	if _trigger_attacks_of_opportunity(from, sender_peer_id, mover):
		return { "ok": false, "reason": "dead" }

	# Mutate occupancy and record the glide, branching on the origin-timing toggle. Both branches
	# live only here — clients never touch this state.
	var token := _next_token
	_next_token += 1
	_gliding[sender_peer_id] = { "from": from, "to": to, "token": token }
	# Accepted glide → face the glide direction (v0.11.0 facing, mutation rule: accepted verdict only;
	# set after the AoO scan so a mover killed there — cleared by clear_entity — never leaves a facing).
	_facing[sender_peer_id] = dir
	if GameManager.config.origin_frees_at_glide_start:
		# Conga: the origin frees immediately; the mover claims the destination now.
		_occupied.erase(from)
		_occupied[to] = sender_peer_id
	else:
		# Hold origin: keep it in _occupied, reserve the destination until arrival.
		_reserved[to] = sender_peer_id
	# Host-side completion fires at the END of the action window (glide + rest) — the mover holds its
	# occupancy for the whole of it, and a pending step promotes here. create_timer survives on the
	# host's tree; the stale-guard in _finish_glide ignores a fire whose glide has been superseded or
	# whose peer has left. The broadcast carries slide_sec: clients tween the shorter visible slide,
	# then sit SETTLED on the destination tile until the next step's broadcast arrives at the
	# action-window boundary — the settle is the grid tell (v0.8.0) and exists even at rest 0.
	get_tree().create_timer(busy_sec).timeout.connect(_finish_glide.bind(sender_peer_id, token))
	# Arriving window (v0.19.2): the mover is now sliding INTO `to` (occupancy already claimed it above under
	# conga). Mark it arriving and clear at slide_sec = VISUAL arrival (token-guarded), so a bump against it is
	# refused until the sprite lands. A commit_in_place (from==to) never reaches here, so no bump/wind-up is
	# wrongly gated. hold-origin (reserved, no early claim) has no early-attack gap — but marking is harmless.
	_arriving[sender_peer_id] = to
	get_tree().create_timer(slide_sec).timeout.connect(_clear_arriving.bind(sender_peer_id, token))

	return { "ok": true, "data": { "from": from, "to": to, "duration_sec": slide_sec } }


## Clear an entity's ARRIVING mark at VISUAL arrival (slide_sec), token-guarded like _finish_glide: only clear
## if the entity's CURRENT glide is still this same one. A superseded glide overwrote _arriving with its own
## (newer) destination and armed its own clear; this stale timer must NOT wipe that newer arrival, so a token
## mismatch no-ops. Death/exit erase _arriving directly, so a gone entity's stale timer also no-ops here.
func _clear_arriving(entity_id: int, token: int) -> void:
	var rec = _gliding.get(entity_id)
	if rec != null and int(rec.get("token", -1)) == token:
		_arriving.erase(entity_id)


## Compute a step's GLIDE term seconds — NOT the visible tween (that is slide_fraction of this, see
## _slide_fraction) and NOT the busy window (glide + rest, see _rest_duration). The mover's tier beats
## (or the warned fallback), converted to seconds at the mover's RESOLVED PACE (PaceReferee.beat_sec_for
## — explore or tactical per §2.8.7, read at stamp time so an in-flight commit keeps its baked seconds),
## then the diagonal multiplier on the GLIDE portion only. The debug glidesec= override, when set,
## replaces the final glide seconds BEFORE the multiplier so a diagonal debug step still stamps override
## × multiplier — the exact mirror of the beat product it stands in for. `mover` is untyped: a Player or
## a Monster, both of which expose glide_speed (the referee reads only that); mover_id keys the pace resolve.
func _step_duration(mover, dir: Vector2i, mover_id: int) -> float:
	var glide_beats := fallback_glide_beats
	if mover.glide_speed == null:
		if not _warned_null_speed:
			push_warning("[MoveReferee] mover has no GlideSpeed — using fallback %.1f beat(s)" % fallback_glide_beats)
			_warned_null_speed = true
	else:
		glide_beats = mover.glide_speed.glide_beats
	var base := glide_beats * PaceReferee.beat_or_explore(_pace, mover_id)
	if GameManager.debug_glide_override_sec > 0.0:
		base = GameManager.debug_glide_override_sec
	if dir.x != 0 and dir.y != 0:
		base *= GameManager.config.diagonal_step_multiplier
	return base


## The REST seconds appended to every step's action window (DESIGN §2.8): move_rest_beats converted at
## the mover's RESOLVED PACE (§2.8.7 — same pace as the glide term, keyed by mover_id) via the shared
## PaceReferee.beat_or_explore policy site (the null-resolver → explore fallback lives there now, not a
## private wrapper per referee). Defaults to 0 as of v0.8.0 (the committed-rest experiment was
## answered/retired; the visible slide carries the pause now — see slide_fraction). Still a SEPARATE term
## from the glide — the diagonal multiplier does NOT scale the rest (a diagonal step glides longer but
## rests the same). Baked into busy_sec at stamp time (stamp-and-bake): a later tempo change never re-derives it.
func _rest_duration(mover_id: int) -> float:
	return GameManager.config.move_rest_beats * PaceReferee.beat_or_explore(_pace, mover_id)


## The clamped visible-slide fraction (DESIGN §2.8, v0.8.0). Read live from GameConfig and clamped
## to [0.05, 1.0] (inclusive both ends) at stamp time so a hand-edited .tres can never zero/exceed the slide. The one
## clamp site the referee stamps against (the monster brain applies the same clamp for its wake).
func _slide_fraction() -> float:
	return clampf(GameManager.config.slide_fraction, 0.05, 1.0)


## Begin a BUMP attack (host-only, decision 1+2). The idle mover moves INTO a hostile living tile:
## damage applies instantly (deterministic), then the attacker is BUSY for its swing duration via the
## shared from==to commit — NO occupancy mutation (the attacker never leaves its tile), NO glide_to
## broadcast (the returned `deferred` verdict suppresses it). CombatReferee.apply_damage posts the
## `attack` event that drives all feedback. The busy record's timer runs the existing _finish_glide,
## which promotes a differently-directed intent committed mid-swing (swing-then-move) or erases the
## record. Damage/duration come from the combat referee (stats live in ONE place); `attacker` is
## untyped so the reads duck-type across player (the only M3 bumper) and a future monster bumper.
func _begin_bump(attacker_id: int, attacker, target_id: int, target, dir: Vector2i) -> Dictionary:
	# Executed bump → the attacker faces the struck tile (v0.11.0 facing, mutation rule: accepted
	# verdict only). `dir` is the sign-vector toward the target the validator already resolved (the
	# bump IS a move-into-hostile, so dir == sign toward target). Set BEFORE apply_damage so a passive
	# reading the ATTACKER's facing sees the post-swing direction; the DEFENDER's facing is untouched
	# here (a bump never turns the victim), so backstab evaluates the victim's own last-committed facing.
	_facing[attacker_id] = dir
	# KICK vs SWING (v0.17.1, option A): a RANGED weapon (range_tiles > 0) has no melee swing, so a
	# point-blank bump is a weaponless KICK — a flat kick_damage (config), kind "kick", NO weapon graphic
	# (combat_referee suppresses the weapon stamp for a kick). A MELEE weapon keeps its swing roll_damage_of +
	# kind "bump". NOTE: range_tiles > 0 is today equivalent to "ranged" (only the bow has it) — it is the
	# kick-eligibility predicate. If a future MELEE reach weapon ever wants range_tiles > 0, gate the kick
	# on a dedicated weapon flag instead of raw range. Option D (a 1-tile knockback on the kick) slots in here.
	# Resolved FIRST (v0.17.1 review #1) so `kind` is known before fire_before_attack — a kick's observation
	# seam must see "kick", not "bump" (parity with apply_damage's ctx kind and the shoot path's "shoot").
	var weapon: WeaponType = attacker.equipped_weapon if attacker is Entity else null
	var is_kick := weapon != null and weapon.range_tiles > 0
	var kind := "kick" if is_kick else "bump"
	var damage: int = GameManager.config.kick_damage if is_kick else _combat.roll_damage_of(attacker)
	# before_attack observation seam (v0.11.0): fire the attacker's passives' read-only pre-commit hook
	# at bump ENTRY, before any damage math. Host-only (this referee is inert on clients). Delegated to
	# CombatReferee, which owns passive resolution + the ctx build; a no-passive attacker (or a monster) no-ops.
	if _combat != null:
		_combat.fire_before_attack(attacker_id, target_id, kind)
	# Anti-cheese, ordered FIRST (Tactical Zones v1, §2.8.7): a bump is the ONLY way a player attacks in
	# M3, and _begin_bump is where that attack's own window (bump_duration_of, below) is stamped. Report
	# the hostile action to the pace resolver BEFORE that stamp so the triggering swing is ITSELF a
	# tactical-pace action (no fast first swing) AND the forcing window keeps the attacker tactical for
	# a beat afterward — even against the brainless dummy (the rule is uniform). attacker_id is always a
	# player here (only players bump). TWO-SITE SPLIT (review #6): this EARLY arming exists purely for
	# stamp ORDERING (the bump window below must stamp tactical); CombatReferee.apply_damage / wind_up are
	# the UNIFORM catch-alls that arm on every player-dealt hostile action (AoO free strikes, future
	# windup weapons). Re-arming there is idempotent-by-design — each hostile action refreshes the one
	# wall-clock deadline — so the bump path arming here and re-arming in apply_damage cost nothing.
	if _pace != null:
		_pace.report_hostile_action(attacker_id)
	var duration: float = _combat.bump_duration_of(attacker)
	commit_in_place(attacker_id, duration)
	_combat.apply_damage(attacker_id, target_id, damage, kind, duration)
	return { "ok": true, "deferred": true }


## Attack-of-opportunity scan (host-only, DESIGN §2.2.6, decision 4). For each of the origin's 8
## neighbours holding a body, an alive + hostile occupant gets a REAL free attack (instant, no
## wind-up — an opportunity strike) via CombatReferee.apply_damage(kind "free"). Returns whether the
## MOVER died mid-scan so the caller can abort its glide. Mid-scan death safety: SNAPSHOT the attacker
## list before applying any damage (apply_damage mutates _occupied on a kill — never iterate + mutate),
## then apply in order, stopping the instant the mover is dead. Occupants resolve via _node_of_id, so
## a monster deals AoO and a monster mover takes it (both guards lifted from chunk 1).
func _trigger_attacks_of_opportunity(from: Vector2i, mover_peer_id: int, mover) -> bool:
	# §2.2.6 provisionally OFF via config (Jon/Jeff 2026-07-19): the spec and this scan both stand —
	# this early return IS the playtest switch. Read HOST-side (server-authoritative), so no client
	# grants itself free strikes; with AoO disabled a glide simply never triggers one (no occupancy
	# touched — the false return leaves the caller's mutation path exactly as if no hostile were near).
	if not GameManager.config.attacks_of_opportunity_enabled:
		return false
	if _combat == null:
		return false
	# Snapshot phase: collect the eligible attacker ids from CURRENT occupancy, touching nothing.
	var attackers: Array[int] = []
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if dx == 0 and dy == 0:
				continue
			var neighbor := from + Vector2i(dx, dy)
			if not _occupied.has(neighbor):
				continue
			var occupant_id: int = _occupied[neighbor]
			var occupant := _node_of_id(occupant_id)
			if occupant == null:
				continue
			# §2.2.6 "alive and able to act": a dead neighbour deals nothing.
			if not _combat.is_alive(occupant_id):
				continue
			if not occupant.is_hostile_to(mover):
				continue
			attackers.append(occupant_id)
	# Apply phase: each snapshotted attacker strikes, in order. Re-check liveness (an earlier strike
	# in this same scan could in principle have killed a later attacker), and stop once the mover
	# dies — a corpse takes no further free hits, and apply_damage already tore its state down.
	for occupant_id in attackers:
		var occupant := _node_of_id(occupant_id)
		if not is_instance_valid(occupant) or not _combat.is_alive(occupant_id):
			continue
		if not _combat.is_alive(mover_peer_id):
			return true
		var mover_died: bool = _combat.apply_damage(occupant_id, mover_peer_id, _combat.roll_damage_of(occupant), "free", 0.0)
		if mover_died:
			return true
	return false


## Completion timer callback. Stale-guard: only finalize if the peer's current glide is still the
## one this token was stamped for (a superseding glide or a disconnect/rejoin bumps the token, so
## an old timer no-ops). In the hold-origin branch the occupancy swap happens HERE.
func _finish_glide(peer_id: int, token: int) -> void:
	var rec = _gliding.get(peer_id)
	if rec == null or int(rec.get("token", -1)) != token:
		return
	# Walk-over pickup seam (v0.18.0 chunk B). THIS is the settle point: reaching here past the stale-guard
	# means peer_id's committed action window (glide + rest) has run to completion and its arrival at rec["to"]
	# is final — the honest moment a body has "landed on" a tile (occupancy is already authoritative: swapped at
	# accept under conga, or in the hold-origin branch just below). Route the arrival tile to the inventory
	# referee, which picks up any ground item there. Guarded two ways:
	#  - _inventory != null: only the HOST wired it (this whole referee is host-only; a client never reaches here).
	#  - rec["from"] != rec["to"]: EXCLUDE a commit_in_place BUSY record (a bump swing / wind-up), whose from==to
	#    is NOT a walk-over — only a real STEP onto a tile loots. This keeps pickup a movement event.
	# The inventory referee itself ignores a monster mover (negative id) and a vanished mover node. Placed at the
	# TOP so it fires for BOTH the terminal glide AND a pipelined promotion below — each conga tile the mover
	# lands on is a genuine walk-over. Commitment Rule intact: this READS the just-completed step's arrival, it
	# never cancels, interrupts, or redirects it.
	var arrival_from: Vector2i = rec["from"]
	var arrival_to: Vector2i = rec["to"]
	if _inventory != null and arrival_from != arrival_to:
		_inventory.try_pickup(peer_id, arrival_to)
	# The pending guard covers a mid-session true->false toggle flip: a pipelined accept already
	# swapped this mover's occupancy one step deeper, so running the hold-origin swap here would
	# write a SECOND _occupied entry at the finished glide's dest. With a pending slot, occupancy
	# is already authoritative — skip. (Pure false-branch sessions never populate the slot.)
	if not GameManager.config.origin_frees_at_glide_start and not _pending.has(peer_id):
		var from: Vector2i = rec["from"]
		var to: Vector2i = rec["to"]
		_occupied.erase(from)
		_reserved.erase(to)
		_occupied[to] = peer_id
	# Boundary of the just-finished glide. A held next step (pipelined accept) is promoted to a
	# live glide and broadcast HERE — keyed on _pending.has alone, never a config re-check, so a
	# mid-session toggle flip can't strand a held slot. Occupancy was already swapped at accept;
	# only the AoO scan, the _gliding record, the completion timer, and the broadcast run now.
	if _pending.has(peer_id):
		var slot: Dictionary = _pending[peer_id]
		_pending.erase(peer_id)
		var from: Vector2i = slot["from"]
		var to: Vector2i = slot["to"]
		var slide_sec: float = slot["slide_sec"]
		var busy_sec: float = slot["busy_sec"]
		# Re-resolve the mover: exit cleanup erases the slot, so a live pending slot should always
		# have a live node — a miss is a real invariant break, worth a log line, never a silent
		# no-op. Erase the stale _gliding record and bail defensively. The slot holds players AND
		# monsters (chase parity, v0.9.3), so resolve UNTYPED through _node_of_id — the code below
		# only touches the duck-typed AoO surface (is_hostile_to), never a Player-only member.
		var mover = _node_of_id(peer_id)
		if mover == null:
			push_warning("[MoveReferee] pending slot for peer %d has no node — dropping" % peer_id)
			_gliding.erase(peer_id)
			# Self-contained cleanup: if this fired, exit cleanup did NOT run — drop the ghost's
			# occupancy too (its single entry is the pre-claimed dest) so no tile stays claimed.
			_erase_by_value(_occupied, peer_id)
			return
		# AoO fires at the moment the step actually STARTS (boundary-time adjacency — the honest
		# §2.2.6 read for a deferred step). This INVERTS the fire-before-mutation note on the idle
		# path (there the swap has not happened yet); here occupancy swapped at accept, so `from`
		# is the tile the mover is leaving right now. If the AoO KILLS the mover at this boundary,
		# apply_damage already erased its occupancy (the pre-claimed dest) and despawned it via
		# clear_entity — nothing to promote or broadcast, so bail (decision 4, boundary case).
		if _trigger_attacks_of_opportunity(from, peer_id, mover):
			_gliding.erase(peer_id)
			return
		# Promote to a live glide with a FRESH token + timer. The full _gliding record must be in
		# place BEFORE the broadcast: post_event is call_local, so on the host it re-enters the
		# event path synchronously and any handler that reads referee state must see consistent
		# truth. AoO's attack events sit at the lower seq, same relative order as the idle path.
		var next_token := _next_token
		_next_token += 1
		_gliding[peer_id] = { "from": from, "to": to, "token": next_token }
		# The promoted step's own action window (glide + rest) — the NEXT window is honoured too, so
		# a held run keeps its cadence step after step. Broadcast carries slide_sec (the visible slide).
		get_tree().create_timer(busy_sec).timeout.connect(_finish_glide.bind(peer_id, next_token))
		# Arriving window for the promoted step (v0.19.2): its VISIBLE slide starts NOW (at this promotion, not
		# at the earlier pipelined accept), so mark + clear at slide_sec exactly like the direct-accept path.
		_arriving[peer_id] = to
		get_tree().create_timer(slide_sec).timeout.connect(_clear_arriving.bind(peer_id, next_token))
		NetEvents.post_event("glide_to", { "from": from, "to": to, "duration_sec": slide_sec }, peer_id)
		return
	_gliding.erase(peer_id)


## Reverse lookup: the single tile a peer rests on in _occupied, or _NO_TILE if it has none.
## Called only for a non-gliding member, which has exactly one entry — the scan is over ≤ a
## handful of players.
func _tile_of_peer(peer_id: int) -> Vector2i:
	for tile in _occupied:
		if _occupied[tile] == peer_id:
			return tile
	return _NO_TILE


## Seed occupancy as an Entity enters its container — players AND monsters, one hook, one id space
## (positive peer ids, negative monster ids). tile and entity_id are set by Main's spawn_function
## BEFORE the node enters the tree, so both read the server-derived values here — never a
## client-supplied value, and never a _ready-time field (this hook fires pre-_ready).
func _on_entity_entered(node: Node) -> void:
	if node is Entity:
		_occupied[node.tile] = node.entity_id
		# Stamina experiment (v0.24.0): seed a full pool at enter. A monster that spawns already
		# engaged gets exactly what the tactical-entry reset would grant, so the no-transition spawn
		# case is covered by construction. Seeded even while /stamina is off (enable reseeds anyway).
		var max_points := _stamina_max_of(node.entity_id)
		_stamina[node.entity_id] = { "points": max_points, "max": max_points }
		# Passive regen (v0.24.9): arm the always-on chain at seed when the knob is live.
		start_passive_regen(node.entity_id)


## Stamina experiment (v0.24.0; bonus-shape v0.24.5; player/monster split v0.24.7): an entity's
## pool max — PLAYERS = config.stamina_max + their class bonus_stamina (0 for every shipped class
## since v0.26.0 — the graduated pool is ONE point and recovery speed is the class differentiator,
## see _regen_idle_beats_of); MONSTERS =
## config.monster_stamina_max (its own independent dial, Jon's tune-them-differently ask).
## Resolved LAZILY at every seed/reset — a mid-session /class change or knob turn lands at the
## next battle entry. Duck-typed node.get like CombatReferee._passives_of. Floor 1: a pool of 0
## would make every tactical step an exhausted crawl with no counterplay.
func _stamina_max_of(entity_id: int) -> int:
	var node = _node_of_id(entity_id)
	if node != null:
		var player_class = node.get("player_class")
		if player_class != null:
			return maxi(1, GameManager.config.stamina_max + int(player_class.bonus_stamina))
	return maxi(1, GameManager.config.monster_stamina_max)


## Sticky-swing support (v0.24.9): EVERY authoritative tile in this entity's motion record — its
## occupancy tile, plus the from/to of any in-flight glide, plus the from/to of any pipelined
## pending step. The victim's VISIBLE body always lies on/between these points, so an adjacency
## test over ALL of them can never catch something that renders outside the ring (the "hit from
## two tiles away" report: occupancy leads the visual by up to two tiles under pipelining).
func motion_tiles_of(entity_id: int) -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	var occupancy := tile_of_entity(entity_id)
	if occupancy != _NO_TILE:
		tiles.append(occupancy)
	if _gliding.has(entity_id):
		tiles.append(_gliding[entity_id]["from"])
		tiles.append(_gliding[entity_id]["to"])
	if _pending.has(entity_id):
		tiles.append(_pending[entity_id]["from"])
		tiles.append(_pending[entity_id]["to"])
	return tiles


## Per-side stamina dial reads (v0.25.0 split, Jon's overhaul): positive entity ids are players,
## negative are monsters — one boundary, seven paired dials. Every stamina read site below goes
## through these, so the side split can never drift per-site.
## ARMOR-WEIGHT idle wait (v0.26.0, Jeff's verdict 2026-07-26 — DESIGN §2.2.10): a MONSTER reads its
## one dial; a PLAYER's rest-to-recover wait is picked from its armor WEIGHT BAND, so heavier armor
## rests slower — which since v0.26.0 IS the cost of wearing it.
## v0.27.0: the band now comes from the WORN BODY ITEM (`equipped_body.armor_weight`, ItemType.ArmorWeight)
## instead of the class, because armor became a real object you can put on and take off — a knight who
## hands his chainmail away starts resting like a rogue, at the very next arm. Duck-typed `equipped_body`
## read (exactly _stamina_max_of's `player_class` pattern) resolved LIVE at every arm, never cached.
## UNARMORED shares the LIGHT dial (the lightest band is a floor, not a bonus), and so does any node with
## an empty slot or an unreadable item: the fastest recovery is the safe default, since the alternative
## would silently punish a mis-authored resource.
func _regen_idle_beats_of(entity_id: int) -> float:
	if entity_id <= 0:
		return GameManager.config.monster_regen_idle_beats
	var node = _node_of_id(entity_id)
	if node != null:
		var body = node.get("equipped_body")
		if body != null:
			match int(body.armor_weight):
				ItemType.ArmorWeight.MEDIUM:
					return GameManager.config.player_regen_idle_medium_beats
				ItemType.ArmorWeight.HEAVY:
					return GameManager.config.player_regen_idle_heavy_beats
	return GameManager.config.player_regen_idle_light_beats


func _regen_interval_beats_of(entity_id: int) -> float:
	return GameManager.config.player_regen_interval_beats if entity_id > 0 \
			else GameManager.config.monster_regen_interval_beats


func _regen_refills_full_of(entity_id: int) -> bool:
	return GameManager.config.player_regen_refills_full if entity_id > 0 \
			else GameManager.config.monster_regen_refills_full


func _passive_regen_beats_of(entity_id: int) -> float:
	return GameManager.config.player_passive_regen_beats if entity_id > 0 \
			else GameManager.config.monster_passive_regen_beats


func _refill_lockout_beats_of(entity_id: int) -> float:
	return GameManager.config.player_refill_lockout_beats if entity_id > 0 \
			else GameManager.config.monster_refill_lockout_beats


func _exhausted_step_beats_of(entity_id: int) -> float:
	return GameManager.config.player_exhausted_step_beats if entity_id > 0 \
			else GameManager.config.monster_exhausted_step_beats


func _exhausted_blocks_movement_of(entity_id: int) -> bool:
	return GameManager.config.player_exhausted_blocks_movement if entity_id > 0 \
			else GameManager.config.monster_exhausted_blocks_movement


## v0.24.3: is this entity's pool sitting at 0? (Cue bookkeeping — the exhausted event's edge reads.)
func _is_exhausted(entity_id: int) -> bool:
	var pool: Dictionary = _stamina.get(entity_id, {})
	return not pool.is_empty() and int(pool["points"]) <= 0


## v0.24.3: broadcast an exhaustion EDGE (on = show the winded cue, off = clear it) for ANY entity
## kind — this is the one stamina signal monsters also get, because a 5-beat crawl with no cue reads
## as a bug (§2.3.4). Edges only, never per-step.
## v0.26.0: the payload carries `hard_stop` — whether THIS side's 0-stamina mode refuses movement
## outright (the /winded dial) rather than crawling. Presentation splits on it: the sweat-drop now
## means ONLY "winded, cannot move", while a crawling/resting entity is told by the recovery bar +
## transparency (the stamina_recovery event). Read host-side from the same per-side dial the movement
## gate reads, so the cue can never disagree with the adjudication.
func _post_exhausted(entity_id: int, on: bool) -> void:
	NetEvents.post_event("exhausted", {
		"entity_id": entity_id, "on": on,
		"hard_stop": _exhausted_blocks_movement_of(entity_id),
	})


## Stamina experiment (v0.24.0): broadcast a PLAYER's pool state (monsters budget silently — their
## tell is the burst-pause movement itself). On-change only: called from spend, reset and each regen
## tick, never per-frame (§2.5). Negative ids return without posting.
func _post_stamina(entity_id: int) -> void:
	if entity_id <= 0 or not _stamina.has(entity_id):
		return
	var pool: Dictionary = _stamina[entity_id]
	NetEvents.post_event("stamina", {
		"entity_id": entity_id, "points": int(pool["points"]), "max": int(pool["max"]),
	})


## Stamina experiment (v0.24.0): one rest-to-recover tick. Fires first at the END of the idle wait,
## then every regen_interval_beats. A stale generation (any activity/reset/teardown since arming)
## no-ops — that guard alone enforces one chain per entity. Membership re-checked (the entity may
## have died while the timer flew). The chain re-arms itself until the pool refills.
func _stamina_regen_tick(entity_id: int, generation: int) -> void:
	if int(_stamina_generation.get(entity_id, -1)) != generation:
		return
	if not GameManager.config.stamina_enabled or not _stamina.has(entity_id):
		return
	var pool: Dictionary = _stamina[entity_id]
	if int(pool["points"]) >= int(pool["max"]):
		return
	var was_exhausted := int(pool["points"]) <= 0
	# INSTANT-REFILL mode (v0.24.9, per-side v0.25.0): the completed rest wait grants the WHOLE
	# pool in one go — one event, no trickle chain.
	if _regen_refills_full_of(entity_id):
		pool["points"] = int(pool["max"])
	else:
		pool["points"] = int(pool["points"]) + 1
	_post_stamina(entity_id)
	# Crossing OUT of exhaustion (v0.24.3): the first regained point ends the crawl — clear the cue.
	if was_exhausted and int(pool["points"]) > 0:
		_post_exhausted(entity_id, false)
	if int(pool["points"]) < int(pool["max"]):
		var interval_sec: float = _regen_interval_beats_of(entity_id) \
				* PaceReferee.beat_or_explore(_pace, entity_id)
		get_tree().create_timer(interval_sec).timeout.connect(_stamina_regen_tick.bind(entity_id, generation))


## PASSIVE regen chain (v0.24.9, off by default): +1 point every passive_regen_beats regardless of
## activity — deliberately generation-FREE (activity must NOT cancel it; that is its whole point)
## and guarded instead by membership + the enable checks at each fire. One chain per entity
## (_passive_regen_running); the chain dies when the knob is 0 at fire time and is re-armed for
## everyone by the /config branch when the knob turns back on.
func start_passive_regen(entity_id: int) -> void:
	if bool(_passive_regen_running.get(entity_id, false)):
		return
	if _passive_regen_beats_of(entity_id) <= 0.0 or not _stamina.has(entity_id):
		return
	_passive_regen_running[entity_id] = true
	var interval_sec: float = _passive_regen_beats_of(entity_id) \
			* PaceReferee.beat_or_explore(_pace, entity_id)
	get_tree().create_timer(interval_sec).timeout.connect(_passive_regen_tick.bind(entity_id))


## Host-only (v0.24.9): arm the passive chain for every tracked entity — the /config
## passive_regen_beats branch calls this so flipping the knob on mid-session reaches everyone.
func start_passive_regen_all() -> void:
	for entity_id in _stamina.keys():
		start_passive_regen(entity_id)


func _passive_regen_tick(entity_id: int) -> void:
	_passive_regen_running.erase(entity_id)
	if not GameManager.config.stamina_enabled or _passive_regen_beats_of(entity_id) <= 0.0 \
			or not _stamina.has(entity_id):
		return
	var pool: Dictionary = _stamina[entity_id]
	if int(pool["points"]) < int(pool["max"]):
		var was_exhausted := int(pool["points"]) <= 0
		pool["points"] = int(pool["points"]) + 1
		_post_stamina(entity_id)
		if was_exhausted:
			_post_exhausted(entity_id, false)
	start_passive_regen(entity_id)


## Forget an entity wholesale as its node leaves (disconnect / despawn / teardown): drop its resting
## tile, any in-flight glide, any pending slot, and any reservation, so a stale timer or a rejoin
## finds clean state. Shared by players and monsters. Both can now hold a _pending slot (chase
## parity, v0.9.3), so erasing it here is the SOLE cancel path for a monster's held step too — a
## despawned/killed monster mid-pipeline drops it cleanly. (_reserved stays a no-op under conga.)
func _on_entity_exiting(node: Node) -> void:
	if not (node is Entity):
		return
	var entity_id: int = node.entity_id
	_gliding.erase(entity_id)
	# Disconnect is the SOLE pipeline-slot cancel path (§2.2.5 amendment). Dropping the slot here
	# discards the held step; _erase_by_value(_occupied) below already reverts its pre-claimed
	# destination — a pipelined mover's single _occupied entry IS that dest (swapped at accept).
	_pending.erase(entity_id)
	_facing.erase(entity_id)
	_arriving.erase(entity_id)
	_erase_by_value(_occupied, entity_id)
	_erase_by_value(_reserved, entity_id)
	# Stamina experiment (v0.24.0): same teardown as clear_entity (idempotent re-erase is a no-op).
	_stamina.erase(entity_id)
	_stamina_generation[entity_id] = int(_stamina_generation.get(entity_id, 0)) + 1
	_last_tactical_exit_msec.erase(entity_id)
	_passive_regen_running.erase(entity_id)
	_interrupt_gen.erase(entity_id)


## Remove every tile->peer entry whose value is this peer (a peer holds at most one of each, but
## the hold-origin branch can momentarily have both an _occupied and a _reserved tile).
func _erase_by_value(dict: Dictionary, peer_id: int) -> void:
	for tile in dict.keys():
		if dict[tile] == peer_id:
			dict.erase(tile)
