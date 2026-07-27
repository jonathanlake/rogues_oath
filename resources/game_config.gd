class_name GameConfig
extends Resource

## Session tuning. Designer-editable per the CLAUDE.md "designer-editable by default" rule.

@export var max_players: int = 6

## The global beat (seconds) — the unit every action duration is authored against (DESIGN §2.8).
## Every gameplay resource expresses its timings as designer-editable BEAT MULTIPLES (glide_beats,
## windup_beats, recovery_beats, move_rest_beats); seconds exist only when a referee stamps a
## verdict. Seeded into GameManager.explore_beat_sec at session start; the runtime tempo knob
## (§2.8.3, future chunk) adjusts the live value from there. NOT a global tick — actions still
## start on commit and share only their unit (§2.4.1 stands).
@export var beat_sec: float = 0.25

## Tempo-knob bounds (seconds/beat) for the runtime tempo control (DESIGN §2.8.3). The host's
## set_tempo validator reads these — they are the sole authority on the knob's range and grid, so a
## designer widens/narrows the tempo band or changes its granularity HERE, no code. tempo_min_sec is
## the fastest allowed beat (smaller = faster), tempo_max_sec the slowest; tempo_step_sec is both the
## snap grid every accepted beat is quantized to AND the size of one +/- nudge. Defaults: 0.05s steps
## across [0.10, 1.00] around the 0.25 default (240 BPM), each step a clearly audible cadence change.
@export var tempo_min_sec: float = 0.10
@export var tempo_max_sec: float = 1.00
@export var tempo_step_sec: float = 0.05

## The TACTICAL beat (seconds) — the second tempo dial (DESIGN §2.8.3, v0.9.2). Stored, adjustable
## ([ / ] keys → set_tactical_tempo, or a /config preset row since v0.22.1) and displayed — and, since
## Tactical Zones v1 (§2.8.7), READ FOR STAMPING: every stamp site resolves through
## PaceReferee.beat_or_explore, which returns this beat for any entity the referee has resolved TACTICAL
## (comment corrected v0.22.1 — the old "not yet read for stamping / groundwork only" note predated that
## and had gone stale). So this is the fight tempo: lowering it speeds up glides, wind-ups, casts, stuns
## and item use in combat while explore pace is untouched.
## Its clamp/snap bounds are DELIBERATELY SHARED with the explore dial (tempo_min_sec / tempo_max_sec /
## tempo_step_sec above); when tactical earns its own band, split them here.
## Seeded into GameManager.tactical_beat_sec at session start on every peer.
## v0.27.0: default 0.50 → **0.25s** (240 BPM) — Jeff's second playtest verdict promoted the `/config 2`
## fight cadence to the shipped game, and this is that loadout's tempo row. The heavier weapon windups
## (§A of the same verdict — longsword/club 3 beats, dagger 2) are authored against THIS beat, so the two
## move together: raising the beat without shortening those windups doubles every telegraph.
@export var tactical_beat_sec: float = 0.25

## Tactical Zones v1 (DESIGN §2.8.7). FORCING WINDOW in BEATS: after a player lands a hostile action
## (its bump — including hitting the training dummy; the rule is uniform), it stays TACTICAL for this
## many tactical beats. Anti-cheese rationale: without it a player could tap an enemy and instantly
## revert to explore pace between swings, out-tempoing the fight it started. The window is measured in
## TACTICAL beats (tactical_force_beats × tactical_beat_sec seconds) so it scales with the fight's own
## cadence, not the explore dial. Spec range 2–4; default 3.0. Read HOST-side by PaceReferee.
@export var tactical_force_beats: float = 3.0

## Tactical Zones v1 (DESIGN §2.8.7). HYSTERESIS exit delay in SECONDS: once a player STOPS qualifying
## for tactical (left every bubble, no longer leashed, forcing window elapsed) it stays tactical until
## this many seconds of continuously qualifying for EXPLORE have passed. Rationale: a player skimming a
## bubble edge would otherwise flip pace every step (flicker) — this holds the last pace across the
## boundary so the switch reads as one deliberate change. A player with NO history (fresh spawn / late
## join) skips the delay and starts explore immediately. Seconds, NOT beats — it is real-time UI-feel
## smoothing, independent of either tempo dial. Default 1.5. Read HOST-side by PaceReferee.
@export var tactical_exit_sec: float = 1.5

## Tactical Zones v1 (DESIGN §2.8.7). PLAYER TACTICAL BUBBLE radius in Chebyshev tiles (v0.10.3): a
## player who is NOT directly in a fight still resolves to TACTICAL pace when within this many king-move
## tiles of a teammate who qualifies via a MONSTER source (forcing window, leash, or monster bubble).
## Rationale (Jon): "the group fights together" — a nearby ally in combat pulls you into the fight's
## cadence too. DELIBERATELY smaller than the enemy bubble (goblin 5) at default 3, so proximity to an
## engaged teammate is a tighter zone than the monster's own reach. NO CHAINING: only the monster-sourced
## teammate projects this pull — a merely-pulled or hysteresis-lingering player projects nothing, so two
## allies can't hold each other tactical forever after the fight ends (enforced by PaceReferee's two-pass
## resolve). 0 = no player pull (the bubble is disabled; only direct monster sources make a player
## tactical). Read HOST-side by PaceReferee.
@export var player_tactical_radius_tiles: int = 3

## FORCE TACTICAL PACE (v0.29.0) — a DEV/TESTING PIN, not a design dial. While true, PaceReferee resolves
## TACTICAL for EVERYONE — every player and every monster — regardless of bubbles, leashes, forcing windows
## or hysteresis, so a fight cadence can be examined without first arranging a fight. Positive polarity and
## SHIPS FALSE: off, every pace verdict is exactly the §2.8.7 machinery it has always been.
##
## SIDE EFFECT, stated out loud because it is the reason to reach for this: the STAMINA system gates on
## `is_tactical`, so pinning tactical also switches stamina on EVERYWHERE — pools spend, exhaustion and its
## recovery bar happen in an empty room. That is usually the point (it is how you look at the recovery
## presentation without a goblin), but it means this pin changes more than the beat length.
##
## Read HOST-side and LIVE at every resolve (the referee is host-only), so a `/config force_tactical_pace 1`
## or a panel toggle lands on the very next verdict — and flipping it back OFF exits through the normal
## `tactical_exit_sec` hysteresis ramp rather than snapping to explore (see PaceReferee's two guards).
@export var force_tactical_pace: bool = false

