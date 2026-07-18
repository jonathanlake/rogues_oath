class_name Monster
extends Entity

## A monster avatar. Holds identity (entity_id, monster_type) and the monster-specific surfaces
## (brain activation, wind-up/whiff cues); the shared presentation — sprite/labels, glide
## playback, combat cues — lives on Entity. It never adjudicates: the host's MoveReferee owns
## occupancy and outcomes, and the host-only MonsterBrain child decides this monster's intents.
## The node graph is identical on every peer (uniform replication); only the host activates the
## brain.
##
## Entity id (DESIGN §2.5, plan decision 5): monsters carry a host-assigned NEGATIVE id, so the
## referee's one occupancy space distinguishes them from players (positive peer ids) with no
## overlap. The id rides the replicated spawn config, so every peer names this node str(entity_id)
## and resolves glide events to it the same way.
##
## Movement flow is Entity.glide_to verbatim: at spawn the node sits at its tile; when the host
## broadcasts an accepted glide_to for this entity, Main calls glide_to() here on every peer and
## the LINEAR tween runs. Per the Commitment Rule there is no cancel path — glide_to only ever
## kills a tween to catch up to newer server truth, never to abort a committed step.

# ── Public state ──────────────────────────────────────────────────────────────

## This monster's authored template — display name, sprite cell, stats, speed tier. Set at spawn
## from the replicated type PATH (each peer loads the same .tres); never streamed as a resource.
var monster_type: MonsterType = null

@onready var _brain := $MonsterBrain
# Wind-up/whiff feedback (§2.3.4). Placeholder assets: pitch-shifted reuses of the two existing
# wavs (windup = bonk mid, whiff = commit_sent very low) — flagged placeholder, real SFX later.
@onready var _windup_audio: AudioStreamPlayer = $Windup
@onready var _whiff_audio: AudioStreamPlayer = $Whiff


func _ready() -> void:
	super()
	# monster_type is set at spawn before the node enters the tree, so it's readable here on
	# every peer. A missing type is a spawn-config bug; warn rather than crash on null access. The
	# name surface arrives pre-tree ("Monster" from the spawn config for a broken type), so this
	# early return just seeds the label from it and leaves it intact — never overwrites it.
	if monster_type == null:
		push_warning("[Monster] entity %d spawned with no MonsterType — using bare defaults" % entity_id)
		_name_label.text = display_name
		return
	glide_speed = monster_type.glide_speed
	var cell := monster_type.atlas_coords
	_sprite.region_enabled = true
	_sprite.region_rect = Rect2(cell.x * WorldGrid.TILE_PX, cell.y * WorldGrid.TILE_PX, WorldGrid.TILE_PX, WorldGrid.TILE_PX)
	# Nameplate is name-only, seeded from the pre-tree display_name; the HP readout rides its own
	# label under the feet, seeded from the authored max locally (max_hp is known everywhere) via
	# set_hp_display, the single formatting site. The combat referee drives updates from attack
	# events. Full HP at spawn.
	_name_label.text = display_name
	set_hp_display(max_hp, max_hp)


# ── Public methods ────────────────────────────────────────────────────────────

## Host-only: hand this monster's brain the movement + combat referees and switch it on. Called by
## Main's monster spawn path INSIDE its is_server() guard (component pattern — the parent wires the
## child). The monster owns the brain<->boundary handshake so the brain never reaches up to its
## parent: it connects its OWN glide_finished to the brain's boundary hook here. Inert on clients.
func activate_brain(referee: Node, combat: Node) -> void:
	glide_finished.connect(_brain.on_boundary)
	_brain.activate(referee, combat, entity_id)


## Hostility test (DESIGN §2.2.6, plan decision 6), read HOST-side. A monster is hostile to any
## player and never to another monster; the debug-only GameManager.all_hostile flag ORs on top so
## the AoO/combat wiring can be demoed with the harness. Symmetric with Player.is_hostile_to.
func is_hostile_to(other: Node) -> bool:
	if GameManager.all_hostile and other != self:
		return true
	return other is Player


## Telegraph feedback (§2.3.4) for a wind-up starting: a distinct yellow flash + telegraph sound,
## played on every peer from the `windup` event. This is the "slow telegraph" tell (DESIGN §2.1)
## that gives a target the window to glide off the committed tile before resolution.
func play_windup() -> void:
	_flash(Color(1.5, 1.5, 0.4))
	_windup_audio.play()


## Whiff feedback (§2.3.4): the wind-up resolved against an empty/vacated tile — a distinct
## swing-into-nothing sound (no target flash, no hit). Keeps "the attack missed" audibly separate
## from "it landed" under deterministic damage.
func play_whiff(dir: Vector2i) -> void:
	_shake(dir)
	_whiff_audio.play()
