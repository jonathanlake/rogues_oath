class_name WeaponType
extends Resource

## Designer-editable weapon template (DESIGN §2.3.7 "add a .tres, not a script"). One WeaponType
## per weapon; a non-coder tunes a weapon's feel or adds a new one by editing / dropping a .tres
## under resources/weapons/, never by touching code. Read HOST-side for the GAMEPLAY fields when
## the combat referee adjudicates a player's attack (damage + occupied window); the ANIMATION
## fields are presentation-only and read CLIENT-side by the weapon rig on every peer.
##
## Authoring model (Godot-canonical, same as MonsterType): a .tres stores ONLY values that differ
## from the script defaults below — the editor's saver STRIPS default-equal properties on every
## save, so the defaults here ARE part of the authored surface. The defaults are longsword-like
## (today's shipped feel), so a fresh WeaponType behaves like the longsword until overridden.
##
## DOCTRINE (DESIGN §2.3.7): animation explains state. The phase fractions below are
## ANIMATION-INTERNAL slices of the stamped attack window (the referee owns the window in beats);
## gameplay NEVER reads an animation timing. Damage is instant-at-commit for windup_beats == 0 (the
## default), so the strike must LOOK simultaneous with its damage flash — startup is anticipation
## only and is capped ≤ ~0.15 (a readable pre-hit windup is what windup_beats > 0 is for, where the
## damage genuinely lands later).

# ── Identity ──────────────────────────────────────────────────────────────────

## Machine + display name for this weapon ("dagger", "longsword"). Doubles as the identity used
## everywhere: the `weapon` field on the attack/swap events, the GameConfig.weapon_roster lookup
## key, the debug weapon= knob token, and the log line ("HOST draws the longsword."). Kept
## one-word so the knob token and the log read the same.
@export var display_name: String = "longsword"

# ── Gameplay (read HOST-side by CombatReferee; never the wire) ─────────────────

## BEATS this attack OCCUPIES on the attacker's one timeline (DESIGN §2.3.7 / §2.8). The whole
## action window — there are no separate cooldowns (Part 4 Q9): the attacker is BUSY for this many
## beats and cannot act, exactly like a step reserves its beats. The referee stamps it to seconds
## at the attacker's resolved pace (beats × beat) as the bump's occupied window; the attack event
## carries that duration, so the recovery tell + the weapon rig auto-align to it. dagger 1.0,
## longsword 2.0 (the longer commitment carries a damage premium — see `damage`).
@export var attack_beats: float = 2.0

## Hit points removed per landed strike (deterministic — no to-hit roll, DESIGN §2.3 amendment).
## dagger 2 over 1 beat = 2.0 DPS; longsword 5 over 2 beats = 2.5 DPS — the longer lock carries a
## damage premium so neither trivially dominates the A/B (all Feel=-tunable in the .tres).
@export var damage: int = 5

## Telegraph BEATS between committing the attack and the damage resolving (DESIGN §2.3.7, §2.1).
## 0 = the instant strike at commit — today's default for both weapons. > 0 = the preserved
## telegraph/whiff machinery (CombatReferee.wind_up), the dial a future heavy weapon (greatsword)
## turns up, where damage genuinely lands later and a long startup_frac becomes honest. Wired 0
## this milestone; the machinery M3.5 preserved is a .tres number away. The bow's DRAW (v0.17.0) reuses
## it as the delay from commit to LOOSE (windup_beats before the arrow leaves the string).
@export var windup_beats: float = 0.0

## RANGE in tiles (v0.17.0, the ranged discriminator). 0 = a MELEE weapon (the default — dagger/longsword);
## > 0 = a RANGED weapon whose shot is validated host-side against the CLICKED tile by CHEBYSHEV distance
## (bow 7). Read HOST-side by CombatReferee's shoot validator; never the wire.
@export var range_tiles: int = 0

## Arrow flight speed in TILES PER (tactical) BEAT (v0.17.0). The referee stamps a shot's per-tile flight
## time ONCE at loose as beat_sec ÷ this, then never rescales it mid-flight (like a glide's baked seconds).
## Bigger = a faster arrow. Read HOST-side when a ranged shot looses; ignored for a melee weapon (range 0).
@export var projectile_tiles_per_beat: float = 4.0

## Sprite cell (column, row) into assets/32rogues/items.png for the flying PROJECTILE (v0.17.0),
## presentation-only — chunk 2's arrow rig windows this out of the sheet. Ignored for a melee weapon.
@export var projectile_atlas_coords: Vector2i = Vector2i(0, 23)