## Rest beats appended to every movement step's committed window (DESIGN §2.8/§2.2). A step is now
## 1 beat TOTAL — this defaults to 0.0. Kept as a reversible, now-ANSWERED experiment: the v0.7.0
## committed rest (go-stop-go) read as lag in feel-testing, so the pause moved out of the action
## window and into the visible slide instead (see slide_fraction). If ever re-raised, this is a
## SEPARATE term appended to the action window — the diagonal multiplier scales the glide term only,
## never this rest — so the visible slide length is unchanged and the rest extends only the settle.
## Read HOST-side by MoveReferee when it stamps a step's busy window.
@export var move_rest_beats: float = 0.0

## Fraction of a step's ACTION window that the visible slide occupies; the remainder the avatar
## stands SETTLED on the destination tile — the grid "snap" tell (DESIGN §2.8, v0.8.0). Unitless,
## so it scales with any tier's glide_beats and the diagonal multiplier automatically and can
## never exceed the window. 1.0 = no settle (continuous glide); low = teleport-y. VISUAL ONLY —
## occupancy/adjudication are unchanged (busy window is still the full action window). The referee
## ALSO clamps this at stamp time, so a hand-edited .tres can't drive it out of range.
@export_range(0.05, 1.0) var slide_fraction: float = 0.7

## Unitless duration multiplier applied to a glide's per-step time when the step is diagonal
## (DESIGN §2.2.7). Jeff's default is 2.0× — a diagonal costs twice an orthogonal step, so
## corner-cutting isn't a free shortcut. Read server-side when stamping each glide's duration.
@export var diagonal_step_multiplier: float = 2.0

## Provisional corner rule (DESIGN §2.2.7, amended 2026-07-21). A diagonal squeeze is refused for
## WALLS only when BOTH flanks are walls (a single wall corner may be rounded); this toggle governs
## bodies: when true, EITHER occupied flank also blocks the diagonal. Default false (Jeff: bodies
## don't block) — a playtest toggle, flip without touching code.
@export var bodies_block_corners: bool = false

## Provisional Q4 origin-tile timing (DESIGN Part 4 Q4). When true, the tile a player departs
## frees the instant the glide STARTS (conga-line movement — Jeff leans this); when false, the
## origin stays held until the glide finishes. A playtest toggle, flip without touching code.
@export var origin_frees_at_glide_start: bool = true

## Provisional playtest toggle (DESIGN §2.2.6): attacks of opportunity — a hostile adjacent to a
## tile a mover glides OUT of gets a free strike. Default true = the ORIGINAL shipped behavior (AoO
## on); resources/game_config.tres ships it false for the v0.6.0 rhythm experiment (Jon/Jeff wire
## notes, 2026-07-19 — "toggle it, don't remove it"). Read HOST-side in MoveReferee's AoO scan, so
## no client can grant itself free strikes; the §2.2.6 spec and code both stand — this parks the
## mechanic, nothing more. Flip in the .tres, no code.
@export var attacks_of_opportunity_enabled: bool = true

## STAMINA (v0.24.0 as "movement points", renamed v0.24.1; GRADUATED to a core engine rule by
## Jeff's verdict 2026-07-26 — DESIGN §2.2.10 is no longer an experiment).
## Battle-only movement budget: while an entity's pace resolves tactical, each accepted glide spends
## 1 stamina; at 0 the step still COMMITS but as an exhausted CRAWL (exhausted_step_beats below) —
## never a hard stop (Jon, v0.24.1). Pool resets to max on each tactical ENTRY. Bumps, wind-ups and
## attacks never spend (attacking is not moving). Read HOST-side only (MoveReferee). The /stamina
## dev command survives as the DEV ESCAPE HATCH (off = exactly pre-stamina movement), not as the
## experiment's revert switch.
##
## THE GRADUATED SHAPE (v0.26.0): ONE point per side — a tactical step is a single decision that
## costs your whole budget, and what varies is how fast you get it back (the armor-weight idle dials
## below). That is why the pips are hidden at max 1 (hud.gd) and the recovery bar / transparency
## carries the read instead: the question stopped being "how many steps left" and became "am I
## ready yet".
@export var stamina_enabled: bool = true

## PLAYER stamina baseline (v0.24.7 split — monsters have their own dial below): players get this
## plus their class's bonus_stamina (0 for every shipped class since v0.26.0 — the rogue's +1 was
## dropped when the pool became binary). `/config stamina_max 5` live; pools re-resolve at the next
## battle entry (or a /stamina off/on for an immediate reseed). Raise above 1 and the HUD pips
## return automatically.
@export var stamina_max: int = 1

## MONSTER stamina pool (v0.24.7, Jon: "tune players and enemies differently") — every monster's
## max, independent of the player dial above. `/config monster_stamina_max N` live. Lower = enemies
## gas out first (kiters get caught sooner); higher = tireless pursuers.
@export var monster_stamina_max: int = 1

## The exhausted CRAWL (v0.24.1, Jon: "still able to move, just very slow"; split v0.25.0): a
## tactical step taken at 0 stamina commits at THIS many beats per tile instead of the mover's
## normal tier — the Commitment Rule does the punishing. Diagonals still carry the multiplier.
@export var player_exhausted_step_beats: float = 5.0
@export var monster_exhausted_step_beats: float = 5.0

## STICKY SWING (v0.24.8 experiment, Jon: "swings still land if the target moved but is still
## directly around the swinger"): when a melee wind-up resolves and its committed tile holds no
## reachable hostile, the INTENDED victim is still hit if it merely sidestepped — alive, hostile, and
## its whole motion record Chebyshev-adjacent to the attacker. Escaping beyond adjacency still dodges;
## ground-aimed windups keep pure tile commitment; symmetric for players and monsters. This deliberately
## bends "commits to ground, not to a name" (DESIGN §2.3) INSIDE the §2.2.10 experiment — the
## kiting-thread fix in its adjacency form.
##
## RESTORED AS THE DEFAULT (v0.29.0): **false → true**, and the toggle now means strictly LESS than it
## used to. Its v0.27.0 retirement was a workaround for a bug that lived somewhere else. Jeff's report
## was "attacks landing from two tiles away" (illegible, §2.3.4) — but that came out of the PRIMARY,
## always-on ground-commit branch, where a victim GLIDING INTO the committed tile owned it from the
## moment the glide was accepted while its body was still two tiles out. Turning this dial off never
## fixed that; it only removed the follow-the-mover catch that was never the cause. v0.29.0 fixes it at
## the root instead: CombatReferee._resolve_windup now applies the full motion-record reach test to the
## PRIMARY branch too, unconditionally, so **"never hit from two tiles away" is referee behavior, not a
## setting** (see _motion_within_reach). With that guarantee independent of this flag, the flag governs
## exactly one thing:
##   TRUE  (default) — the swing FOLLOWS the intended victim to a tile still adjacent to the swinger.
##   FALSE           — strict tile-only commitment: step off the committed tile and the swing whiffs.
## The v0.27.0 blink caveat stands and is unchanged: teleport_entity wipes the motion record, so a
## Shadow-Stepped victim's record is just its DESTINATION — with this on, a blink that lands adjacent can
## still be caught. `/config swing_catches_adjacent 0` restores pure ground commitment live.
@export var swing_catches_adjacent: bool = true

