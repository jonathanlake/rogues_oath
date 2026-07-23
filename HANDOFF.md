# HANDOFF — v0.17.0 code-review fix pass (pending)

v0.17.0 (the bow) shipped, verified, and released. A /code-review high-effort pass then
confirmed 10 findings + 2 below-cap items. Nothing invalidates the shipped verification —
these are paths the harness matrix didn't walk. Next session: fix pass (suggest v0.17.1),
ideally on Opus (Jon's Fable weekly budget is nearly spent). Delete this file in the fix
pass's final commit.

## One DESIGN QUESTION for Jon+Jeff first
- **Bow-bump melee**: a bow-equipped player keyboard-bumping an adjacent hostile lands an
  ungated melee hit — weapon-first damage 4 (double dagger), 1.5s window, bow sprite plays
  the SLASH arc ("draw" falls into the not-stab branch of weapon_rig.play_swing). Nothing
  gates bump on range_tiles == 0; only mouse clicks reroute to shoot. Feature or bug?
  Decide before coding (if feature: author a bash animation + record in DESIGN #6; if bug:
  gate _begin_bump or damage_of on range_tiles).

## Confirmed fixes (ranked; file:line)
1. combat_referee.gd:305 — shoot accept path: add `_move_referee.set_facing` toward target
   + `fire_before_attack` (mirror wind_up:231/235). Backstab adjudicates from stale facing
   while sprites visibly turn (main.gd:811 face_toward).
2. main.gd:892 + game_config — weapon_catalog ⊉ class rosters unenforced: client
   `if weapon == null: return` silently desyncs peers/late-joiners while game_log:224
   prints success. Fix: runtime assertion catalog⊇rosters (activate/_ready push_warning)
   AND a loud warning in the null branch.
3. dev_commands.gd:194 — /class equip derefs roster[0] unguarded (null .tres slot → host
   script error mid-handler). Guard per-entry like weapon_by_name.
4. combat_referee.gd:351+392 — F5 reset leaves ghost arrows: pending loose fires post-reset
   (same-peer-id respawn defeats is_alive), in-flight _projectiles/_arrow_step cross rounds.
   Fix: round-generation int captured in timer binds + projectile records, checked at fire;
   clear _projectiles on reset (idiom exists: _next_monster_id / glide tokens).
5. dev_commands.gd:189 — /class equip busy-skip is silent (no bonk/log; class_changed still
   says success). Surface the partial outcome (sender-only line: "weapon equip skipped —
   busy; Tab to equip").
6. main.gd:813 — windup playback non-total for players: weapon unresolvable or style !=
   "draw" → no sound/visual for a committed windup (monsters have the coil fallback).
   Add a default player telegraph fallback (entity flash primitives exist).
7. game_log.gd:190 — bow draw and monster windup log the identical "winds up..." line;
   event already carries `weapon` — branch to "draws the bow..." (§2.3.4).
8. combat_referee.gd:319 — maxf(busy,windup) equal-deadline tie: commit timer (created
   first) fires before loose → pipelined move promotes before the arrow launches.
   Fix: tiny epsilon or create the loose timer before commit_in_place.
9. weapon_rig.gd:157 — play_draw/play_loose render cached _weapon; late-joiner in the 0.5s
   weapon-sync retry sees longsword art doing the bow draw. Pass the event-resolved
   WeaponType down (both events carry the name).
10. (cut by cap, trivial) pace_referee: apply_damage:158 `report_hostile_action` for a
    disconnected shooter re-creates _force_until[id] after cleanup — permanent (harmless)
    dict key. One-line: gate on is_alive.
11. (cut by cap, conventions) combat_referee.gd: the 8 new private shoot methods (278-471)
    sit in the "Public methods" section; move below the Private header (CLAUDE.md script
    order).

## Also on file (not this fix pass)
- Cleanup candidates from the review (not verified, lower value): debug.gd parse/schedule
  duplication (shoot=/click=/move=), play_draw/play_loose shared init extraction,
  _is_skipped_ally as complement of _is_stoppable, stale "CHUNK-1 STUB" comments in
  main.gd:645 + combat_referee.gd:325, weapon_by_name double loop, projectile.gd
  ITEMS_TEX/rotation constants duplication, Vector2i(0,23) magic fallback main.gd:952,
  reject reasons mixing codes and sentences, telegraph-block extraction (wind_up vs
  _validate_shoot — fixing #1 naturally leads here), per-windup weapon_by_name
  guaranteed-miss scan (early-out on empty name).
- Feel= items awaiting Jon+Jeff: bow numbers, draw readability, FF-on default, mouse-aim
  feel, windowed two-zoom verdicts, borderless-fullscreen verdict (ROADMAP parking lot has
  the F11 residual).

## Verification for the fix pass
Re-run the v0.17.0 harness matrix (scratchpad scripts verify_v0170*.ps1 pattern; shoot=,
shootwait=, weapon=, tap= knobs) + add: bow-bump scenario (keyboard move= into adjacent
hostile with bow), catalog-miss warning assertion, F5-mid-draw ghost-arrow regression
(maximize knob was TEMP — re-add if needed). Two-instance gate as always; GLM once at end
(lean: this is a fix pass).