## Screen-space direction (DEGREES, +y DOWN, 0 = right/+x, CW positive) the PROJECTILE art natively points
## as authored in items.png (v0.17.1). The 32rogues arrow (0,23) is drawn pointing NW = -135 (the default,
## so no .tres needs to set it). Presentation-only: the projectile rotates by -deg_to_rad(this) to map the
## art's native direction onto its flight line — one per-art field because the sheet is NOT uniformly
## oriented (melee NE, arrow NW, bow SW), so no single baseline constant can be right. Ignored for melee.
@export var projectile_art_points_deg: float = -135.0

# ── Animation (presentation-only; gameplay NEVER reads these) ──────────────────

## Sprite cell (column, row) into assets/32rogues/items.png — 0-indexed, so items.txt row 1 letter
## a ("dagger") is (0, 0) and letter d ("long sword") is (3, 0). The rig's Sprite2D region is
## derived from this × WorldGrid.TILE_PX.
@export var atlas_coords: Vector2i = Vector2i(3, 0)

## Screen-space direction (DEGREES, +y DOWN, 0 = right/+x, CW positive) the WEAPON art natively points as
## authored in items.png. The DEFAULT -90 restores the pre-v0.17.2 melee presentation (the original PI/2
## baseline): the melee art NOMINALLY points NE on the sheet, but the -90 mapping is the look Jon confirmed
## reads correctly IN MOTION (v0.17.2 veto of the -45 sheet-geometry value) — this field is PRESENTATION
## TRUTH, not sheet geometry. So dagger / longsword / claw need no .tres edit; the bow art fires SW = 135
## (bow.tres overrides explicitly). Presentation-only: the rig rotates its sprite by -deg_to_rad(this) to
## map the art's native direction onto the rig's local +x. One per-weapon field because the sheet is NOT
## uniformly oriented, so no single baseline constant can be right.
@export var art_points_deg: float = -90.0

## The swing shape the rig plays (DESIGN §2.3.7). "stab" = a straight thrust toward the target
## (reach_px); "slash" = a rotational arc across the target (arc_degrees); "draw" = the bow's
## nock-and-release (v0.17.0, used by chunk 2's rig — harmless to gameplay, which never reads this). v1 vocabulary.
@export_enum("stab", "slash", "draw") var attack_style: String = "slash"

## Phase fractions of the stamped attack window (DESIGN §2.3.7). Presentation-only slices — the rig
## NORMALIZES them at playback (divides each by their sum), so they need not sum to exactly 1.0 and
## a .tres authoring error can never push a phase past the stamped window (the same defensive-clamp
## spirit as the referee's slide_fraction clamp). startup = anticipation (weapon raises/leans),
## active = the strike lands, recovery = return. Anticipation is capped early (≤ ~0.15) for
## windup_beats == 0 weapons so the strike reads simultaneous with the damage flash (§2.3.7).
@export var startup_frac: float = 0.12
@export var active_frac: float = 0.18
@export var recovery_frac: float = 0.7

## Orbit radius in PIXELS — how far out from the avatar centre the weapon sprite rides on the rig's
## radius (the rig pivots AT the avatar centre and the sprite orbits it). Bigger = the weapon sweeps
## a wider circle around the player. Read by the rig for both styles. A designer knob so there is no
## magic number in the rig.
@export var orbit_radius_px: float = 14.0

## Slash sweep in DEGREES — the total arc the weapon rotates through during the active phase of a
## "slash" (a big sweep across the target direction). Read only when attack_style == "slash".
@export var arc_degrees: float = 160.0

## Raised-telegraph angle in DEGREES the rig parks BEHIND the slash's start edge during a
## windup_beats > 0 telegraph (presentation-only; ignored at windup 0 and for stab/draw styles).
@export var windup_raise_degrees: float = 60.0

## Stab reach in PIXELS — how far the weapon thrusts toward the target during the active phase of a
## "stab" (and the forward travel of a slash, at half this). Read by the rig.
@export var reach_px: float = 12.0

## Body-language lean in DEGREES the rig rotates into during startup (the anticipation coil) for a
## "stab" (DESIGN §2.3.7, presentation-only). A designer knob so there is no magic number in the rig.
@export var lean_degrees: float = 5.0

## Recoil in PIXELS the rig pulls back during recovery — the spent-strike settle (DESIGN §2.3.7,
## presentation-only). A designer knob so there is no magic number in the rig.
@export var recoil_px: float = 3.0