## WHIFF RECOVERY BEATS (v0.32.0) — DESIGN §2.3.9, now a DIAL rather than a toggle. How much of its
## committed recovery tail a WHIFFED swing / ability / smite actually pays. Replaces v0.28.0's
## `whiff_pays_recovery` bool, whose two settings are still reachable as the two endpoints:
##
##   -1.0  (THE DEFAULT) — the whiff pays its FULL committed tail. The old TRUE, and the pre-v0.26.0
##                         behavior Jeff asked to have back: the window plays out untouched, the whiff
##                         event carries the real `recovery_sec` in `duration_sec`, and every peer shows
##                         the spent-recovery tint + green bar for it. The busy record is not touched.
##    0.0                — released at resolve. The old FALSE (v0.26.0/v0.27.x "recovery only on
##                         contact"): MoveReferee.finish_busy_early runs now, the event stamps
##                         `duration_sec` 0.0, and `busy_released` wakes a whiffing monster in the frame.
##    N > 0              — the PARTIAL tail Jon asked for: the whiff pays `min(N × the attacker's
##                         RESOLVED beat, recovery_sec)` and the REMAINDER is released early (via
##                         MoveReferee.release_busy_after). Capped at the full tail on purpose — a dial
##                         can lengthen nothing; a value past the weapon's own recovery is just "full".
##                         In BEATS, not seconds, so the number means the same at either pace: it is
##                         stamped through the attacker's own resolved beat (§2.8.7), exactly as
##                         `recovery_beats` is.
##
## -1 as the "full" sentinel rather than a second bool: it keeps the whole answer in ONE dial (a bool
## plus a number would let the two disagree, and the panel would show a live number that does nothing),
## and it makes the ONLY negative value mean the ONLY qualitatively different rule. Read HOST-side at
## each whiff resolve, so `/config whiff_recovery_beats 2` changes the very next miss with no restart.
##
## Bow shots have NO whiff concept and are untouched by this dial (a loosed arrow's tail never releases
## early — see CombatReferee's note at the shoot commit).
@export var whiff_recovery_beats: float = -1.0

## HARD-STOP mode (v0.24.6, the `/winded` dev command; split v0.25.0): when true, 0 stamina on
## that side means NO moving at all (distinct "winded" reject) instead of the crawl. `/winded`
## stays the convergent recovery toggle: it reads the PLAYER field and sets BOTH sides to its
## negation, so a GUI-diverged pair snaps back together. Rooted movers still rest-regen.
##
## DEFAULT ON since v0.27.0 (Jeff's second playtest verdict, BOTH sides): at max 1 the crawl was the
## soft answer to a binary budget — you always still got to move, just slowly — and Jeff wanted the
## spend to actually gate the step. The crawl machinery stays behind `/winded` (and the per-side
## `/config` fields) so the softer shape is one keystroke away. NOTE the presentation pairing: the
## sweat-drop cue now marks the CRAWL, not the hard stop (§2.2.10 / main.gd _handle_exhausted_event) —
## a hard-stopped entity reads through its recovery bar + the distinct "winded" reject instead.
@export var player_exhausted_blocks_movement: bool = true
@export var monster_exhausted_blocks_movement: bool = true

## RECOVERY LOCKS ACTIONS (v0.28.0, Jeff's third batch: "try not allowing the player or the enemy to
## do any actions when your stamina is recovering from a move") — DESIGN §2.2.10. While an entity sits at
## ZERO stamina in TACTICAL pace (the green recovery bar showing), every NON-MOVEMENT action is refused
## with the distinct `recovering` reject: a bump attack, an ability, a shot, a drink, an equip, a pickup.
## Host-side only, gated exactly where the STUN gate sits in each validator — it is a gate on STARTING a
## new action, never a cancel of one in flight (§2.1 is untouched).
##
## SCOPE: NON-MOVEMENT ONLY. Movement at 0 stamina stays the winded/crawl dials' business
## (player_/monster_exhausted_blocks_movement above), so the two channels stay independently toggleable:
## `/winded 0` + this ON = crawl freely but cannot attack; `/winded 1` + this OFF = frozen in place but
## may still swing. They are not orthogonal CONDITIONS (both fire off the same 0-stamina signal) — they
## are two CHANNELS over one condition, each with its own dial.
##
## `stamina_enabled 0` makes this a NO-OP (it is the predicate's first term), so "default ON" means "on
## whenever the stamina system itself is on". `/config recovery_locks_actions 0` reverts live.
@export var recovery_locks_actions: bool = true

## Rest-to-recover stamina regen (Jon, 2026-07-25; SPLIT per side v0.25.0 — every stamina dial
## below comes as a player_/monster_ pair so the two sides tune independently, Jon's overhaul ask):
## regen BEGINS only after this many consecutive beats with no movement and no committed action;
## any activity restarts the clock. Beats at the entity's resolved pace.
##
## ARMOR-WEIGHT GRADUATION (v0.26.0): the PLAYER idle wait is no longer one number — it is picked
## from the mover's ARMOR WEIGHT band, so heavier armor rests slower. The lightest dial covers BOTH
## UNARMORED and LIGHT (an unarmored wearer is not faster than a leather one — the floor is the same);
## a player with an empty or unreadable slot also reads it.
## v0.27.0 moved the band OFF the class and onto the WORN BODY ITEM (`ItemType.armor_weight`) — armor is
## an object now, so the band changes when you take it off, not when you change class. v0.27.1 routes the
## read through the ONE resolver, `Player.worn_armor_weight()`.
## Resolved HOST-side per arm in MoveReferee._regen_idle_beats_of — never cached, so an EQUIP (or a
## /class loadout swap, which reconciles the body slot) lands at the next arm.
## (Jeff 2026-07-26; units pending Jeff confirmation — he tuned beat-denominated panel dials)
@export var player_regen_idle_light_beats: float = 2.5
## (Jeff 2026-07-26; units pending Jeff confirmation — he tuned beat-denominated panel dials)
@export var player_regen_idle_medium_beats: float = 3.0
## (Jeff 2026-07-26; units pending Jeff confirmation — he tuned beat-denominated panel dials)
@export var player_regen_idle_heavy_beats: float = 3.5
## Monsters wear no class, so they keep ONE idle dial — deliberately equal to the heavy band, the
## slowest a player can rest (Jeff 2026-07-26; units pending Jeff confirmation — he tuned
## beat-denominated panel dials).
@export var monster_regen_idle_beats: float = 3.5

## Once regenerating, one stamina point returns every this-many beats (pips refill visibly)
## until max or until the next activity cancels the regenerative state. MOOT at max 1 (v0.26.0):
## the first tick already fills the pool, so this only bites if a dial is raised above 1 — kept
## live-tunable for exactly that case, not deleted.
@export var player_regen_interval_beats: float = 4.0
@export var monster_regen_interval_beats: float = 4.0

## INSTANT-REFILL mode (v0.24.9): when true, the moment the rest wait completes, the WHOLE pool
## refills at once — no per-point trickle (the interval dial is then unused for that side).
@export var player_regen_refills_full: bool = false
@export var monster_regen_refills_full: bool = false

## PASSIVE regen (v0.24.9, OFF by default at 0): when > 0, that side regains one stamina point
## every this-many beats NO MATTER WHAT it is doing — moving, attacking, anything. Independent of
## (and stacking with) the rest-to-recover regen above.
@export var player_passive_regen_beats: float = 0.0
@export var monster_passive_regen_beats: float = 0.0

## Refill lockout (v0.24.3, the pace-flicker fix; split v0.25.0): a tactical re-entry within this
## many EXPLORE beats of the last tactical exit keeps its current pool instead of refilling —
## brief pace flaps mid-fight are not "a new battle". 0 = refill on every entry.
@export var player_refill_lockout_beats: float = 20.0
@export var monster_refill_lockout_beats: float = 20.0

## GOBLIN BANTER (v0.24.4): overhead one-liners at pivotal moments, host-picked and broadcast (see
## world/banter.gd). The line ARRAYS below are the authoring surface — rewrite goblin dialogue here
## or in the .tres, never in code. Empty array = that moment is silent.
@export var banter_enabled: bool = true
## Per-bark chance (0-1) for the think-moment barks; the ally-died revenge bark always fires
## (cooldown permitting) — that one is the marquee moment.
@export var banter_chance: float = 0.6
## Global minimum gap between ANY two barks (wall-clock seconds) — five goblins latching at once
## must not produce a wall of text. One room, one voice at a time.
@export var banter_cooldown_sec: float = 2.5

## EARSHOT in TILES (v0.27.1) — how far a bark's REACTION can travel: only monsters who could
## plausibly have heard the moment react to it. CHEBYSHEV distance, measured HOST-side from
## authoritative occupancy (never a rendered position), between the moment's origin and the would-be
## speaker. Two consumers, both reactions rather than initiations:
##   ally_died / notable_death — the mourner must be within earshot of the DEAD monster's tile
##                               (CombatReferee._pick_living_monster_excluding), and
##   help_me                   — the screamer needs an ENGAGED ally within earshot of ITSELF
##                               (MonsterBrain.notify_attacked).
## Before this, both were scoped by ENGAGEMENT alone, which answers "is a fight happening somewhere"
## rather than "is this MY fight" — with three authored packs in separate rooms and a party that splits
## up, that produced cross-fight barks. 12 tiles is roughly a room and a bit; 0 or less makes the two
## reactions silent (a legitimate "off" setting).
@export var banter_earshot_tiles: int = 12
@export var banter_engaged: Array[String] = [
	"fresh meat!", "intruders!", "get 'em!!", "who goes there?!",
	"oi! trespassers!", "supper walked in!"]
@export var banter_retarget: Array[String] = [
	"you're next!", "one down...", "heh heh heh.", "next!", "who's brave now?"]
@export var banter_last_stand: Array[String] = [
	"I ain't scared o' you!", "come on then!", "for the warren!!",
	"come on then, ALL o' you!"]
@export var banter_cornered: Array[String] = [
	"back off!", "stay away!!", "no no no no", "no closer!"]
@export var banter_ally_died: Array[String] = [
	"you'll pay for that!", "murderers!!", "avenge!!", "no... NO!",
	"that was my mate!!"]

## NOTABLE DEATH (v0.27.0): fires INSTEAD of banter_ally_died when the dying monster's type carries
## MonsterType.banter_notable (the three shamans) — the pack loses the thing keeping it alive, so it
## gets its own, louder reaction. Forced past the chance roll like the ally-died bark.
@export var banter_notable_death: Array[String] = [
	"the shaman's DOWN!!", "who heals us now?!", "not the shaman — NOT THE SHAMAN!",
	"we're meat now.", "run! RUN!"]
## FORCED MELEE (v0.27.0): a caster that would rather be kiting had to swing a club instead — the
## utility AI picked melee for a flees_players monster. Chance-gated (it happens a lot in a small room).
@export var banter_forced_melee: Array[String] = [
	"get OFF me!", "I don't DO clubs!", "fine! FINE!", "this is not my job!",
	"hands off, worm!"]
## IDLE (v0.27.0): rare out-of-combat muttering on a 15-30s randomized per-monster timer, gated on the
## monster NOT being in a fight. The normal chance + global cooldown make it genuinely occasional.
@export var banter_idle: Array[String] = [
	"...I'm hungry.", "boring.", "whose turn to watch?", "smells like feet in here.",
	"I could eat a rat.", "*scratches*"]
## HELP ME (v0.27.0): a NOTABLE monster (a shaman) the moment it takes damage while its pack is still
## fighting — once per life, forced past the chance roll. The squishy caster screaming for cover.
@export var banter_help_me: Array[String] = [
	"help me, you fools!", "HELP! HELP!", "don't just STAND there!!",
	"someone DO something!", "I'm too pretty to die!"]

## FRIENDLY FIRE (v0.35.0, Jon) — the goblin archer put an arrow in a packmate. TWO moments, because a
## friendly-fire incident is a two-sided joke and one line can't carry it: the VICTIM barks first, the
## CULPRIT answers about 0.7s later, so it reads as an exchange rather than a chorus. Both are forced past
## the chance roll AND past the global cooldown (see Banter.bark's `force`) — a half-delivered exchange,
## where the victim yells and nobody owns up, is worse than silence.
##
## These fire for any allied monster-on-monster damage, not only arrows, so a future stray AoE inherits
## them for free. Player-on-player friendly fire does NOT bark: players have their own voices.
@export var banter_friendly_fire_hurt: Array[String] = [
	"you IDIOT!", "someone shot me!", "watch where you're pointing that!",
	"that's MY back!", "I'm on your SIDE, you halfwit!", "arrows go THAT way!",
	"OW! who did that?!", "we're on the same team!!"]
## The culprit's answer, posted on a short delay after the victim's line above.
@export var banter_friendly_fire_oops: Array[String] = [
	"whoops.", "my hand slipped.", "you walked into it!", "sorry! sorry.",
	"that one was free.", "stop standing in front of me!", "...didn't see ya.",
	"could've happened to anyone."]

## Monster hesitation (Jeff: "enemies think before moving"): on entering battle a monster rolls
## think beats uniformly in [min, max] (host RNG) and holds its WHOLE brain — no move, attack or
## cast — for that long, with a visible thinking cue. Beats at the monster's resolved pace.
@export var monster_think_min_beats: int = 1
@export var monster_think_max_beats: int = 6

## PACK-RALLY SHOUT REACH in TRAVEL TILES (v0.30.0, Jon + Jeff) — the ONE global dial for how far a
## monster's rally shout carries. Units: Chebyshev-EQUIVALENT travel tiles through OPEN FLOOR. It is
## not a radius: CombatReferee.rally_pack flood-fills outward from the shouter's authoritative tile
## (WorldGrid.tiles_within_travel), so **WALLS BOUND THE SHOUT** and only allies the sound can actually
## REACH are woken. In an open room a travel tile is exactly a king-step, so the number reads like the
## old radius did; around a corner it costs what walking it would cost.
##
## WHY IT REPLACED THE PER-MONSTER RADIUS: the shout used to reuse the shouter's resolved TACTICAL
## bubble (3-5 tiles), which coupled two unrelated ideas — "how far does my presence set the fight's
## pace" and "how far does my voice carry" — and, being wall-blind, it both missed the back rows of a
## big room and could pull through a wall. One global dial, wall-bounded, decouples them.
##
## DEFAULT 15 is deliberately GENEROUS: it covers the largest authored room end to end, so a shout
## wakes the room you are standing in. A shout leaking a few travel-tiles through an open doorway is
## INTENDED emergence (a wandering goblin in the room hears it) — if it over-pulls in play, this dial
## is the answer, not a new rule. 0 = NO SHOUT (the rally is off; the early return in rally_pack).
##
## The ONE-HOP contract is unchanged and independent of this number: a rallied monster never re-shouts,
## so raising this widens one fill, it can never chain a map awake. Read HOST-side and LIVE at each
## organic aggro latch (MonsterBrain._rally_pack), so `/config rally_travel_tiles 8` lands on the very
## next shout with no restart.
@export var rally_travel_tiles: int = 15

## RECKLESS SHOT CHANCE (v0.35.0, Jon: "the archer should reposition, but leave the chance for friendly
## fire") — the odds (0-1) that a bow monster with NO clean lane and NOWHERE USEFUL TO STEP looses anyway,
## straight through its own packmate. Rolled HOST-side, once, at the bottom of the archer's shoot rung
## (MonsterBrain._act_as_kiter), and only after the reposition attempt has already failed.
##
## WHY IT IS A CHANCE AND NOT A RULE: both absolutes are worse. Never shooting through an ally is what
## produced the v0.34.0 bug this dial ships with — a penned-in archer with a blocked lane had no rung left
## and simply stood still forever, which reads as a broken monster rather than a cautious one. ALWAYS
## shooting makes the lane check pointless and turns every pack fight into a self-inflicted massacre. A
## roll keeps the archer visibly trying to line up a clean shot while leaving friendly fire a real,
## recurring outcome — which is the point: it is on-brand (Jon), and it is where the friendly-fire banter
## comes from.
##
## 0 = never (the archer holds when penned in — the old behavior, minus the freeze, since the reposition
## rung above still runs). 1 = always shoot; useful for TESTING the friendly-fire banter on demand rather
## than waiting on the roll. Read LIVE at each think, so `/config archer_reckless_shot_chance 1` lands on
## the very next blocked lane with no restart.
@export var archer_reckless_shot_chance: float = 0.25

## Provisional playtest toggle (DESIGN §2.2.9): click-to-move pathing. The .tres ships it false, which
## drops MoveInput into adjacent-only click mode — a click on one of the 8 neighbor tiles submits one
## step, any farther click does nothing (Jeff: "if you click 8 spaces ahead nothing happens"). The SCRIPT
## DEFAULT is ALSO false (v0.12.0): if a config load ever fails and GameManager falls back to a fresh
## GameConfig, click pathing must stay DISARMED — with the pass-through docked HUD a stray click on a UI
## panel would otherwise commit a hidden walk. PARKED DESIGN NOTE: when this is re-enabled, MoveInput
## clicks must be gated on the HUD's world-frame rect (a click outside the play area is UI, not a move).
## Client-side INPUT convenience only: the same authored file ships in every build and the server never
## reads it for adjudication (§2.2.9's client-side framing). Jon/Jeff 2026-07-19.
@export var click_pathing_enabled: bool = false

## The hardwired weapon roster (M3.7, DESIGN §2.3.7). ONE authoring site for the swap-cycle order:
## the swap validator (main.gd) and the debug weapon= knob (debug.gd) both resolve a weapon THROUGH
## this array — by display_name for a lookup, by index for the swap toggle. Designer-editable (add /
## reorder .tres here, no code). M5's inventory acquisition REPLACES this hardwired list — until
## then swapping just cycles it. Read HOST-side for adjudication resolution; also read client-side to
## repaint a rig from a swap/sync event's weapon name.
@export var weapon_roster: Array[WeaponType] = []

## The MASTER weapon catalog (v0.17.0) — EVERY weapon a name may resolve to, whether or not it sits in a
## Tab-cycle. weapon_by_name resolves from THIS, so `weapon=bow` (and a class-roster weapon like the bow)
## resolves even though the global Tab roster above stays the shipped dagger↔longsword pair. Superset of
## every roster (global + per-class). Designer-editable; add a weapon here to make its name resolvable.
@export var weapon_catalog: Array[WeaponType] = []

## The MASTER item catalog (v0.18.0) — EVERY item a name may resolve to (the mirror of weapon_catalog for
## pickups). item_by_name resolves from THIS, so a ground-item / (future) pickup / use event's item_name
## maps back to its ItemType on every peer. Items have NO roster (there is no equip cycle to belong to — an
## item is picked up, not swapped-to), so this is the SOLE resolution source. Designer-editable; add an item
## here to make its name resolvable across the wire.
@export var item_catalog: Array[ItemType] = []

## The player BAG capacity in slots (v0.21.0) — the AUTHORITATIVE number of items a player can carry, read
## host-side by InventoryReferee (both the walk-over pickup and the manual G pickup gate on it) and client-side
## by the HUD (how many bag sockets it draws) and by Main's presentation-mirror cap. It REPLACES a three-way
## hardcoded coupling that used to carry a comment begging the next person to keep it in sync:
## InventoryReferee's `const INVENTORY_SLOTS := 5`, main.gd's literal `5` in the item_picked_up mirror, and
## hud.gd's INV_COLS. One authored value now; the coupling is gone.
##
## Default 20 = the HUD's existing 5x4 socket block, which is why 20 is FREE: the grid already draws 20
## sockets (rows 2-3 were inert decoration), so promoting all of them to real slots changes zero pixels of
## column height. Raising this ABOVE 20 adds a grid ROW, which makes the HUD column taller — and because the
## HUD picks its integer zoom `h` each layout pass to FIT that column into the window, a taller column
## literally renders the whole HUD smaller. That is the tabled fractional-`h` work, not a free knob: treat
## anything over 20 as a deliberate visual trade, not a balance tweak. The HUD clamps its read (maxi(1, ...))
## so a 0 or negative authored value can't produce a zero-row grid.
@export var inventory_slots: int = 20

## Arrows-hit-allies toggle (v0.17.0, DESIGN ranged). true (default) = an arrow STOPS at the first
## living occupant on its path, ally or enemy (friendly fire on). false = arrows PASS THROUGH allies
## everywhere, stopping only at the first hostile. Read HOST-side by CombatReferee's projectile travel;
## never the wire. A playtest toggle — flip in the .tres, no code.
@export var projectile_hits_allies: bool = true

## Point-blank KICK damage (v0.17.1, DESIGN ranged, option A). Flat damage a RANGED weapon
## (range_tiles > 0) deals when its wielder keyboard-bumps an adjacent hostile — a bow has no melee
## swing, so a point-blank bump is a desperation kick, not a slash. A MELEE weapon (range_tiles == 0)
## keeps its normal swing damage (a roll in the weapon's damage_min..damage_max band, v0.26.1) instead;
## the kick is FLAT — no band, and this value is read ONLY on the ranged-bump
## path. Deliberately low — the kick is a get-off-me poke, not a wielder's main-hand attack. Read
## HOST-side by MoveReferee._begin_bump. Option D (a knockback on the kick) is a future, separate add.
@export var kick_damage: int = 1

## INSTANT ABILITIES EXPERIMENT (v0.26.0, Jon's decision 2026-07-25 — DESIGN §2.11.1). The master
## switch for the two INSTANT class abilities: knight **Shield Block** and rogue **Shadow Step**.
## An "instant" differs from every other ability in exactly two ways — it is usable MID-ACTION
## (no busy gate), and it is gated by a per-ability COOLDOWN instead of by an occupied window.
## (v0.28.1 comment fix: that cooldown used to be "the two dials below" — v0.27.0 deleted those two
## GameConfig fields and moved the cooldown onto `ActiveAbility.cooldown_beats`; see the note under
## this export. The dangling reference outlived the dials by a release.)
##
## Both of those DELIBERATELY SUSPEND standing decisions, and only inside this toggle, pending a
## Jon+Jeff verdict:
##  - §2.1.3 "there is no active dodge, block, or escape input" — Shield Block IS a defensive input,
##    and Shadow Step INTERRUPTS the actor's OWN committed glide (the only self-interrupt in the game).
##  - Part 4 Q9 "unified occupancy — NO separate cooldowns, ever" — these two carry cooldowns.
##
## OFF = the pre-experiment game EXACTLY. Both abilities reject "instant abilities are disabled" at
## the validator, so no teleport and no block can occur; with no teleport, MoveReferee's forced-movement
## interrupt generation never moves and every downstream interrupt guard is inert by construction.
## Read HOST-side only (CombatReferee's use_ability validator) — never a client value.
@export var instant_abilities_enabled: bool = true

## (v0.27.0: the two per-ability cooldown dials that used to live here are GONE. A cooldown is now a
## field on the ABILITY resource — `ActiveAbility.cooldown_beats` — so every ability (instant AND
## strike) carries its own, tuned per `.tres` via `/ab` or the panel's CLASSES section instead of
## through two hand-written GameConfig fields that only two abilities could ever use.)

## BREAK-ON-DAMAGE for the ROOTED condition (v0.34.0 conditions framework). OFF by default, which is
## Jon+Jeff's shipped answer: a root lasts its authored beats and hitting the rooted target does not free
## it, so Entangling Roots is a reliable lock-down rather than a thing your own party accidentally
## cancels. ON = any hit that deals damage > 0 to a rooted entity clears the root immediately (its normal
## `status_expired` doubles as the "released early" cue — no second event shape).
##
## A TOGGLE rather than a decision because the two readings are both defensible and only a playtest can
## separate them: OFF makes the druid a controller (the party focuses the held target freely), ON makes
## the root a SETUP that costs you the moment you cash it in. This is the dial that answers it.
##
## FUTURE INTERACTION, recorded now so it is not discovered by surprise: nothing in the game deals
## damage-over-time yet. When something does, a DOT ticking on a rooted target would break the root on
## its first tick with this ON — i.e. the toggle would silently become "roots last one DOT tick". The
## fix at that point is to exempt the DOT damage kind here, not to re-litigate the toggle.
##
## Read HOST-side at the ONE apply_damage seam (CombatReferee), live at every hit — never a client value.
@export var root_breaks_on_damage: bool = false

## ARMOR FLAT REDUCTION per weight band (v0.27.0, Jeff's second playtest verdict). The FLAT half of the
## two-term armor rule: a physical hit against a PLAYER is reduced by the percentage (the worn item's
## `phys_damage_reduction`) OR by this flat amount, **whichever leaves the target taking LESS** —
## `final = min(pct_result, flat_result)`. Why both: percentages do nothing against small hits (25% of a
## 2-damage club swing rounds back to 2), which is exactly where Jeff expected plate to matter, and a
## pure flat rule would trivialize big hits. Read HOST-side at the one apply_damage seam, by the band the
## worn BODY item declares (ItemType.armor_weight).
## UNARMORED is deliberately NOT a field: no armor means flat 0 (and 0%), so the seam leaves the amount
## untouched — the absence of armor must never be a source of mitigation.
## Paired with the MONSTER-DAMAGE FLOOR at the same seam: a monster's hit on a player that armor would
## reduce to 0 lands for 1 instead (Jeff's worked example — 2 damage vs chainmail: pct 2, flat 0, floored
## to 1). Enemies must always be able to hurt you.
@export var armor_flat_reduction_light: int = 1
@export var armor_flat_reduction_medium: int = 2
@export var armor_flat_reduction_heavy: int = 3

## The MASTER ability catalog (v0.27.0) — every ActiveAbility a dev-command / panel token may resolve to,
## the mirror of weapon_catalog for abilities. `ability_by_name` resolves from THIS (by display_name slug),
## which is what makes `/ab kick cooldown_beats 30` and the panel's CLASSES section possible: an ability
## lives on a class's `active_abilities`, so before this there was no by-name resolution path at all.
## NOT an authority for gameplay — the referee still reads the sender's class list (never this array) when
## it validates a use; this is purely the tuning-surface index. Designer-editable: add an ability here to
## make it name-resolvable.
@export var ability_catalog: Array[ActiveAbility] = []


# ── Weapon roster helpers ─────────────────────────────────────────────────────

## Resolve a weapon by its display_name through the CATALOG (v0.17.0), or null if absent. The single lookup
## the swap validator, the late-join weapon sync, the class-equip, and the debug weapon= knob share — the
## catalog (not a Tab roster) is the one place a weapon id maps to a resource, so any weapon in the game is
## name-resolvable regardless of which cycle it belongs to.
func weapon_by_name(name: String) -> WeaponType:
	for w in weapon_catalog:
		if w != null and w.display_name == name:
			return w
	# Fallback for a config authored without a catalog (the shipped .tres has one; this guards any
	# future/experimental GameConfig): the global Tab roster is the pre-catalog resolution source, so
	# name lookups never silently break just because the catalog was left empty.
	for w in weapon_roster:
		if w != null and w.display_name == name:
			return w
	return null

## Resolve an item by its display_name through the CATALOG (v0.18.0), or null if absent. The single lookup
## every item name-resolution shares (the /item dev command today; pickup + use in later chunks). UNLIKE
## weapon_by_name there is NO roster fallback: items have no equip roster to resolve through — the catalog
## is the one and only place an item id maps to a resource, so a name absent from item_catalog is genuinely
## unknown. First-hit resolution (a duplicate display_name silently shadows) — validate_catalogs() warns.
func item_by_name(name: String) -> ItemType:
	for it in item_catalog:
		if it != null and it.display_name == name:
			return it
	return null


## Resolve an ACTIVE ABILITY by a SLUG of its display_name through ability_catalog (v0.27.0), or null.
## SLUG, not exact match, deliberately: ability display_names are title-case with spaces ("Shield Bash")
## because they are player-facing HUD text, while a dev-command token arrives lowercased and
## space-separated tokens would split into separate args (dev_commands lowercases every arg). So both
## sides are normalized the same way — lowercase, spaces → underscores — making `/ab shield_bash …` the
## typed form and letting the debug panel submit the same slug programmatically. First-hit resolution
## like the other two catalogs.
func ability_by_name(token: String) -> ActiveAbility:
	var want := token.to_lower().replace(" ", "_")
	for a in ability_catalog:
		if a != null and a.display_name.to_lower().replace(" ", "_") == want:
			return a
	return null


## The CATEGORY of a bag / ground entry NAME (v0.21.0) — the ONE place "what kind of thing is this name" is
## answered, host-side, from the shared catalogs (never a client value, §2.5). Callers: InventoryReferee's
## autopickup gate (only POTION is walked-over into the bag; everything else needs the manual G pickup).
##
## RESOLUTION ORDER IS item_catalog FIRST, then weapon_catalog, DELIBERATELY: an ItemType carries an AUTHORED
## category, so it is the specific answer; a weapon has no category field and answers WEAPON purely by
## construction (living in weapon_catalog IS the classification). The order also deliberately MIRRORS
## hud.gd's _bag_icon_coords and main.gd's click routing, which resolve the same bag string item-first — if
## this function disagreed with them, one name could be drawn/clicked as an item but categorised as a weapon.
##
## The two catalogs are kept DISJOINT by _warn_cross_catalog_collisions(), which is a startup push_warning,
## NOT a hard failure. So a display_name authored into BOTH catalogs would resolve item-first here and could
## misclassify a weapon. That is a PRE-EXISTING ambiguity (the same collision already breaks equip-vs-use
## click routing), it warns loudly at session start, and inverting the order here would only trade it for a
## desync against _bag_icon_coords — which is worse. Documented, not changed.
##
## Returns int, NOT ItemType.Category, ON PURPOSE: -1 (unresolvable — a name in neither catalog, i.e. config
## drift or a stale mirror) is a SENTINEL that is not a valid enum member, so a Category-typed return would
## be lying about its domain. Callers compare against ItemType.Category.* explicitly; -1 matches nothing and
## therefore fails closed (no autopickup) by construction.
func category_of(item_name: String) -> int:
	var item: ItemType = item_by_name(item_name)
	if item != null:
		return item.category
	if weapon_by_name(item_name) != null:
		return ItemType.Category.WEAPON
	return -1


## The active swap ROSTER for a player of `player_class` (v0.17.0): the class's own weapon_roster when it is
## non-empty, else the GLOBAL weapon_roster fallback. The ONE resolution the swap validator + class-equip
## share, so "which weapons does THIS player cycle" is answered in exactly one place, host-side.
func active_weapon_roster(player_class: PlayerClass) -> Array[WeaponType]:
	if player_class != null and not player_class.weapon_roster.is_empty():
		return player_class.weapon_roster
	return weapon_roster

## Misconfiguration guard (v0.17.1 review #2). Every weapon that any roster (global + per-class) can
## equip MUST be name-resolvable through weapon_catalog — swap/class-equip/late-join sync all resolve a
## weapon by display_name via weapon_by_name (which reads the catalog), so a roster weapon missing from
## the catalog resolves to null on peers and desyncs SILENTLY while the host's log says success. This
## walks every roster entry and push_warnings any whose display_name the catalog can't resolve, so a
## mis-authored .tres is caught ONCE at session start (called host-side from CombatReferee.activate),
## not mid-fight. Pure diagnostic — mutates nothing. display_name is the join key on BOTH sides
## (weapon_by_name matches w.display_name), so this checks exactly what the runtime resolves.
func validate_catalog_covers_rosters() -> void:
	var rosters: Array = [weapon_roster]
	for c in class_roster:
		if c != null:
			rosters.append(c.weapon_roster)
	for roster in rosters:
		for w in roster:
			if w != null and weapon_by_name(w.display_name) == null:
				push_warning("[GameConfig] weapon '%s' is in a roster but NOT in weapon_catalog — it will resolve to null on peers and desync a swap/equip. Add it to weapon_catalog." % w.display_name)


## Duplicate-name guard (v0.18.0), the sibling of validate_catalog_covers_rosters called beside it host-side
## at session start. Both catalogs resolve by FIRST-HIT display_name (weapon_by_name / item_by_name walk the
## array and return the first match), so a SECOND entry sharing a display_name silently SHADOWS the first —
## a name would resolve to the wrong resource with no error. This walks each catalog and push_warnings any
## display_name that appears more than once, so a mis-authored duplicate is caught ONCE at startup rather
## than surfacing as a baffling "wrong weapon/item" at runtime. Pure diagnostic — mutates nothing.
func validate_catalogs() -> void:
	_warn_duplicate_names(weapon_catalog, "weapon_catalog")
	_warn_duplicate_names(item_catalog, "item_catalog")
	_warn_cross_catalog_collisions()
	_warn_inverted_damage_bands()


## Cross-catalog uniqueness guard (v0.19.x loot, GLM review). A bag entry is a display_name STRING resolved
## against BOTH catalogs — weapon_by_name for a left-click equip, item_by_name for a left-click use (a looted
## weapon and a consumable now share the inventory). A name present in BOTH catalogs is ambiguous: the HUD icon
## and the click-routing would silently pick one, so the WRONG thing gets equipped/drunk with no error. Warn
## ONCE at startup (called host-side from CombatReferee.activate beside the other catalog guards). Pure diagnostic.
func _warn_cross_catalog_collisions() -> void:
	var weapon_names: Dictionary = {}
	for w in weapon_catalog:
		if w != null:
			weapon_names[w.display_name] = true
	for it in item_catalog:
		if it != null and weapon_names.has(it.display_name):
			push_warning("[GameConfig] display_name '%s' is in BOTH weapon_catalog and item_catalog — a looted bag entry with this name is AMBIGUOUS (equip vs use). Rename one." % it.display_name)


## Authored damage-band guard (v0.26.1), the third sibling beside the duplicate/collision scans and
## called from the same host-only startup site. The roll sites TOLERATE an inverted band at runtime
## (they mini/maxi the pair, so a live `/w` retune mid-fight can never crash randi_range) — but an
## inversion baked into a `.tres` is a DESIGNER MISTAKE, not a transient: someone typed the band
## backwards and the weapon silently rolls the range they didn't author. So it warns ONCE per weapon
## at session start, loudly, instead of playing fine and reading wrong. Pure diagnostic — the roll
## still works, nothing is mutated or clamped (reject-not-clamp is the dev pipe's job, not this).
func _warn_inverted_damage_bands() -> void:
	for w in weapon_catalog:
		if w != null and w.damage_min > w.damage_max:
			push_warning("[GameConfig] weapon '%s' has damage_min %d > damage_max %d — the band is authored BACKWARDS. The referee rolls the ordered range anyway, but fix the .tres." % [w.display_name, w.damage_min, w.damage_max])


## Shared duplicate-display_name scan for one catalog (v0.18.0). `entries` is an Array of Resources each with
## a `display_name`; `catalog_name` names the catalog in the warning. Tracks the names already seen and
## push_warnings EVERY entry that repeats an earlier name (three copies of one name → two warnings — one
## per shadowed extra, so the warning count matches how many entries are unreachable via first-hit lookup).
func _warn_duplicate_names(entries: Array, catalog_name: String) -> void:
	var seen: Dictionary = {}
	for e in entries:
		if e == null:
			continue
		var name: String = e.display_name
		if seen.has(name):
			push_warning("[GameConfig] duplicate display_name '%s' in %s — first-hit resolution means the later entry is SHADOWED (never resolvable). Rename or remove the duplicate." % [name, catalog_name])
		seen[name] = true


## The next weapon in `roster` after `current` — the swap TOGGLE (cycles; a 2-weapon roster just alternates).
## An unknown / null current (not in the roster) starts at the first entry. Returns `current` unchanged when
## the roster is empty (a misconfiguration — nothing to swap to). The caller passes the active roster
## (active_weapon_roster) so the cycle honours a class loadout when one is set.
func next_weapon(current: WeaponType, roster: Array[WeaponType]) -> WeaponType:
	if roster.is_empty():
		return current
	var idx := roster.find(current)  # -1 when absent → (idx + 1) wraps to the first entry
	return roster[(idx + 1) % roster.size()]


## The authored player-class roster (v0.10.0). ONE authoring site for the classes a player may BE:
## Player._ready seeds a fresh spawn from `class_roster[spawn_index % size]` (this array IS the old
## per-slot sprite table), the /class validator resolves the requested class through class_by_name, and
## every peer maps a class_changed / sync_player_field event's name back to the same resource through it.
## Designer-editable (add / reorder .tres here, no code). Read HOST-side for adjudication resolution and
## client-side to repaint a sprite from a class event's name — the mirror of weapon_roster above.
@export var class_roster: Array[PlayerClass] = []


# ── Player-class roster helpers ────────────────────────────────────────────────

## Resolve a class by its display_name through the roster, or null if absent. The single lookup the
## /class validator, the late-join class sync, and the spawn seed share, so the roster stays the one
## place a class name maps to a resource (mirror of weapon_by_name).
func class_by_name(name: String) -> PlayerClass:
	for c in class_roster:
		if c != null and c.display_name == name:
			return c
	return null
